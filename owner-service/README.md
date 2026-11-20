# Card Ledger API: runbook

A small Node service. It's the only component that talks to Plaid. It holds user accounts and Plaid Item tokens, and it streams normalized transaction pages to the signed-in iPhone. **It stores no transactions** (design §6–7): the ledger lives only on the phone, in SQLCipher.

```
iPhone (SQLCipher ledger) ──HTTPS, access token──▶ Caddy (TLS) ──▶ API ──▶ Plaid
                                                                   ├──▶ DynamoDB  (accounts, sessions, connections)
                                                                   ├──▶ KMS       (seals each Plaid token)
                                                                   ├──▶ SSM       (Plaid keys, signing secrets)
                                                                   └──▶ SES       (sign-in codes)
```

## How it's secured

| Layer | Mechanism |
|---|---|
| Transport | Public HTTPS only. Caddy terminates TLS with an automatic Let's Encrypt certificate and sends HSTS. Plain HTTP redirects. The security group allows only ports 80 and 443. |
| Sign-in | Email codes are single-use, expire after 10 minutes, and lock after 5 wrong attempts. Accounts can also set a password. Both methods require an authenticator or one-time recovery code when two-factor authentication is on. Registered passkeys sign in with device user verification. |
| Credentials | Passwords are salted and hashed with scrypt and a server-side pepper. Authenticator seeds are sealed with KMS using the owner-bound `account-totp` context. Recovery codes are stored as keyed hashes. Passkey records store public keys and signature counters. |
| Sessions | A 15-minute HS256 access token, plus a refresh token that rotates on every use and lasts 60 days, rolling. Presenting an already-rotated refresh token revokes the session. The phone keeps the refresh token in a device-only Keychain item. |
| Sign-up | Outside mock mode, only invited addresses can create an account (`SIGNUP=invite`, the default). An address with no account and no invite gets the same 202 answer and no email. Each user can hold at most `MAX_CONNECTIONS_PER_USER` bank connections (default 10). |
| Isolation | Every record is keyed by user ID, and every handler reads with the authenticated user's ID. Another user's connection returns 404. |
| Plaid tokens | Sealed with KMS. The encryption context `{purpose, userId, connectionId}` binds each token to its owner. IAM allows the API to decrypt only within that purpose. Every decrypt is logged in CloudTrail. |
| Webhooks | `Plaid-Verification` ES256 JWT check: Plaid's key, an issued-at within 5 minutes, and the SHA-256 of the body. Unsigned or altered webhooks get 401. |
| Secrets | Plaid client ID and secret, `JWT_SECRET` and `CODE_PEPPER` are in SSM Parameter Store as SecureStrings. The instance reads them through its IAM role, so no AWS keys or secrets sit on disk. |
| Host | EC2 with IMDSv2 required, an encrypted EBS volume, automatic security updates, and no SSH port (admin through SSM Session Manager). The service runs as a no-login user under a hardened systemd unit. |
| Logs | Request logs record the method, path with IDs redacted, status and duration. Sign-in mail failures use a fixed message. Bodies, emails, tokens and query strings stay out of the logs. Responses send `Cache-Control: no-store`. |
| Data scope | Sign-in sessions omit device names. Plaid receives an opaque user ID and requests credit-card transactions. Individual card syncs use separate cursors. Bill dates require a separate, revocable approval and an explicit list of card accounts. |
| Account deletion | `DELETE /v1/me` removes every Item at Plaid first, then deletes the user's records. |

Email sign-in accepts the request after saving an eligible address's code. Delivery runs in the background and the response does not confirm delivery.

## Production (AWS, ca-central-1)

| Resource | Name |
|---|---|
| API | `https://api.zhengqiu.net` → EC2 `card-ledger-api` (t4g.small, Ubuntu 24.04), Elastic IP |
| Data | DynamoDB `card-ledger`: on demand, TTL on `ttl`, point-in-time recovery, deletion protection |
| Token key | KMS `alias/card-ledger-plaid-tokens`, with yearly rotation |
| Secrets | SSM `/card-ledger/prod/{PLAID_CLIENT_ID,PLAID_SECRET,JWT_SECRET,CODE_PEPPER}` |
| Email | SES identity `zhengqiu.net` (DKIM), sending as `no-reply@zhengqiu.net` |
| IAM | Role and instance profile `card-ledger-api`: this table, this key (purpose-bound), these parameters, SES from that address, plus SSM managed-instance access |

The non-secret settings are in `/etc/card-ledger/api.env` on the instance:

```
PLAID_ENV=production
STORE=dynamo
TABLE_NAME=card-ledger
KMS_KEY_ID=alias/card-ledger-plaid-tokens
SSM_PARAMETER_PATH=/card-ledger/prod
MAILER=ses
MAIL_FROM=Card Ledger <no-reply@zhengqiu.net>
PUBLIC_URL=https://api.zhengqiu.net
SIGNUP=invite
TRUST_PROXY=1
HOST=127.0.0.1
PORT=8787
```

**Deploy:** copy `package.json`, `package-lock.json`, `tsconfig.json` and `src/` to `/srv/cardledger/app`, then run `npm ci --omit=dev` and `systemctl restart card-ledger-api`. Run commands on the instance with SSM Run Command or Session Manager.

### Invite testers

While `SIGNUP=invite`, a new address can create an account only with an invite. On the instance, run this from `/srv/cardledger/app` with the variables from `/etc/card-ledger/api.env` set:

```bash
npm run invite -- add tester@example.com
```

An invite lasts 30 days unless you pass `--days N` (1 to 365), and it's used up when the account is created. Signing in to an existing account never needs one. To withdraw an unused invite:

```bash
npm run invite -- remove tester@example.com
```

Only a keyed hash of each address is stored, so invites can't be listed. Removing an invite doesn't affect an account that was already created. To remove an account, the user deletes it in the app (`DELETE /v1/me`).

### Deploy sign-in security

1. Allow the API role to call `kms:Encrypt` and `kms:Decrypt` on the configured KMS key with `kms:EncryptionContext:purpose` equal to `account-totp`, alongside the existing Plaid token policy. Retain the `CODE_PEPPER` value because it protects existing passwords and recovery codes.
2. Deploy this API and the updated iOS app together. Existing profiles can enroll methods in place. Once an account has enabled two-factor authentication, that account needs the updated app for email sign-in. Keep the API at version 3 or later after enrollment so every sign-in path enforces the account's second factor. Bank linking and sync use the new scoped endpoints in API v4. Existing cards retain their local history and replay each selected card once to establish its own cursor.
3. To turn on passkeys, set `PASSKEY_RP_ID=api.zhengqiu.net` and `PASSKEY_APP_ID` to the signed app's application identifier, for example `ABCDE12345.local.prototype.CardLedger`. The RP ID must match the HTTPS host in `PUBLIC_URL`. Verify `/.well-known/apple-app-site-association` is publicly served as JSON on that host over HTTPS without redirects and contains the app identifier under `webcredentials.apps`. Sign the iOS app with the matching Associated Domains entitlement.

```bash
aws ssm start-session --region ca-central-1 --target <instance-id>
```

**Logs:**

```bash
journalctl -u card-ledger-api
```

**SES sandbox:** until AWS grants production access, codes reach only verified addresses. Request access in the SES console when you're ready to invite users.

## Scaling

The API holds no state between requests, so instances are interchangeable:
1. **More capacity:** add instances behind an Application Load Balancer, or move the same code to ECS on Fargate. DynamoDB on demand, KMS and SES scale on their own.
2. **Shared rate limits:** each instance's limits are per process. With several instances, add AWS WAF rate-based rules at the load balancer.
3. **Per-Item locks:** these are per process, and a load balancer with sticky sessions keeps one user's syncs on one instance. Plaid's cursor protocol is safe to retry either way.

## Local development

Requires Node 23.6 or later. Node runs the TypeScript directly, with no build step.

```bash
npm install
```

```bash
npm run setup
```

`setup` adds random `JWT_SECRET`, `CODE_PEPPER` and `LOCAL_SEAL_KEY` values to `.env` (mode 0600). With `PLAID_ENV=mock`:
- **Storage:** in memory, so data is lost on restart.
- **Token sealing:** the local key.
- **Sign-in codes:** printed to the service log. That's only allowed in mock mode.

```bash
npm start
```

In a Debug build of the app, set **Developer → Service URL** on the sign-in screen to `http://127.0.0.1:8787`.

| Key | Purpose |
|---|---|
| `PLAID_ENV` | `mock`, `sandbox` or `production` |
| `STORE` | `memory` (the mock default) or `dynamo` |
| `KMS_KEY_ID` / `LOCAL_SEAL_KEY` | Production requires KMS |
| `MAILER` | `console` (mock only) or `ses` |
| `SSM_PARAMETER_PATH` | Load secrets from SSM instead of `.env` |
| `PUBLIC_URL` | Public HTTPS origin; enables Plaid webhooks |
| `PASSKEY_RP_ID` / `PASSKEY_APP_ID` | Set both to enable passkeys. Use the `PUBLIC_URL` host and the app's signed application identifier. |
| `PLAID_BILL_ALERTS` | `1` enables Liabilities (due dates) |
| `SIGNUP` | `invite` (default outside mock mode) or `open` (default in mock mode) |
| `MAX_CONNECTIONS_PER_USER` | Bank connections per user, 1 to 100. Default 10. |
| `PLAID_REDIRECT_URI` | Needed only for OAuth institutions |

## API

Health, the Apple association file, email/password/passkey sign-in, second-factor verification, refresh, and the Plaid webhook are public. Other routes require `Authorization: Bearer <access token>`. Changing sign-in settings requires a session created in the last 10 minutes. Password changes, two-factor changes, and passkey removal replace the current session and revoke earlier sessions.

| Route | Purpose |
|---|---|
| `GET /v1/health` | Service identity, `apiVersion`, environment |
| `POST /v1/auth/email/start` | `{email}`. Emails a code if the address has an account or sign-up allows it; always 202 |
| `POST /v1/auth/email/verify` or `/v1/auth/password/verify` | Verify the email code or password. Returns session tokens or `{secondFactor: {id, expiresIn}}`. A new address whose invite was removed or expired after its code was sent gets 403 `invite_required`. |
| `POST /v1/auth/totp/verify` | `{id, code}` verifies an authenticator or recovery code and returns session tokens. |
| `GET /v1/auth/security` | Lists enabled sign-in methods and registered passkeys. |
| `PUT` or `DELETE /v1/auth/password` | Set or remove a password and issue replacement session tokens. |
| `POST /v1/auth/totp/setup` and `/v1/auth/totp/enable` | Start and verify authenticator setup. Enabling returns replacement session tokens and ten one-time recovery codes. |
| `DELETE /v1/auth/totp` | Disable authenticator sign-in and issue replacement session tokens. |
| `POST /v1/auth/passkeys/start` and `/v1/auth/passkeys/verify` | Issue an assertion challenge and verify the signed passkey response. |
| `POST /v1/auth/passkeys/registration/start` and `/v1/auth/passkeys/registration/verify` | Issue a registration challenge and verify a new credential for the signed-in account. |
| `DELETE /v1/auth/passkeys/:id` | Remove an enrolled passkey and issue replacement session tokens. |
| `POST /v1/auth/refresh` | `{refreshToken}`. Rotates and returns new tokens |
| `POST /v1/auth/sign-out` | Ends this session |
| `GET /v1/me` / `DELETE /v1/me` | Profile / delete the account (Items removed at Plaid first) |
| `POST /v1/credit-card-link-token` | `{country, connectionId?, historyDays?, billAccess?}`. A new link gets 409 `connection_limit_reached` once the user holds the maximum. New links request credit-card transactions for up to 365 days by default or 730 days if selected. Bill access is requested separately in update mode. |
| `POST /v1/connections` | `{publicToken, clientRequestId, country}`. Idempotent across instances. Checks the connection limit again before exchanging the token. |
| `GET /v1/connections` | The user's connections, including `updatesAvailable` from webhooks |
| `POST /v1/connections/:id/card-sync` | `{accountId, cursor}`. One scoped `/transactions/sync` page for a card on the caller's connection. |
| `POST /v1/connections/:id/bill-consent` | `{consentId}` records approval after the optional Plaid flow succeeds. A Link token alone grants no bill access. |
| `DELETE /v1/connections/:id/bill-consent` | Withdraws bill-date access for that connection and invalidates its approval receipt. |
| `POST /v1/connections/:id/credit-card-bills` | `{accountIds}` returns account IDs and due dates for the requested cards when approval is active. |
| `DELETE /v1/connections/:id` | Removes the Item at Plaid; safe to repeat |
| `POST /v1/plaid/webhook` | Plaid webhooks, verified |
| `POST /v1/dev/public-token`, `/v1/dev/webhook` | Development only (not Production / mock only) |

## Migrating from the single-owner vault

`node src/importVault.ts --email <you> --vault data/vault.production.bin` (with `VAULT_KEY` set):
1. Creates the account, if needed.
2. Keeps each connection's ID, so the phone's account mapping and sync cursors still match.
3. Re-seals each token with KMS.
4. Points the Items' webhooks at `PUBLIC_URL`.

After that, the vault file and `VAULT_KEY` are no longer needed.

## Recovery

| Symptom | Fix |
|---|---|
| "You've been signed out" | Sign in again. Cards and history on the phone are kept. |
| No code arrives | Check spam. In the SES sandbox the address must be verified. |
| Card shows "Reconnect required" | Tap Reconnect. Link runs in update mode for the existing Item. |
| Disconnect "will be retried" | Retry once the API is reachable. The token is kept until Plaid confirms removal. |
| Instance lost | Launch a new instance with the `card-ledger-api` profile and deploy. All state is in DynamoDB, KMS and SSM. |

## Tests

```bash
npm test
```

```bash
npm run typecheck
```

The end-to-end suite runs the API in mock mode. It covers:
- Email sign-in, code lockout, and refresh rotation with reuse detection
- Invite-only sign-up and the per-user connection limit
- Isolation between users
- Idempotent connect, pagination, mutation recovery, and pending→posted linkage
- Signed and forged webhooks
- Disconnect, and account deletion
- Logs that contain no tokens or emails

Unit tests cover:
- Token tampering, expiry and algorithm confusion
- Sealing bound to the encryption context
- Webhook signature, body hash and age
- Conditional session rotation
