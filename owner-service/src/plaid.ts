import { Configuration, PlaidApi, PlaidEnvironments, Products, CountryCode } from 'plaid/legacy';
import type { Config } from './config.ts';
import type { LinkedAccount } from './vault.ts';

/** Normalized transaction streamed to the phone. Unused Plaid fields are dropped here (design §8). */
export interface NormalizedTransaction {
  id: string;
  accountId: string;
  /** Signed minor units, Plaid convention: positive = money out of the account. */
  amountMinor: number;
  currency: string | null;
  currencyIsOfficial: boolean;
  date: string;
  authorizedDate: string | null;
  name: string;
  merchantName: string | null;
  originalDescription: string | null;
  categoryPrimary: string | null;
  categoryDetailed: string | null;
  merchantCategoryCode: string | null;
  pending: boolean;
  pendingTransactionId: string | null;
}

export interface SyncPage {
  added: NormalizedTransaction[];
  modified: NormalizedTransaction[];
  removed: string[];
  nextCursor: string;
  hasMore: boolean;
  historyStatus: string;
}

export type PlaidErrorCode =
  | 'ITEM_LOGIN_REQUIRED'
  | 'TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION'
  | 'PRODUCT_NOT_READY'
  | 'RATE_LIMIT_EXCEEDED'
  | 'ITEM_NOT_FOUND'
  | 'INVALID_PUBLIC_TOKEN'
  | 'UPSTREAM';

export class PlaidError extends Error {
  readonly code: PlaidErrorCode;
  readonly retryable: boolean;
  constructor(code: PlaidErrorCode, retryable: boolean) {
    super(code);
    this.code = code;
    this.retryable = retryable;
  }
}

export interface LinkTokenRequest {
  country: 'US' | 'CA';
  accessToken?: string; // update mode
}

export interface PlaidAdapter {
  createLinkToken(req: LinkTokenRequest): Promise<{ linkToken: string; expiration: string }>;
  exchangePublicToken(publicToken: string): Promise<{ accessToken: string; itemId: string }>;
  getAccounts(accessToken: string, country: 'US' | 'CA'): Promise<{ accounts: LinkedAccount[]; institutionId: string | null; institutionName: string | null }>;
  syncTransactions(accessToken: string, cursor: string | null): Promise<SyncPage>;
  removeItem(accessToken: string): Promise<void>;
  /** Sandbox/mock only: create a public token without the Link UI. */
  createTestPublicToken(country: 'US' | 'CA'): Promise<string>;
}

// ---------------------------------------------------------------------------

export function toMinor(amount: number): number {
  return Math.round(amount * 100);
}

/** Maps a Plaid API error to a code without ever logging the request config (which carries the secret). */
function mapError(e: unknown): PlaidError {
  const resp = (e as { response?: { status?: number; data?: { error_code?: string } } }).response;
  const code = resp?.data?.error_code;
  switch (code) {
    case 'ITEM_LOGIN_REQUIRED': return new PlaidError('ITEM_LOGIN_REQUIRED', false);
    case 'TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION': return new PlaidError('TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION', true);
    case 'PRODUCT_NOT_READY': return new PlaidError('PRODUCT_NOT_READY', true);
    case 'RATE_LIMIT_EXCEEDED': case 'TRANSACTIONS_SYNC_LIMIT': return new PlaidError('RATE_LIMIT_EXCEEDED', true);
    case 'ITEM_NOT_FOUND': return new PlaidError('ITEM_NOT_FOUND', false);
    case 'INVALID_PUBLIC_TOKEN': return new PlaidError('INVALID_PUBLIC_TOKEN', false);
    default: {
      const status = resp?.status;
      const retryable = status === undefined || status === 429 || status >= 500;
      console.warn(`plaid error ${code ?? 'network'}`);
      return new PlaidError('UPSTREAM', retryable);
    }
  }
}

interface PlaidTx {
  transaction_id: string; account_id: string; amount: number;
  iso_currency_code: string | null; unofficial_currency_code: string | null;
  date: string; authorized_date: string | null; name: string;
  merchant_name?: string | null; original_description?: string | null;
  personal_finance_category?: { primary: string; detailed: string } | null;
  merchant_category_code?: string | null;
  pending: boolean; pending_transaction_id: string | null;
}

export function normalize(t: PlaidTx): NormalizedTransaction {
  return {
    id: t.transaction_id,
    accountId: t.account_id,
    amountMinor: toMinor(t.amount),
    currency: t.iso_currency_code ?? t.unofficial_currency_code ?? null,
    currencyIsOfficial: t.iso_currency_code != null,
    date: t.date,
    authorizedDate: t.authorized_date ?? null,
    name: t.name,
    merchantName: t.merchant_name ?? null,
    originalDescription: t.original_description ?? null,
    categoryPrimary: t.personal_finance_category?.primary ?? null,
    categoryDetailed: t.personal_finance_category?.detailed ?? null,
    merchantCategoryCode: t.merchant_category_code ?? null,
    pending: t.pending,
    pendingTransactionId: t.pending_transaction_id ?? null,
  };
}

export class RealPlaid implements PlaidAdapter {
  private readonly client: PlaidApi;
  private readonly config: Config;

  constructor(config: Config) {
    this.config = config;
    this.client = new PlaidApi(new Configuration({
      basePath: config.env === 'production' ? PlaidEnvironments.production : PlaidEnvironments.sandbox,
      baseOptions: { headers: { 'PLAID-CLIENT-ID': config.clientId, 'PLAID-SECRET': config.secret, 'Plaid-Version': '2020-09-14' } },
    }));
  }

  async createLinkToken(req: LinkTokenRequest) {
    try {
      const country = req.country === 'CA' ? CountryCode.Ca : CountryCode.Us;
      const { data } = await this.client.linkTokenCreate({
        client_name: 'Card Ledger',
        language: 'en',
        country_codes: [country],
        user: { client_user_id: 'owner' },
        ...(req.accessToken
          ? { access_token: req.accessToken }
          : { products: [Products.Transactions], transactions: { days_requested: 730 } }),
        ...(this.config.redirectUri ? { redirect_uri: this.config.redirectUri } : {}),
      });
      return { linkToken: data.link_token, expiration: data.expiration };
    } catch (e) { throw mapError(e); }
  }

  async exchangePublicToken(publicToken: string) {
    try {
      const { data } = await this.client.itemPublicTokenExchange({ public_token: publicToken });
      return { accessToken: data.access_token, itemId: data.item_id };
    } catch (e) { throw mapError(e); }
  }

  async getAccounts(accessToken: string, country: 'US' | 'CA') {
    try {
      const { data } = await this.client.accountsGet({ access_token: accessToken });
      const institutionId = data.item.institution_id ?? null;
      let institutionName: string | null = null;
      if (institutionId) {
        try {
          const inst = await this.client.institutionsGetById({
            institution_id: institutionId, country_codes: [country === 'CA' ? CountryCode.Ca : CountryCode.Us],
          });
          institutionName = inst.data.institution.name;
        } catch { /* name is cosmetic */ }
      }
      const accounts: LinkedAccount[] = data.accounts.map((a) => ({
        id: a.account_id, name: a.name, officialName: a.official_name ?? null, mask: a.mask ?? null,
        type: String(a.type), subtype: a.subtype ? String(a.subtype) : null,
        currency: a.balances.iso_currency_code ?? a.balances.unofficial_currency_code ?? null,
      }));
      return { accounts, institutionId, institutionName };
    } catch (e) { throw mapError(e); }
  }

  async syncTransactions(accessToken: string, cursor: string | null): Promise<SyncPage> {
    try {
      const { data } = await this.client.transactionsSync({
        access_token: accessToken,
        ...(cursor ? { cursor } : {}),
        count: 250,
        options: { include_original_description: true, days_requested: 730 },
      });
      return {
        added: data.added.map((t) => normalize(t as unknown as PlaidTx)),
        modified: data.modified.map((t) => normalize(t as unknown as PlaidTx)),
        removed: data.removed.map((r) => r.transaction_id).filter((x): x is string => !!x),
        nextCursor: data.next_cursor,
        hasMore: data.has_more,
        historyStatus: String(data.transactions_update_status),
      };
    } catch (e) { throw mapError(e); }
  }

  async removeItem(accessToken: string) {
    try { await this.client.itemRemove({ access_token: accessToken }); }
    catch (e) {
      const err = mapError(e);
      if (err.code === 'ITEM_NOT_FOUND') return; // already removed
      throw err;
    }
  }

  async createTestPublicToken(country: 'US' | 'CA') {
    if (this.config.env !== 'sandbox') throw new Error('Test public tokens are only available in Sandbox');
    try {
      const { data } = await this.client.sandboxPublicTokenCreate({
        // First Platypus Bank (US) / Tartan-Dominion Bank of Canada; dynamic transactions test user.
        institution_id: country === 'CA' ? 'ins_43' : 'ins_109508',
        initial_products: [Products.Transactions],
        options: { override_username: 'user_transactions_dynamic', override_password: 'any' },
      });
      return data.public_token;
    } catch (e) { throw mapError(e); }
  }
}
