import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { Vault } from '../src/vault.ts';
import { issuePairingCode, redeemPairingCode, RateLimiter } from '../src/auth.ts';
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

test('redeemPairingCode locks out immediately on the 5th failed attempt and sanitizes device name', () => {
  const dir = mkdtempSync(join(tmpdir(), 'card-ledger-auth-'));
  try {
    const v = new Vault(dir, 'mock', randomBytes(32));
    const { code } = issuePairingCode(v);
    for (let i = 0; i < 4; i++) {
      const r = redeemPairingCode(v, 'ZZZZ-ZZZZ', 'Bad');
      assert.deepEqual(r, { ok: false, reason: 'invalid' });
    }
    const fifth = redeemPairingCode(v, 'ZZZZ-ZZZZ', 'Bad');
    assert.deepEqual(fifth, { ok: false, reason: 'locked' });
    assert.equal(v.read().pairing, undefined);

    const { code: code2 } = issuePairingCode(v);
    const ok = redeemPairingCode(v, code2, 'My\niPhone\x1b[31m');
    assert.equal(ok.ok, true);
    assert.equal(v.read().devices[0].name, 'My iPhone [31m');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
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
