import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { resolve } from 'node:path';
import { randomBytes, randomUUID } from 'node:crypto';

const root = resolve(import.meta.dirname, '..');
const port = 18000 + Math.floor(Math.random() * 1000);
const env = {
  ...process.env, PLAID_ENV: 'mock', STORE: 'memory', MAILER: 'console', PORT: String(port), HOST: '127.0.0.1',
  JWT_SECRET: randomBytes(32).toString('base64'), CODE_PEPPER: randomBytes(32).toString('base64'),
  LOCAL_SEAL_KEY: randomBytes(32).toString('base64'), MOCK_MUTATION: '1', PLAID_BILL_ALERTS: '1',
  SSM_PARAMETER_PATH: '', KMS_KEY_ID: '', PUBLIC_URL: '', VAULT_KEY: '',
};
const base = `http://127.0.0.1:${port}`;
let server: ChildProcess;
let logs = '';
let auth = '';
let refreshToken = '';

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

/** The mock mailer logs codes; read the newest one for this address. */
async function latestCode(email: string): Promise<string> {
  const masked = email.replace(/^(.).*(@.*)$/, '$1***$2');
  for (let i = 0; i < 20; i++) {
    const hits = [...logs.matchAll(/sign-in code for (\S+): (\d{6})/g)].filter((m) => m[1] === masked);
    if (hits.length) return hits[hits.length - 1][2];
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error('no code logged');
}

async function signIn(email: string) {
  const saved = auth; auth = '';
  const start = await call('POST', '/v1/auth/email/start', { email });
  assert.equal(start.status, 202);
  const r = await call('POST', '/v1/auth/email/verify', { email, code: await latestCode(email), deviceName: 'Test iPhone' });
  auth = saved;
  assert.equal(r.status, 200);
  return r.body;
}

test('rejects unauthenticated calls, forged tokens and non-object JSON bodies', async () => {
  const r = await call('GET', '/v1/connections');
  assert.equal(r.status, 401);
  assert.equal(r.headers.get('cache-control'), 'no-store');
  const forged = await call('GET', '/v1/connections', undefined, { Authorization: 'Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.x' });
  assert.equal(forged.status, 401);
  const badJson = await fetch(`${base}/v1/auth/email/start`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: 'null' });
  assert.equal(badJson.status, 400);
  const health = await call('GET', '/v1/health');
  assert.equal(health.body.apiVersion, 2);
});

test('email code signs in once, locks after five wrong attempts, and issues working tokens', async () => {
  const email = 'Owner@Example.com';
  assert.equal((await call('POST', '/v1/auth/email/start', { email: 'not-an-email' })).status, 400);
  assert.equal((await call('POST', '/v1/auth/email/start', { email })).status, 202);
  const code = await latestCode('owner@example.com');
  const wrong = code === '000000' ? '111111' : '000000';
  for (let i = 0; i < 4; i++) {
    assert.equal((await call('POST', '/v1/auth/email/verify', { email, code: wrong })).body.error, 'code_invalid_or_expired');
  }
  assert.equal((await call('POST', '/v1/auth/email/verify', { email, code: wrong })).body.error, 'code_locked');
  assert.equal((await call('POST', '/v1/auth/email/verify', { email, code })).status, 401, 'locked code no longer works');

  const tokens = await signIn('owner@example.com');
  assert.equal(tokens.user.email, 'owner@example.com');
  assert.equal(tokens.accessTokenExpiresIn, 900);
  auth = `Bearer ${tokens.accessToken}`;
  refreshToken = tokens.refreshToken;
  assert.equal((await call('GET', '/v1/me')).body.user.email, 'owner@example.com');
  const again = await call('POST', '/v1/auth/email/verify', { email, code: await latestCode('owner@example.com') });
  assert.equal(again.status, 401, 'codes are single use');
});

test('refresh rotates the token and a reused token ends the session', async () => {
  const saved = auth; auth = '';
  const r1 = await call('POST', '/v1/auth/refresh', { refreshToken });
  assert.equal(r1.status, 200);
  assert.notEqual(r1.body.refreshToken, refreshToken);
  const reuse = await call('POST', '/v1/auth/refresh', { refreshToken });
  assert.equal(reuse.body.error, 'refresh_reused');
  const dead = await call('POST', '/v1/auth/refresh', { refreshToken: r1.body.refreshToken });
  assert.equal(dead.status, 401, 'the whole session is revoked after reuse');
  auth = saved;
  const fresh = await signIn('owner@example.com');
  auth = `Bearer ${fresh.accessToken}`;
  refreshToken = fresh.refreshToken;
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

test('returns bank-provided bill dates for linked credit cards to the signed-in owner only', async () => {
  const path = `/v1/connections/${connectionId}/credit-card-bills`;
  const denied = await call('GET', path, undefined, { Authorization: '' });
  assert.equal(denied.status, 401);

  const response = await call('GET', path);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.body.status, 'available');
  assert.deepEqual(response.body.bills.map((bill: { accountId: string }) => bill.accountId), ['acc_mock_plat', 'acc_mock_aspire']);
  for (const bill of response.body.bills) {
    assert.deepEqual(Object.keys(bill).sort(), ['accountId', 'dueDate']);
    assert.match(bill.dueDate, /^\d{4}-\d{2}-\d{2}$/);
  }

  const upgrade = await call('POST', '/v1/link-token', { country: 'US', connectionId, billAccess: true });
  assert.equal(upgrade.status, 200);
  assert.match(upgrade.body.linkToken, /^link-mock-US-/);

  const missingConnection = await call('POST', '/v1/link-token', { country: 'US', billAccess: true });
  assert.equal(missingConnection.status, 400);
  assert.equal(missingConnection.body.error, 'connection_required');
});

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

test('another user cannot see or use the first user\'s connection', async () => {
  const other = await signIn('someone.else@example.com');
  const otherAuth = { Authorization: `Bearer ${other.accessToken}` };
  assert.deepEqual((await call('GET', '/v1/connections', undefined, otherAuth)).body.connections, []);
  for (const [m, path] of [['POST', `/v1/connections/${connectionId}/sync`], ['DELETE', `/v1/connections/${connectionId}`],
    ['GET', `/v1/connections/${connectionId}/credit-card-bills`]] as const) {
    const r = await call(m, path, m === 'POST' ? { cursor: null } : undefined, otherAuth);
    assert.equal(r.status, 404, `${m} ${path}`);
  }
});

test('signed Plaid webhooks update the connection; unsigned ones are rejected', async () => {
  const forged = await fetch(`${base}/v1/plaid/webhook`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ webhook_type: 'ITEM', webhook_code: 'USER_PERMISSION_REVOKED', item_id: 'x' }),
  });
  assert.equal(forged.status, 401);
  const hook = await call('POST', '/v1/dev/webhook', { connectionId, type: 'TRANSACTIONS', code: 'SYNC_UPDATES_AVAILABLE' });
  assert.equal(hook.status, 200);
  const list = await call('GET', '/v1/connections');
  assert.equal(list.body.connections.find((c: any) => c.connectionId === connectionId).updatesAvailable, true);
  await call('POST', '/v1/dev/webhook', { connectionId, type: 'ITEM', code: 'ERROR', errorCode: 'ITEM_LOGIN_REQUIRED' });
  const after = await call('GET', '/v1/connections');
  assert.equal(after.body.connections.find((c: any) => c.connectionId === connectionId).status, 'login_required');
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

test('deleting the account signs out and removes all data; logs carry no secrets', async () => {
  const pt = await call('POST', '/v1/dev/public-token', { country: 'CA' });
  const linked = await call('POST', '/v1/connections', { publicToken: pt.body.publicToken, clientRequestId: randomUUID(), country: 'CA' });
  assert.equal(linked.status, 201);
  const del = await call('DELETE', '/v1/me');
  assert.equal(del.body.deleted, true);
  assert.equal((await call('POST', '/v1/auth/refresh', { refreshToken }, { Authorization: '' })).status, 401);
  assert.equal((await call('GET', '/v1/me')).status, 401, 'profile is gone');
  const back = await signIn('owner@example.com');
  assert.deepEqual((await call('GET', '/v1/connections', undefined, { Authorization: `Bearer ${back.accessToken}` })).body.connections, [],
    'a new account with the same email starts empty');

  assert.ok(!logs.includes('access-mock') && !logs.includes('public-mock') && !logs.includes(auth.slice(7)), 'no tokens in logs');
  assert.ok(!logs.includes('owner@example.com') && !logs.includes(refreshToken), 'no emails or refresh tokens in logs');
  assert.ok(!/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}/.test(logs.split('\n').filter((l) => l.includes(' /v1/')).join('\n')), 'ids redacted in access log');
});
