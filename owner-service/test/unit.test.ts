import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { Vault } from '../src/vault.ts';
import { RateLimiter, extractClientIp } from '../src/auth.ts';
import { Accounts, AuthError, normalizeEmail } from '../src/accounts.ts';
import { MemoryStore } from '../src/store.ts';
import { DynamoStore } from '../src/dynamoStore.ts';
import { LocalSealer } from '../src/sealer.ts';
import { ConsoleMailer } from '../src/mailer.ts';
import { WebhookVerifier, webhookEffect } from '../src/webhooks.ts';
import { MockPlaid } from '../src/mockPlaid.ts';
import { PlaidApi, Products, type LinkTokenCreateRequest } from 'plaid/legacy';
import { normalizeCreditCardBills, RealPlaid } from '../src/plaid.ts';
import { maxConnections, signupMode, type Config } from '../src/config.ts';
import type { Mailer } from '../src/mailer.ts';

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

test('sealed tokens reject truncated or tampered values', async () => {
  const sealer = new LocalSealer(randomBytes(32));
  const ctx = { purpose: 'plaid-access-token', userId: 'u1', connectionId: 'c1' };
  const blob = Buffer.from((await sealer.seal('access-secret', ctx)).slice(3), 'base64');
  // IV plus a 4-byte tag and no body: a short tag must never be accepted.
  const shortTag = `l1:${blob.subarray(0, 16).toString('base64')}`;
  await assert.rejects(() => sealer.open(shortTag, ctx), /truncated/);
  const tampered = Buffer.from(blob);
  tampered[tampered.length - 1] ^= 1;
  await assert.rejects(() => sealer.open(`l1:${tampered.toString('base64')}`, ctx));
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
  await store.putSession({ id: 's', userId: 'u', tokenHash: 'h1', createdAt: '', expiresAt: Date.now() + 1000 });
  assert.equal(await store.rotateSession('s', 'h1', 'h2', Date.now() + 1000), true);
  assert.equal(await store.rotateSession('s', 'h1', 'h3', Date.now() + 1000), false);
  assert.equal((await store.getSession('s'))?.prevTokenHash, 'h1');
});

test('MockPlaid US card history always exceeds one page even on Jan 1', async () => {
  const mock = new MockPlaid(true);
  // Access token pinned to Jan 1 (start of month AND start of quarter).
  const token = 'access-mock-US-abc12345-2026-01-01';
  const page1 = await mock.syncTransactions(token, null, 'acc_mock_plat');
  assert.equal(page1.added.length, 12);
  assert.equal(page1.hasMore, true, 'must paginate even on Jan 1');
  await assert.rejects(() => mock.syncTransactions(token, page1.nextCursor, 'acc_mock_plat'), /TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION/);
});

test('new Plaid links request credit-card transactions and reserve liabilities for explicit update mode', async (t) => {
  const requests: LinkTokenCreateRequest[] = [];
  t.mock.method(PlaidApi.prototype, 'linkTokenCreate', async (body: LinkTokenCreateRequest) => {
    requests.push(body);
    return { data: { link_token: 'mock', expiration: '2026-11-19T12:00:00Z' } };
  });
  const plaid = new RealPlaid({ env: 'sandbox', billAlerts: true } as Config);
  const user = { country: 'US' as const, clientUserId: 'opaque-account-id' };
  await plaid.createLinkToken(user);
  await plaid.createLinkToken({ ...user, historyDays: 730 });
  await plaid.createLinkToken({ ...user, accessToken: 'mock-item' });
  await plaid.createLinkToken({ ...user, accessToken: 'mock-item', billAccess: true });

  assert.deepEqual(requests[0].user, { client_user_id: 'opaque-account-id' });
  assert.deepEqual(requests[0].products, [Products.Transactions]);
  assert.deepEqual(requests[0].account_filters, { credit: { account_subtypes: ['credit card'] } });
  assert.equal(requests[0].transactions?.days_requested, 365);
  assert.equal(requests[1].transactions?.days_requested, 730);
  assert.ok(requests.slice(0, 3).every((request) => !request.additional_consented_products));
  assert.deepEqual(requests[3].additional_consented_products, [Products.Liabilities]);
  assert.equal(requests[3].products, undefined);
  assert.equal(requests[3].account_filters, undefined);
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

class CapturingMailer implements Mailer {
  readonly codes = new Map<string, string>();
  async sendLoginCode(to: string, code: string) { this.codes.set(to, code); }
}

function inviteOnly() {
  const store = new MemoryStore();
  const mailer = new CapturingMailer();
  return { store, mailer, accounts: new Accounts(store, mailer, randomBytes(32), randomBytes(32), 'invite') };
}

test('invite-only sign-up sends no code and creates no account for an uninvited address', async () => {
  const { store, mailer, accounts } = inviteOnly();
  await accounts.startEmailSignIn('stranger@example.com');
  assert.equal(mailer.codes.size, 0);
  await assert.rejects(accounts.verifyEmailCode('stranger@example.com', '000000'),
    (e: AuthError) => e.code === 'code_invalid_or_expired');
  assert.equal(await store.findUserIdByEmailKey(accounts.emailKey('stranger@example.com')), null);
});

test('email sign-in returns while an invited address still has delivery in flight', async (t) => {
  let finishDelivery!: () => void;
  const delivery = new Promise<void>((resolve) => { finishDelivery = resolve; });
  const store = new MemoryStore();
  const sendLoginCode = t.mock.fn(async () => { await delivery; });
  const accounts = new Accounts(store, { sendLoginCode }, randomBytes(32), randomBytes(32), 'invite');
  await accounts.invite('invited@example.com');

  let returned = false;
  const invited = accounts.startEmailSignIn('invited@example.com').then(() => { returned = true; });
  try {
    await accounts.startEmailSignIn('uninvited@example.com');
    // Drain the request's storage awaits without completing delivery or relying on elapsed time.
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.equal(returned, true);
    assert.equal(sendLoginCode.mock.callCount(), 1);
    assert.ok(await store.getLoginCode(accounts.emailKey('invited@example.com')));
    assert.equal((await store.getLoginCode(accounts.emailKey('uninvited@example.com')))?.codeHash, '', 'counted, with no code');
  } finally {
    finishDelivery();
    await invited;
  }
});

test('the hourly code limit treats invited and uninvited addresses alike', async () => {
  const { store, mailer, accounts } = inviteOnly();
  await accounts.invite('invited@example.com');
  for (const email of ['invited@example.com', 'stranger@example.com']) {
    for (let i = 0; i < 5; i++) await accounts.startEmailSignIn(email);
    await assert.rejects(accounts.startEmailSignIn(email), (e: AuthError) => e.status === 429 && e.code === 'too_many_codes',
      `sixth request for ${email}`);
  }
  assert.deepEqual([...mailer.codes.keys()], ['invited@example.com'], 'only the invited address is emailed');
  const stranger = await store.getLoginCode(accounts.emailKey('stranger@example.com'));
  assert.equal(stranger?.codeHash, '');
  for (const guess of ['000000', '123456']) {
    await assert.rejects(accounts.verifyEmailCode('stranger@example.com', guess), (e: AuthError) => e.code === 'code_invalid_or_expired');
  }
});

test('email delivery failure is logged without disclosing recipient or provider details', async (t) => {
  const log = t.mock.method(console, 'error', () => {});
  const store = new MemoryStore();
  const mailer: Mailer = {
    async sendLoginCode(to, code) { throw new Error(`Provider rejected ${to} and ${code}`); },
  };
  const accounts = new Accounts(store, mailer, randomBytes(32), randomBytes(32));

  await accounts.startEmailSignIn('tester@example.com');
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.deepEqual(log.mock.calls.map((call) => call.arguments), [['Sign-in code email delivery failed']]);
});

test('an invite creates one account, is used up, and the account keeps signing in without it', async () => {
  const { store, mailer, accounts } = inviteOnly();
  await accounts.invite(' Tester@Example.com ');
  await accounts.startEmailSignIn('tester@example.com');
  const first = await accounts.verifyEmailCode('tester@example.com', mailer.codes.get('tester@example.com'));
  assert.ok('accessToken' in first);
  const key = accounts.emailKey('tester@example.com');
  assert.equal(await store.getInvite(key), null, 'the invite is consumed');

  mailer.codes.clear();
  await accounts.startEmailSignIn('tester@example.com');
  const again = await accounts.verifyEmailCode('tester@example.com', mailer.codes.get('tester@example.com'));
  assert.ok('accessToken' in again && again.user.id === first.user.id);
});

test('an invite removed or expired after the code was sent blocks account creation', async () => {
  const { store, mailer, accounts } = inviteOnly();
  await accounts.invite('late@example.com');
  await accounts.startEmailSignIn('late@example.com');
  await accounts.revokeInvite('late@example.com');
  await assert.rejects(accounts.verifyEmailCode('late@example.com', mailer.codes.get('late@example.com')),
    (e: AuthError) => e.status === 403 && e.code === 'invite_required');
  assert.equal(await store.findUserIdByEmailKey(accounts.emailKey('late@example.com')), null);

  const key = accounts.emailKey('expired@example.com');
  await store.putInvite({ emailKey: key, createdAt: new Date().toISOString(), expiresAt: Date.now() - 1 });
  await accounts.startEmailSignIn('expired@example.com');
  assert.equal(mailer.codes.size, 1, 'no code for an expired invite');
  assert.equal(await store.createInvitedUser(key, 'expired@example.com', Date.now()), null);
});

test('invites reject bad durations and are removed with the account', async () => {
  const { store, accounts } = inviteOnly();
  for (const days of [0, 366, 1.5, Number.NaN]) {
    await assert.rejects(accounts.invite('a@example.com', days), (e: AuthError) => e.code === 'invite_days_invalid');
  }
  const key = accounts.emailKey('a@example.com');
  const user = await store.createUser(key, 'a@example.com');
  await accounts.invite('a@example.com');
  await store.deleteUser(user.id, key);
  assert.equal(await store.getInvite(key), null);
});

test('sign-up is invite-only by default outside mock mode, and settings are validated', () => {
  assert.equal(signupMode('', 'production'), 'invite');
  assert.equal(signupMode('', 'sandbox'), 'invite');
  assert.equal(signupMode('', 'mock'), 'open');
  assert.equal(signupMode('open', 'production'), 'open');
  assert.throws(() => signupMode('Open', 'production'), /SIGNUP must be/);
  assert.equal(maxConnections(''), 10);
  assert.equal(maxConnections('3'), 3);
  for (const bad of ['0', '101', '2.5', '-1', 'ten']) assert.throws(() => maxConnections(bad), /MAX_CONNECTIONS_PER_USER/);
});

test('extractClientIp reads the rightmost proxy hop and ignores untrusted headers', () => {
  assert.equal(extractClientIp('127.0.0.1', '198.51.100.1, 203.0.113.9', true), '203.0.113.9');
  assert.equal(extractClientIp('::ffff:127.0.0.1', ['198.51.100.1', '203.0.113.9'], true), '203.0.113.9');
  assert.equal(extractClientIp('::1', '203.0.113.9', true), '203.0.113.9');
  assert.equal(extractClientIp('127.0.0.1', '198.51.100.1', false), '127.0.0.1');
  assert.equal(extractClientIp('192.0.2.5', '198.51.100.1', true), '192.0.2.5');
});

test('MemoryStore releases failed clientRequestId claims only for the owner and preserves confirmed billConsent', async () => {
  const store = new MemoryStore();
  assert.equal(await store.claimClientRequest('u1', 'req-1', 'conn-1'), 'conn-1');
  await store.releaseClientRequest('u1', 'req-1', 'other-conn');
  assert.equal(await store.claimClientRequest('u1', 'req-1', 'conn-2'), 'conn-1', 'non-owner cannot release');
  await store.releaseClientRequest('u1', 'req-1', 'conn-1');
  assert.equal(await store.claimClientRequest('u1', 'req-1', 'conn-2'), 'conn-2', 'retry reclaims after release');

  await store.putConnection({
    userId: 'u1', id: 'conn-2', itemId: 'item-1', institutionId: null, institutionName: null,
    country: 'US', accounts: [], clientRequestId: 'req-1', status: 'active', createdAt: new Date().toISOString(),
  });
  const now = Date.now();
  await store.updateConnection('u1', 'conn-2', { pendingBillConsent: { id: 'c1', expiresAt: now + 60_000 } });
  assert.equal(await store.confirmBillConsent('u1', 'conn-2', 'c1', now), true);
  assert.deepEqual((await store.getConnection('u1', 'conn-2'))?.billConsent, { id: 'c1' });
  assert.equal((await store.getConnection('u1', 'conn-2'))?.pendingBillConsent, undefined);

  // Starting a second pending Link approval keeps the confirmed billConsent intact.
  await store.updateConnection('u1', 'conn-2', { pendingBillConsent: { id: 'c2', expiresAt: now + 60_000 } });
  assert.deepEqual((await store.getConnection('u1', 'conn-2'))?.billConsent, { id: 'c1' });
});

test('DynamoStore.deleteUser fails when UnprocessedItems remain after retries', async (t) => {
  const store = new DynamoStore('test-table', 'ca-central-1') as unknown as {
    deleteUser(userId: string, emailKey: string): Promise<void>;
    db: { send(cmd: unknown): Promise<unknown> };
  };
  let batchCalls = 0;
  t.mock.method(store.db, 'send', async (cmd: { constructor?: { name?: string }; input?: Record<string, unknown> }) => {
    if (cmd.constructor?.name === 'QueryCommand') {
      const isProfile = (cmd.input?.ExpressionAttributeValues as Record<string, unknown> | undefined)?.[':v'] === 'USER#u1'
        && !cmd.input?.IndexName;
      return { Items: isProfile ? [{ pk: 'USER#u1', sk: 'PROFILE' }] : [] };
    }
    if (cmd.constructor?.name === 'BatchWriteCommand') {
      batchCalls += 1;
      return { UnprocessedItems: { 'test-table': [{ DeleteRequest: { Key: { pk: 'EMAIL#k', sk: 'USER' } } }] } };
    }
    return {};
  });
  await assert.rejects(() => store.deleteUser('u1', 'k'), /unprocessed/i);
  assert.equal(batchCalls, 5);
});
