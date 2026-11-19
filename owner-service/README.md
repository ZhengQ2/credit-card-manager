# Card Ledger owner service — setup and recovery runbook

The owner service is a small Node service that runs on a computer you control. It is the only component that talks to Plaid. It holds the Plaid secret and the Item access tokens, and it streams normalized transaction pages to your paired iPhone. It stores no transactions (design §6–7).

```
iPhone (SQLCipher ledger)  ──LAN/VPN, bearer credential──▶  owner service  ──TLS──▶  Plaid
```

## 1. First-time setup

Requires Node 23.6 or later. No build step is needed because Node runs the TypeScript directly.

```bash
npm install
```

```bash
npm run setup
```

`setup` creates `.env` (mode 0600) containing a fresh `VAULT_KEY`, and it never overwrites an existing key. If you lose the key, the vault cannot be read. You would then have to relink every bank.

Edit `.env`:

| Key | Value |
|---|---|
| `PLAID_ENV` | `mock` (no Plaid account, synthetic data), `sandbox`, or `production` |
| `PLAID_CLIENT_ID` | From the Plaid Dashboard |
| `PLAID_SANDBOX_SECRET` / `PLAID_PRODUCTION_SECRET` | Each environment uses its own secret and its own vault file (`data/vault.<env>.bin`) |
| `HOST` | `127.0.0.1` for the simulator. Use the LAN or VPN interface address for a physical iPhone. |
| `PLAID_REDIRECT_URI` | Needed only for OAuth institutions such as Amex. See section 5. |

## 2. Run and pair

```bash
npm start
```

```bash
npm run pair
```

`pair` prints a single-use code that expires after 10 minutes and allows 5 attempts. On the iPhone, open Settings → Pair with service, or Cards → Connect a bank. Enter the service URL and the code. The phone stores the device credential in a device-only Keychain entry, and the service stores only its SHA-256 hash.

```bash
npm run pair -- list
```

```bash
npm run pair -- revoke <device-id>
```

## 3. Connect a bank

On the iPhone, go to Cards → Connect a bank → choose a country → Continue to Plaid → map each credit-card account to a catalog product → Confirm. The first sync starts automatically.

- **mock**: Link is simulated. You get "American Express (mock)" (Platinum, Aspire, and a checking account that is ignored) or "CIBC (mock)". Each manual refresh after the first sync reveals one scripted update: a pending purchase, then its posting, then its statement credit.
- **sandbox**: You can use the real Plaid Link with sandbox credentials, or tap "Use Sandbox test bank (skip Link)". That option uses `user_transactions_dynamic` at First Platypus Bank.
- **production**: Real Link. Confirm your Production access and institution coverage in the Plaid Dashboard first.

## 4. API (all routes except health and pair require `Authorization: Bearer <deviceId>.<credential>`)

| Route | Purpose |
|---|---|
| `GET /v1/health` | Verifies that this is a Card Ledger service and reports its environment |
| `POST /v1/pair` | Redeems a pairing code for a device credential |
| `POST /v1/link-token` | `{country, connectionId?}` creates a Link token. Passing `connectionId` selects update mode for an existing Item. |
| `POST /v1/connections` | `{publicToken, clientRequestId, country}` exchanges the token and persists the Item token before replying. Requests are deduplicated by `clientRequestId`. |
| `GET /v1/connections` | Lists connections, their accounts, their status and the last successful pull |
| `POST /v1/connections/:id/sync` | `{cursor}` returns one page with `added`, `modified`, `removed`, `nextCursor`, `hasMore` and `historyStatus`. It returns `{status:"resync_required"}` when Plaid reports a mutation during pagination, and 409 `ITEM_LOGIN_REQUIRED` when the bank needs you to sign in again. |
| `DELETE /v1/connections/:id` | Calls Plaid `/item/remove`. Repeating it is safe. On a retryable failure it returns 503 and keeps the token so you can retry. |
| `POST /v1/dev/public-token` | Sandbox and mock only. Creates a public token without Link. |

Logging records only the method, the path with IDs redacted, the status and the duration. No request or response bodies, tokens or query strings are logged. Every response sends `Cache-Control: no-store`.

## 5. Physical iPhone and OAuth banks (not yet exercised)

1. **TLS.** Put an HTTPS reverse proxy (for example Caddy with a LAN certificate) in front of `HOST:PORT`, and reach it only over your LAN or an owner-operated VPN such as WireGuard on your router. In release builds, the app's App Transport Security setting allows plain HTTP only to local hosts.
2. **OAuth redirect.** Banks such as Amex require one. Serve a static `apple-app-site-association` file and a minimal callback page from a domain you own. Register the exact URL as `PLAID_REDIRECT_URI` and in the Plaid Dashboard. Add `applinks:<domain>` under Associated Domains in Xcode, and sign the app with your team. Nothing financial is ever served from that domain.
3. Confirm that iCloud device backup is off on the pilot iPhone. The app's data directory is already excluded from backup.

## 6. Recovery

| Symptom | Fix |
|---|---|
| App shows "service offline" | Start the service, then pull to refresh. Cached data stays visible on the phone. |
| `unauthorized` | Run `npm run pair` and pair the phone again. Cards and history are kept. |
| Card shows "Reconnect required" | Tap Reconnect. This runs Link in update mode for the existing Item, so no new Item is created. |
| Disconnect shows "will be retried" | Tap Retry disconnect when the service is reachable. The Item token is kept until Plaid confirms removal. |
| Lost `VAULT_KEY` | Delete `data/vault.<env>.bin`, run `npm run setup`, pair again and relink. Local history on the phone is kept. |

## 7. Tests

```bash
npm test
```

```bash
npm run typecheck
```

The end-to-end suite starts the service in mock mode in a temporary data directory. It checks auth, single-use pairing, idempotent connect, pagination, recovery from a mid-pagination mutation, pending→posted linkage, idempotent disconnect, that the vault is encrypted at rest, and that logs contain no tokens.

## Not yet done

- Webhooks (`SYNC_UPDATES_AVAILABLE`). The app pulls on launch or foreground after 4 hours, and on manual refresh.
- Plaid Liabilities, for statement and due dates.
- Running Sandbox and Production against real Plaid. This needs your Plaid keys and has not been exercised yet.
