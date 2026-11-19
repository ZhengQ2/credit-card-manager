# Feasibility Study: iOS Credit Card Manager (v1.0 design) + RewardRadar-style expansion

Date: 2026-11-18 · Source: `iOS-Credit-Card-Manager-Design.docx` (v1.0)

## 1. Verdict

**The design is feasible as written for a single-owner private release.** Its riskiest parts are external: Plaid Production access and how well issuer descriptors work. The Swift and TypeScript work is routine.

**Most of RewardRadar's features fit this design. Several are easier here because this app has a real transaction ledger and RewardRadar does not.** Two RewardRadar traits conflict with the current constraints:

1. **iCloud sync, multiple devices and multiple profiles.** The doc forbids iCloud and CloudKit and assumes one authoritative iPhone.
2. **A broad, maintained card catalog for the US, Canada and Australia.** This is an ongoing data-operations job, not an engineering problem.

Everything else fits as local-only additions. That covers best card per category, widgets, points programs, application and 5/24 tracking, annual-fee and payment reminders, and localization.

---

## 2. Feasibility of the current design

### 2.1 What is solid
- **Sync protocol (§7).** `/transactions/sync` with a cursor per Item, staging, an atomic commit, and replay when pagination mutates follows Plaid's documented pattern. Handling pending-to-posted substitution through `pending_transaction_id` is correct.
- **Ledger and matching (§4, §8).** Signed minor units, stable local IDs, allocations capped by source, cap and purchase, and overrides that survive resyncs. The model is sound, and it is the hardest part to retrofit later, so it is right to design it up front.
- **Date handling (§5).** Date-only values, the issuer's calendar, and windows with an inclusive start and exclusive end are correct. Sending boundary cases to review, instead of guessing, is the right default.
- **Privacy boundary (§6).** The owner service holds the tokens and the phone holds the data. This is coherent and simple to audit.

### 2.2 Risks and gaps (ranked)

| # | Risk | Impact | Mitigation |
|---|------|--------|-----------|
| 1 | **Plaid Production access for an individual.** Plaid's Production approval targets businesses, and it reviews your use case, company profile and security questionnaire. A personal, single-user app may get limited or trial access, or be rejected. | Blocks the whole Plaid path | Apply first, before writing UI. Keep the CSV and manual path as a complete product, not just a fallback, so v1 ships either way. |
| 2 | **Issuer credit descriptors.** Auto-confirmation needs a "strong issuer credit descriptor". Amex statement-credit text in Plaid can be truncated or generic, and CIBC's is unknown. | Most credits fall into review, which is tedious | The doc already gates this in the pilot. Add a fallback: confirm one credit by hand, then learn that descriptor and suggest it as a rule. |
| 3 | **Reaching the owner service from mobile networks.** API routes run over the LAN or an owner-operated VPN. The doc says "avoid a hosted proxy or tunnel", and Tailscale or Cloudflare Tunnel arguably count. | Syncs fail away from home | Decide now. Either self-host WireGuard on the home router, or accept syncing only at home or on VPN. The design already tolerates stale data. |
| 4 | **No background data freshness.** Remote push is disabled and BGAppRefresh is best-effort, so balances and reminders reflect only the last foreground sync. | A reminder may fire for a credit that was already used | Reminders already say "last sync". Add a reminder copy variant such as "may already be used — open to refresh". |
| 5 | **Merchant category code (MCC) coverage.** Issuers decide earning by MCC. Plaid's Transaction object does have a `merchant_category_code` field (plaid-node 51), but how often it is filled for each institution is unverified. | Where MCC is missing, rewards replay and category recommendations are approximate | The app prefers MCC when present and falls back to `personal_finance_category`. Measure fill rate in the pilot. Owner category overrides are kept across syncs. |
| 6 | **Catalog staleness.** Amex refreshed the Platinum credits in 2025, adding several quarterly and semiannual credits. The seed list is a subset and will drift. | Missing or wrong benefits | Make the catalog a versioned JSON bundle updatable from the owner service. It is not financial data, so this does not breach §6. Record the source URL and a "last verified" date for each rule (the doc already requires source URLs). |
| 7 | **"Strict storage compliance" relies on the owner turning off iCloud device backup.** Apple treats backup exclusion as advisory. | Policy gap, not a technical one | Already acknowledged in the doc. Add a launch-time check and warning in Settings. |
| 8 | **Plaid product scope.** Only Transactions is enabled. Statement closing dates, due dates and balances need **Liabilities**, which RewardRadar-style reminders depend on (§3.4). | Feature gap | Add Liabilities in the pilot request, or enter these dates manually. |

### 2.3 Effort (rough, one experienced iOS/TS developer)
| Phase | Scope | Estimate |
|---|---|---|
| Pilot | Owner service, pairing, Link plus OAuth Universal Link, sync, account mapping, CSV import | 4–6 weeks |
| v1 | Rules engine, matching and review, reminders, Overview, Activity, Spending | 6–8 weeks |
| v1.1 | Rewards catalog and replay comparison (airfare first) | 3–4 weeks |

---

## 3. RewardRadar feature mapping

RewardRadar is a manual-entry app. You add cards, it loads catalog rates and credits, and you mark benefits used. Its strengths are catalog breadth, "which card to use", widgets and wallet bookkeeping. This design is stronger on evidence, because it has the real transactions.

| RewardRadar feature | Fit with this design | Effort | Notes |
|---|---|---|---|
| Benefit and credit trackers sorted by due date, custom trackers | **Already exceeded** | — | §4–5 auto-match evidence from transactions. Add a one-tap **Mark used** for cards without a feed (the manual evidence option already exists in §4). |
| Best card per spending category | **Good fit** | M | Pure function of the rewards catalog (v1.1) plus held cards. Add a **Which card?** screen. |
| Spend caps with remaining bonus, falling back to the next-best card | **Better here** | S (after v1.1) | RewardRadar tracks caps through manual or estimated spend. This app has the actual ledger, so the remaining cap comes from posted purchases. |
| Rotating quarterly categories (Freedom, Discover it…) | Good fit | S + ongoing data | Calendar-versioned reward rules plus an enrollment flag. Remind the owner to activate each quarter. |
| User pins a preferred card for a category | Good fit | S | A local override row. |
| Points and miles programs with custom point values | Good fit | S–M | §9 already has per-point values. Add a `LoyaltyProgram` entity. **Balances are manual**, because Plaid has no loyalty data. |
| Home and lock screen widgets | Fit with care | M | WidgetKit cannot open the encrypted DB while the phone is locked. Write a small **non-financial snapshot** to the App Group, such as category → card nickname and "next deadline in N days". Make amounts opt-in, consistent with the generic lock-screen default in §5. |
| Payment due and statement closing reminders | Fit | S (manual) / M (Liabilities) | Local notifications reuse the §5 reminder engine. Get dates from Plaid Liabilities or manual entry. |
| Advance notice of annual fees, effective annual fee | **Better here** | S | The renewal date already exists in §5. Effective fee = fee − confirmed credit value used in the last membership year, from real allocations. |
| Wallet summary, application timeline, 5/24 count, authorized-user exclusion, product-change history, watchlist | Good fit | M | Pure local bookkeeping. Plaid does not provide open dates, so the owner enters them. Add `CardLifecycleEvent` (applied, approved, product change, closed) and `Watchlist`. |
| Lounge and travel-protection details | Fit (catalog only) | S code + data | Static catalog fields shown on card detail. |
| Large card database for the US, Canada and Australia; user-submitted cards | **Partial** | Ongoing | For one owner, catalog **held and watchlisted cards only** (likely 10–30). Custom products are already allowed (§3). Defer Australia: the doc's Plaid pilot is US and Canada only. |
| iCloud sync, iPad, Mac, Vision Pro | **Conflicts with §6** | — | See §4. |
| Multiple profiles (household) | **Conflicts with release scope** | M | Local profiles on the same phone are technically easy, but they break the "one owner" assumption in the Plaid and pairing model. Defer. |
| English, Simplified Chinese and Traditional Chinese UI | Good fit | S–M | Use String Catalogs from day one. Benefit text comes from the catalog, so localize catalog display names separately. |

S ≈ days, M ≈ 1–2 weeks.

### 3.1 Data model additions
- `RewardRule`: product, version, category, rate, unit, cap with period and reset basis, rotation calendar, enrollment required, effective dates, source URL.
- `CategoryMap`: Plaid PFC or merchant → reward category, with owner overrides.
- `LoyaltyProgram` and `ProgramBalance`: manual balance, as-of date, owner point value.
- `CardLifecycleEvent`: applied, approved, opened, product change, closed; authorized-user flag.
- `StatementSchedule`: closing day, due day, source (Liabilities or manual).
- `Watchlist`: catalog product with notes.
- `WidgetSnapshot`: an App Group file that is not part of the encrypted store.

None of these touch the sync protocol, and only `StatementSchedule` (through Liabilities) touches the owner service.

---

## 4. Constraint conflicts and options

**iCloud sync and multiple devices.** RewardRadar's selling point is "your data in your own iCloud". This design deliberately excludes iCloud, so Plaid is the only external financial processor.
- *Option A (recommended for private release):* stay single-device. Add a **read-only snapshot** pushed over the paired owner service to a second device, such as an iPad. That is owner infrastructure, so §6 still holds.
- *Option B:* allow CloudKit sync of **non-financial** data only: cards, lifecycle events, watchlist, program values, preferences. Transactions and allocations stay on the device. This is a policy change the owner must approve.
- *Option C:* full CloudKit sync with end-to-end encryption (Advanced Data Protection). This contradicts §6 as written.

**Going public like RewardRadar.** Turning this into a public App Store product would change the architecture, not just extend it. Each user cannot run their own Plaid server, so it would need a hosted multi-tenant token vault, a Plaid business contract, compliance work and per-Item Plaid costs. RewardRadar avoids all of this by having **no bank connection**. A public variant would most likely be a manual-only app, roughly RewardRadar plus CSV import, with Plaid kept as a private add-on.

---

## 5. Recommended roadmap change

| Release | Content |
|---|---|
| Pilot | As designed. **Add:** apply for Plaid Production (including Liabilities) in week 1, and decide how mobile networks reach the service. |
| v1 | As designed. **Add:** Mark used for manual cards, card lifecycle fields (open date, authorized-user flag), annual-fee reminder, String Catalogs. |
| v1.1 | Rewards catalog plus replay (as designed). **Add:** Which card? per category and remaining caps from the ledger, which reuse the same catalog. |
| v1.2 "Radar" | Widgets (snapshot), rotating categories with activation reminders, loyalty programs, wallet summary with 5/24, watchlist, lounge and protection info, statement and due-date reminders. |
| Later, needs policy decision | Second device or sync (option A or B), household profiles, Australia. |

**Bottom line:** keep the architecture. The RewardRadar layer is mostly catalog plus presentation on top of the v1.1 rewards catalog the doc already plans. The main new costs are maintaining catalog data and an explicit decision about sync.

---

### Sources
- RewardRadar App Store listing: https://apps.apple.com/us/app/rewardradar-credit-cards/id6481423239
- Thrifty Traveler, credit card benefits trackers: https://thriftytraveler.com/news/credit-card/credit-card-benefits-tracker/
