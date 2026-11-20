# Card Ledger backlog

Last updated: 2026-11-19

Every planned task for Card Ledger, ranked by priority. Edit this file to track progress, and commit it along with the work it describes.

## How to use this file

- **IDs** are `CL-<n>`. They never change or get reused, even when a ticket is dropped. Give new tickets the next free number (now **CL-53**).
- **Status** is one of `To Do`, `In Progress`, `In Review`, `Blocked`, `Done` or `Won't Do`. Update it in the board and in the ticket.
- **Priority:**
  - **P1, alpha blocker.** Must be done before the first outside tester installs the app.
  - **P2, alpha period.** Needed in the first weeks of alpha, or for testers to give useful feedback.
  - **P3, before beta.** Improves accuracy, coverage or polish before a wider release.
  - **P4, later.** Larger bets, or work that needs a policy decision first.
- **Size:** `S` is up to 2 days, `M` is about a week, `L` is two weeks or more. `Ext` means it waits on someone outside the project (Apple, Plaid, AWS).
- **Area:** `iOS`, `API`, `Catalog`, `Infra`, `Ops`, `Legal` or `Docs`.
- When a ticket is done, record the commit in it, for example `Done (4c850f3)`.

## Board

### P1: alpha blockers

| ID | Title | Area | Size | Status | Depends on |
|---|---|---|---|---|---|
| CL-1 | Invite-only sign-up and per-user connection limit | API, iOS | M | Done (4c850f3) | |
| CL-2 | Deploy the invite gate and invite the first testers | Ops | S | To Do | CL-1 |
| CL-3 | Encrypted export and restore of the ledger | iOS | L | In Review | |
| CL-4 | Benefit-deadline reminders: schedule them or hide the toggles | iOS | M | To Do | |
| CL-5 | Real bundle ID, signing team and version numbers | iOS | S | To Do | |
| CL-6 | Privacy manifest and export-compliance key | iOS | S | To Do | CL-5 |
| CL-7 | Share the Xcode scheme | iOS | S | Done (392316a) | |
| CL-8 | TestFlight setup for internal and external testers | iOS, Ops | S | To Do | CL-5, CL-6 |
| CL-9 | CI workflow that runs the service and iOS tests | Infra | M | Done (f4d284f, 69cb4da) | CL-7 |
| CL-10 | Plaid Production access for alpha users, including Liabilities | Ops | Ext | To Do | CL-11 |
| CL-11 | Privacy policy, terms and data-deletion statement | Legal, iOS | M | To Do | |
| CL-12 | SES production access for sign-in email | Ops | Ext | To Do | |
| CL-13 | Service alarms and an external uptime check | Infra | M | To Do | |

### P2: alpha period

| ID | Title | Area | Size | Status | Depends on |
|---|---|---|---|---|---|
| CL-14 | In-app feedback with a diagnostics report that holds no transaction data | iOS | M | To Do | |
| CL-15 | Onboarding that starts with the tester's own cards, not sample data | iOS | M | To Do | |
| CL-16 | Bank coverage hints in the catalog (`plaidSupport`) | Catalog, iOS | M | To Do | |
| CL-17 | OFX and QFX statement import | iOS | M | To Do | |
| CL-18 | Generic CSV import with column mapping | iOS | L | To Do | |
| CL-19 | Background refresh: sync and reschedule reminders | iOS | M | To Do | CL-4 |
| CL-20 | Catalog updates from the service without a new build | API, iOS | M | To Do | |
| CL-21 | Reminder wording for stale data ("open to refresh") | iOS | S | To Do | CL-4 |
| CL-22 | Alpha tester guide | Docs | S | To Do | CL-2, CL-8 |
| CL-23 | Fix the stale status table in the CardLedger README | Docs | S | Done (8e4394d) | |
| CL-24 | Run the Semgrep source scan locally | Infra | S | To Do | |
| CL-25 | Measure merchant-category and descriptor quality during the pilot | iOS | M | To Do | CL-14 |

### P3: before beta

| ID | Title | Area | Size | Status | Depends on |
|---|---|---|---|---|---|
| CL-26 | Review queue for likely card-linked offer credits | iOS | M | To Do | |
| CL-27 | Manual points rewards for offers, and the Amex rewards-summary bonus | iOS | M | To Do | |
| CL-28 | Per-bank offer rules as real samples arrive | iOS | M | To Do | CL-26 |
| CL-29 | Learn a credit descriptor from one confirmed credit | iOS | M | To Do | |
| CL-30 | Mark a statement credit used by hand on cards without a feed | iOS | S | To Do | |
| CL-31 | Catalog fixes from the November audit | Catalog | M | To Do | |
| CL-32 | Date-aware catalog for replay and upcoming fee changes | Catalog, iOS | L | To Do | CL-20 |
| CL-33 | Full-terms verification of catalog profiles | Catalog | L | In Progress | |
| CL-34 | Rotating categories with activation reminders | Catalog, iOS | M | To Do | CL-4 |
| CL-35 | Annual-fee advance notice | iOS | S | To Do | CL-4 |
| CL-36 | Statement closing-date reminders | iOS | S | To Do | CL-4 |
| CL-37 | Loyalty program balances, entered by hand | iOS | M | To Do | |
| CL-38 | Card watchlist | iOS | S | To Do | |
| CL-39 | Home and lock screen widgets from a non-financial snapshot | iOS | M | To Do | |
| CL-40 | Localization with String Catalogs: English, Simplified and Traditional Chinese | iOS | M | To Do | |
| CL-41 | Hide the timing difference in email sign-in start | API | S | To Do | CL-1 |
| CL-42 | Invite administration beyond the command line | API | M | To Do | CL-1 |

### P4: later or needs a decision

| ID | Title | Area | Size | Status | Depends on |
|---|---|---|---|---|---|
| CL-43 | SimpleFIN Bridge adapter for banks Plaid covers poorly | API | L | To Do | Policy decision |
| CL-44 | Shortcuts action that logs Apple Pay taps | iOS | M | To Do | |
| CL-45 | Read-only snapshot on a second device | iOS, API | L | To Do | Policy decision |
| CL-46 | CloudKit sync of non-financial data | iOS | L | To Do | Policy decision |
| CL-47 | Household profiles | iOS, API | L | To Do | Policy decision |
| CL-48 | Australian cards and banks | Catalog, API | L | To Do | |
| CL-49 | Apple Card through FinanceKit | iOS | L | Blocked | Organization account, App Store release |
| CL-50 | Run several API instances behind a load balancer | Infra | L | To Do | |
| CL-51 | Shared rate limits at the edge (AWS WAF) | Infra | M | To Do | CL-50 |
| CL-52 | Public App Store version without bank linking | iOS | L | To Do | Policy decision |

## Tickets

### P1

#### CL-1 · Invite-only sign-up and per-user connection limit
**Status:** Done (4c850f3) · **Area:** API, iOS · **Size:** M
- **Why:** Anyone who could receive email could create an account and link banks through our Plaid keys.
- **Delivered:** `SIGNUP=invite` by default outside mock mode, single-use invites that expire, `npm run invite`, and `MAX_CONNECTIONS_PER_USER` (default 10). Both new errors have messages in the app.

#### CL-2 · Deploy the invite gate and invite the first testers
**Status:** To Do · **Area:** Ops · **Size:** S · **Depends on:** CL-1
- **Why:** Production still allows open sign-up until the API is redeployed.
- **Done when:**
  - `SIGNUP=invite` is in `/etc/card-ledger/api.env` and the new API is deployed.
  - An uninvited address gets no email.
  - Each tester has an invite.

#### CL-3 · Encrypted export and restore of the ledger
**Status:** In Review · **Area:** iOS · **Size:** L
- **Why:** The database is excluded from backup and its key never leaves the device. Deleting the app or changing phones loses imports, review decisions and overrides. **Settings → Export encrypted archive…** does nothing today.
- **Done when:**
  - Export writes one file encrypted with a passphrase the tester chooses.
  - Restore on a fresh install brings back cards, transactions, decisions, overrides and settings.
  - A wrong passphrase or a damaged file is rejected without changing the ledger.
  - Tests cover a full export, restore and comparison.
- **Implemented:** `LedgerArchive` (`CLBK` v1 container: PBKDF2-HMAC-SHA256 with 600,000 iterations + AES-256-GCM with 42-byte header bound as AAD), atomic SQLCipher snapshot export/restore across all 10 tables (`LedgerRepository+Archive`), `Store+Archive` settings reload, and Export/Restore sheets in **Settings → Privacy**, with round-trip and tamper regression tests in `Tests/LedgerArchiveTests.swift`.

#### CL-4 · Benefit-deadline reminders: schedule them or hide the toggles
**Status:** To Do · **Area:** iOS · **Size:** M
- **Why:** The 14, 7 and 2-day toggles in Settings save a preference, but nothing schedules a notification from it.
- **Done when:**
  - Benefit deadlines schedule local notifications at 9 AM for the chosen offsets, with the same generic lock-screen text as bill reminders.
  - Turning an offset off cancels its notifications.
  - Tests cover scheduling and cancelling.
  - If this is postponed, the toggles are hidden instead.

#### CL-5 · Real bundle ID, signing team and version numbers
**Status:** To Do · **Area:** iOS · **Size:** S
- **Why:** The bundle ID is `local.prototype.CardLedger` and the version is 0.1 (1). TestFlight needs a registered ID, and passkeys need a matching `PASSKEY_APP_ID`.
- **Done when:**
  - The app and test targets use the registered ID and the signing team.
  - The marketing version is set for alpha and the build number goes up with each upload.
  - `PASSKEY_APP_ID` and the Apple app-site association file match the new ID.

#### CL-6 · Privacy manifest and export-compliance key
**Status:** To Do · **Area:** iOS · **Size:** S · **Depends on:** CL-5
- **Why:** There is no `PrivacyInfo.xcprivacy`, and `ITSAppUsesNonExemptEncryption` isn't set. The app uses SQLCipher and talks to its API over TLS.
- **Done when:**
  - The manifest declares the required-reason APIs the app and its packages use, and the data it collects (none for tracking).
  - The encryption key is set with the right answer for SQLCipher.
  - An App Store Connect upload passes validation.

#### CL-7 · Share the Xcode scheme
**Status:** Done (392316a) · **Area:** iOS · **Size:** S
- **Why:** A clean checkout relied on Xcode generating a scheme, so the test configuration could vary by Mac.
- **Done when:**
  - The scheme is in `xcshareddata` and committed.
  - The test command in AGENTS.md works on a clean checkout with the ID of an available iPhone simulator.
- The developer instructions show how to select a simulator by ID and wait for first-boot setup. All 27 iOS tests passed from a clean copy on an iOS 27.2 simulator.

#### CL-8 · TestFlight setup for internal and external testers
**Status:** To Do · **Area:** iOS, Ops · **Size:** S · **Depends on:** CL-5, CL-6
- **Done when:**
  - The app record exists, with an internal group and an external alpha group.
  - The external group has passed beta review.
  - The first build is installed by a tester.

#### CL-9 · CI workflow that runs the service and iOS tests
**Status:** Done (f4d284f, 69cb4da) · **Area:** Infra · **Size:** M · **Depends on:** CL-7
- **Why:** The security scan workflow did not run the service or iOS test suites.
- **Done when:**
  - Pushes to `main` run `npm run typecheck && npm test` and `xcodebuild test` on a macOS runner.
  - Actions are pinned to a commit SHA with a version comment.
  - A failing test fails the run.
- The Tests workflow runs for pull requests and pushes to `main`. It uses Ubuntu with Node 26 for the owner service, and the `xcode-27` image's default Xcode with the newest installed iPhone 17 simulator for iOS. Install scripts are skipped, and a newer push cancels the older run. Both suites passed locally, and the workflow commands surfaced simulated failures. The first run on GitHub (run 44675001862, commit 69cb4da) passed both jobs.

#### CL-10 · Plaid Production access for alpha users, including Liabilities
**Status:** To Do · **Area:** Ops · **Size:** Ext · **Depends on:** CL-11
- **Why:** Production use by people other than the owner needs Plaid's approval for that use case. Bill dates need Liabilities.
- **Done when:**
  - Plaid has approved the use case and the Transactions and Liabilities products.
  - Link shows the privacy policy.
  - An outside tester links a card on Production.

#### CL-11 · Privacy policy, terms and data-deletion statement
**Status:** To Do · **Area:** Legal, iOS · **Size:** M
- **Done when:**
  - The documents are published at stable URLs.
  - They're linked from sign-in, Settings, Plaid Link and App Store Connect.
  - The deletion statement matches what `DELETE /v1/me` and **Delete local history** actually remove.

#### CL-12 · SES production access for sign-in email
**Status:** To Do · **Area:** Ops · **Size:** Ext
- **Why:** In the SES sandbox, codes only reach verified addresses.
- **Done when:** AWS grants production access and an unverified tester address receives a code.

#### CL-13 · Service alarms and an external uptime check
**Status:** To Do · **Area:** Infra · **Size:** M
- **Why:** The service only writes logs, so nobody hears about an outage until a tester reports it.
- **Done when:**
  - CloudWatch alarms cover the 5xx rate, instance status checks, disk use and the SES bounce and complaint rate.
  - An outside check polls `/v1/health`.
  - Alerts reach the owner.

### P2

#### CL-14 · In-app feedback with a diagnostics report that holds no transaction data
**Status:** To Do · **Area:** iOS · **Size:** M
- **Why:** Testers need a way to report problems that doesn't break the rule "never log transactions".
- **Done when:**
  - **Settings → Send feedback** attaches the app version, API version, sync state for each connection and parser failure codes.
  - The report never includes descriptions, amounts, account numbers or tokens, and a test checks this.
  - MetricKit crash and hang reports can be included, if the tester agrees.

#### CL-15 · Onboarding that starts with the tester's own cards, not sample data
**Status:** To Do · **Area:** iOS · **Size:** M
- **Done when:**
  - First launch offers "Add my cards" ahead of sample data.
  - Leaving sample mode clears sample cards.
  - Each path (link a bank, import a statement, enter manually) is one tap away.

#### CL-16 · Bank coverage hints in the catalog (`plaidSupport`)
**Status:** To Do · **Area:** Catalog, iOS · **Size:** M
- **Why:** 23 of 154 catalog cards are unsupported or unreliable on Plaid (see `Plaid-Coverage-Report.md`).
- **Done when:**
  - `build_catalog.py` checks and writes `plaidSupport` (`oauth`, `credential`, `limited` or `unsupported`).
  - Adding an `unsupported` card suggests statement import instead of Plaid Link.

#### CL-17 · OFX and QFX statement import
**Status:** To Do · **Area:** iOS · **Size:** M
- **Why:** One parser covers Apple Card, Rogers, MBNA, Capital One Canada and many other banks.
- **Done when:**
  - OFX 1.x (SGML) and 2.x (XML) files import through the existing import screen.
  - Importing the same file again adds nothing new.
  - Ambiguous input is reported, not guessed.
  - Synthetic fixtures are tested.

#### CL-18 · Generic CSV import with column mapping
**Status:** To Do · **Area:** iOS · **Size:** L
- **Why:** CSV and PDF import read only Amex Canada today.
- **Done when:**
  - The tester maps the date, description and amount columns (or separate debit and credit columns), and the date format.
  - The mapping is saved per card.
  - Dates where both parts are 12 or less are refused unless the format is set.
  - Re-imports are idempotent.

#### CL-19 · Background refresh: sync and reschedule reminders
**Status:** To Do · **Area:** iOS · **Size:** M · **Depends on:** CL-4
- **Done when:**
  - A background refresh task syncs connections that have updates and refreshes bill dates.
  - Bill and benefit reminders are rescheduled from the result.
  - The task is cancelled cleanly when iOS ends it.

#### CL-20 · Catalog updates from the service without a new build
**Status:** To Do · **Area:** API, iOS · **Size:** M
- **Done when:**
  - The API serves a versioned, signed `catalog.json`.
  - The app accepts only a newer version with a valid signature.
  - The bundled catalog stays as the fallback.

#### CL-21 · Reminder wording for stale data
**Status:** To Do · **Area:** iOS · **Size:** S · **Depends on:** CL-4
- **Done when:** a reminder built from data more than a day old says the credit "may already be used. Open Card Ledger to refresh."

#### CL-22 · Alpha tester guide
**Status:** To Do · **Area:** Docs · **Size:** S · **Depends on:** CL-2, CL-8
- **Done when:** one page covers getting an invite, installing from TestFlight, what to test, known limits, how to send feedback and how to delete data.

#### CL-23 · Fix the stale status table in the CardLedger README
**Status:** Done (8e4394d) · **Area:** Docs · **Size:** S
- **Done when:** `CardLedger/README.md` no longer lists CSV import as a stub, and describes export and benefit reminders accurately.
- The README records support for American Express Canada CSV activity, saved benefit reminder preferences, and the encrypted export placeholder.

#### CL-24 · Run the Semgrep source scan locally
**Status:** To Do · **Area:** Infra · **Size:** S
- **Why:** `security/scan_source.py --offline` exits with "could not produce a valid report" because Semgrep isn't installed on the dev Mac.
- **Done when:** the setup steps are in `security/README.md` and the offline scan reports zero findings.

#### CL-25 · Measure merchant-category and descriptor quality during the pilot
**Status:** To Do · **Area:** iOS · **Size:** M · **Depends on:** CL-14
- **Done when:**
  - The diagnostics report includes, per institution, the share of transactions with a merchant category code and the share of credits matched automatically. Only counts, never content.
  - The results are written up in a design note.

### P3

#### CL-26 · Review queue for likely card-linked offer credits
**Status:** To Do · **Area:** iOS · **Size:** M
- **Why:** Offer credits are confirmed only from Amex tags today. The shape heuristic in `Card-Linked-Offers-Design.md` should propose candidates for the owner to review.
- **Done when:**
  - Candidates show in the review queue with **Confirm offer**, **It's a refund** and **It's a benefit credit**.
  - Decisions persist across syncs.

#### CL-27 · Manual points rewards for offers, and the Amex rewards-summary bonus
**Status:** To Do · **Area:** iOS · **Size:** M
- **Done when:**
  - The owner can add a points-only offer reward, valued at their point value.
  - The Amex PDF parser reads the bonus column of the rewards summary.

#### CL-28 · Per-bank offer rules as real samples arrive
**Status:** To Do · **Area:** iOS · **Size:** M · **Depends on:** CL-26
- **Done when:** each rule (Chase, RBC, Amex US and others) is added only with a real sample, redacted into a synthetic fixture, and a test.

#### CL-29 · Learn a credit descriptor from one confirmed credit
**Status:** To Do · **Area:** iOS · **Size:** M
- **Done when:** confirming a credit by hand offers to save its descriptor as a rule for that card, and later matching credits are confirmed automatically.

#### CL-30 · Mark a statement credit used by hand on cards without a feed
**Status:** To Do · **Area:** iOS · **Size:** S
- **Done when:** a manual card's credit can be marked used for an amount and date, and the effective fee includes it. First check whether the existing manual-evidence path already covers this.

#### CL-31 · Catalog fixes from the November audit
**Status:** To Do · **Area:** Catalog · **Size:** M
- **Done when:**
  - Sapphire Reserve's The Edit credit uses a USD 500 calendar-year cap.
  - Chase Aeroplan's two USD 50 Air Canada credits have a rule.
  - Chase Aeroplan's dining and grocery rate drops to 2× on Jan 1, 2027.
  - Home Trust cash back is limited to CAD purchases.
  - Rogers' account-level rates are marked as varying.

#### CL-32 · Date-aware catalog for replay and upcoming fee changes
**Status:** To Do · **Area:** Catalog, iOS · **Size:** L · **Depends on:** CL-20
- **Why:** Replay uses today's rules for past transactions. Fee increases are coming in January and February 2027 (Amex Aeroplan, CIBC and TD Infinite Privilege, Citi AAdvantage Platinum Select, Marriott Canada).
- **Done when:**
  - Rules and fees carry effective dates.
  - Replay and the effective fee use the terms in force on each date.

#### CL-33 · Full-terms verification of catalog profiles
**Status:** In Progress · **Area:** Catalog · **Size:** L
- **Done when:** every held or watchlisted card has `status: verified` with a `checked` date. Other profiles stay pending until someone holds them.

#### CL-34 · Rotating categories with activation reminders
**Status:** To Do · **Area:** Catalog, iOS · **Size:** M · **Depends on:** CL-4
- **Done when:**
  - Quarterly categories (Freedom Flex, Discover it) are versioned by quarter.
  - The owner can record activation.
  - A reminder fires when a new quarter opens.

#### CL-35 · Annual-fee advance notice
**Status:** To Do · **Area:** iOS · **Size:** S · **Depends on:** CL-4
- **Done when:** a reminder fires 30 days before the inferred renewal date, showing the effective fee so far.

#### CL-36 · Statement closing-date reminders
**Status:** To Do · **Area:** iOS · **Size:** S · **Depends on:** CL-4
- **Done when:** a closing day can come from Liabilities or be entered by hand, and an optional reminder fires before it.

#### CL-37 · Loyalty program balances, entered by hand
**Status:** To Do · **Area:** iOS · **Size:** M
- **Done when:** the owner records a balance and its date for each program, and the wallet summary shows the value at their point values.

#### CL-38 · Card watchlist
**Status:** To Do · **Area:** iOS · **Size:** S
- **Done when:** catalog cards can be watchlisted with notes and compared in Best Card without being added to the wallet.

#### CL-39 · Home and lock screen widgets from a non-financial snapshot
**Status:** To Do · **Area:** iOS · **Size:** M
- **Done when:**
  - An App Group snapshot holds only category-to-card nicknames and "next deadline in N days".
  - Amounts appear only if the owner turns them on.
  - Widgets never open the encrypted database.

#### CL-40 · Localization with String Catalogs
**Status:** To Do · **Area:** iOS · **Size:** M
- **Done when:**
  - All UI text is in a String Catalog, with English, Simplified Chinese and Traditional Chinese.
  - Catalog display names can be localized separately.

#### CL-41 · Hide the timing difference in email sign-in start
**Status:** To Do · **Area:** API · **Size:** S · **Depends on:** CL-1
- **Why:** An address that gets an email may answer slightly slower than one that doesn't, because sending through SES takes time. That could reveal which addresses have an account or invite.
- **Done when:** the response no longer waits for the SES call, failures are still logged without the address, and a test covers both paths.

#### CL-42 · Invite administration beyond the command line
**Status:** To Do · **Area:** API · **Size:** M · **Depends on:** CL-1
- **Done when:** the owner can see how many invites are outstanding and when each expires, without storing plain email addresses. Running a command on the instance is no longer the only way.

### P4

#### CL-43 · SimpleFIN Bridge adapter for banks Plaid covers poorly
**Status:** To Do · **Area:** API · **Size:** L · **Depends on:** policy decision
- **Why:** It reaches MBNA Canada and offers a fallback for Rogers, PC Financial, Canadian Tire and Bilt. It adds SimpleFIN and MX as data processors.

#### CL-44 · Shortcuts action that logs Apple Pay taps
**Status:** To Do · **Area:** iOS · **Size:** M
- **Done when:** an App Intent records a pending entry from the Wallet transaction automation, and a statement import later matches and replaces it.

#### CL-45 · Read-only snapshot on a second device
**Status:** To Do · **Area:** iOS, API · **Size:** L · **Depends on:** policy decision
- Option A in `Feasibility-Study.md`: an end-to-end encrypted snapshot sent through the API.

#### CL-46 · CloudKit sync of non-financial data
**Status:** To Do · **Area:** iOS · **Size:** L · **Depends on:** policy decision
- Option B in `Feasibility-Study.md`: sync cards, lifecycle, watchlist and settings only. Transactions stay on the device.

#### CL-47 · Household profiles
**Status:** To Do · **Area:** iOS, API · **Size:** L · **Depends on:** policy decision

#### CL-48 · Australian cards and banks
**Status:** To Do · **Area:** Catalog, API · **Size:** L

#### CL-49 · Apple Card through FinanceKit
**Status:** Blocked · **Area:** iOS · **Size:** L
- **Blocked by:** FinanceKit needs an organization developer account and public App Store distribution. Until then, use OFX or CSV import (CL-17, CL-18).

#### CL-50 · Run several API instances behind a load balancer
**Status:** To Do · **Area:** Infra · **Size:** L
- **Done when:** the API runs behind an Application Load Balancer with sticky sessions or a shared per-Item lock. The connection limit (CL-1) and rate limits work across instances.

#### CL-51 · Shared rate limits at the edge (AWS WAF)
**Status:** To Do · **Area:** Infra · **Size:** M · **Depends on:** CL-50

#### CL-52 · Public App Store version without bank linking
**Status:** To Do · **Area:** iOS · **Size:** L · **Depends on:** policy decision
- A manual and statement-import version for the public, with Plaid kept private. See section 4 of `Feasibility-Study.md`.
