import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { Vault } from '../src/vault.ts';
import { RateLimiter } from '../src/auth.ts';
import { Accounts, AuthError, normalizeEmail } from '../src/accounts.ts';
import { MemoryStore } from '../src/store.ts';
import { LocalSealer } from '../src/sealer.ts';
import { ConsoleMailer } from '../src/mailer.ts';
import { WebhookVerifier, webhookEffect } from '../src/webhooks.ts';
import { MockPlaid } from '../src/mockPlaid.ts';
import { normalizeCreditCardBills } from '../src/plaid.ts';

test('Vault rejects truncated files and cleans up locks', () => {
  const dir = mkdtempSync(join(tmpdir(), 'card-ledger-unit-'));
  try {
    const key = randomBytes(32);
    const v = new Vault(dir, 'mock', key);
    v.update((d) => { d.devices.push({ id: 'dev-1', name: 'Phone', verifier: 'aa', createdAt: new Date().toISOString() }); });
    assert.equal(v.read().devices.length, 1);

    writeFileSync(join(dir, 'vault.mock.bin'), Buffer.from('short'));
    assert.throws(() => v.read(), /truncated/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('access tokens reject tampering, other secrets, expiry and the none algorithm', () => {
  const a = new Accounts(new MemoryStore(), new ConsoleMailer(), randomBytes(32), randomBytes(32));
  const b = new Accounts(new MemoryStore(), new ConsoleMailer(), randomBytes(32), randomBytes(32));
  const now = 1_800_000_000;
  const token = a.signAccess('user-1', 'session-1', now);
  assert.equal(a.verifyAccess(`Bearer ${token}`, now + 10)?.sub, 'user-1');
  assert.equal(b.verifyAccess(`Bearer ${token}`, now + 10), null, 'signed with another secret');
  assert.equal(a.verifyAccess(`Bearer ${token}`, now + 901), null, 'expired after 15 minutes');
  const [h, p, sig] = token.split('.');
  const forgedPayload = Buffer.from(JSON.stringify({ ...JSON.parse(Buffer.from(p, 'base64url').toString()), sub: 'user-2' })).toString('base64url');
  assert.equal(a.verifyAccess(`Bearer ${h}.${forgedPayload}.${sig}`, now + 10), null, 'payload tampering');
  const none = Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })).toString('base64url');
  assert.equal(a.verifyAccess(`Bearer ${none}.${p}.`, now + 10), null);
});

test('email normalization and per-address code throttling', async () => {
  assert.equal(normalizeEmail('  Jane.Doe@Example.COM '), 'jane.doe@example.com');
  assert.throws(() => normalizeEmail('jane@localhost'), AuthError);
  const a = new Accounts(new MemoryStore(), { sendLoginCode: async () => {} }, randomBytes(32), randomBytes(32));
  for (let i = 0; i < 5; i++) await a.startEmailSignIn('jane@example.com');
  await assert.rejects(() => a.startEmailSignIn('jane@example.com'), /too_many_codes/);
  await a.startEmailSignIn('other@example.com');
});

test('sealed tokens only open for the same owner and record', async () => {
  const sealer = new LocalSealer(randomBytes(32));
  const ctx = { purpose: 'plaid-access-token', userId: 'u1', connectionId: 'c1' };
  const sealed = await sealer.seal('access-secret', ctx);
  assert.ok(!sealed.includes('access-secret'));
  assert.equal(await sealer.open(sealed, { ...ctx }), 'access-secret');
  await assert.rejects(() => sealer.open(sealed, { ...ctx, userId: 'u2' }));
  await assert.rejects(() => sealer.open(sealed, { ...ctx, connectionId: 'c2' }));
});

test('webhook verifier checks signature, body hash, age and key', async () => {
  const mock = new MockPlaid(false);
  const verifier = new WebhookVerifier((kid) => mock.webhookVerificationKey(kid));
  const body = Buffer.from(JSON.stringify({ webhook_type: 'TRANSACTIONS', webhook_code: 'SYNC_UPDATES_AVAILABLE', item_id: 'i' }));
  assert.equal(await verifier.verify(mock.signWebhook(body), body), true);
  assert.equal(await verifier.verify(mock.signWebhook(body), Buffer.from(body.toString().replace('"i"', '"j"'))), false, 'body changed');
  assert.equal(await verifier.verify(mock.signWebhook(body, Math.floor(Date.now() / 1000) - 600), body), false, 'too old');
  assert.equal(await verifier.verify(new MockPlaid(false).signWebhook(body), body), false, 'signed by another key');
  assert.equal(await verifier.verify(undefined, body), false);
  assert.deepEqual(webhookEffect({ webhook_type: 'ITEM', webhook_code: 'USER_PERMISSION_REVOKED' }), { kind: 'revoked' });
  assert.deepEqual(webhookEffect({ webhook_type: 'ITEM', webhook_code: 'WEBHOOK_UPDATE_ACKNOWLEDGED' }), { kind: 'ignore' });
});

test('session rotation is conditional, so two refreshes with one token cannot both win', async () => {
  const store = new MemoryStore();
  await store.putSession({ id: 's', userId: 'u', tokenHash: 'h1', deviceName: 'd', createdAt: '', lastUsedAt: '', expiresAt: Date.now() + 1000 });
  assert.equal(await store.rotateSession('s', 'h1', 'h2', Date.now() + 1000), true);
  assert.equal(await store.rotateSession('s', 'h1', 'h3', Date.now() + 1000), false);
  assert.equal((await store.getSession('s'))?.prevTokenHash, 'h1');
});

test('MockPlaid US history always exceeds one page even on Jan 1', async () => {
  const mock = new MockPlaid(true);
  // Access token pinned to Jan 1 (start of month AND start of quarter).
  const token = 'access-mock-US-abc12345-2026-01-01';
  const page1 = await mock.syncTransactions(token, null);
  assert.equal(page1.added.length, 20);
  assert.equal(page1.hasMore, true, 'must paginate even on Jan 1');
  await assert.rejects(() => mock.syncTransactions(token, page1.nextCursor), /TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION/);
});

test('RateLimiter enforces window limits', () => {
  const lim = new RateLimiter(2, 60_000);
  assert.equal(lim.allow('1.2.3.4'), true);
  assert.equal(lim.allow('1.2.3.4'), true);
  assert.equal(lim.allow('1.2.3.4'), false);
  assert.equal(lim.allow('5.6.7.8'), true);
});

test('bill dates include only requested cards with valid dates and a possible payment due', () => {
  const bills = normalizeCreditCardBills([
    { account_id: 'linked', next_payment_due_date: '2028-02-29', minimum_payment_amount: 20 },
    { account_id: 'unknown-minimum', next_payment_due_date: '2028-03-01', minimum_payment_amount: null },
    { account_id: 'paid', next_payment_due_date: '2028-03-01', minimum_payment_amount: 0 },
    { account_id: 'missing-date', next_payment_due_date: null, minimum_payment_amount: 20 },
    { account_id: 'invalid', next_payment_due_date: '2027-02-29', minimum_payment_amount: 20 },
    { account_id: 'unlinked', next_payment_due_date: '2028-03-01', minimum_payment_amount: 20 },
    { account_id: null, next_payment_due_date: '2028-03-01', minimum_payment_amount: 20 },
  ], ['linked', 'unknown-minimum', 'paid', 'missing-date', 'invalid']);
  assert.deepEqual(bills, [
    { accountId: 'linked', dueDate: '2028-02-29' },
    { accountId: 'unknown-minimum', dueDate: '2028-03-01' },
  ]);
});
