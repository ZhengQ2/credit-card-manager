# Agent guide

Instructions for any coding agent (Claude, Codex, Gemini, or others) working in this repository. They apply to every change, however small.

## Repository map

| Path | What it is |
|---|---|
| `CardLedger/` | SwiftUI iOS app. `Engine/` holds reward, benefit and fee logic; `Import/` holds PDF and CSV statement parsers; `Sync/` talks to the owner service; `Persistence/` is the SQLCipher store; `Views/` is UI. Tests live in `CardLedger/Tests/`. |
| `owner-service/` | Node (>= 23.6) TypeScript API, run directly with `node` (no build step). Accounts, sign-in factors, Plaid connections, webhooks. Tests live in `owner-service/test/`. |
| `security/` | Semgrep rules and Python scanners run by `.github/workflows/security-scans.yml`. |
| `*.md` at the root | Design notes and reports. |

## Code style

**General**
- Match the style of the file you are editing; do not reformat code you are not changing.
- Keep changes focused on the task. No drive-by refactors, renames or dependency upgrades unless asked.
- Prefer small, named helpers over long functions. Comments explain *why*, not *what*; add one when the reason is not obvious from the code (security choices, issuer quirks, date edge cases).
- No new dependencies without a stated reason. Pin GitHub Actions to a commit SHA with a version comment, as the existing workflow does.

**Swift (`CardLedger`)**
- Swift 6 concurrency: keep UI state on the main actor; do not silence concurrency warnings with `@unchecked Sendable` or `nonisolated(unsafe)` without a comment explaining why it is safe.
- Calendar dates are `Day` values. Convert to and from `Date` only through `Day.toLocal` / `Day.fromLocal`; never mix UTC and local time for due dates or statement periods.
- Money is never `Double` arithmetic in new code paths without rounding to cents at the boundary; follow the existing engine types.
- Parsers must treat unrecognized or ambiguous input (for example `a/b/yyyy` dates where both parts are 12 or less) as unknown and leave it for the owner, never guess.
- Never log transaction descriptions, amounts, account numbers or tokens.

**TypeScript (`owner-service`)**
- `strict` TypeScript, ES modules, `.ts` import specifiers (`./store.ts`). Must pass `npm run typecheck`.
- Validate every request body field explicitly; reject unknown or malformed input with a typed `AuthError` or 4xx, not a 500.
- Secrets (Plaid tokens, TOTP secrets) are sealed with the `Sealer`; never store or return them in plain text. Compare secrets with `safeEqual`.
- Any change to a user's sign-in factors (password, authenticator, passkey) must bump the security `epoch` and end the current session before issuing a new one.
- Rate limiting keys on the client address. Read `X-Forwarded-For` only behind the trusted loopback proxy, and only the entry the proxy itself appended (the rightmost); never trust the client-supplied leftmost value.
- Keep the store interface in sync across `store.ts` (file/memory) and `dynamoStore.ts`.

## Tests

Every behaviour change ships with a test that fails without it. Bug fixes add a regression test for the exact input that broke.

```bash
cd owner-service && npm run typecheck && npm test
```

```bash
cd CardLedger && xcodebuild test -project CardLedger.xcodeproj -scheme CardLedger -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

```bash
python3 -m unittest discover -s security && python3 security/scan_source.py --offline
```

Run the suites for every area you touched. If you could not run one, say so in your final message; never claim tests pass without running them.

## Self-review before every commit (required)

Before running `git commit`, read your full staged diff (`git diff --staged`) as a reviewer who did not write it, and work through this list. Fix what you find, then re-run the tests. Do not commit until every item holds.

**Correctness**
- [ ] The change does what was asked, and nothing else.
- [ ] Edge cases are handled: empty input, missing fields, ambiguous dates, time zones and month ends, refunds and negative amounts, duplicate or out-of-order events, cancelled tasks.
- [ ] Every new code path is exercised by a test, and the tests pass.

**Safety and security**
- [ ] No secrets, tokens, keys, real account numbers or personal data in code, tests, fixtures, logs or commit messages.
- [ ] All external input (HTTP bodies, headers, Plaid payloads, imported PDF/CSV text) is validated before use.
- [ ] Authentication and authorization are checked on every new endpoint; a user can only reach their own data.
- [ ] Session, key and factor changes revoke what they replace.
- [ ] Errors fail closed: a failed check denies access or skips the action, never proceeds.
- [ ] No new network destinations, permissions, entitlements or data leaving the device without a stated reason.
- [ ] Destructive operations (deletes, migrations, overwrites of keys or databases) are guarded and reversible where possible.

**Quality**
- [ ] No dead code, debugging output, commented-out blocks or TODOs without an owner.
- [ ] Names and comments are accurate after the change.
- [ ] Docs (`README.md` files) are updated when setup, commands or behaviour change.

If the review finds a problem you cannot fix within the task, stop and report it instead of committing around it.

## Commits

- Commit only when the user asks. Never force-push, rewrite published history or push to `main` unless the user explicitly asks.
- One logical change per commit. Stage specific files; do not commit `.DS_Store`, `node_modules`, `__pycache__`, `.env` or local data.
- **Subject:** imperative mood, capitalized, no trailing period, at most about 72 characters, describing the user-visible effect. Examples from history:
  - `Let the owner change a card's product`
  - `Parse Amex Canada PDF statements`
  - `Fix statement payment-due reminder review findings`
- **Body:** blank line after the subject, wrapped at about 72 columns. Explain what changed and why; use `-` bullets for several distinct fixes. Mention added regression tests.
- **Trailers:** end every commit with your own co-author line and both sign-offs, in this order, using your real identity (never another agent's):

  ```
  Co-authored-by: <Agent name> <agent-email>
  Signed-off-by: Zheng Qiu <liqiu2003@gmail.com>
  Signed-off-by: <Agent name> <agent-email>
  ```
