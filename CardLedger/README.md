# Card Ledger — prototype

A SwiftUI app implementing `../iOS-Credit-Card-Manager-Design.docx`, plus the RewardRadar-style expansion described in `../Feasibility-Study.md`.

Bank data comes through Plaid via your own owner service (`../owner-service`, see its README for setup). It is stored on the iPhone in a SQLCipher-encrypted database. Until you map a linked card, the app shows synthetic sample data.

## Run
Open `CardLedger.xcodeproj` in Xcode and run on an iOS 18 or later simulator. To build from the command line:

```bash
xcodebuild -project CardLedger.xcodeproj -scheme CardLedger -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## What's real vs. stubbed
| Area | Status |
|---|---|
| Benefit matching (descriptor match, late-credit attribution, partial allocation, refunds, review queue, owner decisions) | Working engine, `Engine/BenefitEngine.swift` |
| Overview, benefit detail, credit review, Activity, transaction evidence, Spending (CAD and USD kept separate) | Working |
| Best Card per category with ledger-based remaining caps, pins, point values, FX assumption | Working, `Engine/RewardsEngine.swift` |
| Compare cards (date-ordered replay with caps, airfare first) | Working. Statement credits are not reallocated |
| Wallet summary, 5/24 count, effective annual fee, renewal inferred from posted fee | Working |
| Pairing with the owner service (single-use code, device credential in Keychain) | Working |
| Plaid Link (LinkKit 6.5.8, SwiftUI) and update-mode reconnect | Wired. Exercised end to end only against the mock service |
| Account → card mapping, transactions sync (staged pages, atomic commit with cursor, mutation replay, backoff) | Working |
| Pending → posted keeps the stable local ID, so overrides and matches survive | Working |
| Encrypted storage: SQLCipher 4.20 (AES-256, WAL), 256-bit key in a device-only Keychain entry, Complete file protection, excluded from backup | Working, checked on disk |
| Persisted review decisions and category overrides | Working |
| Disconnect (Plaid Item removal, with retry state) and delete local history | Working |
| Face ID or passcode lock, privacy cover in the app switcher | Working |
| CSV import, local reminders, encrypted export | UI stubs only |

Sample data is generated relative to today (`Engine/SampleData.swift`), so there are always live deadlines.

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
