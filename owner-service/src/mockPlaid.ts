import { randomUUID } from 'node:crypto';
import { PlaidError, type LinkTokenRequest, type NormalizedTransaction, type PlaidAdapter, type SyncPage } from './plaid.ts';
import type { LinkedAccount } from './vault.ts';

/**
 * Deterministic stand-in for Plaid used in development and CI (PLAID_ENV=mock).
 * Mirrors /transactions/sync semantics: cursor pagination, pending→posted replacement,
 * removed records and (optionally) a pagination mutation. Synthetic data only.
 */

interface Entry { kind: 'added' | 'modified' | 'removed'; tx: NormalizedTransaction }

const PAGE = 20;

function iso(d: Date): string { return d.toISOString().slice(0, 10); }
/** The bank's local calendar date (Plaid dates are institution-local, not UTC). */
function localDay(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
function dayOf(base: Date, monthOffset: number, day: number): Date {
  return new Date(Date.UTC(base.getUTCFullYear(), base.getUTCMonth() + monthOffset, day));
}

const INSTITUTIONS = {
  US: {
    id: 'ins_mock_amex', name: 'American Express (mock)',
    accounts: [
      { id: 'acc_mock_plat', name: 'Platinum Card', officialName: 'The Platinum Card®', mask: '1008', type: 'credit', subtype: 'credit card', currency: 'USD' },
      { id: 'acc_mock_aspire', name: 'Hilton Honors Aspire', officialName: 'Hilton Honors American Express Aspire Card', mask: '2004', type: 'credit', subtype: 'credit card', currency: 'USD' },
      { id: 'acc_mock_chk', name: 'Rewards Checking', officialName: null, mask: '7781', type: 'depository', subtype: 'checking', currency: 'USD' },
    ] satisfies LinkedAccount[],
  },
  CA: {
    id: 'ins_mock_cibc', name: 'CIBC (mock)',
    accounts: [
      { id: 'acc_mock_aventura', name: 'CIBC Aventura Visa Infinite', officialName: null, mask: '5003', type: 'credit', subtype: 'credit card', currency: 'CAD' },
    ] satisfies LinkedAccount[],
  },
} as const;

class TxBuilder {
  readonly list: NormalizedTransaction[] = [];
  private n = 0;
  private readonly prefix: string;
  private readonly today: string;
  constructor(prefix: string, today: Date) { this.prefix = prefix; this.today = iso(today); }

  add(account: string, amount: number, currency: string, date: Date, name: string, original: string,
      primary: string, detailed: string, opts: { merchant?: string | null; mcc?: string; pending?: boolean } = {}) {
    const d = iso(date);
    if (d > this.today) return;
    this.n += 1;
    this.list.push({
      id: `${this.prefix}_${this.n}`, accountId: account, amountMinor: Math.round(amount * 100), currency, currencyIsOfficial: true,
      date: d, authorizedDate: amount > 0 ? iso(new Date(date.getTime() - 86_400_000)) : null,
      name, merchantName: opts.merchant === undefined ? name : opts.merchant, originalDescription: original,
      categoryPrimary: primary, categoryDetailed: detailed, merchantCategoryCode: opts.mcc ?? null,
      pending: opts.pending ?? false, pendingTransactionId: null,
    });
  }
}

function usHistory(itemKey: string, today: Date): NormalizedTransaction[] {
  const b = new TxBuilder(itemKey, today);
  const m = (o: number, d: number) => dayOf(today, o, d);
  const P = 'acc_mock_plat', A = 'acc_mock_aspire';
  const ENT = ['ENTERTAINMENT', 'ENTERTAINMENT_TV_AND_MOVIES'] as const;
  const CREDIT = ['INCOME', 'INCOME_OTHER_INCOME'] as const;
  for (const k of [-4, -3, -2, -1]) {
    b.add(P, 13.99, 'USD', m(k, 5), 'Disney+', 'DISNEY PLUS BURBANK CA', ...ENT, { mcc: '4899' });
    b.add(P, -13.99, 'USD', m(k, 7), 'Platinum Digital Entertainment Credit', 'PLATINUM DIGITAL ENTERTAINMENT CREDIT', ...CREDIT, { merchant: null });
  }
  b.add(P, 642.30, 'USD', m(-2, 9), 'Delta Air Lines', 'DELTA AIR LINES ATLANTA GA', 'TRAVEL', 'TRAVEL_FLIGHTS', { mcc: '3058' });
  b.add(P, 129.99, 'USD', m(-1, 4), 'Amazon', 'AMZN MKTP US*2K4', 'GENERAL_MERCHANDISE', 'GENERAL_MERCHANDISE_ONLINE_MARKETPLACES', { mcc: '5942' });
  b.add(P, -129.99, 'USD', m(-1, 11), 'Amazon', 'AMZN MKTP US RETURN', 'GENERAL_MERCHANDISE', 'GENERAL_MERCHANDISE_ONLINE_MARKETPLACES', { mcc: '5942' });
  b.add(P, 895, 'USD', m(-2, 1), 'Annual Membership Fee', 'ANNUAL MEMBERSHIP FEE', 'BANK_FEES', 'BANK_FEES_OTHER_BANK_FEES', { merchant: null });
  b.add(P, -1500, 'USD', m(-1, 25), 'Payment Received - Thank You', 'AUTOPAY PAYMENT RECEIVED - THANK YOU', 'LOAN_PAYMENTS', 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT', { merchant: null });
  b.add(P, 41.20, 'USD', m(0, 3), 'Uber', 'UBER *TRIP HELP.UBER.COM', 'TRANSPORTATION', 'TRANSPORTATION_TAXIS_AND_RIDE_SHARES', { mcc: '4121' });

  const qStart = new Date(Date.UTC(today.getUTCFullYear(), Math.floor(today.getUTCMonth() / 3) * 3, 1));
  const prevQ = new Date(Date.UTC(qStart.getUTCFullYear(), qStart.getUTCMonth() - 3, 1));
  const plus = (d: Date, n: number) => new Date(d.getTime() + n * 86_400_000);
  b.add(A, 412, 'USD', plus(prevQ, 19), 'Air Canada', 'AIR CANADA 0142233 MONTREAL', 'TRAVEL', 'TRAVEL_FLIGHTS', { mcc: '3009' });
  b.add(A, -50, 'USD', plus(prevQ, 22), 'Hilton Aspire Flight Credit', 'HILTON ASPIRE FLIGHT CREDIT', ...CREDIT, { merchant: null });
  b.add(A, 289.40, 'USD', plus(qStart, 6), 'United Airlines', 'UNITED 0162298811 HOUSTON TX', 'TRAVEL', 'TRAVEL_FLIGHTS', { mcc: '3000' });
  b.add(A, 66.80, 'USD', m(-1, 13), 'Carbone', 'CARBONE NEW YORK NY', 'FOOD_AND_DRINK', 'FOOD_AND_DRINK_RESTAURANT', { mcc: '5812' });
  b.add(A, 310.55, 'USD', m(-2, 17), 'Hilton Chicago', 'HILTON HOTELS CHICAGO IL', 'TRAVEL', 'TRAVEL_LODGING', { mcc: '3504' });
  b.add(A, 550, 'USD', m(-1, 3), 'Annual Membership Fee', 'ANNUAL MEMBERSHIP FEE', 'BANK_FEES', 'BANK_FEES_OTHER_BANK_FEES', { merchant: null });
  // Ensure history always exceeds one page (> 20 items) even on the 1st of a quarter.
  b.add(P, 22.50, 'USD', m(-3, 14), 'Sweetgreen', 'SWEETGREEN NEW YORK NY', 'FOOD_AND_DRINK', 'FOOD_AND_DRINK_RESTAURANT', { mcc: '5812' });
  b.add(P, 54.00, 'USD', m(-2, 18), 'Whole Foods Market', 'WHOLE FOODS MARKET NEW YORK NY', 'FOOD_AND_DRINK', 'FOOD_AND_DRINK_GROCERIES', { mcc: '5411' });
  b.add(A, 18.40, 'USD', m(-3, 21), 'Blue Bottle Coffee', 'BLUE BOTTLE COFFEE', 'FOOD_AND_DRINK', 'FOOD_AND_DRINK_COFFEE', { mcc: '5814' });
  b.add('acc_mock_chk', 3200, 'USD', m(-1, 1), 'Rent', 'ZELLE TO LANDLORD', 'RENT_AND_UTILITIES', 'RENT_AND_UTILITIES_RENT', { merchant: null });
  return b.list.sort((x, y) => x.date.localeCompare(y.date));
}

function caHistory(itemKey: string, today: Date): NormalizedTransaction[] {
  const b = new TxBuilder(itemKey, today);
  const m = (o: number, d: number) => dayOf(today, o, d);
  const V = 'acc_mock_aventura';
  for (const k of [-3, -2, -1, 0]) {
    b.add(V, 71.40, 'CAD', m(k, 4), 'Petro-Canada', 'PETRO-CANADA 4410', 'TRANSPORTATION', 'TRANSPORTATION_GAS', { mcc: '5541' });
    b.add(V, 38.60, 'CAD', m(k, 8), 'Shoppers Drug Mart', 'SHOPPERS DRUG MART #0821', 'MEDICAL', 'MEDICAL_PHARMACIES_AND_SUPPLEMENTS', { mcc: '5912' });
    b.add(V, 112.35, 'CAD', m(k, 12), 'Loblaws', 'LOBLAWS #1042 TORONTO ON', 'FOOD_AND_DRINK', 'FOOD_AND_DRINK_GROCERIES', { mcc: '5411' });
  }
  b.add(V, 642.88, 'CAD', m(-2, 22), 'Air Canada', 'AIR CANADA 0142998 MONTREAL', 'TRAVEL', 'TRAVEL_FLIGHTS', { mcc: '3009' });
  b.add(V, 139, 'CAD', m(-3, 2), 'Annual Fee', 'ANNUAL FEE', 'BANK_FEES', 'BANK_FEES_OTHER_BANK_FEES', { merchant: null });
  b.add(V, -900, 'CAD', m(-1, 28), 'Payment Thank You', 'PAYMENT THANK YOU / PAIEMENT MERCI', 'LOAN_PAYMENTS', 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT', { merchant: null });
  return b.list.sort((x, y) => x.date.localeCompare(y.date));
}

/**
 * Scripted updates, one group revealed per sync once history is delivered:
 * a pending purchase; then (as Plaid does) the pending removal together with the posted record; then its credit.
 */
function scriptedEvents(itemKey: string, country: 'US' | 'CA', today: Date): Entry[][] {
  const d = iso(today);
  const acct = country === 'US' ? 'acc_mock_plat' : 'acc_mock_aventura';
  const cur = country === 'US' ? 'USD' : 'CAD';
  const base: NormalizedTransaction = {
    id: `${itemKey}_p1`, accountId: acct, amountMinor: 1399, currency: cur, currencyIsOfficial: true, date: d, authorizedDate: d,
    name: 'YouTube Premium', merchantName: 'YouTube Premium', originalDescription: 'GOOGLE *YOUTUBEPREMIUM',
    categoryPrimary: 'ENTERTAINMENT', categoryDetailed: 'ENTERTAINMENT_TV_AND_MOVIES', merchantCategoryCode: '4899',
    pending: true, pendingTransactionId: null,
  };
  const posted = { ...base, id: `${itemKey}_y1`, pending: false, pendingTransactionId: base.id };
  const events: Entry[][] = [
    [{ kind: 'added', tx: base }],
    [{ kind: 'added', tx: posted }, { kind: 'removed', tx: base }],
  ];
  if (country === 'US') {
    events.push([{ kind: 'added', tx: {
      ...base, id: `${itemKey}_c1`, amountMinor: -1399, pending: false, authorizedDate: null,
      name: 'Platinum Digital Entertainment Credit', merchantName: null, originalDescription: 'PLATINUM DIGITAL ENTERTAINMENT CREDIT',
      categoryPrimary: 'INCOME', categoryDetailed: 'INCOME_OTHER_INCOME', merchantCategoryCode: null,
    } }]);
  }
  return events;
}

interface MockItem { key: string; country: 'US' | 'CA'; created: Date; revealed: number; mutated: boolean }

export class MockPlaid implements PlaidAdapter {
  private readonly items = new Map<string, MockItem>();
  private readonly mutation: boolean;
  constructor(mutation: boolean) { this.mutation = mutation; }

  async createLinkToken(req: LinkTokenRequest) {
    return { linkToken: `link-mock-${req.country}-${randomUUID()}`, expiration: new Date(Date.now() + 4 * 3600_000).toISOString() };
  }

  async createTestPublicToken(country: 'US' | 'CA') {
    return `public-mock-${country}-${randomUUID()}`;
  }

  async exchangePublicToken(publicToken: string) {
    const m = /^public-mock-(US|CA)-/.exec(publicToken);
    if (!m) throw new PlaidError('INVALID_PUBLIC_TOKEN', false);
    const key = randomUUID().slice(0, 8);
    // Access token encodes country, key and creation day so a service restart can rebuild the fixture.
    return { accessToken: `access-mock-${m[1]}-${key}-${localDay(new Date())}`, itemId: `item-mock-${key}` };
  }

  private item(accessToken: string): MockItem {
    const m = /^access-mock-(US|CA)-([a-z0-9]+)-(\d{4}-\d{2}-\d{2})$/.exec(accessToken);
    if (!m) throw new PlaidError('ITEM_NOT_FOUND', false);
    let it = this.items.get(accessToken);
    if (!it) {
      it = { key: m[2], country: m[1] as 'US' | 'CA', created: new Date(`${m[3]}T00:00:00Z`), revealed: 0, mutated: false };
      this.items.set(accessToken, it);
    }
    return it;
  }

  async getAccounts(accessToken: string, country: 'US' | 'CA') {
    const it = this.item(accessToken);
    const inst = INSTITUTIONS[it.country ?? country];
    return { accounts: inst.accounts.map((a) => ({ ...a })), institutionId: inst.id, institutionName: inst.name };
  }

  async creditCardBills(accessToken: string, accountIds: string[]) {
    const item = this.item(accessToken);
    const today = new Date(`${localDay(new Date())}T00:00:00Z`);
    return INSTITUTIONS[item.country].accounts.filter((account) =>
      account.type === 'credit' && accountIds.includes(account.id),
    ).map((account, index) => {
      const day = 8 + index * 11;
      const thisMonth = dayOf(today, 0, day);
      return { accountId: account.id, dueDate: iso(thisMonth >= today ? thisMonth : dayOf(today, 1, day)) };
    });
  }

  async syncTransactions(accessToken: string, cursor: string | null): Promise<SyncPage> {
    const it = this.item(accessToken);
    const history = (it.country === 'US' ? usHistory : caHistory)(it.key, it.created);
    const events = scriptedEvents(it.key, it.country, it.created);
    const base: Entry[] = history.map((tx) => ({ kind: 'added', tx }));

    let pos = 0;
    if (cursor) {
      const m = /^m1\.(\d+)$/.exec(cursor);
      if (!m) throw new PlaidError('UPSTREAM', false);
      pos = Number(m[1]);
    }
    const logLength = (groups: number) => base.length + events.slice(0, groups).reduce((n, g) => n + g.length, 0);
    // After a service restart, recover how many groups the cursor has already seen.
    while (it.revealed < events.length && logLength(it.revealed) < pos) it.revealed += 1;
    // At the end of the log, the "bank" produces the next scripted update.
    if (pos >= logLength(it.revealed) && it.revealed < events.length) it.revealed += 1;

    if (this.mutation && !it.mutated && pos > 0 && pos < base.length) {
      it.mutated = true;
      throw new PlaidError('TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION', true);
    }

    const log = [...base, ...events.slice(0, it.revealed).flat()];
    const slice = log.slice(pos, pos + PAGE);
    const next = pos + slice.length;
    return {
      added: slice.filter((e) => e.kind === 'added').map((e) => e.tx),
      modified: slice.filter((e) => e.kind === 'modified').map((e) => e.tx),
      removed: slice.filter((e) => e.kind === 'removed').map((e) => e.tx.id),
      nextCursor: `m1.${next}`,
      hasMore: next < log.length,
      historyStatus: 'HISTORICAL_UPDATE_COMPLETE',
    };
  }

  async removeItem(accessToken: string) {
    this.item(accessToken);
    this.items.delete(accessToken);
  }
}
