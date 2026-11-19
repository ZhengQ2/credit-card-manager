# Card-linked offers: count what you earned and net it against the annual fee

Card Ledger design note, November 2026.

## Goal
On each card, show how many card-linked offers you earned and their total value for the current cardmember year. Then subtract that total from the annual fee alongside benefit credits. Examples are Amex Offers, Chase Offers, RBC Offers and Neo partner cashback.

Today the effective fee is `annual fee − benefit credits redeemed` (`Store.effectiveFee`). An offer credit is stored as a merchant **refund**. That lowers the merchant's category spend, and the credit never reaches the fee calculation.

## What the research and your data show

**No issuer publicly documents how an offer credit is labelled on a statement or in its data feed.** Amex, Chase, Bank of America and RBC all describe the payout, but none give the wording. So detection can't rely on one fixed string per bank. It needs several signals, and it has to be tuned against real accounts.

| Program | How it pays | What we can see | Confidence |
|---|---|---|---|
| **Amex Canada** | Statement credit, sometimes bonus MR points | **CSV export:** the credit row carries the merchant name, and *Additional Information* says `<Merchant>Offer` (for example `ShopSmallOffer`). **PDF statement:** the credit sits under "Other Account Transactions", with the same tag on the next line. | **Verified** on a real export and statement |
| **Amex US** | Statement credit, or bonus MR points | Similar to Canada is likely, but no US sample yet | Needs a sample |
| **Chase Offers** | Statement credit within about 30 days | Not documented | Needs a sample |
| **Capital One Offers** | Statement credit, miles or cash back, about 45 days | Not documented. Miles payouts won't appear as a credit. | Needs a sample |
| **Citi Merchant Offers** | Statement credit | Not documented | Needs a sample |
| **BankAmeriDeals** | Cash back to a chosen account, which can be a **bank** account | May not land on the card at all | Needs a sample |
| **RBC Offers** | Statement credit, deposit, or bonus Avion points; "as fast as 2 business days" | Credit wording not documented. Points never appear as a card credit. | Needs a sample |
| **Scotiabank** | Scene+ Offers pay **points**. Amex Connect offers on Scotia Amex cards pay credits. | Points: not in the feed. Credits: likely Amex-style. | Partial |
| **TD** | Personalized offers through TD Rewards (new program) | Unknown | Needs a sample |
| **CIBC** | No card-linked offers of its own (Paymi partnership) | Not applicable | Not applicable |
| **BMO** | No card-linked offer program found | Not applicable | Not applicable |
| **Neo** | Partner cashback held **in the app** until you cash it out | Only the cash-out may reach the card, as one combined credit | Needs a sample |

So there are three kinds of payout:
1. **Statement credit on the card:** detectable from the ledger (Amex, Chase, Citi, Capital One, RBC, Scotia Amex).
2. **Points or miles:** not in the transaction feed (Scene+, RBC Avion bonus, Capital One miles, Amex bonus MR). Amex statements do list bonus points in the rewards summary.
3. **Paid somewhere else:** a bank deposit (BankAmeriDeals) or an in-app wallet (Neo). Neo's cash-out may arrive as one lump credit that doesn't match any single offer.

## Detection: layered signals, strongest first
1. **Explicit tag:** confirmed automatically.
   - **Amex Canada CSV:** `Additional Information` ends in `Offer`.
   - **Amex Canada PDF:** the parser currently drops the line under a row. It should attach that line to the row as a detail and check it for `Offer`.
   - **Keyword rules:** each needs a real sample before it confirms automatically. Until then, a match only proposes a candidate. Planned patterns: `\bAMEX OFFERS?\b`, `\bCHASE OFFERS?\b`, `\bMERCHANT OFFER\b`, `\bBANKAMERIDEALS\b`, `\bRBC OFFERS?\b`, `\bSHOP ?SMALL\b`, `\bPAYMI\b`.
2. **Issuer section:** a merchant-named credit listed under "Other Account Transactions" on an Amex statement (verified layout) is an offer candidate.
3. **Shape heuristic:** proposes candidates for the review queue, never confirms. All of these must hold:
   - It's a negative row carrying a merchant name.
   - No earlier purchase of the same amount at that merchant (a real refund usually mirrors one).
   - There was a purchase at that merchant in the previous 90 days, at least as large as the credit.
   - Optionally, the amount is round, or a round percentage of that purchase.
4. **Owner decision:** **Confirm offer**, **It's a refund** or **It's a benefit credit**. This reuses the review queue, and decisions persist like today's credit decisions.

**Points payouts** come from manual entry: "Add offer reward: 1,000 MR points". They're valued at your point value settings, and later read from the Amex rewards summary's bonus column.

## Data model
- **Separate offers from refunds** in one of two ways:
  - Add a `TransactionKind.offerCredit`.
  - Keep the kind and add an `offer_credit` table: `txn_id`, `source` (tag / section / heuristic / manual), `confirmed`, `merchant`.

  The table is the safer first step, because many `switch` statements over the kind would need updating.
- **Spending:** offer credits shouldn't reduce category spend. Issuers pay them separately and don't claw back the points you earned on the purchase.
- **Rewards replay and Best Card:** these ignore offer credits.
- **Points rewards:** a small `offer_reward` table for points-only rewards: `card_id`, date, points, program, note.

## Fee netting
`effectiveFee = annual fee − benefit credits − card-linked offers`, counted over the same cardmember-year window as the credits. The window starts on the renewal date inferred from the posted fee.

Show the three parts separately on the card ("Credits used $X · Offers earned N, $Y"). Offers are optional and merchant-funded, and some owners won't want them netted, so add a setting: **Count offers toward effective fee** (on by default).

Overview gets one line: "12 offers earned this year, $148".

## Delivery plan
1. **Amex Canada, verified paths:**
   - PDF: keep the continuation line on each row and confirm offers from the tag or the section.
   - CSV import: build it (currently a stub). Amex Canada's CSV is the richest source, since it carries the tag and a full reference.
   - Add the offer table, card section, fee netting and setting.
2. **Review queue for heuristic candidates.**
3. **Manual points rewards**, plus the Amex rewards-summary bonus column.
4. **Per-bank rules, as real samples arrive.** First check what Plaid's Amex feed exposes: look at the original description of a known offer credit on a linked account. A rule for Chase, RBC or another bank goes in only once a real row from that bank confirms the wording.

## Open questions for you
- Should offers count toward the effective fee by default, or be opt-in?
- Is a bonus-points offer worth valuing in dollars at your point value, or only counted?
- Which accounts can provide sample offer credits? That decides which bank rules come first.

## Sources
- [Chase Offers FAQ](https://www.chase.com/personal/merchant-offers/faqs)
- [Amex Offers](https://www.americanexpress.com/en-us/benefits/offers)
- [Card-linked offers by issuer (The Points Party)](https://thepointsparty.com/articles/card-linked-offers-amex-chase-capital-one-citi-bank-of-america)
- [RBC Offers FAQ](https://www.rbcroyalbank.com/rbcoffers/faq.html)
- [Card-linked offers in Canada (Frugal Flyer)](https://frugalflyer.ca/blog/credit-card-linked-offers-guide/)
- [Neo partner cashback discussion](https://neofinancial.discourse.group/t/how-does-neo-partner-cashback-actually-work/4305)
- [BankAmeriDeals guide (NerdWallet)](https://www.nerdwallet.com/article/credit-cards/bank-of-america-bankamerideals-review)
