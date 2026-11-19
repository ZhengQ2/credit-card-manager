# Card Ledger catalog audit

November 18, 2026 · Catalog 2026.11.4

Card Ledger has **115 issuer card profiles and two generic fallback entries**. All 117 are selectable in the app. The published standard fee or standard agreement supported the listed fee for **113 profiles**. The exact fee for Citi Custom Cash and the legacy Capital One Canada Platinum Mastercard remains account-specific or unconfirmed from the public sources reviewed. Amounts below are in each card's local currency and are for the primary cardholder. Introductory offers, fee waivers, and existing-account pricing can differ.

Plaid Transactions supports credit accounts at participating institutions. The catalog selection and account-name suggestion work independently of the bank feed. A live connection and posted-transaction sample are still needed to verify each institution, login channel, and card account. [Plaid Transactions account types](https://support.plaid.com/hc/en-us/articles/15373492186263-What-account-types-are-compatible-with-the-Plaid-Transactions-product) · [Plaid coverage explorer](https://plaid.com/docs/institutions/)

## Changes in this release

| Card | Updated catalog information | Evidence |
|---|---|---|
| WestJet RBC World Elite | CAD 139 standard annual fee, previously CAD 119. WestJet earnings use the points unit. | [RBC](https://www.rbcroyalbank.com/credit-cards/annual-fee-comparison/index.html) |
| BMO CashBack World Elite | CAD 139 standard annual fee, previously CAD 120. | [BMO](https://www.bmo.com/en-ca/main/personal/credit-cards/bmo-cashback-world-elite-mastercard/) |
| BMO Blue Rewards World Elite | AIR MILES converted to Blue Rewards in June 2026. The existing catalog ID now points to the successor profile and its CAD 150 public fee. Existing cardholders should check their renewal fee. | [Product](https://www.bmo.com/en-ca/main/personal/credit-cards/bmo-blue-rewards-world-elite-mastercard/) · [Conversion](https://www.bmo.com/en-ca/main/personal/blue-rewards/) |
| Capital One Canada Guaranteed Mastercard | CAD 0 standard annual fee for the current offer, previously CAD 59 in the app. Legacy agreements can differ. | [Capital One](https://www.capitalone.ca/credit-cards/guaranteed-mastercard/) |
| Canadian Hilton Honors Amex | Launched Oct 29. CAD 150 standard fee, 6× at eligible Hilton properties, 4× in eligible Canadian gas, grocery and dining, 2× other eligible purchases, and Hilton Gold. | [Hilton and Amex release](https://stories.hilton.com/releases/american-express-and-hilton-launch-canadas-first-hilton-honors-credit-card) |
| Amex Cobalt | The 2× rule now covers eligible gas, transit and rideshare. Flights use the base rate for general purchases. | [Amex](https://www.americanexpress.com/en-ca/credit-cards/cobalt-card/) |
| Chase Aeroplan | Added 3× eligible travel and 2× eligible gas. Direct Air Canada purchases earn 3× from the card. The additional advertised 2× is an Aeroplan 25K benefit. | [Chase](https://creditcards.chase.com/travel-credit-cards/aircanada/aeroplan) |
| Rogers Red cards | Updated for Nov 18 changes. Eligible Rogers purchases earn 5%, subject to the applicable annual limit. The 1.5× redemption bonus ended. The World Elite profile now uses a 2.5% FX fee. | [Rogers changes](https://www.rogersbank.com/en/help_centre_answers/upcoming_account_changes/) · [World Elite terms](https://www.rogersbank.com/en/rogers_red_worldelite_mastercard_details/) |
| Wealthsimple | Distinguished the 2% Infinite+ from the fee-free, invite-only 1% Infinite. The 2% cards have a CAD 20 monthly fee where a waiver does not apply. | [Wealthsimple](https://help.wealthsimple.com/hc/en-ca/articles/31614256039835-Apply-for-a-Wealthsimple-credit-card) |
| Citi Custom Cash and Amex U.S. Classic Green | Retained their existing card IDs for cardholders. Citi stopped taking Custom Cash applications in May 2026. Amex lists Classic Green in its cardmember agreements. | [Citi](https://www.citi.com/credit-cards/citi-custom-cash-credit-card) · [Amex](https://www.americanexpress.com/en-us/company/legal/cardmember-agreements/) |

## Remaining terms checks

The app models 29 statement-credit rules. Full earn schedules, credit eligibility, caps, enrollment, underwriting variants, and live descriptor matching remain pending. The rewards comparison uses the bundled rules for historical transactions, so product conversions and future effective dates require a date-aware catalog to replay earlier terms accurately.

- Sapphire Reserve's The Edit credit is up to USD 250 per eligible booking with a USD 500 calendar-year cap. The current app rule still assumes a semiannual reset. [Chase](https://creditcards.chase.com/rewards-credit-cards/sapphire/reserve)
- Chase Aeroplan offers two USD 50 Air Canada statement credits. The app lists the credits in the issuer notes. Automatic tracking for those credits needs a rule and a sample of posted transactions. The current 3× dining and grocery rate is scheduled to become 2× on January 1, 2027. [Chase](https://creditcards.chase.com/travel-credit-cards/aircanada/aeroplan)
- Amex Aeroplan and Aeroplan Reserve list CAD 150 and CAD 799 fees from January 12, 2027. CIBC Aeroplan Visa Infinite Privilege lists CAD 699 from January 12. TD Infinite Privilege lists CAD 699 for existing cardholders at their first renewal on or after January 25. The app retains the current fee and displays the announced increase. [Amex regular](https://www.americanexpress.com/en-ca/charge-cards/aeroplan-card/) · [Amex Reserve](https://www.americanexpress.com/en-ca/credit-cards/aeroplan-reserve/) · [CIBC](https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/aeroplan-visa-infinite-privilege-card.html) · [TD](https://www.td.com/ca/en/personal-banking/products/credit-cards/aeroplan/aeroplan-visa-infinite-privilege-card-faq)
- Citi / AAdvantage Platinum Select lists a USD 150 fee effective January 24, 2027. For Canadian Marriott Bonvoy Amex personal cards, the CAD 150 fee applies from the first annual-fee billing date on or after February 9, 2027. [American Airlines and Citi](https://news.aa.com/news/news-details/2026/American-and-Citi-enhance-the-Citi-AAdvantage-Platinum-Select-World-Elite-Mastercard-and-the-Citi-AAdvantage-Business-World-Elite-Mastercard-with-more-ways-to-earn-and-new-travel-benefits-AADV-10/default.aspx) · [Amex](https://www.americanexpress.com/en-us/newsroom/global-news/marriott-bonvoy-expanded-canadian-card-portfolio/)
- Rogers rates tied to total spend, USD purchases and eligible service still require account-level inputs. Home Trust Preferred Visa limits cash back to eligible Canadian-dollar purchases, while the base-rate estimate currently applies across currencies. [Rogers](https://www.rogersbank.com/en/help_centre_answers/upcoming_account_changes/) · [Home Trust](https://www.hometrust.ca/credit-cards/preferred-visa-card/)

## Card-by-card inventory

**Fee confirmed** means the standard annual or annualized fee matched a public issuer source. It does not certify the entire card's terms. The artwork code matches the code in the wallet and card picker.

### U.S. cards

| Card | Code | Annual fee (USD) | Review | Source |
|---|---|---:|---|---|
| American Express Blue Business Plus | BBP | $0 | Fee confirmed | [Issuer](https://www.americanexpress.com/us/credit-cards/business/business-credit-cards/compare-credit-cards/compare-no-annual-fee-credit-cards/) |
| American Express Blue Cash Everyday | BCE | $0 | Fee confirmed | [Issuer](https://www.americanexpress.com/us/credit-cards/card/blue-cash-everyday/) |
| American Express Blue Cash Preferred | BCP | $95 | Fee confirmed | [Issuer](https://www.americanexpress.com/us/credit-cards/card/blue-cash-preferred/) |
| American Express Business Gold Card | ABG | $375 | Fee confirmed | [Issuer](https://www.americanexpress.com/content/dam/amex/en-us/company/legal/cardmember-agreements/public-site-2026-q1-pdf-cmas/sbs-small-business/business-gold-03-31-2026.pdf) |
| American Express Business Platinum Card | ABP | $895 | Fee confirmed | [Issuer](https://www.americanexpress.com/content/dam/amex/en-us/company/legal/cardmember-agreements/public-site-adhoc-2025-09-18/business-platinum-09-18-2025.pdf) |
| American Express Classic Green Card | GRN | $150 | Standard agreement. Existing cardholders | [Issuer](https://www.americanexpress.com/content/dam/amex/en-us/company/legal/cardmember-agreements/public-site-2026-q1-pdf-cmas/cps-charge/american-express-green-card-03-31-2026.pdf) |
| American Express Delta SkyMiles Gold | DLG | $150 | Fee confirmed | [Issuer](https://www.americanexpress.com/us/credit-cards/card/delta-skymiles-gold-american-express-card/) |
| American Express Delta SkyMiles Platinum | DLP | $350 | Fee confirmed | [Issuer](https://www.americanexpress.com/us/credit-cards/card/delta-skymiles-platinum-american-express-card/) |
| American Express Delta SkyMiles Reserve | DLR | $650 | Fee confirmed | [Issuer](https://www.americanexpress.com/us/credit-cards/card/delta-skymiles-reserve-american-express-card/) |
| American Express Gold Card | GLD | $325 | Fee confirmed | [Issuer](https://www.americanexpress.com/us/credit-cards/card/gold-card/) |
| American Express Hilton Honors Aspire | ASP | $550 | Fee confirmed | [Issuer](https://www.americanexpress.com/us/credit-cards/card/hilton-honors-aspire/) |
| American Express Hilton Honors Card | HHH | $0 | Fee confirmed | [Issuer](https://www.americanexpress.com/us/credit-cards/card/hilton-honors/) |
| American Express Hilton Honors Surpass | SUR | $150 | Fee confirmed | [Issuer](https://www.americanexpress.com/us/credit-cards/card/hilton-honors-surpass/?searchresult=cd+calculator) |
| American Express Marriott Bonvoy Bevy | BEV | $250 | Fee confirmed | [Issuer](https://www.americanexpress.com/us/credit-cards/card/marriott-bonvoy-bevy/) |
| American Express Marriott Bonvoy Brilliant | BRI | $650 | Fee confirmed | [Issuer](https://www.americanexpress.com/us/credit-cards/card/marriott-bonvoy-brilliant/) |
| American Express Platinum Card | PLT | $895 | Fee confirmed | [Issuer](https://www.americanexpress.com/us/credit-cards/card/platinum/) |
| Apple Apple Card | APL | $0 | Fee confirmed | [Issuer](https://card.apple.com/apply/start) |
| Bank of America Atmos Rewards Ascent | ASC | $95 | Fee confirmed | [Issuer](https://www.bankofamerica.com/credit-cards/products/alaska-airlines-credit-card/) |
| Bank of America Atmos Rewards Summit Visa Infinite | SUM | $395 | Fee confirmed | [Issuer](https://www.bankofamerica.com/credit-cards/products/alaska-airlines-infinite-credit-card/) |
| Bank of America Customized Cash Rewards | BCC | $0 | Fee confirmed | [Issuer](https://www.bankofamerica.com/credit-cards/products/cash-back-credit-card/) |
| Bank of America Premium Rewards | BPR | $95 | Fee confirmed | [Issuer](https://www.bankofamerica.com/credit-cards/products/premium-rewards-credit-card/) |
| Bank of America Travel Rewards | BTR | $0 | Fee confirmed | [Issuer](https://www.bankofamerica.com/credit-cards/products/travel-rewards-credit-card/) |
| Bank of America Unlimited Cash Rewards | BUC | $0 | Fee confirmed | [Issuer](https://www.bankofamerica.com/credit-cards/products/unlimited-cash-back-credit-card/) |
| Bilt Bilt Blue Card | BLU | $0 | Fee confirmed | [Issuer](https://www.bilt.com/card) |
| Bilt Bilt Obsidian Card | OBS | $95 | Fee confirmed | [Issuer](https://www.bilt.com/card) |
| Bilt Bilt Palladium Card | PAL | $495 | Fee confirmed | [Issuer](https://www.bilt.com/card) |
| Capital One Quicksilver | QSV | $0 | Fee confirmed | [Issuer](https://www.capitalone.com/credit-cards/quicksilver/) |
| Capital One Savor | SAV | $0 | Fee confirmed | [Issuer](https://www.capitalone.com/credit-cards/savor/) |
| Capital One Venture | VNT | $95 | Fee confirmed | [Issuer](https://www.capitalone.com/credit-cards/venture/) |
| Capital One Venture X | VTX | $395 | Fee confirmed | [Issuer](https://www.capitalone.com/credit-cards/venture-x/) |
| Capital One VentureOne | V1 | $0 | Fee confirmed | [Issuer](https://www.capitalone.com/credit-cards/ventureone/) |
| Chase Air Canada Aeroplan Card | CHAP | $195 | Fee confirmed | [Issuer](https://creditcards.chase.com/travel-credit-cards/aircanada/aeroplan) |
| Chase Freedom Flex | CFF | $0 | Fee confirmed | [Issuer](https://creditcards.chase.com/cash-back-credit-cards/freedom/flex) |
| Chase Freedom Rise | CFR | $0 | Fee confirmed | [Issuer](https://creditcards.chase.com/cash-back-credit-cards/freedom/rise) |
| Chase Freedom Unlimited | CFU | $0 | Fee confirmed | [Issuer](https://creditcards.chase.com/cash-back-credit-cards/freedom/unlimited) |
| Chase IHG One Rewards Premier | IHG | $99 | Fee confirmed | [Issuer](https://creditcards.chase.com/travel-credit-cards/ihg) |
| Chase Ink Business Cash | INKC | $0 | Fee confirmed | [Issuer](https://creditcards.chase.com/business-credit-cards/ink/cash) |
| Chase Ink Business Preferred | INKP | $95 | Fee confirmed | [Issuer](https://creditcards.chase.com/business-credit-cards/ink/business-preferred) |
| Chase Ink Business Unlimited | INKU | $0 | Fee confirmed | [Issuer](https://creditcards.chase.com/business-credit-cards/ink/unlimited) |
| Chase Marriott Bonvoy Boundless | BND | $95 | Fee confirmed | [Issuer](https://creditcards.chase.com/travel-credit-cards/marriott-bonvoy/boundless) |
| Chase Prime Visa | PRM | $0 | Fee confirmed | [Issuer](https://creditcards.chase.com/cash-back-credit-cards/amazon-prime-rewards) |
| Chase Sapphire Preferred | CSP | $95 | Fee confirmed | [Issuer](https://creditcards.chase.com/rewards-credit-cards/sapphire/preferred) |
| Chase Sapphire Reserve | CSR | $795 | Fee confirmed | [Issuer](https://creditcards.chase.com/rewards-credit-cards/sapphire/reserve) |
| Chase Southwest Rapid Rewards Plus | SW+ | $99 | Fee confirmed | [Issuer](https://creditcards.chase.com/travel-credit-cards/southwest/plus) |
| Chase Southwest Rapid Rewards Priority | SWP | $229 | Fee confirmed | [Issuer](https://creditcards.chase.com/travel-credit-cards/southwest) |
| Chase United Explorer | UEX | $150 | Fee confirmed | [Issuer](https://creditcards.chase.com/travel-credit-cards/united/united-explorer) |
| Chase World of Hyatt | HYT | $95 | Fee confirmed | [Issuer](https://creditcards.chase.com/travel-credit-cards/world-of-hyatt-credit-card) |
| Citi AAdvantage Platinum Select | AAP | $99 | Fee confirmed | [Issuer](https://www.citi.com/credit-cards/rewards-credit-cards) |
| Citi Costco Anywhere Visa | CSV | $0 | Fee confirmed. Paid Costco membership required | [Issuer](https://www.citi.com/credit-cards/citi-costco-anywhere-visa-credit-card) |
| Citi Custom Cash | CTC | $0 | Existing cardholders. Current public fee unconfirmed | [Issuer](https://www.citi.com/credit-cards/citi-custom-cash-credit-card?category=view-all-credit-cards) |
| Citi Double Cash | DBC | $0 | Fee confirmed | [Issuer](https://www.citi.com/credit-cards/citi-double-cash-credit-card) |
| Citi Strata Elite | STE | $595 | Fee confirmed | [Issuer](https://www.citi.com/credit-cards/citi-strata-credit-card/apply) |
| Citi Strata Premier | STP | $95 | Fee confirmed | [Issuer](https://www.citi.com/credit-cards/citi-strata-premier-credit-card) |
| Discover Discover it Cash Back | DCB | $0 | Fee confirmed | [Issuer](https://www.discover.com/credit-cards/cash-back/it-card.html) |
| Discover Discover it Miles | DMI | $0 | Fee confirmed | [Issuer](https://www.discover.com/credit-cards/) |
| Robinhood Robinhood Gold Card | RHG | $0 | Fee confirmed. Paid Gold membership required | [Issuer](https://robinhood.com/creditcard/) |
| U.S. Bank Altitude Connect | ACN | $0 | Fee confirmed | [Issuer](https://www.usbank.com/credit-cards/altitude-connect-visa-signature-credit-card.html) |
| U.S. Bank Altitude Go | AGO | $0 | Fee confirmed | [Issuer](https://www.usbank.com/credit-cards/altitude-go-visa-signature-credit-card.html) |
| U.S. Bank Cash+ | CSH+ | $0 | Fee confirmed | [Issuer](https://www.usbank.com/credit-cards/cash-plus-visa-signature-credit-card.html) |
| Wells Fargo Active Cash | WAC | $0 | Fee confirmed | [Issuer](https://creditcards.wellsfargo.com/active-cash-credit-card/) |
| Wells Fargo Autograph | AUT | $0 | Fee confirmed | [Issuer](https://creditcards.wellsfargo.com/autograph-visa-credit-card/) |
| Other U.S. card | US | — | Generic fallback | [Consumer guidance](https://www.consumerfinance.gov/consumer-tools/credit-cards/) |

### Canadian cards

| Card | Code | Annual fee (CAD) | Review | Source |
|---|---|---:|---|---|
| American Express Aeroplan Card | AAPC | $120 | Fee confirmed | [Issuer](https://www.americanexpress.com/en-ca/charge-cards/aeroplan-card/) |
| American Express Aeroplan Reserve Card | APR | $599 | Fee confirmed | [Issuer](https://www.americanexpress.com/en-ca/credit-cards/aeroplan-reserve/) |
| American Express Cobalt Card | COB | $191.88 | Fee confirmed. CAD 15.99 monthly outside Quebec | [Issuer](https://www.americanexpress.com/en-ca/credit-cards/cobalt-card/) |
| American Express Gold Rewards Card (Canada) | GLCA | $250 | Fee confirmed | [Issuer](https://www.americanexpress.com/en-ca/credit-cards/gold-rewards-card/) |
| American Express Green Card (Canada) | GRCA | $0 | Fee confirmed | [Issuer](https://www.americanexpress.com/en-ca/credit-cards/green-card/) |
| American Express Hilton Honors Card (Canada) | HCA | $150 | Fee confirmed | [Issuer](https://stories.hilton.com/releases/american-express-and-hilton-launch-canadas-first-hilton-honors-credit-card) |
| American Express Marriott Bonvoy Business Card (Canada) | MBB | $150 | Fee confirmed | [Issuer](https://www.americanexpress.com/en-us/newsroom/global-news/marriott-bonvoy-expanded-canadian-card-portfolio/) |
| American Express Marriott Bonvoy Card (Canada) | MBC | $120 | Fee confirmed | [Issuer](https://www.americanexpress.com/en-us/newsroom/global-news/marriott-bonvoy-expanded-canadian-card-portfolio/) |
| American Express Platinum Card (Canada) | PLCA | $799 | Fee confirmed | [Issuer](https://www.americanexpress.com/en-ca/charge-cards/the-platinum-card/) |
| American Express SimplyCash Card | SIM | $0 | Fee confirmed | [Issuer](https://www.americanexpress.com/en-ca/credit-cards/simply-cash/?dsparms=dc_pcrid_494601410145_kword_amex_match_e) |
| American Express SimplyCash Preferred | SCP | $119.88 | Fee confirmed. CAD 9.99 monthly outside Quebec | [Issuer](https://www.americanexpress.com/en-ca/credit-cards/simply-cash-preferred/?page=PR) |
| BMO Ascend World Elite Mastercard | BAW | $150 | Fee confirmed | [Issuer](https://www.bmo.com/en-ca/main/personal/credit-cards/bmo-ascend-world-elite-mastercard/) |
| BMO Blue Rewards World Elite Mastercard | BLWE | $150 | Fee updated | [Issuer](https://www.bmo.com/en-ca/main/personal/credit-cards/bmo-blue-rewards-world-elite-mastercard/) |
| BMO CashBack World Elite Mastercard | BCW | $139 | Fee updated | [Issuer](https://www.bmo.com/en-ca/main/personal/credit-cards/bmo-cashback-world-elite-mastercard/) |
| BMO eclipse Visa Infinite | ECL | $120 | Fee confirmed | [Issuer](https://www.bmo.com/pdf/PDF_MC%207613%20COB_insert_E.pdf) |
| Canadian Tire Bank Triangle Mastercard | TRMC | $0 | Fee confirmed | [Issuer](https://triangle.canadiantire.ca/en/credit-cards/triangle-mastercard.html) |
| Canadian Tire Bank Triangle World Elite Mastercard | TRWE | $0 | Fee confirmed | [Issuer](https://triangle.canadiantire.ca/en/credit-cards.html) |
| Capital One Guaranteed Mastercard (Canada) | C1G | $0 | Fee updated | [Issuer](https://www.capitalone.ca/credit-cards/guaranteed-mastercard/) |
| Capital One Platinum Mastercard (Canada) | C1PL | $0 | Legacy profile. Fee and exact current product unconfirmed | [Issuer](https://www.capitalone.ca/credit-cards/compare/) |
| CIBC Aeroplan Visa | CAV | $0 | Fee confirmed | [Issuer](https://www.cibc.com/en/personal-banking/credit-cards/aeroplan-cards.html) |
| CIBC Aeroplan Visa Infinite | CAP | $139 | Fee confirmed | [Issuer](https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/aeroplan-visa-infinite-card.html) |
| CIBC Aeroplan Visa Infinite Privilege | CAVP | $599 | Fee confirmed | [Issuer](https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/aeroplan-visa-infinite-privilege-card.html) |
| CIBC Aventura Visa Infinite | AVT | $139 | Fee confirmed | [Issuer](https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/aventura-visa-infinite-card.html) |
| CIBC Costco Mastercard | CCM | $0 | Fee confirmed. Paid Costco membership required | [Issuer](https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/costco-mastercard.html) |
| CIBC Dividend Visa Infinite | DIV | $120 | Fee confirmed | [Issuer](https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/dividend-visa-infinite-card.html) |
| Home Trust Preferred Visa | HTP | $0 | Fee confirmed | [Issuer](https://www.hometrust.ca/credit-cards/preferred-visa-card/) |
| MBNA Rewards World Elite Mastercard | MBNA | $120 | Fee confirmed | [Issuer](https://www.mbna.ca/en/credit-cards/rewards) |
| National Bank World Elite Mastercard | NBC | $150 | Fee confirmed | [Issuer](https://www.nbc.ca/personal/mastercard-credit-cards/world-elite.html) |
| PC Financial PC Mastercard | PCMC | $0 | Fee confirmed | [Issuer](https://www.pcfinancial.ca/en/credit-cards/pc-mastercard/) |
| PC Financial PC World Elite Mastercard | PCWE | $0 | Fee confirmed | [Issuer](https://www.pcfinancial.ca/en/credit-cards/world-elite/) |
| RBC Avion Visa Infinite | AVI | $120 | Fee confirmed | [Issuer](https://www.rbcroyalbank.com/credit-cards/travel/rbc-avion-visa-infinite.html) |
| RBC Avion Visa Platinum | AVP | $120 | Fee confirmed | [Issuer](https://www.rbcroyalbank.com/credit-cards/travel/rbc-visa-platinum-avion.html) |
| RBC Cash Back Mastercard | RCB | $0 | Fee confirmed | [Issuer](https://www.rbcroyalbank.com/credit-cards/cash-back/rbc-cashback-mastercard.html) |
| RBC ION+ Visa | ION+ | $48 | Fee confirmed | [Issuer](https://www.rbcroyalbank.com/credit-cards/rewards/rbc-ion-plus-visa.html) |
| RBC WestJet World Elite Mastercard | WJ | $139 | Fee updated | [Issuer](https://www.rbcroyalbank.com/credit-cards/annual-fee-comparison/index.html) |
| Rogers Bank Rogers Red Mastercard | RGMC | $0 | Fee confirmed | [Issuer](https://www.rogersbank.com/en/rogers_red_mastercard_details/) |
| Rogers Bank Rogers Red World Elite Mastercard | RGWE | $0 | Fee confirmed | [Issuer](https://www.rogersbank.com/en/rogers_red_worldelite_mastercard_details/) |
| Scotiabank Gold American Express | SGA | $120 | Fee confirmed | [Issuer](https://www.scotiabank.com/ca/en/personal/credit-cards/american-express/gold-card.html) |
| Scotiabank Momentum Visa Infinite+ | MOM | $120 | Fee confirmed | [Issuer](https://www.scotiabank.com/ca/en/personal/credit-cards/visa/momentum-infinite-card.html) |
| Scotiabank Passport Visa Infinite | SPV | $150 | Fee confirmed | [Issuer](https://www.scotiabank.com/ca/en/personal/credit-cards/visa/passport-infinite-card.html) |
| Scotiabank Scene+ Visa | SCN+ | $0 | Fee confirmed | [Issuer](https://www.scotiabank.com/ca/en/personal/credit-cards/no-annual-fee.html) |
| Simplii Financial Cash Back Visa | SCB | $0 | Fee confirmed | [Issuer](https://www.simplii.com/en/credit-cards/cash-back-visa.html) |
| Tangerine Money-Back Mastercard | TMB | $0 | Fee confirmed | [Issuer](https://www.tangerine.ca/en/products/spending/creditcard/money-back) |
| Tangerine Rewards World Elite Mastercard | TGWE | $120 | Fee confirmed | [Issuer](https://www.tangerine.ca/en/personal/spend/credit-cards/world-elite-mastercard) |
| TD Aeroplan Visa Business | TAB | $149 | Fee confirmed | [Issuer](https://www.td.com/ca/en/business-banking/small-business/credit-cards/aeroplan-visa-business-card) |
| TD Aeroplan Visa Infinite | TAP | $139 | Fee confirmed | [Issuer](https://www.td.com/ca/en/personal-banking/products/credit-cards/aeroplan/aeroplan-visa-infinite-card) |
| TD Aeroplan Visa Infinite Privilege | TAVP | $599 | Fee confirmed | [Issuer](https://www.td.com/ca/en/personal-banking/products/credit-cards/aeroplan/aeroplan-visa-infinite-privilege-card-faq) |
| TD Aeroplan Visa Platinum | TAPL | $89 | Fee confirmed | [Issuer](https://www.td.com/ca/en/personal-banking/products/credit-cards/aeroplan/aeroplan-visa-platinum-card) |
| TD Cash Back Visa Infinite | TCB | $139 | Fee confirmed | [Issuer](https://www.td.com/ca/en/personal-banking/products/credit-cards/cash-back/cash-back-visa-infinite-card) |
| TD First Class Travel Visa Infinite | FCT | $139 | Fee confirmed | [Issuer](https://www.td.com/ca/en/personal-banking/products/credit-cards/travel-rewards/first-class-travel-visa-infinite-card) |
| TD Rewards Visa | TDR | $0 | Fee confirmed | [Issuer](https://www.td.com/ca/en/personal-banking/products/credit-cards/no-annual-fee) |
| Wealthsimple Visa Infinite (1%) | WS1 | $0 | Fee confirmed. Invitation-only beta | [Issuer](https://help.wealthsimple.com/hc/en-ca/articles/51274223026203-Understand-premium-benefits-for-the-Visa-Infinite-1-credit-card-beta) |
| Wealthsimple Visa Infinite Privilege | WSVP | $240 | Fee confirmed. CAD 20 monthly with waivers | [Issuer](https://help.wealthsimple.com/hc/en-ca/articles/31614256039835-Apply-for-a-Wealthsimple-credit-card) |
| Wealthsimple Visa Infinite+ (2%) | WS2 | $240 | Fee confirmed. CAD 20 monthly with waivers | [Issuer](https://help.wealthsimple.com/hc/en-ca/articles/31614256039835-Apply-for-a-Wealthsimple-credit-card) |
| Other Canadian card | CA | — | Generic fallback | [Consumer guidance](https://www.canada.ca/en/financial-consumer-agency/services/credit-cards.html) |
