#!/usr/bin/env python3
"""
Card Ledger product catalog — editable source of truth.

Run:  python3 catalog-src/build_catalog.py
Writes CardLedger/Resources/catalog.json (bundled, versioned; design §4).

Every product carries `status` ("unverified" until someone checks the issuer's current terms page and records
`checked` = YYYY-MM-DD) and a `source` URL. Fees, earn rates and credits change often: treat values as a starting
point. Credit descriptors are best guesses; a credit that doesn't match a descriptor goes to review instead of
being auto-confirmed, so a wrong descriptor fails safe.

Cash-back cards use a program worth 1¢ per point, so `x: 3` means 3% back.
"""
import json, os, sys
from datetime import date

VERSION = "2026.11.6"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "CardLedger", "Resources", "catalog.json")

CATEGORIES = {"dining", "groceries", "gas", "flights", "hotels", "streaming", "transit", "drugstore", "entertainment", "other"}
PERIODS = {"monthly", "quarterly", "semiannual", "annual", "cardmemberYear"}
TRAVEL = ["flights", "hotels", "transit"]

# ---------------------------------------------------------------- programs (owner can override values in Settings)
programs = [
    # US
    ("mr_us", "Amex Membership Rewards (US)", "MR", 1.8, "USD"),
    ("ur", "Chase Ultimate Rewards", "UR", 1.7, "USD"),
    ("c1", "Capital One Miles", "mi", 1.7, "USD"),
    ("ty", "Citi ThankYou", "TY", 1.6, "USD"),
    ("hilton", "Hilton Honors", "HH", 0.5, "USD"),
    ("marriott", "Marriott Bonvoy", "MB", 0.8, "USD"),
    ("hyatt", "World of Hyatt", "WoH", 1.7, "USD"),
    ("delta", "Delta SkyMiles", "SM", 1.1, "USD"),
    ("united", "United MileagePlus", "UA", 1.3, "USD"),
    ("usb", "U.S. Bank Altitude", "pts", 1.0, "USD"),
    ("cash_us", "Cash back (USD)", "¢", 1.0, "USD"),
    ("aeroplan_us", "Aeroplan (US cards)", "AP", 1.4, "USD"),
    ("bilt", "Bilt Rewards", "Bilt", 1.8, "USD"),
    ("atmos", "Atmos Rewards (Alaska/Hawaiian)", "AR", 1.3, "USD"),
    ("aadvantage", "American AAdvantage", "AA", 1.3, "USD"),
    ("southwest", "Southwest Rapid Rewards", "RR", 1.3, "USD"),
    ("ihg", "IHG One Rewards", "IHG", 0.5, "USD"),
    ("wells_fargo", "Wells Fargo Rewards", "pts", 1.0, "USD"),
    # Canada
    ("mr_ca", "Amex Membership Rewards (CA)", "MR", 1.5, "CAD"),
    ("aeroplan", "Aeroplan", "AP", 1.5, "CAD"),
    ("aventura", "CIBC Aventura", "AV", 1.0, "CAD"),
    ("td", "TD Rewards", "TD", 0.5, "CAD"),
    ("avion", "RBC Avion", "Avion", 1.2, "CAD"),
    ("rbc_ion", "RBC ION Avion", "ION", 0.58, "CAD"),
    ("westjet", "WestJet Rewards", "pts", 1.0, "CAD"),
    ("bmo", "BMO Rewards", "BMO", 0.67, "CAD"),
    ("scene", "Scene+", "S+", 1.0, "CAD"),
    ("cash_ca", "Cash back (CAD)", "¢", 1.0, "CAD"),
    ("marriott_ca", "Marriott Bonvoy (CA cards)", "MB", 0.9, "CAD"),
    ("hilton_ca", "Hilton Honors (CA cards)", "HH", 0.6, "CAD"),
    ("pc_optimum", "PC Optimum", "pts", 0.1, "CAD"),
    ("ct_money", "Canadian Tire Money", "CT$", 1.0, "CAD"),
    ("mbna", "MBNA Rewards", "pts", 0.8, "CAD"),
    ("nbc", "National Bank à la carte", "pts", 1.0, "CAD"),
    ("bmo_blue", "BMO Blue Rewards", "Blue pts", 1000 / 1500, "CAD"),
    ("viporter", "VIPorter", "pts", 1.4, "CAD"),
    ("ba_avios", "British Airways Avios", "Avios", 1.5, "CAD"),
]

# ---------------------------------------------------------------- helpers
# Stable, unique labels for the original SwiftUI artwork. Keep them when issuer names change.
ART_CODES = dict(line.split() for line in """
amex-platinum-us PLT
amex-gold-us GLD
amex-green-us GRN
amex-bcp-us BCP
amex-bce-us BCE
amex-hilton-aspire ASP
amex-hilton-surpass SUR
amex-marriott-brilliant BRI
amex-delta-reserve DLR
chase-sapphire-reserve CSR
chase-sapphire-preferred CSP
chase-freedom-unlimited CFU
chase-freedom-flex CFF
chase-united-explorer UEX
chase-world-of-hyatt HYT
capone-venture-x VTX
capone-venture VNT
capone-savor SAV
capone-quicksilver QSV
citi-strata-premier STP
citi-double-cash DBC
citi-custom-cash CTC
usbank-altitude-go AGO
usbank-altitude-connect ACN
usbank-cash-plus CSH+
bofa-customized-cash BCC
bofa-premium-rewards BPR
wf-active-cash WAC
wf-autograph AUT
discover-it-cash DCB
amex-cobalt-ca COB
amex-platinum-ca PLCA
amex-gold-ca GLCA
amex-simplycash-preferred-ca SCP
td-aeroplan-vi TAP
td-first-class-vi FCT
td-cash-back-vi TCB
cibc-aventura-vi AVT
cibc-aeroplan-vi CAP
cibc-dividend-vi DIV
rbc-avion-vi AVI
rbc-ion-plus ION+
rbc-westjet-we WJ
bmo-eclipse-vi ECL
bmo-cashback-we BCW
scotia-gold-amex SGA
scotia-passport-vi SPV
amex-hilton-honors-us HHH
amex-marriott-bevy BEV
amex-delta-gold DLG
amex-delta-platinum DLP
amex-blue-business-plus BBP
amex-business-gold ABG
amex-business-platinum ABP
chase-aeroplan-us CHAP
chase-amazon-prime-visa PRM
chase-marriott-boundless BND
chase-ihg-premier IHG
chase-southwest-plus SW+
chase-southwest-priority SWP
chase-ink-preferred INKP
chase-ink-cash INKC
chase-ink-unlimited INKU
chase-freedom-rise CFR
capone-ventureone V1
citi-strata-elite STE
citi-costco-anywhere CSV
citi-aadvantage-platinum AAP
bofa-unlimited-cash BUC
bofa-travel-rewards BTR
atmos-ascent ASC
atmos-summit SUM
discover-it-miles DMI
apple-card APL
bilt-blue BLU
bilt-obsidian OBS
bilt-palladium PAL
robinhood-gold-card RHG
td-aeroplan-platinum TAPL
td-aeroplan-vip TAVP
td-aeroplan-business TAB
cibc-aeroplan-visa CAV
cibc-aeroplan-vip CAVP
amex-aeroplan-ca AAPC
amex-aeroplan-reserve-ca APR
amex-marriott-ca MBC
amex-marriott-business-ca MBB
amex-hilton-ca HCA
amex-green-ca GRCA
amex-simplycash-ca SIM
wealthsimple-vi-2 WS2
wealthsimple-vip WSVP
wealthsimple-vi-1 WS1
rogers-red-we RGWE
rogers-red-mc RGMC
capone-ca-platinum C1PL
capone-ca-guaranteed C1G
cibc-costco-mc CCM
pc-world-elite PCWE
pc-mastercard PCMC
triangle-world-elite TRWE
triangle-mc TRMC
mbna-rewards-we MBNA
tangerine-money-back TMB
tangerine-rewards-we TGWE
simplii-cash-back SCB
nbc-world-elite NBC
bmo-ascend-we BAW
bmo-airmiles-we BLWE
rbc-avion-platinum AVP
rbc-cash-back RCB
scotia-momentum-vi MOM
scotia-scene-visa SCN+
td-rewards-visa TDR
home-trust-preferred HTP
chase-united-gateway UGW
chase-united-quest UQT
chase-united-club UCL
chase-marriott-bold BOLD
chase-ihg-traveler ITR
chase-southwest-premier SWM
chase-amazon-visa AMZ
chase-sapphire-reserve-business CSRB
amex-blue-business-cash BBC
amex-delta-blue DLB
amex-marriott-business-us MBU
capone-venture-x-business VTXB
capone-spark-cash-plus SPC
citi-strata STR
citi-aadvantage-globe GLB
citi-aadvantage-executive AAE
wf-autograph-journey AUJ
usbank-smartly SMT
bmo-viporter VP
bmo-viporter-world-elite VPWE
bmo-eclipse-vip ECVP
rbc-avion-vip AVIP
rbc-ion ION
rbc-westjet-mc WJMC
rbc-british-airways BAVI
cibc-dividend-visa DIV0
cibc-aventura-visa AV0
cibc-aventura-vip AVVP
pc-insiders-we PCI
tangerine-money-back-world TMW
mbna-true-line MTL
mbna-rewards-plat MRP
scotia-amex SCA
scotia-passport-vip SPVP
scotia-momentum-no-fee MNF
rogers-red-world RGW
rogers-red-legend RGL
td-platinum-travel TPT
td-cash-back-visa TCB0
custom-us US
custom-ca CA
""".strip().splitlines())

def earn(cats, x, cap=None, per=None, merchants=None, restricted=False, note=None):
    d = {"categories": cats, "x": x}
    if cap is not None: d["cap"], d["capPeriod"] = cap, per
    if merchants: d["merchants"] = merchants
    if restricted: d["restricted"] = True
    if note: d["note"] = note
    return d

def credit(id, name, cap, period, descriptor, merchants=None, categories=None, lag=30, enrollment=False, notes="", version=1,
           redeem="statement", cap_by_month=None, certificate=None):
    d = {"id": id, "version": version, "name": name, "cap": cap, "period": period, "descriptor": descriptor,
         "lagDays": lag, "enrollment": enrollment, "notes": notes, "redeem": redeem}
    if cap_by_month: d["capByMonth"] = {str(k): v for k, v in cap_by_month.items()}
    if certificate: d["certificate"] = certificate
    if merchants: d["merchants"] = merchants
    if categories: d["categories"] = categories
    return d

# Benefits that never post as statement credits. The owner logs their use (app credits), records the award
# (certificates), or marks activation (memberships).
def app_credit(id, name, cap, period, merchants, cap_by_month=None, enrollment=True, notes=""):
    """Value loaded into a merchant app (Uber Cash, DoorDash promos, Lyft credit)."""
    return credit(id, name, cap, period, "", merchants=merchants, enrollment=enrollment, notes=notes,
                  redeem="app", cap_by_month=cap_by_month)

def free_night(id, name, trigger="renewal", spend=None, points=None, label=None, valid=12, lag=8, notes=""):
    """A hotel free-night certificate deposited in the loyalty account."""
    cert = {"trigger": trigger, "validMonths": valid, "lagWeeks": lag}
    if spend: cert["spend"] = spend
    if points: cert["points"] = points
    if label: cert["label"] = label
    return credit(id, name, 0, "annual", "", notes=notes, redeem="certificate", certificate=cert)

def membership(id, name, value, notes=""):
    """A complimentary membership the cardholder activates once."""
    return credit(id, name, value, "annual", "", enrollment=True, notes=notes, redeem="membership")

products = []
def card(id, issuer, name, market, network, fee, program, base, earn_rules, *, ftf=None, credits=(), perks=(),
         style=("#5B6472", "#2A2F38"), light=True, match=(), source, notes=None, segment="personal"):
    products.append({
        "id": id, "issuer": issuer, "name": name, "market": market, "network": network,
        "annualFee": fee, "ftf": (0.03 if market == "USD" else 0.025) if ftf is None else ftf,
        "program": program, "base": base, "earn": list(earn_rules), "benefits": list(credits), "perks": list(perks),
        "style": {"from": style[0], "to": style[1], "lightText": light}, "artCode": ART_CODES.get(id, ""),
        "match": [m.lower() for m in match], "source": source, "status": "unverified", "checked": None, "segment": segment,
        **({"notes": notes} if notes else {}),
    })

AMEX_TRAVEL = ["amex travel", "american express travel", "amextravel"]
HILTON = ["hilton", "conrad", "waldorf", "doubletree", "hampton", "embassy suites", "curio", "tapestry"]
MARRIOTT = ["marriott", "westin", "sheraton", "ritz", "st. regis", "w hotel", "courtyard", "fairfield", "aloft"]

# ================================================================= UNITED STATES
# ---- American Express
card("amex-platinum-us", "American Express", "Platinum Card", "USD", "Amex", 895, "mr_us", 1, [
        earn(["flights"], 5, cap=500000, per="annual", note="Booked directly with airlines or Amex Travel; $500k/yr"),
        earn(["hotels"], 5, restricted=True, note="Prepaid hotels via Amex Travel only"),
    ], ftf=0, credits=[
        credit("plat-entertainment", "Digital entertainment credit", 25, "monthly", "DIGITAL ENTERTAINMENT CREDIT",
               merchants=["disney+", "disney plus", "hulu", "espn", "peacock", "new york times", "nytimes", "wall street journal",
                          "youtube premium", "youtube tv", "paramount+"], enrollment=True, version=3,
               notes="Enrollment required. Eligible subscriptions billed directly by the merchant."),
        credit("plat-resy", "Resy dining credit", 100, "quarterly", "RESY CREDIT", categories=["dining"], enrollment=True,
               notes="U.S. Resy restaurants; the feed cannot confirm Resy participation."),
        credit("plat-lululemon", "lululemon credit", 75, "quarterly", "LULULEMON CREDIT", merchants=["lululemon"], enrollment=True,
               notes="U.S. lululemon stores and online."),
        credit("plat-hotel", "Hotel credit (FHR / THC)", 300, "semiannual", "HOTEL CREDIT", merchants=AMEX_TRAVEL, lag=45,
               notes="Prepaid Fine Hotels + Resorts or The Hotel Collection via Amex Travel."),
        credit("plat-airline", "Airline fee credit", 200, "annual", "AIRLINE FEE CREDIT", categories=["flights"], enrollment=True,
               notes="Incidental fees on one selected airline; tickets don't qualify. Review matches."),
        credit("plat-clear", "CLEAR Plus credit", 219, "annual", "CLEAR CREDIT", merchants=["clear"]),
        credit("plat-oura", "Oura Ring credit", 200, "annual", "OURA RING CREDIT", merchants=["oura"], enrollment=True,
               notes="Oura Ring hardware bought at ouraring.com. Added after a real 'Platinum Oura Ring Credit' posted."),
        credit("plat-uber-one", "Uber One credit", 120, "annual", "UBER ONE CREDIT", merchants=["uber one"], enrollment=True,
               notes="Auto-renewing Uber One membership."),
        credit("plat-walmart", "Walmart+ credit", 12.95, "monthly", "WALMART+ CREDIT", merchants=["walmart+", "walmart plus"],
               notes="Monthly Walmart+ membership; plus applicable tax."),
        credit("plat-equinox", "Equinox credit", 300, "annual", "EQUINOX CREDIT", merchants=["equinox"], enrollment=True,
               notes="Equinox club or Equinox+ app."),
    ], perks=["Centurion Lounge + Priority Pass", "Hilton & Marriott Gold status", "No foreign transaction fee"],
    style=("#D9DCE1", "#9CA3AD"), light=False, match=["the platinum card", "platinum card"],
    source="https://www.americanexpress.com/us/credit-cards/card/platinum/")

card("amex-gold-us", "American Express", "Gold Card", "USD", "Amex", 325, "mr_us", 1, [
        earn(["dining"], 4, cap=50000, per="annual", note="Restaurants worldwide; $50k/yr"),
        earn(["groceries"], 4, cap=25000, per="annual", note="U.S. supermarkets; $25k/yr"),
        earn(["flights"], 3, note="Booked directly with airlines or Amex Travel"),
        earn(["hotels"], 2, restricted=True, note="Prepaid hotels via Amex Travel"),
    ], ftf=0, credits=[
        credit("gold-dining", "Dining credit", 10, "monthly", "DINING CREDIT",
               merchants=["grubhub", "cheesecake factory", "goldbelly", "wine.com", "five guys"], enrollment=True),
        credit("gold-resy", "Resy credit", 50, "semiannual", "RESY CREDIT", categories=["dining"], enrollment=True),
        credit("gold-dunkin", "Dunkin' credit", 7, "monthly", "DUNKIN CREDIT", merchants=["dunkin"], enrollment=True),
    ], perks=["No foreign transaction fee"], style=("#D8B86A", "#9E7C34"), light=False, match=["gold card", "amex gold"],
    source="https://www.americanexpress.com/us/credit-cards/card/gold-card/")

card("amex-green-us", "American Express", "Classic Green Card", "USD", "Amex", 150, "mr_us", 1, [
        earn(TRAVEL + ["dining"], 3, note="Travel, transit and restaurants"),
    ], ftf=0, credits=[credit("green-clear", "CLEAR Plus credit", 209, "annual", "CLEAR CREDIT", merchants=["clear"])],
    style=("#4E8A5B", "#24502F"), match=["green card"],
    source="https://www.americanexpress.com/en-us/company/legal/cardmember-agreements/",
    notes="Existing U.S. cardholders. Use your account-specific agreement for current fees and benefits.")

card("amex-bcp-us", "American Express", "Blue Cash Preferred", "USD", "Amex", 95, "cash_us", 1, [
        earn(["groceries"], 6, cap=6000, per="annual", note="U.S. supermarkets; $6k/yr"),
        earn(["streaming"], 6, note="Select U.S. streaming"),
        earn(["gas", "transit"], 3, note="U.S. gas stations and transit"),
    ], credits=[credit("bcp-disney", "Disney Bundle credit", 7, "monthly", "DISNEY BUNDLE CREDIT",
                       merchants=["disney+", "disney plus", "hulu", "espn"], enrollment=True)],
    style=("#3B77C9", "#1C4787"), match=["blue cash preferred"],
    source="https://www.americanexpress.com/us/credit-cards/card/blue-cash-preferred/")

card("amex-bce-us", "American Express", "Blue Cash Everyday", "USD", "Amex", 0, "cash_us", 1, [
        earn(["groceries", "gas"], 3, cap=6000, per="annual", note="U.S. supermarkets, U.S. gas, U.S. online retail; $6k/yr each"),
    ], credits=[credit("bce-disney", "Disney Bundle credit", 7, "monthly", "DISNEY BUNDLE CREDIT",
                       merchants=["disney+", "disney plus", "hulu", "espn"], enrollment=True)],
    style=("#69A7E8", "#2F6FB5"), match=["blue cash everyday"],
    source="https://www.americanexpress.com/us/credit-cards/card/blue-cash-everyday/")

card("amex-hilton-aspire", "American Express", "Hilton Honors Aspire", "USD", "Amex", 550, "hilton", 3, [
        earn(["hotels"], 14, merchants=HILTON, note="Hilton portfolio properties only"),
        earn(["flights"], 7, note="Booked directly with airlines"),
        earn(["dining"], 7, note="U.S. restaurants"),
    ], ftf=0, credits=[
        credit("aspire-flight", "Flight credit", 50, "quarterly", "ASPIRE FLIGHT CREDIT",
               merchants=["delta", "united", "american airlines", "alaska air", "jetblue", "air canada", "westjet", "southwest"],
               notes="Flight purchases booked directly with an airline or through Amex Travel."),
        credit("aspire-resort", "Hilton resort credit", 200, "semiannual", "HILTON RESORT CREDIT",
               merchants=["waldorf", "conrad", "hilton resort", "resort"], lag=45,
               notes="Participating Hilton resorts. Review when the feed cannot verify the property."),
    ], perks=["Hilton Diamond status", "Annual Free Night Reward", "No foreign transaction fee"],
    style=("#2F3A52", "#141A28"), match=["aspire"],
    source="https://www.americanexpress.com/us/credit-cards/card/hilton-honors-aspire/")

card("amex-hilton-surpass", "American Express", "Hilton Honors Surpass", "USD", "Amex", 150, "hilton", 3, [
        earn(["hotels"], 12, merchants=HILTON, note="Hilton portfolio properties only"),
        earn(["dining", "groceries", "gas"], 6, note="U.S. restaurants, supermarkets and gas"),
    ], ftf=0, credits=[credit("surpass-hilton", "Hilton credit", 50, "quarterly", "HILTON CREDIT", merchants=HILTON)],
    perks=["Hilton Gold status"], style=("#5A6E8C", "#2C3A52"), match=["surpass"],
    source="https://www.americanexpress.com/us/credit-cards/card/hilton-honors-surpass/")

card("amex-marriott-brilliant", "American Express", "Marriott Bonvoy Brilliant", "USD", "Amex", 650, "marriott", 2, [
        earn(["hotels"], 6, merchants=MARRIOTT, note="Marriott properties only"),
        earn(["dining", "flights"], 3, note="Worldwide restaurants; flights booked directly"),
    ], ftf=0, credits=[credit("brilliant-dining", "Dining credit", 25, "monthly", "BRILLIANT DINING CREDIT", categories=["dining"],
                              notes="Eligible restaurants worldwide.")],
    perks=["Marriott Platinum Elite", "Free Night Award after renewal", "Priority Pass"],
    style=("#52283A", "#240E17"), match=["brilliant", "bonvoy brilliant"],
    source="https://www.americanexpress.com/us/credit-cards/card/marriott-bonvoy-brilliant/")

card("amex-delta-reserve", "American Express", "Delta SkyMiles Reserve", "USD", "Amex", 650, "delta", 1, [
        earn(["flights"], 3, merchants=["delta"], note="Delta purchases"),
    ], ftf=0, credits=[
        credit("delta-resy", "Resy credit", 20, "monthly", "RESY CREDIT", categories=["dining"], enrollment=True),
        credit("delta-rideshare", "Rideshare credit", 10, "monthly", "RIDESHARE CREDIT", merchants=["uber", "lyft"], enrollment=True),
    ], perks=["Delta Sky Club access", "Companion Certificate"], style=("#3A4451", "#111820"), match=["delta", "skymiles reserve"],
    source="https://www.americanexpress.com/us/credit-cards/card/delta-skymiles-reserve-american-express-card/")

# ---- Chase
card("chase-sapphire-reserve", "Chase", "Sapphire Reserve", "USD", "Visa", 795, "ur", 1, [
        earn(["flights", "hotels"], 8, restricted=True, note="Booked through Chase Travel"),
        earn(["flights", "hotels"], 4, note="Booked directly with airlines and hotels"),
        earn(["dining"], 3),
    ], ftf=0, credits=[
        credit("csr-travel", "Travel credit", 300, "cardmemberYear", "TRAVEL CREDIT", categories=TRAVEL,
               notes="First $300 of travel each cardmember year."),
        credit("csr-edit", "The Edit hotel credit", 250, "semiannual", "THE EDIT CREDIT", merchants=["chase travel", "the edit"], lag=45,
               notes="Prepaid The Edit stays via Chase Travel."),
        credit("csr-dining", "Exclusive Tables dining credit", 150, "semiannual", "DINING CREDIT", categories=["dining"],
               notes="Sapphire Reserve Exclusive Tables restaurants only; review matches."),
        credit("csr-stubhub", "StubHub credit", 150, "semiannual", "STUBHUB CREDIT", merchants=["stubhub", "viagogo"], enrollment=True),
    ], perks=["Priority Pass + Sapphire Lounges", "Primary rental car insurance"],
    style=("#2C3E5C", "#0F1A2E"), match=["sapphire reserve"],
    source="https://creditcards.chase.com/rewards-credit-cards/sapphire/reserve")

card("chase-sapphire-preferred", "Chase", "Sapphire Preferred", "USD", "Visa", 95, "ur", 1, [
        earn(["flights", "hotels"], 5, restricted=True, note="Booked through Chase Travel"),
        earn(["dining", "streaming"], 3, note="Dining, select streaming, online groceries"),
        earn(TRAVEL, 2, note="Other travel"),
    ], ftf=0, credits=[credit("csp-hotel", "Hotel credit", 50, "cardmemberYear", "HOTEL CREDIT", merchants=["chase travel"], lag=45,
                              notes="Hotel stays booked through Chase Travel.")],
    perks=["Primary rental car insurance"], style=("#3D5A86", "#1B2F4E"), match=["sapphire preferred"],
    source="https://creditcards.chase.com/rewards-credit-cards/sapphire/preferred")

card("chase-freedom-unlimited", "Chase", "Freedom Unlimited", "USD", "Visa", 0, "ur", 1.5, [
        earn(["flights", "hotels"], 5, restricted=True, note="Booked through Chase Travel"),
        earn(["dining", "drugstore"], 3),
    ], style=("#3E78C2", "#1D4A86"), match=["freedom unlimited"],
    source="https://creditcards.chase.com/cash-back-credit-cards/freedom/unlimited")

card("chase-freedom-flex", "Chase", "Freedom Flex", "USD", "Mastercard", 0, "ur", 1, [
        earn(["dining", "groceries", "gas", "streaming", "entertainment", "other"], 5, cap=1500, per="quarterly", restricted=True,
             note="Quarterly rotating categories with activation; $1,500/qtr"),
        earn(["flights", "hotels"], 5, restricted=True, note="Booked through Chase Travel"),
        earn(["dining", "drugstore"], 3),
    ], style=("#5D8FD6", "#27569B"), match=["freedom flex"],
    source="https://creditcards.chase.com/cash-back-credit-cards/freedom/flex")

card("chase-united-explorer", "Chase", "United Explorer", "USD", "Visa", 150, "united", 1, [
        earn(["flights"], 2, merchants=["united"], note="United purchases"),
        earn(["dining", "hotels"], 2, note="Dining and hotels booked directly"),
    ], ftf=0, perks=["Free first checked bag", "2 United Club passes"], style=("#2D5DA8", "#122E5C"), match=["united explorer", "mileageplus"],
    source="https://www.theexplorercard.com/")

card("chase-world-of-hyatt", "Chase", "World of Hyatt", "USD", "Visa", 95, "hyatt", 1, [
        earn(["hotels"], 4, merchants=["hyatt", "andaz", "park hyatt", "grand hyatt", "thompson"], note="Hyatt properties"),
        earn(["dining", "flights", "transit"], 2, note="Dining, flights direct, transit, fitness"),
    ], ftf=0, perks=["Annual Category 1–4 free night", "Discoverist status"], style=("#6B4E8F", "#33204F"), match=["world of hyatt", "hyatt"],
    source="https://creditcards.chase.com/travel-credit-cards/world-of-hyatt-credit-card")

# ---- Capital One
card("capone-venture-x", "Capital One", "Venture X", "USD", "Visa", 395, "c1", 2, [
        earn(["hotels"], 10, restricted=True, note="Hotels and rental cars via Capital One Travel"),
        earn(["flights"], 5, restricted=True, note="Flights via Capital One Travel"),
    ], ftf=0, credits=[credit("vx-travel", "Travel credit", 300, "cardmemberYear", "TRAVEL CREDIT", merchants=["capital one travel"], lag=45,
                              notes="Bookings through Capital One Travel. 10,000 anniversary miles are not tracked here.")],
    perks=["Capital One + Priority Pass lounges"], style=("#2E3440", "#0C0F14"), match=["venture x"],
    source="https://www.capitalone.com/credit-cards/venture-x/")

card("capone-venture", "Capital One", "Venture", "USD", "Visa", 95, "c1", 2, [
        earn(["hotels"], 5, restricted=True, note="Hotels and rental cars via Capital One Travel"),
    ], ftf=0, style=("#25476F", "#0F2440"), match=["venture rewards", "venture card"],
    source="https://www.capitalone.com/credit-cards/venture/")

card("capone-savor", "Capital One", "Savor", "USD", "Mastercard", 0, "cash_us", 1, [
        earn(["dining", "entertainment", "streaming", "groceries"], 3, note="Groceries exclude superstores like Walmart and Target"),
        earn(["hotels"], 5, restricted=True, note="Hotels and rental cars via Capital One Travel"),
    ], ftf=0, style=("#9C4A2F", "#5A2213"), match=["savor"],
    source="https://www.capitalone.com/credit-cards/savor/")

card("capone-quicksilver", "Capital One", "Quicksilver", "USD", "Visa", 0, "cash_us", 1.5, [
        earn(["hotels"], 5, restricted=True, note="Hotels and rental cars via Capital One Travel"),
    ], ftf=0, style=("#B8BEC7", "#7D8591"), light=False, match=["quicksilver"],
    source="https://www.capitalone.com/credit-cards/quicksilver/")

# ---- Citi
card("citi-strata-premier", "Citi", "Strata Premier", "USD", "Mastercard", 95, "ty", 1, [
        earn(["hotels"], 10, restricted=True, note="Hotels, car rentals and attractions via Citi Travel"),
        earn(["flights", "hotels", "dining", "groceries", "gas"], 3, note="Air travel, hotels, restaurants, supermarkets, gas & EV"),
    ], ftf=0, credits=[credit("strata-hotel", "Hotel credit", 100, "annual", "HOTEL CREDIT", merchants=["citi travel"], lag=45,
                              notes="One stay of $500+ booked through Citi Travel.")],
    style=("#2B4A6B", "#122438"), match=["strata premier", "citi premier"],
    source="https://www.citi.com/credit-cards/citi-strata-premier-credit-card")

card("citi-double-cash", "Citi", "Double Cash", "USD", "Mastercard", 0, "ty", 2, [
        earn(["hotels"], 5, restricted=True, note="Hotels and car rentals via Citi Travel"),
    ], style=("#5A7FA6", "#2B4A6B"), match=["double cash"],
    source="https://www.citi.com/credit-cards/citi-double-cash-credit-card")

card("citi-custom-cash", "Citi", "Custom Cash", "USD", "Mastercard", 0, "ty", 1, [
        earn(["dining", "groceries", "gas", "transit", "streaming", "drugstore", "entertainment"], 5, cap=500, per="monthly",
             restricted=True, note="5% on your top eligible category each billing cycle, up to $500"),
    ], style=("#3C8C8C", "#1B4F4F"), match=["custom cash"],
    source="https://www.citi.com/credit-cards/citi-custom-cash-credit-card",
    notes="Citi stopped accepting new applications May 28, 2026. The app still supports existing cardholders.")

# ---- U.S. Bank
card("usbank-altitude-go", "U.S. Bank", "Altitude Go", "USD", "Visa", 0, "usb", 1, [
        earn(["dining"], 4, note="Dining, takeout and delivery"),
        earn(["groceries", "gas", "streaming"], 2, note="Grocery, grocery delivery, gas & EV, streaming"),
    ], ftf=0, style=("#3F6E6A", "#1C3D3A"), match=["altitude go"],
    source="https://www.usbank.com/credit-cards/altitude-go-visa-signature-credit-card.html")

card("usbank-altitude-connect", "U.S. Bank", "Altitude Connect", "USD", "Visa", 0, "usb", 1, [
        earn(["hotels"], 5, restricted=True, note="Prepaid hotels and car rentals via the Altitude Rewards Center"),
        earn(TRAVEL + ["gas"], 4, note="Travel, gas & EV"),
        earn(["groceries", "dining", "streaming"], 2),
    ], ftf=0, style=("#2E4E7A", "#132540"), match=["altitude connect"],
    source="https://www.usbank.com/credit-cards/altitude-connect-visa-signature-credit-card.html")

card("usbank-cash-plus", "U.S. Bank", "Cash+", "USD", "Visa", 0, "cash_us", 1, [
        earn(["streaming", "entertainment", "other"], 5, cap=2000, per="quarterly", restricted=True,
             note="Two 5% categories you choose each quarter; $2,000 combined"),
        earn(["gas", "groceries", "dining"], 2, restricted=True, note="One 2% everyday category you choose"),
    ], style=("#7C3A8C", "#3F1A49"), match=["cash+", "cash plus"],
    source="https://www.usbank.com/credit-cards/cash-plus-visa-signature-credit-card.html")

# ---- Bank of America
card("bofa-customized-cash", "Bank of America", "Customized Cash Rewards", "USD", "Visa", 0, "cash_us", 1, [
        earn(["gas", "dining", "drugstore", "flights", "hotels"], 3, cap=2500, per="quarterly", restricted=True,
             note="3% in one category you choose; $2,500/qtr combined with 2%"),
        earn(["groceries"], 2, cap=2500, per="quarterly", note="Grocery stores and wholesale clubs"),
    ], style=("#B4323A", "#6A1219"), match=["customized cash"],
    source="https://www.bankofamerica.com/credit-cards/products/cash-back-credit-card/")

card("bofa-premium-rewards", "Bank of America", "Premium Rewards", "USD", "Visa", 95, "cash_us", 1.5, [
        earn(TRAVEL + ["dining"], 2),
    ], ftf=0, credits=[credit("bofa-airline", "Airline incidental credit", 100, "annual", "AIRLINE INCIDENTAL", categories=["flights"],
                              notes="Seat upgrades, bags, in-flight purchases; tickets don't qualify. Review matches.")],
    style=("#3B3F4A", "#15171C"), match=["premium rewards"],
    source="https://www.bankofamerica.com/credit-cards/products/premium-rewards-credit-card/")

# ---- Wells Fargo / Discover
card("wf-active-cash", "Wells Fargo", "Active Cash", "USD", "Visa", 0, "cash_us", 2, [],
     style=("#C7362F", "#7A1712"), match=["active cash"],
     source="https://creditcards.wellsfargo.com/active-cash-credit-card/")

card("wf-autograph", "Wells Fargo", "Autograph", "USD", "Visa", 0, "cash_us", 1, [
        earn(["dining", "gas", "streaming"] + TRAVEL, 3, note="Restaurants, travel, gas, transit, streaming, phone plans"),
    ], ftf=0, style=("#3A3A3F", "#121214"), match=["autograph"],
    source="https://creditcards.wellsfargo.com/autograph-visa-credit-card/")

card("discover-it-cash", "Discover", "Discover it Cash Back", "USD", "Discover", 0, "cash_us", 1, [
        earn(["dining", "groceries", "gas", "streaming", "entertainment", "drugstore", "other"], 5, cap=1500, per="quarterly",
             restricted=True, note="Quarterly rotating categories with activation; $1,500/qtr"),
    ], ftf=0, style=("#E8822A", "#A54E0C"), match=["discover it cash", "discover it"],
    source="https://www.discover.com/credit-cards/cash-back/it-card.html")

# ================================================================= CANADA
# ---- American Express Canada
card("amex-cobalt-ca", "American Express", "Cobalt Card", "CAD", "Amex", 191.88, "mr_ca", 1, [
        earn(["dining", "groceries"], 5, cap=2500, per="monthly", note="Eats & drinks; combined CAD 2,500 monthly spend cap"),
        earn(["streaming"], 3, note="Eligible streaming in Canada"),
        earn(["transit", "gas"], 2, note="Eligible Canadian gas, transit and rideshare purchases"),
    ], perks=["Amex Experiences", "Hotel collection credit"], style=("#1F4D9E", "#0D245C"), match=["cobalt"],
    source="https://www.americanexpress.com/en-ca/credit-cards/cobalt-card/")

card("amex-platinum-ca", "American Express", "Platinum Card (Canada)", "CAD", "Amex", 799, "mr_ca", 1, [
        earn(["dining"], 2), earn(TRAVEL, 2),
    ], ftf=0.025, credits=[
        credit("platca-travel", "Annual travel credit", 200, "cardmemberYear", "TRAVEL CREDIT", merchants=AMEX_TRAVEL, lag=45,
               notes="One booking through Amex Travel Online each cardmember year."),
        credit("platca-dining", "Dining credit", 200, "cardmemberYear", "DINING CREDIT", categories=["dining"],
               notes="Eligible restaurants in Canada; review matches."),
    ], perks=["Centurion Lounge + Priority Pass", "NEXUS credit"], style=("#D9DCE1", "#9CA3AD"), light=False,
    match=["the platinum card", "platinum card"], source="https://www.americanexpress.com/en-ca/charge-cards/the-platinum-card/")

card("amex-gold-ca", "American Express", "Gold Rewards Card (Canada)", "CAD", "Amex", 250, "mr_ca", 1, [
        earn(TRAVEL + ["gas", "groceries", "drugstore"], 2),
    ], credits=[credit("goldca-travel", "Annual travel credit", 100, "cardmemberYear", "TRAVEL CREDIT", merchants=AMEX_TRAVEL, lag=45)],
    style=("#D8B86A", "#9E7C34"), light=False, match=["gold rewards"],
    source="https://www.americanexpress.com/en-ca/credit-cards/gold-rewards-card/")

card("amex-simplycash-preferred-ca", "American Express", "SimplyCash Preferred", "CAD", "Amex", 119.88, "cash_ca", 2, [
        earn(["gas", "groceries"], 4, cap=30000, per="annual", note="Gas and groceries; annual spend cap"),
    ], style=("#4A7FC1", "#214B80"), match=["simplycash"],
    source="https://www.americanexpress.com/en-ca/credit-cards/simply-cash-preferred/")

# ---- TD
card("td-aeroplan-vi", "TD", "Aeroplan Visa Infinite", "CAD", "Visa", 139, "aeroplan", 1, [
        earn(["gas", "groceries"], 1.5), earn(["flights"], 1.5, merchants=["air canada"], note="Air Canada purchases"),
    ], perks=["Free first checked bag on Air Canada"], style=("#2E3A48", "#11161D"), match=["aeroplan visa infinite"],
    source="https://www.td.com/ca/en/personal-banking/products/credit-cards/aeroplan/aeroplan-visa-infinite-card")

card("td-first-class-vi", "TD", "First Class Travel Visa Infinite", "CAD", "Visa", 139, "td", 2, [
        earn(["flights", "hotels"], 8, restricted=True, note="Booked through Expedia for TD"),
        earn(["groceries", "dining"], 6),
        earn(["streaming"], 4, note="Recurring bill payments"),
    ], style=("#2F6B3A", "#123A1A"), match=["first class travel", "first class"],
    source="https://www.td.com/ca/en/personal-banking/products/credit-cards/travel-rewards/first-class-travel-visa-infinite-card")

card("td-cash-back-vi", "TD", "Cash Back Visa Infinite", "CAD", "Visa", 139, "cash_ca", 1, [
        earn(["groceries", "gas", "streaming"], 3, note="Groceries, gas & EV, recurring bills; caps apply"),
    ], style=("#3E8A4A", "#1A4A22"), match=["cash back visa infinite", "td cash back"],
    source="https://www.td.com/ca/en/personal-banking/products/credit-cards/cash-back/cash-back-visa-infinite-card")

# ---- CIBC
card("cibc-aventura-vi", "CIBC", "Aventura Visa Infinite", "CAD", "Visa", 139, "aventura", 1, [
        earn(["flights"], 2, restricted=True, note="Booked through CIBC Rewards Centre only"),
        earn(["gas", "groceries", "drugstore"], 1.5),
    ], perks=["NEXUS fee rebate every 4 years", "Visa Airport Companion (4 visits)"],
    style=("#9E1A24", "#540A10"), match=["aventura visa infinite", "aventura"],
    source="https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/aventura-visa-infinite-card.html")

card("cibc-aeroplan-vi", "CIBC", "Aeroplan Visa Infinite", "CAD", "Visa", 139, "aeroplan", 1, [
        earn(["gas", "groceries"], 1.5), earn(["flights"], 1.5, merchants=["air canada"], note="Air Canada purchases"),
    ], perks=["Free first checked bag on Air Canada"], style=("#7A1F28", "#3D0B10"), match=["aeroplan visa infinite"],
    source="https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/aeroplan-visa-infinite-card.html")

card("cibc-dividend-vi", "CIBC", "Dividend Visa Infinite", "CAD", "Visa", 120, "cash_ca", 1, [
        earn(["gas", "groceries"], 4, cap=20000, per="annual", note="Gas & EV and groceries; annual cap"),
        earn(["transit", "dining", "streaming"], 2, note="Transportation, dining, recurring payments"),
    ], style=("#B02A33", "#64121A"), match=["dividend visa infinite", "dividend"],
    source="https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/dividend-visa-infinite-card.html")

# ---- RBC
card("rbc-avion-vi", "RBC", "Avion Visa Infinite", "CAD", "Visa", 120, "avion", 1, [
        earn(TRAVEL, 1.25, note="Eligible travel purchases"),
    ], style=("#1F3E7A", "#0A1C3E"), match=["avion"],
    source="https://www.rbcroyalbank.com/credit-cards/travel/rbc-avion-visa-infinite.html")

card("rbc-ion-plus", "RBC", "ION+ Visa", "CAD", "Visa", 48, "rbc_ion", 1, [
        earn(["groceries", "dining", "transit", "gas", "streaming"], 3, note="Groceries, dining, rides, gas & EV, streaming, subscriptions"),
    ], style=("#2A5DB0", "#123067"), match=["ion+", "ion plus"],
    source="https://www.rbcroyalbank.com/credit-cards/rewards/rbc-ion-plus-visa.html")

card("rbc-westjet-we", "RBC", "WestJet World Elite Mastercard", "CAD", "Mastercard", 139, "westjet", 1.5, [
        earn(["flights"], 2, merchants=["westjet"], note="WestJet flights and vacations"),
    ], perks=["Annual companion voucher", "Free first checked bag"], style=("#1B6E8C", "#0A3445"), match=["westjet"],
    source="https://www.rbcroyalbank.com/credit-cards/travel/westjet-rbc-world-elite-mastercard.html")

# ---- BMO
card("bmo-eclipse-vi", "BMO", "eclipse Visa Infinite", "CAD", "Visa", 120, "bmo", 1, [
        earn(["dining", "groceries", "gas", "transit"], 5, note="Dining, groceries, gas and transit; caps apply"),
    ], style=("#1E2C4A", "#0A1122"), match=["eclipse"],
    source="https://www.bmo.com/en-ca/main/personal/credit-cards/bmo-eclipse-visa-infinite/")

card("bmo-cashback-we", "BMO", "CashBack World Elite Mastercard", "CAD", "Mastercard", 139, "cash_ca", 1, [
        earn(["groceries"], 5, cap=500, per="monthly", note="Groceries; CAD 500/month"),
        earn(["transit"], 4, cap=300, per="monthly"), earn(["gas"], 3, cap=300, per="monthly"),
        earn(["streaming"], 2, cap=500, per="monthly", note="Recurring bills"),
    ], style=("#0F5FA8", "#06305A"), match=["cashback world elite", "bmo cashback"],
    source="https://www.bmo.com/en-ca/main/personal/credit-cards/bmo-cashback-world-elite-mastercard/")

# ---- Scotiabank
card("scotia-gold-amex", "Scotiabank", "Gold American Express", "CAD", "Amex", 120, "scene", 1, [
        earn(["groceries"], 6, merchants=["sobeys", "safeway", "iga", "foodland", "freshco", "thrifty"], note="Sobeys-family grocers"),
        earn(["groceries", "dining", "entertainment"], 5),
        earn(["gas", "transit", "streaming"], 3),
    ], ftf=0, style=("#C9A24A", "#8A6A1F"), light=False, match=["scotiabank gold", "gold american express"],
    source="https://www.scotiabank.com/ca/en/personal/credit-cards/american-express/gold-card.html")

card("scotia-passport-vi", "Scotiabank", "Passport Visa Infinite", "CAD", "Visa", 150, "scene", 1, [
        earn(["groceries"], 3, merchants=["sobeys", "safeway", "iga", "foodland", "freshco"], note="Sobeys-family grocers"),
        earn(["groceries", "dining", "entertainment", "transit"], 2),
    ], ftf=0, perks=["6 lounge visits a year", "No foreign transaction fee"], style=("#2B4C6F", "#11243A"), match=["passport"],
    source="https://www.scotiabank.com/ca/en/personal/credit-cards/visa/passport-infinite-card.html")

# ================================================================= UNITED STATES — additional popular cards (catalog 2026.11.3)
VERIFY = "Earn structure changed recently; bonus counted at base rate until verified."

# ---- American Express (more personal + business)
card("amex-hilton-honors-us", "American Express", "Hilton Honors Card", "USD", "Amex", 0, "hilton", 3, [
        earn(["hotels"], 7, merchants=HILTON, note="Hilton portfolio properties"),
        earn(["dining", "groceries", "gas"], 5, note="U.S. restaurants, supermarkets and gas"),
    ], ftf=0, perks=["Hilton Silver status"], style=("#6B86AE", "#33496E"), match=["hilton honors card", "hilton honors american express card"],
    source="https://www.americanexpress.com/us/credit-cards/card/hilton-honors/")

card("amex-marriott-bevy", "American Express", "Marriott Bonvoy Bevy", "USD", "Amex", 250, "marriott", 2, [
        earn(["hotels"], 6, merchants=MARRIOTT, note="Marriott properties"),
        earn(["dining", "groceries"], 4, cap=15000, per="annual", note="Restaurants and U.S. supermarkets; $15k/yr"),
    ], ftf=0, perks=["Marriott Gold Elite"], style=("#8C6A4A", "#4A3220"), match=["bevy"],
    source="https://www.americanexpress.com/us/credit-cards/card/marriott-bonvoy-bevy/")

card("amex-delta-gold", "American Express", "Delta SkyMiles Gold", "USD", "Amex", 150, "delta", 1, [
        earn(["flights"], 2, merchants=["delta"], note="Delta purchases"),
        earn(["dining", "groceries"], 2, note="Restaurants and U.S. supermarkets"),
    ], ftf=0, perks=["Free first checked bag on Delta"], style=("#B9975B", "#7A5E2E"), light=False, match=["skymiles gold", "delta gold"],
    source="https://www.americanexpress.com/us/credit-cards/card/delta-skymiles-gold-american-express-card/")

card("amex-delta-platinum", "American Express", "Delta SkyMiles Platinum", "USD", "Amex", 350, "delta", 1, [
        earn(["flights"], 3, merchants=["delta"], note="Delta purchases"),
        earn(["hotels"], 3, note="Hotels booked directly"),
        earn(["dining", "groceries"], 2, note="Restaurants and U.S. supermarkets"),
    ], ftf=0, perks=["Companion Certificate"], style=("#9AA3AE", "#5C6470"), match=["skymiles platinum", "delta platinum"],
    source="https://www.americanexpress.com/us/credit-cards/card/delta-skymiles-platinum-american-express-card/")

card("amex-blue-business-plus", "American Express", "Blue Business Plus", "USD", "Amex", 0, "mr_us", 1, [
        earn(["dining", "groceries", "gas", "flights", "hotels", "transit", "streaming", "drugstore", "entertainment", "other"], 2,
             cap=50000, per="annual", note="2x on all purchases up to $50k/yr"),
    ], segment="business", style=("#3D6FB0", "#1A3C6B"), match=["blue business plus"],
    source="https://www.americanexpress.com/us/credit-cards/business/business-credit-cards/blue-business-plus-credit-card-amex/")

card("amex-business-gold", "American Express", "Business Gold Card", "USD", "Amex", 375, "mr_us", 1, [
        earn(["dining", "gas", "transit", "streaming", "other"], 4, cap=150000, per="annual", restricted=True,
             note="4x in your top two eligible categories each month; $150k/yr"),
        earn(["flights", "hotels"], 3, restricted=True, note="Flights and prepaid hotels via Amex Travel"),
    ], ftf=0, segment="business", style=("#D8B86A", "#9E7C34"), light=False, match=["business gold"],
    source="https://www.americanexpress.com/us/credit-cards/business/business-credit-cards/american-express-business-gold-card-amex/")

card("amex-business-platinum", "American Express", "Business Platinum Card", "USD", "Amex", 895, "mr_us", 1, [
        earn(["flights", "hotels"], 5, restricted=True, note="Flights and prepaid hotels via Amex Travel"),
    ], ftf=0, segment="business", perks=["Centurion Lounge + Priority Pass"], style=("#C9CDD3", "#8A929C"), light=False,
    match=["business platinum"], source="https://www.americanexpress.com/us/credit-cards/business/business-credit-cards/american-express-business-platinum-credit-card-amex/")

# ---- Chase (co-brands, Amazon, Ink)
card("chase-aeroplan-us", "Chase", "Air Canada Aeroplan Card", "USD", "Mastercard", 195, "aeroplan_us", 1, [
        earn(TRAVEL, 3, note="Eligible travel. Air Canada advertises up to 5×, including 2× from Aeroplan 25K status."),
        earn(["dining", "groceries"], 3, note="Through Dec 31, 2026. Chase lists 2× starting Jan 1, 2027."),
        earn(["gas"], 2),
    ], ftf=0, perks=["Aeroplan 25K status", "Free first checked bag on Air Canada"], style=("#1D2733", "#0A0F15"),
    match=["aeroplan"], source="https://creditcards.chase.com/travel-credit-cards/aircanada/aeroplan",
    notes="Standard fee after the September 2026 refresh. Published dining and grocery rates change Jan 1, 2027. Chase offers two $50 Air Canada statement credits per year on eligible transactions.")

card("chase-amazon-prime-visa", "Chase", "Prime Visa", "USD", "Visa", 0, "cash_us", 1, [
        earn(["groceries", "other"], 5, merchants=["amazon", "whole foods", "amzn"], note="Amazon and Whole Foods with Prime"),
        earn(["dining", "gas", "transit"], 2),
    ], ftf=0, style=("#232F3E", "#0B1017"), match=["prime visa", "amazon prime"],
    source="https://creditcards.chase.com/cash-back-credit-cards/amazon-prime-rewards")

card("chase-marriott-boundless", "Chase", "Marriott Bonvoy Boundless", "USD", "Visa", 95, "marriott", 2, [
        earn(["hotels"], 6, merchants=MARRIOTT, note="Marriott properties"),
        earn(["groceries", "gas", "dining"], 3, cap=6000, per="annual", note="Grocery, gas and dining; $6k/yr combined"),
    ], ftf=0, perks=["Annual Free Night (35k)"], style=("#5C4A3A", "#2A1F17"), match=["boundless"],
    source="https://creditcards.chase.com/travel-credit-cards/marriott-bonvoy/boundless")

card("chase-ihg-premier", "Chase", "IHG One Rewards Premier", "USD", "Mastercard", 99, "ihg", 3, [
        earn(["hotels"], 10, merchants=["ihg", "holiday inn", "intercontinental", "crowne plaza", "kimpton", "staybridge", "candlewood"],
             note="IHG hotels"),
        earn(TRAVEL + ["dining", "gas"], 5),
    ], ftf=0, perks=["Anniversary Free Night", "IHG Platinum Elite"], style=("#1F4E46", "#0C2622"), match=["ihg"],
    source="https://creditcards.chase.com/travel-credit-cards/ihg-rewards-club/premier")

card("chase-southwest-plus", "Chase", "Southwest Rapid Rewards Plus", "USD", "Visa", 99, "southwest", 1, [
        earn(["flights"], 2, merchants=["southwest"], note="Southwest purchases"),
        earn(["groceries", "dining"], 2, restricted=True, note=VERIFY),
    ], style=("#304CB2", "#16246A"), match=["rapid rewards plus", "southwest plus"],
    source="https://creditcards.chase.com/travel-credit-cards/southwest/plus")

card("chase-southwest-priority", "Chase", "Southwest Rapid Rewards Priority", "USD", "Visa", 229, "southwest", 1, [
        earn(["flights"], 3, merchants=["southwest"], note="Southwest purchases"),
        earn(["groceries", "dining"], 2, restricted=True, note=VERIFY),
    ], ftf=0, style=("#2A3F8F", "#121E52"), match=["rapid rewards priority", "southwest priority"],
    source="https://creditcards.chase.com/travel-credit-cards/southwest/priority")

card("chase-ink-preferred", "Chase", "Ink Business Preferred", "USD", "Visa", 95, "ur", 1, [
        earn(TRAVEL + ["streaming"], 3, cap=150000, per="annual", note="Travel, shipping, internet/cable/phone, social ads; $150k/yr"),
    ], ftf=0, segment="business", style=("#2B3440", "#10141A"), match=["ink business preferred", "ink preferred"],
    source="https://creditcards.chase.com/business-credit-cards/ink/business-preferred")

card("chase-ink-cash", "Chase", "Ink Business Cash", "USD", "Visa", 0, "ur", 1, [
        earn(["streaming", "other"], 5, cap=25000, per="annual", restricted=True, note="Office supply stores, internet, cable, phone; $25k/yr"),
        earn(["gas", "dining"], 2, cap=25000, per="annual"),
    ], segment="business", style=("#3A4757", "#161C24"), match=["ink business cash", "ink cash"],
    source="https://creditcards.chase.com/business-credit-cards/ink/cash")

card("chase-ink-unlimited", "Chase", "Ink Business Unlimited", "USD", "Visa", 0, "ur", 1.5, [], segment="business",
     style=("#4A5767", "#1E2530"), match=["ink business unlimited", "ink unlimited"],
     source="https://creditcards.chase.com/business-credit-cards/ink/unlimited")

card("chase-freedom-rise", "Chase", "Freedom Rise", "USD", "Visa", 0, "ur", 1.5, [], style=("#6FA0DC", "#33669F"),
     match=["freedom rise"], source="https://creditcards.chase.com/cash-back-credit-cards/freedom/rise")

# ---- Capital One / Citi / BofA / Discover / others
card("capone-ventureone", "Capital One", "VentureOne", "USD", "Visa", 0, "c1", 1.25, [
        earn(["hotels"], 5, restricted=True, note="Hotels and rental cars via Capital One Travel"),
    ], ftf=0, style=("#3B5F8A", "#1A3150"), match=["ventureone", "venture one"],
    source="https://www.capitalone.com/credit-cards/ventureone/")

card("citi-strata-elite", "Citi", "Strata Elite", "USD", "Mastercard", 595, "ty", 1.5, [
        earn(["hotels"], 12, restricted=True, note="Hotels, car rentals and attractions via Citi Travel"),
        earn(["flights"], 6, restricted=True, note="Air travel via Citi Travel"),
        earn(["dining"], 6, restricted=True, note="Citi Nights dining (Fri/Sat evenings); 3x other times — verify"),
    ], ftf=0, perks=["Priority Pass + Admirals Club passes"], style=("#1E2A3A", "#0A1018"), match=["strata elite"],
    source="https://www.citi.com/credit-cards/citi-strata-elite-credit-card")

card("citi-costco-anywhere", "Citi", "Costco Anywhere Visa", "USD", "Visa", 0, "cash_us", 1, [
        earn(["gas"], 4, cap=7000, per="annual", note="Gas and EV charging; $7k/yr, then 1%"),
        earn(["dining", "flights", "hotels", "transit"], 3, note="Restaurants and eligible travel"),
        earn(["groceries", "other"], 2, merchants=["costco"], note="Costco and Costco.com"),
    ], ftf=0, style=("#2D5C9E", "#C8303A"), match=["costco anywhere", "costco"],
    source="https://www.citi.com/credit-cards/citi-costco-anywhere-visa-credit-card", notes="Annual fee is $0 with a paid Costco membership.")

card("citi-aadvantage-platinum", "Citi", "AAdvantage Platinum Select", "USD", "Mastercard", 99, "aadvantage", 1, [
        earn(["flights"], 2, merchants=["american airlines", "american air"], note="American Airlines purchases"),
        earn(["dining", "gas"], 2),
    ], ftf=0, perks=["Free first checked bag on American"], style=("#8A9199", "#4B5159"), match=["aadvantage platinum", "aadvantage"],
    source="https://www.citi.com/credit-cards/citi-aadvantage-platinum-select-world-elite-mastercard",
    notes="Citi and American Airlines announced a $150 annual fee and updated benefits starting Jan 24, 2027.")

card("bofa-unlimited-cash", "Bank of America", "Unlimited Cash Rewards", "USD", "Visa", 0, "cash_us", 1.5, [],
     style=("#C2353D", "#6E1218"), match=["unlimited cash rewards"],
     source="https://www.bankofamerica.com/credit-cards/products/unlimited-cash-back-credit-card/")

card("bofa-travel-rewards", "Bank of America", "Travel Rewards", "USD", "Visa", 0, "cash_us", 1.5, [], ftf=0,
     style=("#1F3C70", "#0B1A38"), match=["travel rewards"],
     source="https://www.bankofamerica.com/credit-cards/products/travel-rewards-credit-card/")

card("atmos-ascent", "Bank of America", "Atmos Rewards Ascent", "USD", "Visa", 95, "atmos", 1, [
        earn(["flights"], 3, merchants=["alaska", "hawaiian"], note="Alaska and Hawaiian purchases"),
        earn(["gas", "transit", "streaming"], 2, restricted=True, note=VERIFY),
    ], ftf=0, perks=["Annual companion fare", "Free checked bag"], style=("#1E4E79", "#0B2440"), match=["atmos ascent", "atmos rewards ascent", "alaska airlines"],
    source="https://www.bankofamerica.com/credit-cards/products/alaska-airlines-credit-card/",
    notes="Formerly Alaska Airlines Visa Signature.")

card("atmos-summit", "Bank of America", "Atmos Rewards Summit Visa Infinite", "USD", "Visa", 395, "atmos", 1, [
        earn(["dining"], 3), earn(["flights"], 3, merchants=["alaska", "hawaiian"], note="Alaska and Hawaiian purchases"),
    ], ftf=0, perks=["3x on purchases abroad", "Lounge passes"], style=("#14324F", "#06121F"), match=["atmos summit", "atmos rewards summit", "summit visa infinite"],
    source="https://www.bankofamerica.com/credit-cards/products/alaska-airlines-infinite-credit-card/")

card("discover-it-miles", "Discover", "Discover it Miles", "USD", "Discover", 0, "cash_us", 1.5, [], ftf=0,
     style=("#3A6EA5", "#1A3B60"), match=["discover it miles"],
     source="https://www.discover.com/credit-cards/travel/it-miles.html")

card("apple-card", "Apple", "Apple Card", "USD", "Mastercard", 0, "cash_us", 1, [
        earn(["other"], 3, merchants=["apple", "uber", "walgreens", "nike", "exxon", "t-mobile"], note="Apple and select merchants via Apple Pay"),
        earn(["dining", "groceries", "gas", "transit", "streaming", "drugstore", "entertainment", "flights", "hotels", "other"], 2,
             restricted=True, note="2% when paid with Apple Pay (the feed can't see the payment method)"),
    ], ftf=0, style=("#F2F2F4", "#C9CACF"), light=False, match=["apple card"],
    source="https://www.apple.com/apple-card/")

card("bilt-blue", "Bilt", "Bilt Blue Card", "USD", "Mastercard", 0, "bilt", 1, [
        earn(["dining", "flights", "hotels"], 2, restricted=True, note=VERIFY),
    ], style=("#2B5FD9", "#132E73"), match=["bilt blue"], source="https://www.bilt.com/card",
    notes="Bilt replaced its single card with Blue, Obsidian and Palladium in Feb 2026.")

card("bilt-obsidian", "Bilt", "Bilt Obsidian Card", "USD", "Mastercard", 95, "bilt", 1, [
        earn(["dining", "groceries"], 3, restricted=True, note="Choose dining or groceries — " + VERIFY),
        earn(["flights", "hotels"], 2, restricted=True, note=VERIFY),
    ], ftf=0, style=("#2A2A2E", "#0B0B0D"), match=["bilt obsidian"], source="https://www.bilt.com/card")

card("bilt-palladium", "Bilt", "Bilt Palladium Card", "USD", "Mastercard", 495, "bilt", 2, [], ftf=0,
     perks=["Lounge access"], style=("#B7B9BE", "#7A7D84"), light=False, match=["bilt palladium"],
     source="https://www.bilt.com/card", notes="Premium Bilt card; verify earn and credits.")

card("robinhood-gold-card", "Robinhood", "Robinhood Gold Card", "USD", "Visa", 0, "cash_us", 3, [
        earn(["flights", "hotels"], 5, restricted=True, note="Travel booked through Robinhood's portal"),
    ], ftf=0, style=("#C9A93F", "#7A6419"), light=False, match=["robinhood"],
    source="https://robinhood.com/creditcard/", notes="Requires a paid Robinhood Gold membership.")

# ================================================================= CANADA — additional popular cards (catalog 2026.11.3)
AIR_CANADA = ["air canada"]
LOBLAW = ["loblaws", "no frills", "real canadian superstore", "zehrs", "fortinos", "provigo", "maxi", "independent", "valu-mart", "loblaw"]

# ---- Aeroplan: every personal tier at TD, CIBC and Amex, plus TD business
card("td-aeroplan-platinum", "TD", "Aeroplan Visa Platinum", "CAD", "Visa", 89, "aeroplan", 0.67, [
        earn(["gas", "groceries"], 1), earn(["flights"], 1, merchants=AIR_CANADA, note="Air Canada purchases"),
    ], style=("#6E7682", "#363C45"), match=["aeroplan visa platinum"],
    source="https://www.td.com/ca/en/personal-banking/products/credit-cards/aeroplan/aeroplan-visa-platinum-card",
    notes="1 point per $1.50 on other purchases.")

card("td-aeroplan-vip", "TD", "Aeroplan Visa Infinite Privilege", "CAD", "Visa", 599, "aeroplan", 1.25, [
        earn(["flights"], 2, merchants=AIR_CANADA, note="Air Canada purchases"),
        earn(["gas", "groceries", "dining"], 1.5),
    ], perks=["Maple Leaf Lounge access", "Priority airport services", "Free checked bags"], style=("#1A1F27", "#05070A"),
    match=["aeroplan visa infinite privilege", "infinite privilege"],
    source="https://www.td.com/ca/en/personal-banking/products/credit-cards/aeroplan/aeroplan-visa-infinite-privilege-card",
    notes="TD has announced a $699 primary card fee. Existing cardholders pay the new fee on their first renewal due on or after Jan 25, 2027.")

card("td-aeroplan-business", "TD", "Aeroplan Visa Business", "CAD", "Visa", 149, "aeroplan", 1, [
        earn(["flights"], 2, merchants=AIR_CANADA, note="Air Canada purchases"),
        earn(TRAVEL + ["dining"], 1.5, note="Travel, dining and select business categories"),
    ], segment="business", style=("#2A3340", "#0E1218"), match=["aeroplan visa business"],
    source="https://www.td.com/ca/en/business-banking/small-business/credit-cards/aeroplan-visa-business-card")

card("cibc-aeroplan-visa", "CIBC", "Aeroplan Visa", "CAD", "Visa", 0, "aeroplan", 0.67, [
        earn(["gas", "groceries"], 1), earn(["flights"], 1, merchants=AIR_CANADA, note="Air Canada purchases"),
    ], style=("#A83A44", "#5C141B"), match=["aeroplan visa card", "aeroplan visa"],
    source="https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/aeroplan-visa-card.html",
    notes="1 point per $1.50 on other purchases.")

card("cibc-aeroplan-vip", "CIBC", "Aeroplan Visa Infinite Privilege", "CAD", "Visa", 599, "aeroplan", 1.25, [
        earn(["flights"], 2, merchants=AIR_CANADA, note="Air Canada purchases"),
        earn(["gas", "groceries", "dining", "transit"], 1.5),
    ], perks=["Maple Leaf Lounge access", "Priority airport services", "Free checked bags"], style=("#3A0D12", "#140305"),
    match=["aeroplan visa infinite privilege", "infinite privilege"],
    source="https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/aeroplan-visa-infinite-privilege-card.html",
    notes="CIBC lists a $699 annual fee effective Jan 12, 2027.")

card("amex-aeroplan-ca", "American Express", "Aeroplan Card", "CAD", "Amex", 120, "aeroplan", 1, [
        earn(["flights"], 2, merchants=AIR_CANADA, note="Air Canada purchases"),
        earn(["dining"], 1.5, note="Dining and food delivery in Canada"),
    ], style=("#3E4A5A", "#151B24"), match=["american express aeroplan card", "aeroplan card"],
    source="https://www.americanexpress.com/en-ca/credit-cards/aeroplan-card/",
    notes="Annual fee scheduled to rise to $150 on Jan 12, 2027.")

card("amex-aeroplan-reserve-ca", "American Express", "Aeroplan Reserve Card", "CAD", "Amex", 599, "aeroplan", 1.25, [
        earn(["flights"], 3, merchants=AIR_CANADA, note="Air Canada purchases"),
        earn(["dining"], 2, note="Dining and food delivery in Canada"),
    ], perks=["Maple Leaf Lounge + Centurion Lounge access", "Annual Worldwide Companion Pass"], style=("#1B1E23", "#050608"),
    match=["aeroplan reserve"], source="https://www.americanexpress.com/en-ca/credit-cards/aeroplan-reserve/",
    notes="Amex lists a $799 annual fee and updated Air Canada travel benefits effective Jan 12, 2027.")

# ---- Amex Canada hotel and no-fee cards
card("amex-marriott-ca", "American Express", "Marriott Bonvoy Card (Canada)", "CAD", "Amex", 120, "marriott_ca", 2, [
        earn(["hotels"], 5, merchants=MARRIOTT, note="Marriott properties"),
    ], perks=["Annual Free Night (35k)", "Silver Elite"], style=("#52283A", "#240E17"), match=["marriott bonvoy"],
    source="https://www.americanexpress.com/en-ca/credit-cards/marriott-bonvoy-card/",
    notes="Amex lists a $150 fee from the first annual-fee billing date on or after Feb 9, 2027.")

card("amex-marriott-business-ca", "American Express", "Marriott Bonvoy Business Card (Canada)", "CAD", "Amex", 150, "marriott_ca", 2, [
        earn(["hotels"], 5, merchants=MARRIOTT, note="Marriott properties"),
        earn(["gas", "dining", "flights", "transit"], 3, restricted=True, note="Gas, dining and travel — verify"),
    ], segment="business", perks=["Annual Free Night (35k)"], style=("#3C1E2B", "#17080E"), match=["marriott bonvoy business"],
    source="https://www.americanexpress.com/en-ca/business/business-cards/marriott-bonvoy-business-card/")

card("amex-hilton-ca", "American Express", "Hilton Honors Card (Canada)", "CAD", "Amex", 150, "hilton_ca", 2, [
        earn(["groceries", "dining", "gas"], 4, note="Eligible grocery, restaurants and gas in Canada"),
        earn(["hotels"], 6, merchants=HILTON, note="Eligible purchases at Hilton properties"),
    ], perks=["Hilton Honors Gold status", "50,000 bonus Hilton Honors points after $12,000 in eligible calendar-year purchases"],
    style=("#2F3A52", "#141A28"), match=["hilton honors"],
    source="https://www.americanexpress.com/en-ca/credit-cards/apply/personal/hilton-honors")

card("amex-green-ca", "American Express", "Green Card (Canada)", "CAD", "Amex", 0, "mr_ca", 1, [], style=("#4E8A5B", "#24502F"),
     match=["green card"], source="https://www.americanexpress.com/en-ca/credit-cards/green-card/")

card("amex-simplycash-ca", "American Express", "SimplyCash Card", "CAD", "Amex", 0, "cash_ca", 1.25, [
        earn(["gas", "groceries"], 2, cap=15000, per="annual", note="Gas and groceries; annual cap"),
    ], style=("#69A7E8", "#2F6FB5"), match=["simplycash card"],
    source="https://www.americanexpress.com/en-ca/credit-cards/simply-cash/")

# ---- Wealthsimple
card("wealthsimple-vi-2", "Wealthsimple", "Visa Infinite+ (2%)", "CAD", "Visa", 240, "cash_ca", 2, [], style=("#1C1C1C", "#000000"),
     match=["wealthsimple visa infinite", "visa infinite+", "visa infinite +", "wealthsimple"],
     source="https://help.wealthsimple.com/hc/en-ca/articles/31614256039835-Apply-for-a-Wealthsimple-credit-card",
     notes="Fee is $20/month, waived for eligible clients (assets or direct deposit).")

card("wealthsimple-vip", "Wealthsimple", "Visa Infinite Privilege", "CAD", "Visa", 240, "cash_ca", 2, [],
     perks=["Lounge access", "Rental car coverage"], style=("#2A2A2A", "#050505"), match=["wealthsimple visa infinite privilege", "visa infinite privilege", "wealthsimple"],
     source="https://help.wealthsimple.com/hc/en-ca/articles/31614256039835-Apply-for-a-Wealthsimple-credit-card",
     notes="Fee is $20/month, waived for eligible clients.")

card("wealthsimple-vi-1", "Wealthsimple", "Visa Infinite (1%)", "CAD", "Visa", 0, "cash_ca", 1, [], style=("#3A3A3A", "#151515"),
     match=["wealthsimple 1%", "visa infinite (1%)", "visa infinite 1%"],
     source="https://help.wealthsimple.com/hc/en-ca/articles/51274223026203-Understand-premium-benefits-for-the-Visa-Infinite-1-credit-card-beta",
     notes="Invitation-only beta.")

# ---- Rogers Bank (structure changed Nov 18, 2026)
ROGERS = ["rogers", "fido", "shaw", "comwave"]
card("rogers-red-we", "Rogers Bank", "Rogers Red World Elite Mastercard", "CAD", "Mastercard", 0, "cash_ca", 1.5, [
        earn(["streaming", "other"], 5, merchants=ROGERS, restricted=True, note="Up to 5% on Rogers purchases — verify tiers"),
        earn(["dining", "groceries", "gas", "flights", "hotels", "transit", "streaming", "drugstore", "entertainment", "other"], 2,
             restricted=True, note="Up to 2% with eligible service during the annual spend period"),
    ], style=("#DA291C", "#7A120A"), match=["rogers red world elite", "rogers world elite"],
    source="https://www.rogersbank.com/en/rogers_red_worldelite_mastercard_details/",
    notes="From Nov 18, 2026, eligible Rogers purchases earn 5% until the $61,000 annual spend limit. The 1.5× redemption bonus ended. Estimated rewards exclude the USD rate and shared spend-limit logic.")

card("rogers-red-mc", "Rogers Bank", "Rogers Red Mastercard", "CAD", "Mastercard", 0, "cash_ca", 1, [
        earn(["streaming", "other"], 5, merchants=ROGERS, restricted=True, note="Up to 5% on Rogers purchases — verify tiers"),
        earn(["dining", "groceries", "gas", "flights", "hotels", "transit", "streaming", "drugstore", "entertainment", "other"], 1.5,
             restricted=True, note="Higher rate for Rogers/Fido customers — verify"),
    ], style=("#E0473B", "#8C1A12"), match=["rogers red mastercard", "rogers mastercard"],
    source="https://www.rogersbank.com/en/rogers_red_mastercard_details/",
    notes="From Nov 18, 2026, eligible Rogers purchases earn 5%. A qualifying Rogers, Fido, Shaw or Comwave service affects other earnings.")

# ---- Capital One Canada (credit-building cards; no rewards)
card("capone-ca-platinum", "Capital One", "Platinum Mastercard (Canada)", "CAD", "Mastercard", 0, "cash_ca", 0, [],
     style=("#5A6270", "#2A2F38"), match=["platinum mastercard"], source="https://www.capitalone.ca/credit-cards/compare/",
     notes="Legacy profile. Confirm your fee and rewards against your account terms.")
card("capone-ca-guaranteed", "Capital One", "Guaranteed Mastercard (Canada)", "CAD", "Mastercard", 0, "cash_ca", 0, [],
     style=("#3E4652", "#1A1E24"), match=["guaranteed mastercard", "guaranteed secured"],
     source="https://www.capitalone.ca/credit-cards/guaranteed-mastercard/",
     notes="Current offer has no annual fee. Check your cardholder agreement for legacy pricing.")

# ---- Costco, PC Financial, Canadian Tire, MBNA, Tangerine, Simplii, National Bank, BMO, RBC, Scotiabank, TD, Home Trust
card("cibc-costco-mc", "CIBC", "Costco Mastercard", "CAD", "Mastercard", 0, "cash_ca", 1, [
        earn(["dining"], 3), earn(["gas"], 2, note="Costco gas and other gas stations"),
        earn(["other"], 2, merchants=["costco.ca"], note="Costco.ca"),
    ], style=("#2D5C9E", "#C8303A"), match=["costco"], source="https://www.cibc.com/en/personal-banking/credit-cards/costco.html",
    notes="Requires a Costco membership.")

card("pc-world-elite", "PC Financial", "PC World Elite Mastercard", "CAD", "Mastercard", 0, "pc_optimum", 10, [
        earn(["groceries", "other"], 30, merchants=LOBLAW, note="Loblaw-family stores"),
        earn(["drugstore"], 45, merchants=["shoppers drug mart", "pharmaprix"], note="Shoppers Drug Mart"),
        earn(["gas"], 30, restricted=True, note="30 points per litre at Esso/Mobil — per-litre, not per dollar"),
    ], style=("#1A1A1A", "#000000"), match=["pc world elite", "president's choice world elite"],
    source="https://www.pcfinancial.ca/en/credit-cards/world-elite/")

card("pc-mastercard", "PC Financial", "PC Mastercard", "CAD", "Mastercard", 0, "pc_optimum", 10, [
        earn(["groceries", "other"], 25, merchants=LOBLAW, note="Loblaw-family stores"),
        earn(["drugstore"], 25, merchants=["shoppers drug mart", "pharmaprix"], note="Shoppers Drug Mart"),
    ], style=("#C8102E", "#6A0716"), match=["pc mastercard", "president's choice mastercard"],
    source="https://www.pcfinancial.ca/en/credit-cards/pc-mastercard/")

CT = ["canadian tire", "sport chek", "mark's", "party city", "atmosphere", "gas+"]
card("triangle-world-elite", "Canadian Tire Bank", "Triangle World Elite Mastercard", "CAD", "Mastercard", 0, "ct_money", 1, [
        earn(["other", "gas", "entertainment"], 4, merchants=CT, note="Canadian Tire and partners"),
        earn(["groceries"], 3, cap=12000, per="annual", note="Groceries; $12k/yr"),
    ], style=("#D71920", "#7A0B0F"), match=["triangle world elite"],
    source="https://triangle.canadiantire.ca/en/credit-cards.html")

card("triangle-mc", "Canadian Tire Bank", "Triangle Mastercard", "CAD", "Mastercard", 0, "ct_money", 0.5, [
        earn(["other", "gas", "entertainment"], 4, merchants=CT, note="Canadian Tire and partners"),
        earn(["groceries"], 1.5, cap=12000, per="annual"),
    ], style=("#E4413F", "#8E1A18"), match=["triangle mastercard"],
    source="https://triangle.canadiantire.ca/en/credit-cards/triangle-mastercard.html")

card("mbna-rewards-we", "MBNA", "Rewards World Elite Mastercard", "CAD", "Mastercard", 120, "mbna", 1, [
        earn(["dining", "groceries", "streaming"], 5, cap=50000, per="annual", note="Restaurants, groceries, digital media, memberships, utilities"),
    ], style=("#0D3B66", "#05192E"), match=["mbna rewards world elite"],
    source="https://www.mbna.ca/en/credit-cards/rewards/rewards-world-elite-mastercard")

card("tangerine-money-back", "Tangerine", "Money-Back Mastercard", "CAD", "Mastercard", 0, "cash_ca", 0.5, [
        earn(["dining", "groceries", "gas", "transit", "streaming", "drugstore", "entertainment", "hotels", "other"], 2, restricted=True,
             note="2% in 2 categories you choose (3 with a Tangerine savings deposit)"),
    ], style=("#F28C28", "#A65310"), match=["money-back", "money back"],
    source="https://www.tangerine.ca/en/products/spending/creditcard/money-back")

card("tangerine-rewards-we", "Tangerine", "Rewards World Elite Mastercard", "CAD", "Mastercard", 120, "scene", 1, [
        earn(["dining", "groceries", "gas", "transit", "streaming", "drugstore", "entertainment", "hotels", "other"], 1.5, restricted=True,
             note="1.5x in 3 categories you choose"),
    ], style=("#E0702A", "#8A3A0C"), match=["tangerine rewards world elite", "tangerine world elite"],
    source="https://www.tangerine.ca/en/personal/spend/credit-cards/world-elite-mastercard")

card("simplii-cash-back", "Simplii Financial", "Cash Back Visa", "CAD", "Visa", 0, "cash_ca", 0.5, [
        earn(["dining"], 4, cap=5000, per="annual", note="Restaurants, bars and coffee shops; $5k/yr"),
        earn(["gas", "groceries", "drugstore"], 1.5, cap=15000, per="annual"),
    ], style=("#E0218A", "#7A0C48"), match=["simplii"], source="https://www.simplii.com/en/credit-cards/cash-back-visa.html")

card("nbc-world-elite", "National Bank", "World Elite Mastercard", "CAD", "Mastercard", 150, "nbc", 1, [
        earn(["groceries", "dining"], 5, cap=2500, per="monthly", note="Groceries and restaurants; tiered caps — verify"),
        earn(["gas", "streaming"], 2, note="Gas, EV charging and recurring bills"),
    ], style=("#C8102E", "#5C0613"), match=["national bank world elite", "world elite mastercard"],
    source="https://www.nbc.ca/personal/mastercard-credit-cards/world-elite.html")

card("bmo-ascend-we", "BMO", "Ascend World Elite Mastercard", "CAD", "Mastercard", 150, "bmo", 1, [
        earn(["flights", "hotels", "transit"], 5, note="Travel"),
        earn(["dining", "entertainment", "streaming"], 3, note="Dining, entertainment, recurring bills"),
    ], style=("#0F2B52", "#050F1F"), match=["ascend"], source="https://www.bmo.com/en-ca/main/personal/credit-cards/bmo-ascend-world-elite-mastercard/")

# Existing wallet mappings keep the same ID after BMO's program conversion.
card("bmo-airmiles-we", "BMO", "Blue Rewards World Elite Mastercard", "CAD", "Mastercard", 150, "bmo_blue", 1, [
        earn(["groceries", "gas"], 2, note="Eligible grocery, gas, EV charging, wholesale and alcohol purchases"),
    ], style=("#00539B", "#002448"), match=["blue rewards world elite", "air miles world elite", "air miles"],
    source="https://www.bmo.com/en-ca/main/personal/credit-cards/bmo-blue-rewards-world-elite-mastercard/",
    notes="AIR MILES converted to Blue Rewards on June 2, 2026. The public fee is $150. Confirm your renewal fee with BMO. Up to 10× at eligible partners and through Blue Rewards Travel; the app estimates those purchases at tracked category rates.")

card("rbc-avion-platinum", "RBC", "Avion Visa Platinum", "CAD", "Visa", 120, "avion", 1, [], style=("#4E6A9E", "#22355A"),
     match=["avion visa platinum"], source="https://www.rbcroyalbank.com/credit-cards/travel/rbc-visa-platinum-avion.html")

card("rbc-cash-back", "RBC", "Cash Back Mastercard", "CAD", "Mastercard", 0, "cash_ca", 0.5, [
        earn(["groceries"], 2, cap=6000, per="annual", note="Groceries; tiered — verify"),
    ], style=("#2F5DA8", "#122D5C"), match=["rbc cash back"], source="https://www.rbcroyalbank.com/credit-cards/cash-back/rbc-cashback-mastercard.html")

card("scotia-momentum-vi", "Scotiabank", "Momentum Visa Infinite+", "CAD", "Visa", 120, "cash_ca", 1, [
        earn(["groceries", "streaming"], 4, cap=25000, per="annual", note="Groceries and recurring bills; $25k/yr"),
        earn(["gas", "transit"], 2, cap=25000, per="annual"),
    ], style=("#5A1F2C", "#24080F"), match=["momentum visa infinite", "momentum"],
    source="https://www.scotiabank.com/ca/en/personal/credit-cards/visa/momentum-infinite-card.html")

card("scotia-scene-visa", "Scotiabank", "Scene+ Visa", "CAD", "Visa", 0, "scene", 1, [
        earn(["groceries", "entertainment"], 2, merchants=["sobeys", "safeway", "iga", "foodland", "freshco", "cineplex"],
             note="Sobeys-family grocers and Cineplex"),
    ], style=("#1A1A1A", "#000000"), match=["scene+ visa", "scene visa"],
    source="https://www.scotiabank.com/ca/en/personal/loans-lines/help-me-choose-payments/Scene-Visa.html")

card("td-rewards-visa", "TD", "Rewards Visa", "CAD", "Visa", 0, "td", 1, [
        earn(["flights", "hotels"], 4, restricted=True, note="Booked through Expedia for TD"),
        earn(["groceries", "dining", "streaming"], 3, note="Groceries, dining, recurring bills"),
    ], style=("#3E8A4A", "#1A4A22"), match=["td rewards visa"], source="https://www.td.com/ca/en/personal-banking/products/credit-cards/travel-rewards/rewards-visa-card")

card("home-trust-preferred", "Home Trust", "Preferred Visa", "CAD", "Visa", 0, "cash_ca", 1, [], ftf=0,
     perks=["No foreign transaction fee"], style=("#4A6E8C", "#203646"), match=["home trust"],
     source="https://www.hometrust.ca/credit-cards/preferred-visa-card/",
     notes="Cash back applies to eligible Canadian-dollar purchases. Foreign-currency purchases carry no FX fee.")

# ================================================================= additional U.S. cards

UNITED_MERCHANTS = ["united", "united.com"]
AMERICAN_AIRLINES = ["american airlines", "aa.com"]
IHG_HOTELS = ["ihg", "holiday inn", "intercontinental", "crowne plaza", "kimpton", "staybridge", "candlewood",
              "hotel indigo", "six senses", "voco", "avid hotels", "even hotels"]

card("chase-united-gateway", "Chase", "United Gateway", "USD", "Visa", 0, "united", 1, [
        earn(["flights"], 2, merchants=UNITED_MERCHANTS, note="Eligible United purchases"),
        earn(["gas", "transit"], 2, note="Gas stations and local transit or commuting"),
    ], ftf=0, perks=["25% back on eligible United inflight and Club purchases",
                     "Two checked-bag awards after $10,000 in calendar-year spend"],
    style=("#496985", "#1F334B"), match=["united gateway", "gateway card"],
    source="https://creditcards.chase.com/travel-credit-cards/united/united-gateway")

card("chase-united-quest", "Chase", "United Quest", "USD", "Visa", 350, "united", 1, [
        earn(["flights"], 4, merchants=UNITED_MERCHANTS, note="Card miles on eligible United purchases"),
        earn(["hotels"], 5, restricted=True, note="Prepaid through Renowned Hotels and Resorts for United cardholders"),
        earn(TRAVEL + ["dining", "streaming"], 2, note="Other travel, dining and select streaming services"),
    ], ftf=0, perks=["$200 annual United travel benefit", "Annual 10,000-mile award flight discount after first anniversary",
                     "First and second standard checked bags free on eligible United itineraries"],
    style=("#384365", "#202039"), match=["united quest", "quest card"],
    source="https://creditcards.chase.com/travel-credit-cards/united/united-quest",
    notes="The $200 benefit goes to United TravelBank. The app estimates credit-card miles separately from miles United awards for flying.")

card("chase-united-club", "Chase", "United Club", "USD", "Visa", 695, "united", 1, [
        earn(["flights"], 5, merchants=UNITED_MERCHANTS, note="Card miles on eligible United purchases"),
        earn(["hotels"], 5, restricted=True, note="Prepaid through Renowned Hotels and Resorts for United cardholders"),
        earn(TRAVEL + ["dining"], 2, note="Other travel and dining"),
    ], ftf=0, perks=["United Club membership", "First and second standard checked bags free on eligible United itineraries",
                     "Premier Access travel services"],
    style=("#253B61", "#0A122B"), match=["united club", "club infinite"],
    source="https://creditcards.chase.com/travel-credit-cards/united/club-infinite",
    notes="Rates shown are miles earned by paying with the card. United also awards miles for eligible flights.")

card("chase-marriott-bold", "Chase", "Marriott Bonvoy Bold", "USD", "Visa", 0, "marriott", 1, [
        earn(["hotels"], 3, merchants=MARRIOTT, note="Participating Marriott Bonvoy hotels"),
        earn(["groceries", "streaming"], 2, note="Grocery stores and eligible digital and communications services"),
        earn(["transit", "dining"], 2, restricted=True, note="Rideshare and select food delivery"),
    ], ftf=0, perks=["Marriott Bonvoy Silver Elite", "5 annual elite night credits"],
    style=("#625D54", "#3A342F"), match=["bonvoy bold", "marriott bold"],
    source="https://creditcards.chase.com/travel-credit-cards/marriott-bonvoy/bold")

card("chase-ihg-traveler", "Chase", "IHG One Rewards Traveler", "USD", "Mastercard", 0, "ihg", 2, [
        earn(["hotels"], 5, merchants=IHG_HOTELS, note="Participating IHG hotels"),
        earn(["dining", "gas", "streaming"], 3, note="Dining, gas, select streaming and eligible utilities"),
    ], ftf=0, perks=["IHG One Rewards Silver Elite", "Fourth night free on eligible award stays"],
    style=("#43857D", "#204F49"), match=["ihg one rewards traveler", "ihg traveler", "rewards traveler"],
    source="https://creditcards.chase.com/travel-credit-cards/ihg-rewards-club/traveler")

card("chase-southwest-premier", "Chase", "Southwest Rapid Rewards Premier", "USD", "Visa", 149, "southwest", 1, [
        earn(["flights"], 3, merchants=["southwest"], note="Eligible Southwest Airlines purchases"),
        earn(["groceries", "dining"], 2, restricted=True, note="First $8,000 combined per account anniversary year"),
    ], ftf=0, perks=["6,000 anniversary points", "First checked bag free on eligible Southwest itineraries",
                     "15% anniversary flight discount code on eligible fares"],
    style=("#4557AC", "#242E72"), match=["rapid rewards premier", "southwest premier"],
    source="https://creditcards.chase.com/travel-credit-cards/southwest/premier")

card("chase-amazon-visa", "Chase", "Amazon Visa", "USD", "Visa", 0, "cash_us", 1, [
        earn(["groceries", "other", "streaming"], 3, merchants=["amazon", "amzn", "audible", "whole foods"],
             note="Eligible Amazon.com, Audible and Whole Foods purchases"),
        earn(["flights", "hotels"], 3, restricted=True, note="Chase Travel bookings"),
        earn(["dining", "gas", "transit"], 2),
    ], ftf=0, style=("#49535D", "#202D38"), match=["amazon visa", "amazon rewards visa"],
    source="https://creditcards.chase.com/cash-back-credit-cards/amazon-rewards",
    notes="This profile uses the standard Amazon Visa rewards schedule. Select Prime Visa for the eligible Prime rate.")

card("chase-sapphire-reserve-business", "Chase", "Sapphire Reserve for Business", "USD", "Visa", 795, "ur", 1, [
        earn(TRAVEL, 8, restricted=True, note="Chase Travel bookings"),
        earn(["flights", "hotels"], 4, restricted=True, note="Flights and hotels booked directly"),
        earn(["other"], 3, restricted=True, note="Eligible search engine and social media advertising; account-year cap applies"),
    ], ftf=0, segment="business", credits=[
        credit("csr-business-travel", "Annual travel credit", 300, "cardmemberYear", "TRAVEL CREDIT", categories=TRAVEL,
               notes="Up to $300 in eligible travel purchases each account anniversary year."),
    ], perks=["Chase Sapphire Lounge and Priority Pass access", "Up to $500 in annual The Edit credits on eligible bookings"],
    style=("#343E53", "#131824"), match=["sapphire reserve for business", "sapphire reserve business"],
    source="https://creditcards.chase.com/business-credit-cards/sapphire/reserve")

card("amex-blue-business-cash", "American Express", "Blue Business Cash", "USD", "Amex", 0, "cash_us", 1, [
        earn(sorted(CATEGORIES), 2, cap=50000, per="annual", note="First $50,000 in eligible purchases per calendar year"),
    ], ftf=0.027, segment="business", style=("#3E789B", "#24455D"), match=["blue business cash"],
    source="https://www.americanexpress.com/us/credit-cards/business/business-credit-cards/blue-business-cash/")

card("amex-delta-blue", "American Express", "Delta SkyMiles Blue", "USD", "Amex", 0, "delta", 1, [
        earn(["flights"], 2, merchants=["delta"], note="Eligible Delta purchases"),
        earn(["dining"], 2, note="Restaurants worldwide and eligible U.S. takeout and delivery"),
    ], ftf=0, perks=["20% back on eligible Delta inflight purchases"], style=("#486F9C", "#234269"),
    match=["skymiles blue", "delta blue"],
    source="https://www.americanexpress.com/us/credit-cards/card/delta-skymiles-blue-american-express-card/")

card("amex-marriott-business-us", "American Express", "Marriott Bonvoy Business", "USD", "Amex", 125, "marriott", 2, [
        earn(["hotels"], 6, merchants=MARRIOTT, note="Participating Marriott Bonvoy hotels"),
        earn(["dining"], 4, note="Restaurants worldwide"),
        earn(["gas"], 4, restricted=True, note="Eligible U.S. gas stations; wireless service and shipping also earn 4× under issuer terms"),
    ], ftf=0, segment="business", perks=["Marriott Bonvoy Gold Elite", "Annual 35,000-point free night award after renewal"],
    style=("#6C4D54", "#39242D"), match=["marriott bonvoy business", "bonvoy business"],
    source="https://www.americanexpress.com/us/credit-cards/business/business-credit-cards/amex-marriott-bonvoy-business-credit-card/")

card("capone-venture-x-business", "Capital One", "Venture X Business", "USD", "Mastercard", 395, "c1", 2, [
        earn(["hotels"], 10, restricted=True, note="Eligible hotels and rental cars booked through Capital One Business Travel"),
        earn(["flights"], 5, restricted=True, note="Eligible flights and vacation rentals through Capital One Business Travel"),
    ], ftf=0, segment="business", perks=["$300 annual Capital One Business Travel credit", "10,000 anniversary miles"],
    style=("#2D4654", "#112B34"), match=["venture x business", "venture x biz"],
    source="https://www.capitalone.com/small-business/credit-cards/venture-x-business/")

card("capone-spark-cash-plus", "Capital One", "Spark Cash Plus", "USD", "Mastercard", 150, "cash_us", 2, [
        earn(["hotels"], 5, restricted=True, note="Hotels and rental cars booked through Capital One Business Travel"),
    ], ftf=0, segment="business", perks=["Annual fee refund after $150,000 in annual spend"],
    style=("#385B50", "#203D35"), match=["spark cash plus", "spark 2% cash plus"],
    source="https://www.capitalone.com/small-business/credit-cards/spark-cash-plus/")

card("citi-strata", "Citi", "Strata Card", "USD", "Mastercard", 0, "ty", 1, [
        earn(["hotels"], 5, restricted=True, note="Eligible hotels, rental cars and attractions booked through Citi Travel"),
        earn(["groceries", "gas", "transit"], 3, note="Supermarkets, gas and EV charging, and select transit"),
        earn(["dining"], 2, note="Restaurants"),
        earn(["streaming", "entertainment"], 3, restricted=True, note="Select streaming or live entertainment if chosen as your Self-Select Category"),
    ], style=("#3A6A82", "#234353"), match=["strata card", "citi strata"],
    source="https://www.citi.com/credit-cards/citi-strata-credit-card")

card("citi-aadvantage-globe", "Citi", "AAdvantage Globe", "USD", "Mastercard", 350, "aadvantage", 1, [
        earn(["flights"], 3, merchants=AMERICAN_AIRLINES, note="Eligible American Airlines purchases"),
        earn(["dining"], 2, note="Restaurants"),
        earn(["transit"], 2, restricted=True, note="Eligible rideshare and rail purchases"),
        earn(["hotels"], 6, restricted=True, note="Eligible AAdvantage Hotels bookings"),
    ], ftf=0, perks=["Four annual Admirals Club Globe passes", "Up to $100 annual Splurge statement credit with an activated merchant"],
    style=("#5F5A7F", "#312E54"), match=["aadvantage globe", "globe mastercard"],
    source="https://www.citi.com/credit-cards/travel-reward-credit-cards",
    notes="The Splurge credit requires merchant activation. Eligible Rides and Rails purchases earn 2× miles.")

card("citi-aadvantage-executive", "Citi", "AAdvantage Executive World Legend Mastercard", "USD", "Mastercard", 695, "aadvantage", 1, [
        earn(["flights"], 4, merchants=AMERICAN_AIRLINES, note="Eligible American Airlines purchases; 5× after $150,000 in yearly account spend"),
        earn(["hotels"], 10, restricted=True, note="Eligible AAdvantage Hotels and AAdvantage Cars bookings"),
    ], ftf=0, perks=["Admirals Club membership", "First checked bag free on eligible domestic American Airlines itineraries"],
    style=("#41434C", "#20252C"), match=["aadvantage executive", "executive world legend"],
    source="https://www.citi.com/credit-cards/citi-aadvantage-executive-world-legend-mastercard")

card("wf-autograph-journey", "Wells Fargo", "Autograph Journey", "USD", "Visa", 95, "wells_fargo", 1, [
        earn(["hotels"], 5, note="Hotels"),
        earn(["flights"], 4, note="Airlines and air carriers"),
        earn(["dining", "transit"], 3, note="Restaurants and eligible other travel"),
    ], ftf=0, perks=["$50 airline statement credit after a qualifying airline purchase of at least $50"],
    style=("#7D405D", "#451A31"), match=["autograph journey"],
    source="https://creditcards.wellsfargo.com/autograph-journey-visa-credit-card/",
    notes="After the first year, the airline credit period starts on the first day of the month after the annual fee is assessed.")

card("usbank-smartly", "U.S. Bank", "Bank Smartly Visa Signature", "USD", "Visa", 0, "cash_us", 2, [],
     style=("#325E72", "#193844"), match=["bank smartly", "smartly visa"],
     source="https://www.usbank.com/credit-cards/bank-smartly-visa-signature-credit-card.html",
     notes="The 2% base rate applies without relationship bonuses. Higher rates depend on qualifying U.S. Bank balances and spending limits.")

# ================================================================= additional Canadian cards

PORTER = ["porter airlines", "flyporter", "porter air"]
SCENE_GROCERS = ["sobeys", "safeway", "iga", "foodland", "freshco", "thrifty foods", "voilà", "voila"]

card("bmo-viporter", "BMO", "VIPorter Mastercard", "CAD", "Mastercard", 89, "viporter", 0.5, [
        earn(["flights"], 2, 10000, "annual", merchants=PORTER, note="Eligible purchases made directly with Porter"),
        earn(["gas", "transit"], 1, 3000, "annual", note="Gas and transportation combined"),
        earn(["dining", "groceries"], 1, 5000, "annual", note="Dining and grocery purchases combined"),
        earn(["hotels"], 1, 3000, "annual"),
    ], perks=["35% annual Porter discount voucher after meeting the spend requirement"],
    style=("#44798B", "#223D50"), match=["viporter mastercard", "viporter world mastercard"],
    source="https://www.bmo.com/en-ca/main/personal/credit-cards/bmo-viporter-mastercard/")

card("bmo-viporter-world-elite", "BMO", "VIPorter World Elite Mastercard", "CAD", "Mastercard", 199, "viporter", 1, [
        earn(["flights"], 3, 20000, "annual", merchants=PORTER, note="Eligible purchases made directly with Porter"),
        earn(["gas", "transit"], 2, 5000, "annual", note="Gas and transportation combined"),
        earn(["dining", "groceries"], 2, 10000, "annual", note="Dining and grocery purchases combined"),
        earn(["hotels"], 2, 5000, "annual"),
    ], perks=["First checked bag free on eligible Porter itineraries", "Priority travel services on eligible Porter itineraries"],
    style=("#2B566A", "#172C42"), match=["viporter world elite", "porter world elite"],
    source="https://www.bmo.com/en-ca/main/personal/credit-cards/bmo-viporter-world-elite-mastercard/")

card("bmo-eclipse-vip", "BMO", "eclipse Visa Infinite Privilege", "CAD", "Visa", 599, "bmo", 1, [
        earn(["flights", "hotels", "gas", "groceries", "dining", "drugstore"], 5, 100000, "annual",
             note="Eligible travel, gas, groceries, health and wellness, and dining. Shared annual limit."),
    ], ftf=0, perks=["$200 annual travel credit", "10 complimentary annual airport lounge visits"],
    style=("#34364B", "#141521"), match=["eclipse visa infinite privilege", "eclipse privilege"],
    source="https://www.bmo.com/en-ca/main/personal/credit-cards/bmo-eclipse-visa-infinite-privilege/",
    notes="The November 2026 refresh added the travel credit and removed foreign transaction fees. An eligible additional cardholder can increase the earn rate by 25%.")

card("rbc-avion-vip", "RBC", "Avion Visa Infinite Privilege", "CAD", "Visa", 399, "avion", 1.25, [],
     perks=["Visa Airport Companion lounge membership and eligible complimentary visits"],
     style=("#4B5679", "#242C45"), match=["avion visa infinite privilege", "avion infinite privilege"],
     source="https://www.rbcroyalbank.com/credit-cards/travel/rbc-avion-visa-infinite-privilege-t.html")

card("rbc-ion", "RBC", "ION Visa", "CAD", "Visa", 0, "rbc_ion", 1, [
        earn(["gas", "groceries", "streaming"], 1.5, note="Eligible gas and EV charging, groceries, streaming and digital gaming"),
        earn(["transit"], 1.5, merchants=["uber", "lyft"], note="Eligible rideshare purchases"),
    ], style=("#6B8CB2", "#304F76"), match=["ion visa", "rbc ion card"],
    source="https://www.rbcroyalbank.com/credit-cards/rewards/rbc-ion-visa.html")

card("rbc-westjet-mc", "RBC", "WestJet RBC Mastercard", "CAD", "Mastercard", 39, "westjet", 1, [
        earn(["flights"], 1.5, merchants=["westjet", "sunwing"], note="Eligible WestJet and Sunwing purchases"),
        earn(["dining", "streaming"], 1.5, note="Eligible dining, food delivery, digital subscriptions and games"),
    ], perks=["Annual companion voucher after meeting the spend requirement"],
    style=("#347F89", "#20545D"), match=["westjet rbc mastercard", "westjet mastercard"],
    source="https://www.rbcroyalbank.com/credit-cards/travel/westjet-rbc-mastercard.html")

card("rbc-british-airways", "RBC", "British Airways Visa Infinite", "CAD", "Visa", 165, "ba_avios", 1, [
        earn(["flights"], 3, merchants=["british airways", "ba.com"], note="Eligible British Airways purchases"),
        earn(["dining"], 2, note="Eligible dining and food delivery"),
    ], perks=["10% off eligible British Airways flights", "Companion Voucher after $30,000 in eligible annual spend"],
    style=("#40547A", "#1C2B4D"), match=["british airways visa", "rbc british airways"],
    source="https://www.rbcroyalbank.com/credit-cards/travel/rbc-british-airways-visa-infinite.html")

card("cibc-dividend-visa", "CIBC", "Dividend Visa", "CAD", "Visa", 0, "cash_ca", 0.5, [
        earn(["groceries"], 2, restricted=True, note="Eligible grocery stores and supermarkets. Subject to shared spending limits."),
        earn(["gas", "transit", "dining", "streaming"], 1, restricted=True,
             note="Eligible gas, EV charging, transportation, dining and recurring payments. Subject to shared spending limits."),
        earn(["flights", "hotels"], 1, restricted=True, note="CIBC by Expedia bookings"),
    ], style=("#A64956", "#662632"), match=["dividend visa"],
    source="https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/dividend-visa-card.html",
    notes="The app estimates 0.5% by default because the 2% and 1% rates share category and total-account spending limits.")

card("cibc-aventura-visa", "CIBC", "Aventura Visa", "CAD", "Visa", 0, "aventura", 0.5, [
        earn(["gas", "groceries", "drugstore"], 1, note="Eligible gas, EV charging, groceries and drugstores"),
        earn(["flights", "hotels"], 1, restricted=True, note="Travel booked through CIBC Rewards Centre"),
    ], style=("#A84F58", "#68323C"), match=["aventura visa card", "aventura visa"],
    source="https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/aventura-visa-card.html")

card("cibc-aventura-vip", "CIBC", "Aventura Visa Infinite Privilege", "CAD", "Visa", 499, "aventura", 1.25, [
        earn(["dining", "entertainment", "gas", "transit", "groceries"], 2, note="Includes eligible EV charging"),
        earn(["flights", "hotels"], 3, restricted=True, note="Travel booked through CIBC Rewards Centre"),
    ], perks=["$200 annual CIBC Rewards travel credit", "Six annual Visa Airport Companion lounge visits", "Two eligible NEXUS rebates"],
    style=("#662F40", "#281420"), match=["aventura visa infinite privilege", "aventura infinite privilege"],
    source="https://www.cibc.com/en/personal-banking/credit-cards/all-credit-cards/aventura-visa-infinite-privilege-card.html")

card("pc-insiders-we", "PC Financial", "PC Insiders World Elite Mastercard", "CAD", "Mastercard", 120, "pc_optimum", 10, [
        earn(["groceries"], 40, merchants=LOBLAW, note="At eligible Loblaw banner grocery stores"),
        earn(["drugstore"], 35, merchants=["shoppers drug mart", "pharmaprix"], note="Card points at eligible drugstores. PC Optimum members earn separate store points."),
    ], perks=["PC Express Pass subscription for eligible orders"],
    style=("#484948", "#222222"), match=["pc insiders", "insiders world elite"],
    source="https://www.pcfinancial.ca/en/credit-cards/insiders/",
    notes="Fuel earns points per litre at eligible Esso and Mobil stations. Additional partner points depend on the retailer and PC Optimum membership.")

card("tangerine-money-back-world", "Tangerine", "Money-Back World Mastercard", "CAD", "Mastercard", 0, "cash_ca", 0.5, [
        earn(sorted(CATEGORIES), 2, restricted=True, note="Two selected categories, or three with rewards deposited to a Tangerine Savings Account"),
    ], perks=["Mastercard Travel Pass membership", "Mobile device insurance on eligible purchases"],
    style=("#BF671F", "#793609"), match=["money-back world", "money back world"],
    source="https://www.tangerine.ca/en/personal/spend/credit-cards/world-credit-card")

card("mbna-true-line", "MBNA", "True Line Mastercard", "CAD", "Mastercard", 0, "cash_ca", 0, [],
     style=("#486982", "#20394B"), match=["true line mastercard", "trueline mastercard"],
     source="https://www.mbna.ca/en/credit-cards/low-interest/true-line-mastercard",
     notes="Low-interest card with no rewards program.")

card("mbna-rewards-plat", "MBNA", "Rewards Platinum Plus Mastercard", "CAD", "Mastercard", 0, "mbna", 1, [
        earn(["groceries"], 2, 10000, "annual"),
        earn(["dining"], 2, 10000, "annual"),
        earn(["streaming"], 2, 10000, "annual", note="Eligible digital media. Membership and utility purchases have separate limits."),
    ], perks=["Annual 10% birthday points bonus, up to 10,000 points"],
    style=("#47617A", "#25384C"), match=["mbna rewards platinum plus", "rewards platinum plus"],
    source="https://www.mbna.ca/en/credit-cards/rewards/mbna-rewards-mastercard")

card("scotia-amex", "Scotiabank", "Scotiabank American Express Card", "CAD", "Amex", 0, "scene", 1, [
        earn(["groceries"], 3, merchants=SCENE_GROCERS, note="Eligible Scene+ grocery partner stores"),
        earn(["groceries", "dining", "entertainment", "gas", "transit", "streaming"], 2, note="Eligible everyday categories"),
        earn(["hotels"], 4, restricted=True, note="Eligible hotels and car rentals through Scene+ Travel"),
    ], style=("#9F4650", "#5C2437"), match=["scotiabank american express card", "scotiabank amex no fee", "scotiabank american express"],
    source="https://www.scotiabank.com/ca/en/personal/credit-cards/american-express/no-fee-amex-card.html")

card("scotia-passport-vip", "Scotiabank", "Passport Visa Infinite Privilege", "CAD", "Visa", 599, "scene", 1, [
        earn(TRAVEL, 3, note="Eligible travel purchases"),
        earn(["dining", "entertainment"], 2),
        earn(["hotels"], 6, restricted=True, note="Eligible hotels and car rentals through Scene+ Travel"),
    ], ftf=0, perks=["10 complimentary annual Visa Airport Companion lounge visits"],
    style=("#393B47", "#1B1B24"), match=["passport visa infinite privilege", "passport infinite privilege"],
    source="https://www.scotiabank.com/ca/en/personal/credit-cards/visa/passport-infinite-privilege-card.html")

card("scotia-momentum-no-fee", "Scotiabank", "Momentum No-Fee Visa", "CAD", "Visa", 0, "cash_ca", 0.5, [
        earn(["groceries", "drugstore", "gas", "transit", "streaming"], 1, 15000, "cardmemberYear", note="Eligible everyday and recurring purchases"),
    ], style=("#A7535A", "#662B3C"), match=["momentum no-fee visa", "momentum no fee visa"],
    source="https://www.scotiabank.com/ca/en/personal/credit-cards/visa/momentum-no-fee-card.html")

card("rogers-red-world", "Rogers Bank", "Rogers Red World Mastercard", "CAD", "Mastercard", 0, "cash_ca", 1, [
        earn(["streaming", "other"], 5, merchants=ROGERS, restricted=True, note="Eligible Rogers purchases before the annual account-spend limit"),
        earn(sorted(CATEGORIES), 2, restricted=True, note="Qualifying Rogers service or eligible U.S.-dollar purchases. Shared $26,000 account-year spend limit."),
    ], style=("#BA413A", "#732522"), match=["rogers red world mastercard", "rogers world mastercard"],
    source="https://www.rogersbank.com/en/rogers_red_world_mastercard_details/",
    notes="Currently offered as an eligible card upgrade. The new $50 roaming credit begins January 12, 2027.")

card("rogers-red-legend", "Rogers Bank", "Rogers Red World Legend Mastercard", "CAD", "Mastercard", 495, "cash_ca", 1.5, [
        earn(["streaming", "other"], 5, merchants=ROGERS, restricted=True, note="Eligible Rogers purchases"),
        earn(sorted(CATEGORIES), 2, restricted=True, note="Eligible purchases with qualifying Rogers service"),
    ], ftf=0, perks=["$200 eligible Rogers entertainment credit", "Six Plaza Premium lounge passes"],
    style=("#6B353B", "#2B171D"), match=["rogers red world legend", "rogers world legend"],
    source="https://www.rogersbank.com/en/rogers_red_worldlegend_mastercard_details/",
    notes="The new $200 roaming credit begins January 12, 2027.")

card("td-platinum-travel", "TD", "Platinum Travel Visa", "CAD", "Visa", 89, "td", 1.5, [
        earn(["flights", "hotels"], 6, restricted=True, note="Eligible Expedia For TD bookings"),
        earn(["groceries"], 4.5, 15000, "annual"),
        earn(["dining"], 4.5, 15000, "annual"),
        earn(["transit"], 4.5, 15000, "annual", note="Eligible public transit"),
        earn(["streaming"], 3, 15000, "annual", note="Eligible recurring bills, streaming and digital media"),
    ], style=("#50765B", "#2B5135"), match=["td platinum travel", "platinum travel visa"],
    source="https://www.td.com/ca/en/personal-banking/products/credit-cards/travel-rewards/platinum-travel-visa-card")

card("td-cash-back-visa", "TD", "Cash Back Visa", "CAD", "Visa", 0, "cash_ca", 0.5, [
        earn(["groceries"], 1, 5000, "annual"),
        earn(["gas"], 1, 5000, "annual", note="Eligible gas and EV charging"),
        earn(["transit"], 1, 5000, "annual", note="Eligible public transit"),
        earn(["streaming"], 1, 5000, "annual", note="Eligible recurring bills, streaming and digital media"),
    ], style=("#49805B", "#2D5339"), match=["cash back visa", "td cashback visa"],
    source="https://www.td.com/ca/en/personal-banking/products/credit-cards/cash-back/cash-back-visa-card")

# ================================================================= custom products for unlisted cards
card("custom-us", "Other", "Other U.S. card", "USD", "Card", 0, "cash_us", 1, [], style=("#6B7280", "#374151"),
     source="https://www.consumerfinance.gov/consumer-tools/credit-cards/", notes="Generic 1% card for products not in the catalog.")
card("custom-ca", "Other", "Other Canadian card", "CAD", "Card", 0, "cash_ca", 1, [], style=("#6B7280", "#374151"),
     source="https://www.canada.ca/en/financial-consumer-agency/services/credit-cards.html", notes="Generic 1% card for products not in the catalog.")

# ---------------------------------------------------------------- non-statement benefits (unverified; see notes)
EXTRA_BENEFITS = {
    "amex-platinum-us": [
        app_credit("plat-uber-cash", "Uber Cash", 15, "monthly", ["uber"], cap_by_month={12: 35},
                   notes="Loaded to your Uber account each month once the Platinum Card is added in the Uber app "
                         "(USD 35 in December). Unused Uber Cash expires at month end."),
    ],
    "amex-hilton-aspire": [
        free_night("aspire-fnr", "Annual Free Night Reward", label="Standard room at most Hilton hotels",
                   notes="Issued after each card renewal."),
        free_night("aspire-fnr-spend", "Spend Free Night Reward", trigger="spend", spend=30000,
                   label="Standard room at most Hilton hotels", notes="After USD 30,000 in purchases in a calendar year."),
    ],
    "amex-hilton-surpass": [
        free_night("surpass-fnr", "Free Night Reward", trigger="spend", spend=15000,
                   label="Standard room at most Hilton hotels", notes="After USD 15,000 in purchases in a calendar year."),
    ],
    "amex-marriott-brilliant": [
        free_night("brilliant-fna", "Free Night Award", points=85000, notes="Issued after each card renewal.", lag=12),
    ],
    "amex-marriott-bevy": [
        free_night("bevy-fna", "Free Night Award", trigger="spend", spend=15000, points=50000,
                   notes="After USD 15,000 in purchases in a calendar year.", lag=12),
    ],
    "chase-marriott-boundless": [free_night("boundless-fna", "Free Night Award", points=35000, lag=12)],
    "amex-marriott-business-us": [free_night("marriott-biz-fna", "Free Night Award", points=35000, lag=12)],
    "amex-marriott-ca": [free_night("marriott-ca-fna", "Free Night Award", points=35000, lag=12)],
    "amex-marriott-business-ca": [free_night("marriott-biz-ca-fna", "Free Night Award", points=35000, lag=12)],
    "chase-ihg-premier": [free_night("ihg-premier-fn", "Anniversary Free Night", points=40000)],
    "chase-world-of-hyatt": [free_night("hyatt-fn", "Anniversary Free Night", label="Category 1–4 Hyatt hotel")],
    "chase-sapphire-reserve": [
        membership("csr-dashpass", "DashPass membership", 120, notes="Complimentary DashPass; activate with the card in DoorDash."),
        app_credit("csr-doordash", "DoorDash promos", 25, "monthly", ["doordash"],
                   notes="Monthly DashPass promos applied at DoorDash checkout; they don't post as statement credits."),
        app_credit("csr-lyft", "Lyft in-app credit", 10, "monthly", ["lyft"],
                   notes="Monthly Lyft credit applied in the Lyft app."),
    ],
    "chase-sapphire-preferred": [
        membership("csp-dashpass", "DashPass membership", 120, notes="Complimentary DashPass; activate with the card in DoorDash."),
    ],
}
for p in products:
    extra = EXTRA_BENEFITS.pop(p["id"], [])
    p["benefits"].extend(extra)
    if any(b["redeem"] == "certificate" for b in extra):
        # The certificate is now tracked as a benefit; drop the duplicate perk line.
        p["perks"] = [x for x in p["perks"] if "free night" not in x.lower()]
if EXTRA_BENEFITS:
    print("catalog error: unknown products in EXTRA_BENEFITS:", list(EXTRA_BENEFITS), file=sys.stderr); sys.exit(1)

# ---------------------------------------------------------------- validation
def fail(msg):
    print("catalog error:", msg, file=sys.stderr); sys.exit(1)

prog_ids = {p[0]: p[4] for p in programs}
seen, benefit_ids, art_codes = set(), set(), set()
for p in products:
    if p["id"] in seen: fail(f"duplicate product {p['id']}")
    seen.add(p["id"])
    code = p["artCode"]
    if not 2 <= len(code) <= 4 or set(code) - set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+"):
        fail(f"{p['id']}: invalid card art code {code}")
    if code in art_codes: fail(f"duplicate card art code {code}")
    art_codes.add(code)
    if p["market"] not in ("USD", "CAD"): fail(f"{p['id']}: market")
    if p["program"] not in prog_ids: fail(f"{p['id']}: unknown program {p['program']}")
    if prog_ids[p["program"]] != p["market"]: fail(f"{p['id']}: program currency differs from market")
    if not p["source"].startswith("https://"): fail(f"{p['id']}: source must be https")
    if p["segment"] not in ("personal", "business"): fail(f"{p['id']}: segment")
    if p["base"] < 0: fail(f"{p['id']}: negative base")
    for r in p["earn"]:
        if not r["categories"] or not set(r["categories"]) <= CATEGORIES: fail(f"{p['id']}: bad earn categories {r['categories']}")
        if r["x"] < p["base"]: fail(f"{p['id']}: bonus {r['x']} below base {p['base']}")
        if "cap" in r and r.get("capPeriod") not in PERIODS: fail(f"{p['id']}: cap without period")
    for b in p["benefits"]:
        if b["id"] in benefit_ids: fail(f"duplicate benefit {b['id']}")
        benefit_ids.add(b["id"])
        if b["period"] not in PERIODS: fail(f"{b['id']}: period")
        if b["redeem"] not in ("statement", "app", "certificate", "membership"): fail(f"{b['id']}: redeem")
        if b["redeem"] == "certificate" and not b.get("certificate"): fail(f"{b['id']}: certificate spec missing")
        if b["redeem"] in ("statement", "app") and not b.get("merchants") and not b.get("categories"):
            fail(f"{b['id']}: needs merchants or categories")
        if set(b.get("categories", [])) - CATEGORIES: fail(f"{b['id']}: categories")
        if b["redeem"] == "statement" and not b["descriptor"].strip(): fail(f"{b['id']}: empty descriptor")

if seen != ART_CODES.keys(): fail("card artwork references an unknown product")

catalog = {
    "version": VERSION,
    "generated": date.today().isoformat(),
    "disclaimer": "Rewards and credits are estimates pending a full terms review. Check the issuer's current terms for your account.",
    "programs": [{"id": i, "name": n, "unit": u, "centsPerPoint": c, "currency": cur} for i, n, u, c, cur in programs],
    "products": products,
}
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    json.dump(catalog, f, indent=1, ensure_ascii=False)
    f.write("\n")
us = sum(p["market"] == "USD" for p in products); ca = len(products) - us
issuers = len({(p["issuer"], p["market"]) for p in products if p["issuer"] != "Other"})
print(f"catalog {VERSION}: {len(products)} products ({us} US, {ca} CA) from {issuers} issuer/market pairs, "
      f"{sum(p['segment']=='business' for p in products)} business, {len(benefit_ids)} credits, {len(programs)} programs -> {os.path.relpath(OUT)}")
