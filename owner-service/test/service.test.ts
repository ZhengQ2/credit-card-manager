import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync, type ChildProcess } from 'node:child_process';
import { mkdtempSync, readFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { randomBytes, randomUUID } from 'node:crypto';

const root = resolve(import.meta.dirname, '..');
const dataDir = mkdtempSync(join(tmpdir(), 'card-ledger-test-'));
const port = 18000 + Math.floor(Math.random() * 1000);
const env = {
  ...process.env, PLAID_ENV: 'mock', DATA_DIR: dataDir, PORT: String(port), HOST: '127.0.0.1',
  VAULT_KEY: randomBytes(32).toString('base64'), MOCK_MUTATION: '1',
};
const base = `http://127.0.0.1:${port}`;
let server: ChildProcess;
let logs = '';
let auth = '';

async function call(method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
  const res = await fetch(base + path, {
    method, headers: { 'Content-Type': 'application/json', ...(auth ? { Authorization: auth } : {}), ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, body: await res.json() as any, headers: res.headers };
}

before(async () => {
  server = spawn(process.execPath, ['src/server.ts'], { cwd: root, env });
  server.stdout!.on('data', (d) => { logs += d; });
  server.stderr!.on('data', (d) => { logs += d; });
  for (let i = 0; i < 50; i++) {
    try { if ((await fetch(`${base}/v1/health`)).ok) return; } catch { /* starting */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`server did not start:\n${logs}`);
});

after(() => { server.kill(); });

function pairCode(): string {
  const out = execFileSync(process.execPath, ['src/pair.ts'], { cwd: root, env }).toString();
  return /: ([A-Z0-9]{4}-[A-Z0-9]{4})/.exec(out)![1];
}

test('rejects unauthenticated API calls and non-object JSON bodies', async () => {
  const r = await call('GET', '/v1/connections');
  assert.equal(r.status, 401);
  assert.equal(r.headers.get('cache-control'), 'no-store');
  const badJson = await fetch(`${base}/v1/pair`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: 'null',
  });
  assert.equal(badJson.status, 400);
});

test('pairing code is single use and issues a working credential', async () => {
  const code = pairCode();
  const bad = await call('POST', '/v1/pair', { code: 'ZZZZ-ZZZZ', deviceName: 'Test' });
  assert.equal(bad.status, 401);
  const ok = await call('POST', '/v1/pair', { code, deviceName: 'Test iPhone' });
  assert.equal(ok.status, 201);
  const again = await call('POST', '/v1/pair', { code, deviceName: 'Other' });
  assert.equal(again.status, 410, 'code cannot be reused');
  auth = `Bearer ${ok.body.deviceId}.${ok.body.credential}`;
  assert.equal((await call('GET', '/v1/connections')).status, 200);
});

let connectionId = '';

test('connect is idempotent by client request ID', async () => {
  const lt = await call('POST', '/v1/link-token', { country: 'US' });
  assert.equal(lt.status, 200);
  assert.match(lt.body.linkToken, /^link-mock-US-/);
  const pt = await call('POST', '/v1/dev/public-token', { country: 'US' });
  const clientRequestId = randomUUID();
  const first = await call('POST', '/v1/connections', { publicToken: pt.body.publicToken, clientRequestId, country: 'US' });
  assert.equal(first.status, 201);
  assert.equal(first.body.accounts.length, 3);
  const retry = await call('POST', '/v1/connections', { publicToken: pt.body.publicToken, clientRequestId, country: 'US' });
  assert.equal(retry.status, 200);
  assert.equal(retry.body.connectionId, first.body.connectionId);
  connectionId = first.body.connectionId;
});

async function fullSync(cursor: string | null) {
  const start = cursor;
  let resyncs = 0;
  for (;;) {
    const ids = new Map<string, any>();
    const removed: string[] = [];
    let c = start;
    let restarted = false;
    for (;;) {
      const r = await call('POST', `/v1/connections/${connectionId}/sync`, { cursor: c });
      assert.equal(r.status, 200);
      if (r.body.status === 'resync_required') { resyncs++; restarted = true; break; }
      for (const t of r.body.added) ids.set(t.id, t);
      removed.push(...r.body.removed);
      c = r.body.nextCursor;
      if (!r.body.hasMore) break;
    }
    if (!restarted) return { added: ids, removed, cursor: c, resyncs };
  }
}

test('initial sync paginates, survives a mutation, and normalizes fields', async () => {
  const r = await fullSync(null);
  assert.equal(r.resyncs, 1, 'mock throws one pagination mutation');
  assert.ok(r.added.size > 20, 'more than one page');
  const credit = [...r.added.values()].find((t) => t.originalDescription === 'PLATINUM DIGITAL ENTERTAINMENT CREDIT');
  assert.ok(credit);
  assert.ok(Number.isInteger(credit.amountMinor) && credit.amountMinor < 0);
  assert.equal(credit.currency, 'USD');
  assert.ok(!('location' in credit) && !('payment_meta' in credit), 'unused Plaid fields are dropped');

  // Repeat pull from the same starting point yields the same totals.
  const again = await fullSync(null);
  const sum = (m: Map<string, any>) => [...m.values()].reduce((s, t) => s + t.amountMinor, 0);
  assert.equal(sum(again.added), sum(r.added));

  // Incremental: a pending purchase, then the pending removal arrives with the posted record that links to it.
  const s1 = await fullSync(r.cursor);
  const pending = [...s1.added.values()][0];
  assert.equal(pending.pending, true);
  const s2 = await fullSync(s1.cursor);
  assert.deepEqual(s2.removed, [pending.id]);
  const posted = [...s2.added.values()][0];
  assert.equal(posted.pendingTransactionId, pending.id);
  assert.equal(posted.pending, false);
  // Then the issuer credit; afterwards the log is stable (repeat pulls return nothing new).
  const s3 = await fullSync(s2.cursor);
  assert.equal([...s3.added.values()][0].amountMinor, -1399);
  const s4 = await fullSync(s3.cursor);
  assert.equal(s4.added.size + s4.removed.length, 0);
});

test('disconnect revokes the Item and is idempotent', async () => {
  const d1 = await call('DELETE', `/v1/connections/${connectionId}`);
  assert.equal(d1.status, 200);
  assert.equal(d1.body.status, 'disconnected');
  const d2 = await call('DELETE', `/v1/connections/${connectionId}`);
  assert.equal(d2.body.status, 'disconnected');
  const s = await call('POST', `/v1/connections/${connectionId}/sync`, { cursor: null });
  assert.equal(s.status, 410);
});

test('vault is encrypted at rest with owner-only permissions; logs carry no secrets', () => {
  const file = join(dataDir, 'vault.mock.bin');
  assert.equal(statSync(file).mode & 0o777, 0o600);
  const raw = readFileSync(file).toString('latin1');
  assert.ok(!raw.includes('access-mock'), 'access tokens are not readable on disk');
  assert.ok(!raw.includes('devices'), 'vault JSON is not plaintext');
  assert.ok(!logs.includes('access-mock') && !logs.includes('public-mock') && !logs.includes(auth.slice(7)), 'no tokens in logs');
  assert.ok(!/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}/.test(logs.split('\n').filter((l) => l.includes(' /v1/')).join('\n')), 'ids redacted in access log');
});
