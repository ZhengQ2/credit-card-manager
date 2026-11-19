# Card Ledger — prototype

A SwiftUI app implementing `../iOS-Credit-Card-Manager-Design.docx`, plus the RewardRadar-style expansion described in `../Feasibility-Study.md`.

Bank data comes through Plaid via the Card Ledger API at `https://api.zhengqiu.net` (source and runbook in `../owner-service`). You sign in with an emailed one-time code. Transactions are stored only on the iPhone, in a SQLCipher-encrypted database. Until you map a linked card, the app shows synthetic sample data.

## Run
Open `CardLedger.xcodeproj` in Xcode 27.1 or later and run on an iOS 18 or later simulator. To build from the command line:

```bash
xcodebuild -project CardLedger.xcodeproj -scheme CardLedger -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

To check iPhone Duo, use Device Hub to open and close the simulator while viewing card or transaction details, then rotate the outer display. The inner display can show a sidebar, while the outer display uses the system tab bar. Liquid Glass controls appear on iOS 26 and later.

## Credit card bill alerts

In **Overview → More → Settings**, turn on **Bill payment alerts** and allow iOS notifications. Once a linked bank reports an upcoming payment due date, it appears in Overview. The app schedules generic alerts for 9 AM local time three days before and on the due date, for times that are still ahead.

The mock API provides synthetic due dates after you link and add a mock card. For Sandbox or Production, set `PLAID_BILL_ALERTS=1` on the [API](../owner-service/README.md). If an existing connection needs consent, use **Authorize bill dates** in Settings to update it through Plaid Link. Dates refresh on app open or sync when due for refresh, and you can request a fresh check in Settings. Open the app periodically to pick up new statement cycles. Coverage varies by bank, and manually added cards and connections without a reported date have no scheduled bill alert.

## What's real vs. stubbed
| Area | Status |
|---|---|
| Benefit matching (descriptor match, late-credit attribution, partial allocation, refunds, review queue, owner decisions) | Working engine, `Engine/BenefitEngine.swift` |
| Overview, benefit detail, credit review, Activity, transaction evidence, Spending (CAD and USD kept separate) | Working |
| Best Card per category with ledger-based remaining caps, pins, point values, FX assumption | Working, `Engine/RewardsEngine.swift` |
| Compare cards (date-ordered replay with caps, airfare first) | Working. Statement credits are not reallocated |
| Wallet summary, 5/24 count, effective annual fee, renewal inferred from posted fee | Working |
| Account sign-in (email code, 15-minute access token, rotating refresh token in Keychain), sign-out, account deletion | Working |
| Plaid Link (LinkKit 6.5.8, SwiftUI) and update-mode reconnect | Wired. Exercised end to end only against the mock service |
| Account → card mapping, transactions sync (staged pages, atomic commit with cursor, mutation replay, backoff) | Working |
| Pending → posted keeps the stable local ID, so overrides and matches survive | Working |
| Encrypted storage: SQLCipher 4.20 (AES-256, WAL), 256-bit key in a device-only Keychain entry, Complete file protection, excluded from backup | Working, checked on disk |
| Persisted review decisions and category overrides | Working |
| Disconnect (Plaid Item removal, with retry state) and delete local history | Working |
| Face ID, Touch ID, or passcode lock, privacy cover in the app switcher | Working |
| Automatic credit card bill alerts | Works with mock cards and supported Plaid Liabilities connections |
| CSV import, benefit deadline reminders, encrypted export | UI stubs only |

Sample data is generated relative to today (`Engine/SampleData.swift`), so there are always live deadlines.

## Tests
The `CardLedgerTests` target runs the engine checks (`Tests/EngineTests.swift`) and the PDF statement checks (`Tests/PDFStatementTests.swift`) inside the app host:

```bash
xcodebuild test -project CardLedger.xcodeproj -scheme CardLedger -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Each failing check is reported with its line. PDF fixtures are synthetic. Never add a real statement to the repository.

## Card catalog
`CardLedger/Resources/catalog.json` is bundled and versioned. Version 2026.11.5 includes 154 card profiles and two generic fallbacks across the U.S. and Canada, with 37 reward programs and 30 tracked credit rules. The [November 2026 catalog audit](CardLedger-Catalog-Audit.md) records the fee review for version 2026.11.4. For newer profiles, see the issuer link on each card.

Version 2026.11.5 adds 39 cards. U.S. additions include United Gateway, Quest and Club, Wells Fargo Autograph Journey, Chase Sapphire Reserve for Business, Capital One Venture X Business and Citi AAdvantage Globe and Executive. Canadian additions include BMO VIPorter, RBC ION, RBC British Airways, PC Insiders, Rogers Red World and World Legend, and additional no-fee cards from CIBC, TD, Scotiabank, MBNA and Tangerine.

- **US issuers:** Amex, Chase (including the Air Canada Aeroplan, Amazon Prime, Marriott, IHG, Southwest and Ink cards), Capital One, Citi (including Costco and AAdvantage), U.S. Bank, Bank of America (including Atmos Rewards), Wells Fargo, Discover, Apple, Bilt (Blue, Obsidian, Palladium) and Robinhood.
- **Canadian issuers:** Amex (Cobalt, Platinum, Gold, Green, SimplyCash, Aeroplan and Aeroplan Reserve, Marriott personal and business, Hilton), TD, CIBC, RBC, BMO, Scotiabank, Wealthsimple, Rogers Bank, Capital One Canada, PC Financial, Canadian Tire, MBNA, Tangerine, Simplii, National Bank and Home Trust.
- **Aeroplan:** every personal tier is included. That's TD Platinum, Infinite and Infinite Privilege; CIBC Visa, Infinite and Infinite Privilege; Amex Aeroplan and Reserve; plus TD Business and the Chase US card. A linked account is matched to its tier by name and to its bank by institution.
- **Picker:** search by card or issuer, and filter to personal or business.
- **Card artwork.** The wallet, detail screen, and picker use the same original SwiftUI geometry and unique product abbreviation. Each abbreviation is keyed to the catalog ID so it stays stable as product names change.

- **Edit the source, not the JSON.** Change `catalog-src/build_catalog.py`, then run `python3 catalog-src/build_catalog.py`. The script checks for unique IDs, valid categories and periods, consistent program currencies and https sources before it writes the JSON.
- **Full terms status.** Set `status` to `verified` and record `checked` once the modeled fees, earn rules, credits, and perks have been reviewed. The annual-fee audit alone leaves the full terms status pending. The detail screen links to the source and shows account-specific and upcoming changes where documented.
- **Bonuses the feed can't confirm are counted at the base rate.** That covers booking-portal bonuses, rotating categories (Freedom Flex, Discover it), top-category cards (Custom Cash) and categories you choose (Cash+, Customized Cash). Best Card and Compare mark these "varies".
- **Credit descriptors are guesses until the pilot.** A credit that doesn't match its descriptor goes to review instead of being confirmed automatically.
- **Credits that reset on your account anniversary (`cardmemberYear`)** use the card's renewal date. With no renewal date they fall back to the calendar year.
- **Rewards caps that reset per cardmember year** use the recorded renewal date or the opening month.
