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
| Sign-in | A 6-digit email code: single use, expires in 10 minutes, locks after 5 wrong attempts, at most 5 codes per address per hour. The response is the same whether or not an account exists. Only HMACs of the email and the code are stored, using a server-side pepper. |
| Sessions | A 15-minute HS256 access token, plus a refresh token that rotates on every use and lasts 60 days, rolling. Presenting an already-rotated refresh token revokes the session. The phone keeps the refresh token in a device-only Keychain item. |
| Isolation | Every record is keyed by user ID, and every handler reads with the authenticated user's ID. Another user's connection returns 404. |
| Plaid tokens | Sealed with KMS. The encryption context `{purpose, userId, connectionId}` binds each token to its owner. IAM allows the API to decrypt only within that purpose. Every decrypt is logged in CloudTrail. |
| Webhooks | `Plaid-Verification` ES256 JWT check: Plaid's key, an issued-at within 5 minutes, and the SHA-256 of the body. Unsigned or altered webhooks get 401. |
| Secrets | Plaid client ID and secret, `JWT_SECRET` and `CODE_PEPPER` are in SSM Parameter Store as SecureStrings. The instance reads them through its IAM role, so no AWS keys or secrets sit on disk. |
| Host | EC2 with IMDSv2 required, an encrypted EBS volume, automatic security updates, and no SSH port (admin through SSM Session Manager). The service runs as a no-login user under a hardened systemd unit. |
| Logs | Method, path with IDs redacted, status and duration only. Never bodies, emails, tokens or query strings. Responses send `Cache-Control: no-store`. |
| Account deletion | `DELETE /v1/me` removes every Item at Plaid first, then deletes the user's records. |

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
TRUST_PROXY=1
HOST=127.0.0.1
PORT=8787
```

**Deploy:** copy `package.json`, `package-lock.json`, `tsconfig.json` and `src/` to `/srv/cardledger/app`, then run `npm ci --omit=dev` and `systemctl restart card-ledger-api`. Run commands on the instance with SSM Run Command or Session Manager.

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
| `PLAID_BILL_ALERTS` | `1` enables Liabilities (due dates) |
| `PLAID_REDIRECT_URI` | Needed only for OAuth institutions |

## API

Every route except health, the `auth` routes and the webhook requires `Authorization: Bearer <access token>`.

| Route | Purpose |
|---|---|
| `GET /v1/health` | Service identity, `apiVersion`, environment |
| `POST /v1/auth/email/start` | `{email}`. Emails a code; always 202 |
| `POST /v1/auth/email/verify` | `{email, code, deviceName}` → `{accessToken, accessTokenExpiresIn, refreshToken, user}` |
| `POST /v1/auth/refresh` | `{refreshToken}`. Rotates and returns new tokens |
| `POST /v1/auth/sign-out` | Ends this session |
| `GET /v1/me` / `DELETE /v1/me` | Profile / delete the account (Items removed at Plaid first) |
| `POST /v1/link-token` | `{country, connectionId?, billAccess?}`. Link token, with webhook and per-user ID |
| `POST /v1/connections` | `{publicToken, clientRequestId, country}`. Idempotent across instances |
| `GET /v1/connections` | The user's connections, including `updatesAvailable` from webhooks |
| `POST /v1/connections/:id/sync` | One `/transactions/sync` page |
| `GET /v1/connections/:id/credit-card-bills` | Due dates (when bill alerts are enabled) |
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
