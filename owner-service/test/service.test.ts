import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { resolve } from 'node:path';
import { createHash, generateKeyPairSync, randomBytes, randomUUID, sign } from 'node:crypto';
import { isoCBOR } from '@simplewebauthn/server/helpers';
import { URI } from 'otpauth';

const root = resolve(import.meta.dirname, '..');
const port = 18000 + Math.floor(Math.random() * 1000);
const rpID = 'ledger.example.com';
const origin = `https://${rpID}`;
const appID = 'TESTTEAM00.net.example.CardLedger';
const env = {
  ...process.env, PLAID_ENV: 'mock', STORE: 'memory', MAILER: 'console', PORT: String(port), HOST: '127.0.0.1',
  JWT_SECRET: randomBytes(32).toString('base64'), CODE_PEPPER: randomBytes(32).toString('base64'),
  LOCAL_SEAL_KEY: randomBytes(32).toString('base64'), MOCK_MUTATION: '1', PLAID_BILL_ALERTS: '1', MAX_CONNECTIONS_PER_USER: '2',
  SSM_PARAMETER_PATH: '', KMS_KEY_ID: '', PUBLIC_URL: origin, PASSKEY_RP_ID: rpID, PASSKEY_APP_ID: appID, VAULT_KEY: '',
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
  const r = await call('POST', '/v1/auth/email/verify', { email, code: await latestCode(email) });
  auth = saved;
  assert.equal(r.status, 200);
  return r.body;
}

test('rejects unauthenticated calls, forged tokens and non-object JSON bodies', async () => {
  const r = await call('GET', '/v1/connections');
  assert.equal(r.status, 401);
  assert.equal(r.headers.get('cache-control'), 'no-store');
  // Deliberately forged unsigned token (alg "none", sub "x"), not a credential.
  // nosemgrep: generic.secrets.security.detected-jwt-token.detected-jwt-token
  const forged = await call('GET', '/v1/connections', undefined, { Authorization: 'Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.x' });
  assert.equal(forged.status, 401);
  const badJson = await fetch(`${base}/v1/auth/email/start`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: 'null' });
  assert.equal(badJson.status, 400);
  const health = await call('GET', '/v1/health');
  assert.equal(health.body.apiVersion, 4);
  assert.deepEqual(health.body.signIn, ['email-code', 'password', 'totp', 'passkey']);
  const association = await call('GET', '/.well-known/apple-app-site-association');
  assert.equal(association.status, 200);
  assert.deepEqual(association.body, { webcredentials: { apps: [appID] } });
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
  const lt = await call('POST', '/v1/credit-card-link-token', { country: 'US' });
  assert.equal(lt.status, 200);
  assert.match(lt.body.linkToken, /^link-mock-US-/);
  assert.equal(lt.body.billConsentId, undefined);
  const pt = await call('POST', '/v1/dev/public-token', { country: 'US' });
  const clientRequestId = randomUUID();
  // A failed exchange must release clientRequestId so retrying with the same ID succeeds immediately.
  const bad = await call('POST', '/v1/connections', { publicToken: 'invalid-public-token', clientRequestId, country: 'US' });
  assert.equal(bad.status, 400);
  const first = await call('POST', '/v1/connections', { publicToken: pt.body.publicToken, clientRequestId, country: 'US' });
  assert.equal(first.status, 201);
  assert.deepEqual(first.body.accounts.map((a: { type: string }) => a.type), ['credit', 'credit']);
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
      const r = await call('POST', `/v1/connections/${connectionId}/card-sync`, { accountId: 'acc_mock_plat', cursor: c });
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

test('bill dates require completed, unrevoked approval and named credit cards owned by the caller', async () => {
  const path = `/v1/connections/${connectionId}/credit-card-bills`;
  const consent = `/v1/connections/${connectionId}/bill-consent`;
  const cards = { accountIds: ['acc_mock_plat'] };
  const denied = await call('POST', path, cards, { Authorization: '' });
  assert.equal(denied.status, 401);
  const blocked = { status: 'consent_required', bills: [] };
  assert.deepEqual((await call('POST', path, cards)).body, blocked);
  assert.equal((await call('POST', consent, { consentId: randomUUID() })).status, 409);

  const link = '/v1/credit-card-link-token';
  const upgrade = await call('POST', link, { country: 'US', connectionId, billAccess: true });
  assert.equal(upgrade.status, 200);
  assert.match(upgrade.body.linkToken, /^link-mock-US-/);
  const receipt = { consentId: upgrade.body.billConsentId };
  assert.deepEqual((await call('POST', path, cards)).body, blocked, 'starting Link does not authorize collection');
  assert.equal((await call('POST', consent, receipt)).status, 200);

  const response = await call('POST', path, cards);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.body.status, 'available');
  assert.deepEqual(response.body.bills.map((bill: { accountId: string }) => bill.accountId), cards.accountIds);
  for (const bill of response.body.bills) {
    assert.deepEqual(Object.keys(bill).sort(), ['accountId', 'dueDate']);
    assert.match(bill.dueDate, /^\d{4}-\d{2}-\d{2}$/);
  }

  // Starting another billAccess Link flow without completing it must not revoke the active bill consent.
  const abandoned = await call('POST', link, { country: 'US', connectionId, billAccess: true });
  assert.equal(abandoned.status, 200);
  assert.equal((await call('POST', path, cards)).body.status, 'available');

  assert.equal((await call('POST', path, { accountIds: ['acc_mock_chk'] })).status, 404);
  assert.equal((await call('POST', path, { accountIds: [] })).status, 400);
  assert.equal((await call('DELETE', consent)).status, 200);
  assert.deepEqual((await call('POST', path, cards)).body, blocked);
  assert.equal((await call('POST', consent, receipt)).status, 409, 'withdrawal invalidates the old approval');
  assert.equal((await call('POST', consent, { consentId: abandoned.body.billConsentId })).status, 409, 'withdrawal clears pending approval');

  const missingConnection = await call('POST', link, { country: 'US', billAccess: true });
  assert.equal(missingConnection.status, 400);
  assert.equal(missingConnection.body.error, 'connection_required');
});

test('initial sync paginates, survives a mutation, and normalizes fields', async () => {
  const path = `/v1/connections/${connectionId}/card-sync`;
  assert.equal((await call('POST', path, { cursor: null })).body.error, 'scoped_sync_required');
  assert.equal((await call('POST', path, { accountId: 'acc_mock_chk' })).status, 404);
  const r = await fullSync(null);
  assert.equal(r.resyncs, 1, 'mock throws one pagination mutation');
  assert.ok(r.added.size > 12, 'more than one page');
  assert.ok([...r.added.values()].every((t) => t.accountId === 'acc_mock_plat'));
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
  for (const [m, path] of [['POST', `/v1/connections/${connectionId}/card-sync`], ['DELETE', `/v1/connections/${connectionId}`],
    ['POST', `/v1/connections/${connectionId}/credit-card-bills`], ['DELETE', `/v1/connections/${connectionId}/bill-consent`]] as const) {
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

  // Revocation webhook clears token, billConsent, and account metadata just like disconnect().
  const pt = await call('POST', '/v1/dev/public-token', { country: 'US' });
  const temp = await call('POST', '/v1/connections', { publicToken: pt.body.publicToken, clientRequestId: randomUUID(), country: 'US' });
  assert.equal(temp.status, 201);
  const tempId = temp.body.connectionId;
  const grant = await call('POST', '/v1/credit-card-link-token', { country: 'US', connectionId: tempId, billAccess: true });
  assert.equal((await call('POST', `/v1/connections/${tempId}/bill-consent`, { consentId: grant.body.billConsentId })).status, 200);
  assert.equal((await call('POST', '/v1/dev/webhook', { connectionId: tempId, type: 'ITEM', code: 'USER_PERMISSION_REVOKED' })).status, 200);
  assert.deepEqual((await call('POST', `/v1/connections/${tempId}/credit-card-bills`, { accountIds: ['acc_mock_plat'] })).body,
    { status: 'consent_required', bills: [] }, 'revoked webhook clears billConsent');
  assert.equal((await call('POST', `/v1/connections/${tempId}/card-sync`, { accountId: 'acc_mock_plat', cursor: null })).status, 410);
});

test('disconnect revokes the Item and is idempotent', async () => {
  const d1 = await call('DELETE', `/v1/connections/${connectionId}`);
  assert.equal(d1.status, 200);
  assert.equal(d1.body.status, 'disconnected');
  const d2 = await call('DELETE', `/v1/connections/${connectionId}`);
  assert.equal(d2.body.status, 'disconnected');
  const s = await call('POST', `/v1/connections/${connectionId}/card-sync`, { accountId: 'acc_mock_plat', cursor: null });
  assert.equal(s.status, 410);
});

test('a user cannot link more banks than the connection limit; retries and disconnects still work', async () => {
  // The owner's earlier connection is disconnected by now. A new sign-in here would trip the per-IP code limit.
  assert.deepEqual((await call('GET', '/v1/connections')).body.connections, []);
  const link = (clientRequestId: string) => call('POST', '/v1/dev/public-token', { country: 'US' })
    .then((pt) => call('POST', '/v1/connections', { publicToken: pt.body.publicToken, clientRequestId, country: 'US' }));
  const first = await link(randomUUID());
  const secondId = randomUUID();
  const second = await link(secondId);
  assert.equal(first.status, 201);
  assert.equal(second.status, 201);

  const token = await call('POST', '/v1/credit-card-link-token', { country: 'US' });
  assert.equal(token.status, 409);
  assert.equal(token.body.error, 'connection_limit_reached');
  const third = await link(randomUUID());
  assert.equal(third.status, 409, 'the exchange is refused too, even with a public token in hand');
  assert.equal(third.body.error, 'connection_limit_reached');
  const retry = await link(secondId);
  assert.equal(retry.status, 200, 'a retry of a connect that succeeded is not counted again');
  assert.equal(retry.body.connectionId, second.body.connectionId);
  const reauth = await call('POST', '/v1/credit-card-link-token', { country: 'US', connectionId: first.body.connectionId });
  assert.equal(reauth.status, 200, 'update mode for an existing connection is allowed at the limit');

  assert.equal((await call('DELETE', `/v1/connections/${first.body.connectionId}`, undefined)).status, 200);
  assert.equal((await call('POST', '/v1/credit-card-link-token', { country: 'US' })).status, 200, 'a disconnect frees a slot');
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

const digest = (value: Buffer | string) => createHash('sha256').update(value).digest();
const encoded = (value: Uint8Array) => Buffer.from(value).toString('base64url');

/** A virtual ES256 authenticator. The API verifies real WebAuthn signatures and credential data. */
function virtualPasskey(userHandle: string) {
  const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const { x, y } = publicKey.export({ format: 'jwk' });
  const idBytes = randomBytes(32);
  const id = encoded(idBytes);
  const envelope = { id, rawId: id, type: 'public-key', clientExtensionResults: {} };
  const client = (type: string, challenge: string, clientOrigin: string) =>
    Buffer.from(JSON.stringify({ type, challenge, origin: clientOrigin }));
  const header = (flags: number, counter: number) => {
    const metadata = Buffer.alloc(5);
    metadata[0] = flags;
    metadata.writeUInt32BE(counter, 1);
    return Buffer.concat([digest(rpID), metadata]);
  };
  return {
    id,
    register(challenge: string) {
      const coseKey = isoCBOR.encode(new Map<number, number | Uint8Array>([
        [1, 2], [3, -7], [-1, 1], [-2, Buffer.from(x!, 'base64url')], [-3, Buffer.from(y!, 'base64url')],
      ]));
      const authData = Buffer.concat([header(0x45, 0), Buffer.alloc(16), Buffer.from([0, idBytes.length]), idBytes, coseKey]);
      const attestation = isoCBOR.encode(new Map<string, string | Uint8Array | Map<never, never>>([
        ['fmt', 'none'], ['attStmt', new Map<never, never>()], ['authData', authData],
      ]));
      return { ...envelope, response: {
        clientDataJSON: encoded(client('webauthn.create', challenge, origin)), attestationObject: encoded(attestation),
      } };
    },
    assert(challenge: string, counter: number, clientOrigin = origin, verified = true) {
      const clientDataJSON = client('webauthn.get', challenge, clientOrigin);
      const authenticatorData = header(verified ? 0x05 : 0x01, counter);
      const signature = sign('sha256', Buffer.concat([authenticatorData, digest(clientDataJSON)]), privateKey);
      return { ...envelope, response: {
        clientDataJSON: encoded(clientDataJSON), authenticatorData: encoded(authenticatorData), signature: encoded(signature), userHandle,
      } };
    },
  };
}

test('an existing email account can enroll password, TOTP and a passkey on the same account', async () => {
  const email = 'factors@example.com';
  const password = 'discrete fiddle forest 99';
  const bearer = (token: string) => ({ Authorization: `Bearer ${token}` });
  const first = await signIn(email);
  const firstAuth = bearer(first.accessToken);
  assert.equal((await call('GET', '/v1/auth/security', undefined, { Authorization: '' })).status, 401);
  assert.deepEqual((await call('GET', '/v1/auth/security', undefined, firstAuth)).body,
    { totpEnabled: false, passwordEnabled: false, passkeysEnabled: true, passkeys: [] });

  const registration = await call('POST', '/v1/auth/passkeys/registration/start', undefined, firstAuth);
  assert.equal(registration.status, 200);
  assert.deepEqual(registration.body.excludedCredentialIDs, []);
  const key = virtualPasskey(registration.body.userID);
  const registered = await call('POST', '/v1/auth/passkeys/registration/verify', {
    id: registration.body.id, credential: key.register(registration.body.challenge),
  }, firstAuth);
  assert.equal(registered.status, 200);
  assert.equal(registered.body.passkeys[0].id, key.id);
  assert.equal(registered.body.passwordEnabled, false);
  const again = await call('POST', '/v1/auth/passkeys/registration/start', undefined, firstAuth);
  assert.deepEqual(again.body.excludedCredentialIDs, [key.id]);

  assert.equal((await call('PUT', '/v1/auth/password', { password: 'short' }, firstAuth)).body.error, 'password_length');
  const addedPassword = await call('PUT', '/v1/auth/password', { password }, firstAuth);
  assert.equal(addedPassword.status, 200);
  assert.equal(addedPassword.body.user.id, first.user.id);
  assert.equal((await call('GET', '/v1/me', undefined, firstAuth)).status, 401);
  assert.equal((await call('POST', '/v1/auth/password/verify', { email: 'unknown@example.com', password })).body.error, 'password_invalid');
  assert.equal((await call('POST', '/v1/auth/password/verify', { email, password: 'a different password' })).body.error, 'password_invalid');
  const passwordLogin = await call('POST', '/v1/auth/password/verify', { email, password });
  assert.equal(passwordLogin.status, 200);
  assert.equal(passwordLogin.body.user.id, first.user.id);
  const passwordAuth = bearer(passwordLogin.body.accessToken);

  const setup = await call('POST', '/v1/auth/totp/setup', undefined, passwordAuth);
  assert.equal(setup.status, 200);
  const totp = URI.parse(setup.body.uri);
  const timestamp = Date.now();
  const setupCode = totp.generate({ timestamp });
  const fromOtherSession = await call('POST', '/v1/auth/totp/enable', { id: setup.body.id, code: setupCode }, bearer(addedPassword.body.accessToken));
  assert.equal(fromOtherSession.body.error, 'challenge_invalid_or_expired');
  const enabled = await call('POST', '/v1/auth/totp/enable', { id: setup.body.id, code: setupCode }, passwordAuth);
  assert.equal(enabled.status, 200);
  assert.equal(enabled.body.recoveryCodes.length, 10);
  assert.equal((await call('POST', '/v1/auth/refresh', { refreshToken: passwordLogin.body.refreshToken })).status, 401);
  const securedAuth = bearer(enabled.body.tokens.accessToken);
  const security = await call('GET', '/v1/auth/security', undefined, securedAuth);
  assert.equal(security.body.passkeys[0].id, key.id);
  assert.equal(security.body.totpEnabled, true);

  const emailSecondStep = await signIn(email);
  assert.equal(emailSecondStep.accessToken, undefined);
  const id = emailSecondStep.secondFactor.id;
  const verify = async (id: string, code: string) => call('POST', '/v1/auth/totp/verify', { id, code });
  assert.equal((await verify(id, setupCode)).body.error, 'totp_invalid');
  const nextCode = totp.generate({ timestamp: timestamp + 30_000 });
  const completion = await verify(id, nextCode);
  assert.equal(completion.status, 200);
  assert.equal(completion.body.user.id, first.user.id);
  assert.equal((await verify(id, nextCode)).body.error, 'challenge_invalid_or_expired');

  const passwordSecondStep = async () => {
    const r = await call('POST', '/v1/auth/password/verify', { email, password });
    assert.equal(r.status, 200);
    assert.equal(r.body.accessToken, undefined);
    return r.body.secondFactor.id as string;
  };
  const recovery = enabled.body.recoveryCodes[0];
  const passwordChallenge = await passwordSecondStep();
  assert.equal((await verify(passwordChallenge, nextCode)).body.error, 'totp_invalid');
  const attempts = await Promise.all([verify(passwordChallenge, recovery), verify(passwordChallenge, recovery)]);
  assert.deepEqual(attempts.map((a) => a.status).sort(), [200, 401]);
  const newChallenge = await passwordSecondStep();
  assert.equal((await verify(newChallenge, recovery)).body.error, 'totp_invalid');
  for (let attempt = 0; attempt < 4; attempt++) assert.equal((await verify(newChallenge, 'wrong')).body.error, 'totp_invalid');
  assert.equal((await verify(newChallenge, enabled.body.recoveryCodes[1])).body.error, 'challenge_invalid_or_expired');

  const passkeyAttempt = async (counter: number, clientOrigin = origin, verified = true) => {
    const start = await call('POST', '/v1/auth/passkeys/start');
    assert.equal(start.body.rpID, rpID);
    const proof = { id: start.body.id, credential: key.assert(start.body.challenge, counter, clientOrigin, verified) };
    return { proof, response: await call('POST', '/v1/auth/passkeys/verify', proof) };
  };
  assert.equal((await passkeyAttempt(1, 'https://other.example.com')).response.body.error, 'passkey_invalid');
  assert.equal((await passkeyAttempt(1, origin, false)).response.body.error, 'passkey_invalid');
  const passkey = await passkeyAttempt(1);
  assert.equal(passkey.response.status, 200);
  assert.equal(passkey.response.body.user.id, first.user.id);
  assert.equal((await call('POST', '/v1/auth/passkeys/verify', passkey.proof)).body.error, 'challenge_invalid_or_expired');
  assert.equal((await passkeyAttempt(1)).response.body.error, 'passkey_invalid', 'reused authenticator counter');

  const removedKey = await call('DELETE', `/v1/auth/passkeys/${key.id}`, {}, bearer(passkey.response.body.accessToken));
  assert.equal(removedKey.status, 200);
  assert.equal((await passkeyAttempt(2)).response.body.error, 'passkey_invalid');
  const disabled = await call('DELETE', '/v1/auth/totp', {}, bearer(removedKey.body.accessToken));
  assert.equal(disabled.status, 200);
  const changedPassword = 'bedrock glacier poppy 87';
  const changed = await call('PUT', '/v1/auth/password', { password: changedPassword }, bearer(disabled.body.accessToken));
  assert.equal(changed.status, 200);
  assert.equal((await call('POST', '/v1/auth/password/verify', { email, password })).body.error, 'password_invalid');
  const changedLogin = await call('POST', '/v1/auth/password/verify', { email, password: changedPassword });
  assert.equal(changedLogin.body.user.id, first.user.id);
  const removedPassword = await call('DELETE', '/v1/auth/password', {}, bearer(changedLogin.body.accessToken));
  assert.equal(removedPassword.status, 200);
  assert.equal((await signIn(email)).user.id, first.user.id);
  for (const secret of [password, changedPassword, setup.body.secret, recovery, key.id]) assert.ok(!logs.includes(secret));
});
