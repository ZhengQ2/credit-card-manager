# Card Ledger — prototype

A SwiftUI app implementing `../iOS-Credit-Card-Manager-Design.docx`, plus the RewardRadar-style expansion described in `../Feasibility-Study.md`.

Bank data comes through Plaid via the Card Ledger API at `https://api.zhengqiu.net` (source and runbook in `../owner-service`). You sign in with an emailed one-time code. Transactions are stored only on the iPhone, in a SQLCipher-encrypted database. Until you map a linked card, the app shows synthetic sample data.

## Run
Open `CardLedger.xcodeproj` in Xcode 27.1 or later and run the shared `CardLedger` scheme on an iPhone simulator with iOS 18 or later. For a command-line build, run `xcrun simctl list devices available` and replace `SIMULATOR_ID` with the ID of an installed iPhone simulator.

```bash
xcodebuild -project CardLedger.xcodeproj -scheme CardLedger -destination 'platform=iOS Simulator,id=SIMULATOR_ID' build
```

To check iPhone Duo, use Device Hub to open and close the simulator while viewing card or transaction details, then rotate the outer display. The inner display can show a sidebar, while the outer display uses the system tab bar. Liquid Glass controls appear on iOS 26 and later.

## Sign-in security

Existing users sign in with their usual email code, then open **Settings → Sign-in security** to set a password, add a passkey, or enable two-factor authentication. A password is optional. With two-factor authentication on, email and password sign-in both require an authenticator code or a one-time recovery code. Save the recovery codes shown during setup. A saved passkey signs in through Face ID, Touch ID, or the device passcode.

Passkeys require the [API passkey configuration](../owner-service/README.md#deploy-sign-in-security) and an app signed with Associated Domains. Release is configured for `webcredentials:api.zhengqiu.net`. A Debug build leaves the entitlement off by default. To test with an eligible provisioning profile and HTTPS service, set `CARD_LEDGER_PASSKEY_DOMAIN` to the service host and `CODE_SIGN_ENTITLEMENTS=Config/Passkeys.entitlements` in the Debug build settings.

## Bank data and bill alerts

At first sign-in, choose whether to set up automatic bill dates and reminders. If you skip, you can turn them on later from **Overview → More → Settings → Bill payment alerts**. Allow iOS notifications and approve bill dates for each bank you want to use. New bank connections offer that approval after you add cards. Choose **Authorize bill dates** in Settings to approve an existing connection.

Bank linking requests credit card transactions with up to 12 months of history by default. You can choose 24 months when linking. The app syncs only cards you add to your ledger. Manual cards and statement import work without linking a bank.

Upcoming due dates appear in Overview. The app schedules generic alerts for 9 AM local time three days before and on the due date, for times that are still ahead. Turning off the setting stops bill-date checks on this iPhone, clears saved dates, and cancels reminders. **Withdraw bill access** also stops future collection for that connection on the service. Disconnect the bank in Cards to remove the Plaid link.

The mock API provides synthetic dates after approval. For Sandbox or Production, set `PLAID_BILL_ALERTS=1` on the [API](../owner-service/README.md). Coverage varies by bank. Dates refresh on app open or sync, and Settings offers a manual refresh.

## Feature status

| Area | Status |
|---|---|
| Benefit matching (descriptor match, late-credit attribution, partial allocation, refunds, review queue, owner decisions) | Working engine, `Engine/BenefitEngine.swift` |
| Overview, benefit detail, credit review, Activity, transaction evidence, Spending (CAD and USD kept separate) | Working |
| Best Card per category with ledger-based remaining caps, pins, point values, FX assumption | Working, `Engine/RewardsEngine.swift` |
| Compare cards (date-ordered replay with caps, airfare first) | Working. Statement credits are not reallocated |
| Wallet summary, 5/24 count, effective annual fee, renewal inferred from posted fee | Working |
| Account sign-in with email or password, authenticator and recovery codes, passkeys, sign-out, account deletion | Sign-in security requires API v3. Passkeys also require Associated Domains. |
| Plaid Link (LinkKit 6.5.8, SwiftUI) and update-mode reconnect | Wired. Exercised end to end only against the mock service |
| Account → card mapping, transactions sync (staged pages, atomic commit with cursor, mutation replay, backoff) | Working |
| Pending → posted keeps the stable local ID, so overrides and matches survive | Working |
| Encrypted storage: SQLCipher 4.20 (AES-256, WAL), 256-bit key in a device-only Keychain entry, Complete file protection, excluded from backup | Working, checked on disk |
| Persisted review decisions and category overrides | Working |
| Disconnect (Plaid Item removal, with retry state) and delete local history | Working |
| Face ID, Touch ID, or passcode lock, privacy cover in the app switcher | Working |
| Automatic credit card bill alerts | Works with mock cards and supported Plaid Liabilities connections |
| PDF statements and CSV activity imports | Parsed on the iPhone with a review step before saving. CSV supports the American Express Canada activity export. |
| OFX and QFX statement imports | Supports legacy OFX and XML exports for one USD or CAD credit card. The review lists skipped rows. Repeat imports to the same card use the issuer's transaction IDs to skip duplicates. |
| Benefit deadline reminders | The 14-, 7-, and 2-day switches save your preferences. Notification scheduling is pending. |
| Encrypted export | Passphrase-encrypted `.cardledger` export (PBKDF2-HMAC-SHA256 + AES-256-GCM) and atomic restore in Settings → Privacy. |

In **Cards**, choose **Import OFX or QFX** from the add menu or from a card's detail screen. Choose the file, confirm the target card, and review the transactions before saving.

Sample data is generated relative to today (`Engine/SampleData.swift`), so there are always live deadlines.

## Tests
The shared `CardLedger` scheme runs `CardLedgerTests` inside the app host. The suite covers the engine, PDF, CSV, OFX and QFX imports, statement bills, and merchant categories. Use the simulator ID from the build instructions above.

```bash
xcodebuild test -project CardLedger.xcodeproj -scheme CardLedger -destination 'platform=iOS Simulator,id=SIMULATOR_ID'
```

The [Tests workflow](../.github/workflows/tests.yml) runs the owner-service and iOS suites for pull requests and pushes to `main`. Statement fixtures are synthetic. Never add a real statement to the repository.

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
