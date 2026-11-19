import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { loadConfig, type Config } from './config.ts';
import { RateLimiter } from './auth.ts';
import { Accounts, AuthError, type AccessClaims } from './accounts.ts';
import { MemoryStore, type Store, type ConnectionRecord } from './store.ts';
import { DynamoStore } from './dynamoStore.ts';
import { KmsSealer, LocalSealer, type Sealer } from './sealer.ts';
import { ConsoleMailer, SesMailer } from './mailer.ts';
import { WebhookVerifier, webhookEffect, type PlaidWebhook } from './webhooks.ts';
import { PlaidError, RealPlaid, type PlaidAdapter } from './plaid.ts';
import { MockPlaid } from './mockPlaid.ts';

const config: Config = await loadConfig();
const store: Store = config.store === 'dynamo' ? new DynamoStore(config.tableName, config.awsRegion) : new MemoryStore();
const sealer: Sealer = config.kmsKeyId ? new KmsSealer(config.kmsKeyId, config.awsRegion) : new LocalSealer(config.localSealKey!);
const mailer = config.mailer === 'ses' ? new SesMailer(config.mailFrom, config.awsRegion) : new ConsoleMailer();
const accounts = new Accounts(store, mailer, config.jwtSecret, config.codePepper);
const plaid: PlaidAdapter = config.env === 'mock' ? new MockPlaid(config.mockMutation) : new RealPlaid(config);
const webhooks = new WebhookVerifier((kid) => plaid.webhookVerificationKey(kid));
const webhookUrl = config.publicUrl ? `${config.publicUrl}/v1/plaid/webhook` : undefined;

// Per-instance limits. With several instances behind a load balancer, add a shared limit at the edge (AWS WAF).
const limiters = {
  health: new RateLimiter(60, 60_000),
  authStart: new RateLimiter(10, 15 * 60_000),
  authVerify: new RateLimiter(30, 15 * 60_000),
  refresh: new RateLimiter(60, 15 * 60_000),
  webhook: new RateLimiter(600, 60_000),
  user: new RateLimiter(240, 60_000),
};
/** Per-Item serialization of Plaid calls on this instance (design §7). */
const itemLocks = new Map<string, Promise<unknown>>();

class HttpError extends Error {
  readonly status: number;
  readonly code: string;
  readonly retryable: boolean;
  constructor(status: number, code: string, retryable = false) {
    super(code); this.status = status; this.code = code; this.retryable = retryable;
  }
}

function send(res: ServerResponse, status: number, body: unknown) {
  const json = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Pragma': 'no-cache',
    'X-Content-Type-Options': 'nosniff',
    'Content-Length': Buffer.byteLength(json),
  });
  res.end(json);
}

async function readRaw(req: IncomingMessage, limit = 64 * 1024): Promise<Buffer> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const c of req) {
    size += (c as Buffer).length;
    if (size > limit) throw new HttpError(413, 'body_too_large');
    chunks.push(c as Buffer);
  }
  return Buffer.concat(chunks);
}

function parseJson(raw: Buffer): Record<string, unknown> {
  if (!raw.length) return {};
  try {
    const parsed = JSON.parse(raw.toString('utf8'));
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) throw new HttpError(400, 'invalid_json');
    return parsed as Record<string, unknown>;
  } catch (e) {
    if (e instanceof HttpError) throw e;
    throw new HttpError(400, 'invalid_json');
  }
}

const readJson = async (req: IncomingMessage) => parseJson(await readRaw(req));

function country(v: unknown): 'US' | 'CA' {
  if (v === 'US' || v === 'CA') return v;
  throw new HttpError(400, 'country_must_be_US_or_CA');
}

function publicConnection(c: ConnectionRecord) {
  return {
    connectionId: c.id,
    institution: c.institutionName,
    country: c.country,
    status: c.status,
    accounts: c.accounts,
    lastSuccessfulPull: c.lastSuccessfulPull ?? null,
    updatesAvailable: c.updatesAvailable ?? false,
  };
}

const sealContext = (c: { userId: string; id: string }) => ({ purpose: 'plaid-access-token', userId: c.userId, connectionId: c.id });

async function accessToken(c: ConnectionRecord): Promise<string> {
  if (!c.sealedAccessToken || c.status === 'disconnected') throw new HttpError(410, 'connection_disconnected');
  return sealer.open(c.sealedAccessToken, sealContext(c));
}

async function findConnection(user: AccessClaims, id: string): Promise<ConnectionRecord> {
  const c = await store.getConnection(user.sub, id);
  if (!c) throw new HttpError(404, 'connection_not_found');
  return c;
}

async function withItemLock<T>(itemId: string, fn: () => Promise<T>): Promise<T> {
  const prev = itemLocks.get(itemId) ?? Promise.resolve();
  const next = prev.catch(() => undefined).then(fn);
  itemLocks.set(itemId, next);
  try { return await next; } finally { if (itemLocks.get(itemId) === next) itemLocks.delete(itemId); }
}

async function plaidToHttp(e: unknown, conn?: ConnectionRecord): Promise<never> {
  if (e instanceof PlaidError) {
    if (e.code === 'ITEM_LOGIN_REQUIRED' && conn) {
      await store.updateConnection(conn.userId, conn.id, { status: 'login_required' });
      throw new HttpError(409, 'ITEM_LOGIN_REQUIRED');
    }
    if (e.code === 'RATE_LIMIT_EXCEEDED') throw new HttpError(429, e.code, true);
    if (e.code === 'INVALID_PUBLIC_TOKEN') throw new HttpError(400, e.code);
    if (e.code === 'ITEM_NOT_FOUND') throw new HttpError(410, e.code);
    throw new HttpError(502, e.code, e.retryable);
  }
  throw e;
}

/** Removes the Plaid Item (stopping billing) and then the stored token. */
async function disconnect(conn: ConnectionRecord): Promise<void> {
  if (conn.status === 'disconnected' || !conn.sealedAccessToken) return;
  await withItemLock(conn.itemId, async () => {
    const fresh = await store.getConnection(conn.userId, conn.id);
    if (!fresh || fresh.status === 'disconnected' || !fresh.sealedAccessToken) return;
    await store.updateConnection(fresh.userId, fresh.id, { status: 'disconnect_pending' });
    try {
      await plaid.removeItem(await accessToken(fresh));
    } catch (e) {
      const retryable = !(e instanceof PlaidError) || e.retryable;
      throw new HttpError(503, 'disconnect_retry_required', retryable);
    }
    await store.updateConnection(fresh.userId, fresh.id, { sealedAccessToken: null, status: 'disconnected' });
  });
}

type Ctx = { req: IncomingMessage; params: string[]; user: AccessClaims; ip: string };
type PublicCtx = Omit<Ctx, 'user'>;
type Route = {
  method: string; pattern: RegExp; limiter: keyof typeof limiters;
  handler: (ctx: Ctx) => Promise<[number, unknown]>; authenticated: boolean;
};
const routes: Route[] = [];
function pub(method: string, pattern: RegExp, limiter: keyof typeof limiters, handler: (ctx: PublicCtx) => Promise<[number, unknown]>) {
  routes.push({ method, pattern, limiter, handler: handler as Route['handler'], authenticated: false });
}
function authed(method: string, pattern: RegExp, handler: (ctx: Ctx) => Promise<[number, unknown]>) {
  routes.push({ method, pattern, limiter: 'user', handler, authenticated: true });
}

// --- Public ----------------------------------------------------------------------

pub('GET', /^\/v1\/health$/, 'health', async () => [200, {
  ok: true, service: 'card-ledger-api', apiVersion: 2, environment: config.env, signIn: ['email-code'],
}]);

pub('POST', /^\/v1\/auth\/email\/start$/, 'authStart', async ({ req }) => {
  const body = await readJson(req);
  await accounts.startEmailSignIn(body.email);
  // Same answer whether or not the address has an account.
  return [202, { sent: true, expiresIn: 600 }];
});

pub('POST', /^\/v1\/auth\/email\/verify$/, 'authVerify', async ({ req }) => {
  const body = await readJson(req);
  return [200, await accounts.verifyEmailCode(body.email, body.code, body.deviceName)];
});

pub('POST', /^\/v1\/auth\/refresh$/, 'refresh', async ({ req }) => {
  const body = await readJson(req);
  return [200, await accounts.refresh(body.refreshToken)];
});

pub('POST', /^\/v1\/plaid\/webhook$/, 'webhook', async ({ req }) => {
  const raw = await readRaw(req, 256 * 1024);
  const header = req.headers['plaid-verification'];
  if (!(await webhooks.verify(Array.isArray(header) ? header[0] : header, raw))) throw new HttpError(401, 'webhook_unverified');
  await applyWebhook(parseJson(raw) as PlaidWebhook);
  return [200, { ok: true }];
});

async function applyWebhook(w: PlaidWebhook) {
  if (!w.item_id) return;
  const effect = webhookEffect(w);
  if (effect.kind === 'ignore') return;
  for (const c of await store.findConnectionsByItemId(w.item_id)) {
    if (c.status === 'disconnected') continue;
    if (effect.kind === 'updates_available') await store.updateConnection(c.userId, c.id, { updatesAvailable: true });
    else if (effect.kind === 'login_required') await store.updateConnection(c.userId, c.id, { status: 'login_required' });
    else if (effect.kind === 'repaired') await store.updateConnection(c.userId, c.id, { status: 'active' });
    else if (effect.kind === 'revoked') await store.updateConnection(c.userId, c.id, { status: 'disconnected', sealedAccessToken: null });
  }
}

// --- Account ---------------------------------------------------------------------

authed('GET', /^\/v1\/me$/, async ({ user }) => {
  const u = await store.getUser(user.sub);
  if (!u) throw new HttpError(401, 'unauthorized');
  return [200, { user: { id: u.id, email: u.email } }];
});

authed('POST', /^\/v1\/auth\/sign-out$/, async ({ user }) => {
  await accounts.signOut(user.sid);
  return [200, { ok: true }];
});

/** Deletes the account: removes every Plaid Item first so nothing stays linked or billed. */
authed('DELETE', /^\/v1\/me$/, async ({ user }) => {
  const u = await store.getUser(user.sub);
  if (!u) return [200, { deleted: true }];
  for (const c of await store.listConnections(user.sub)) await disconnect(c);
  await store.deleteUser(user.sub, accounts.emailKey(u.email));
  return [200, { deleted: true }];
});

// --- Bank connections --------------------------------------------------------------

authed('POST', /^\/v1\/link-token$/, async ({ req, user }) => {
  const body = await readJson(req);
  const c = country(body.country);
  const billAccess = body.billAccess === true;
  if (billAccess && !config.billAlerts) throw new HttpError(409, 'bill_alerts_disabled');
  if (billAccess && typeof body.connectionId !== 'string') throw new HttpError(400, 'connection_required');
  let token: string | undefined;
  if (typeof body.connectionId === 'string') token = await accessToken(await findConnection(user, body.connectionId));
  try {
    const t = await plaid.createLinkToken({ country: c, accessToken: token, billAccess, clientUserId: user.sub, webhookUrl });
    return [200, { linkToken: t.linkToken, expiration: t.expiration, environment: config.env }];
  } catch (e) { return plaidToHttp(e); }
});

authed('POST', /^\/v1\/connections$/, async ({ req, user }) => {
  const body = await readJson(req);
  const publicToken = typeof body.publicToken === 'string' ? body.publicToken : '';
  const clientRequestId = typeof body.clientRequestId === 'string' ? body.clientRequestId : '';
  const c = country(body.country);
  if (!publicToken || !/^[A-Za-z0-9-]{8,64}$/.test(clientRequestId)) throw new HttpError(400, 'publicToken_and_clientRequestId_required');

  // Idempotent across instances: the first request to claim this clientRequestId owns the connection.
  const candidate = crypto.randomUUID();
  const owner = await store.claimClientRequest(user.sub, clientRequestId, candidate);
  if (owner !== candidate) {
    for (let i = 0; i < 20; i++) {
      const existing = await store.getConnection(user.sub, owner);
      if (existing) {
        if (existing.accounts.length === 0 && existing.status !== 'disconnected') {
          try {
            const info = await plaid.getAccounts(await accessToken(existing), existing.country);
            const repaired = await store.updateConnection(user.sub, owner, {
              accounts: info.accounts, institutionId: info.institutionId, institutionName: info.institutionName,
            });
            return [200, publicConnection(repaired ?? existing)];
          } catch (e) { return plaidToHttp(e, existing); }
        }
        return [200, publicConnection(existing)];
      }
      await new Promise((r) => setTimeout(r, 250)); // the first request is still exchanging the token
    }
    throw new HttpError(409, 'connection_in_progress', true);
  }

  try {
    const exchanged = await plaid.exchangePublicToken(publicToken);
    const conn: ConnectionRecord = {
      userId: user.sub, id: candidate, itemId: exchanged.itemId,
      sealedAccessToken: await sealer.seal(exchanged.accessToken, sealContext({ userId: user.sub, id: candidate })),
      institutionId: null, institutionName: null, country: c, accounts: [], clientRequestId,
      status: 'active', createdAt: new Date().toISOString(),
    };
    await store.putConnection(conn); // persist the Item token before acknowledging
    const info = await plaid.getAccounts(exchanged.accessToken, c);
    const saved = await store.updateConnection(user.sub, conn.id, {
      accounts: info.accounts, institutionId: info.institutionId, institutionName: info.institutionName,
    });
    return [201, publicConnection(saved ?? conn)];
  } catch (e) { return plaidToHttp(e); }
});

authed('GET', /^\/v1\/connections$/, async ({ user }) => {
  const all = await store.listConnections(user.sub);
  return [200, { connections: all.filter((c) => c.status !== 'disconnected').map(publicConnection) }];
});

authed('GET', /^\/v1\/connections\/([0-9a-f-]{36})\/credit-card-bills$/, async ({ params: [id], user }) => {
  if (!config.billAlerts) return [200, { status: 'disabled', bills: [] }];
  const initial = await findConnection(user, id);
  try {
    return await withItemLock(initial.itemId, async (): Promise<[number, unknown]> => {
      const conn = await findConnection(user, id);
      if (conn.status === 'disconnect_pending') throw new HttpError(410, 'connection_disconnected');
      const token = await accessToken(conn);
      const accountIds = conn.accounts.filter((a) => a.type === 'credit').map((a) => a.id);
      if (!accountIds.length) return [200, { status: 'unavailable', bills: [] }];
      return [200, { status: 'available', bills: await plaid.creditCardBills(token, accountIds) }];
    });
  } catch (e) {
    if (e instanceof PlaidError) {
      if (e.code === 'BILL_CONSENT_REQUIRED') return [200, { status: 'consent_required', bills: [] }];
      if (e.code === 'BILL_DATA_UNAVAILABLE') return [200, { status: 'unavailable', bills: [] }];
    }
    return plaidToHttp(e, initial);
  }
});

authed('POST', /^\/v1\/connections\/([0-9a-f-]{36})\/sync$/, async ({ req, params: [id], user }) => {
  const body = await readJson(req);
  const cursor = body.cursor == null ? null : String(body.cursor);
  const initial = await findConnection(user, id);
  try {
    const page = await withItemLock(initial.itemId, async () => {
      const fresh = await findConnection(user, id);
      return plaid.syncTransactions(await accessToken(fresh), cursor);
    });
    const current = await store.getConnection(user.sub, id);
    if (current && current.status !== 'disconnected') {
      await store.updateConnection(user.sub, id, {
        lastSuccessfulPull: new Date().toISOString(),
        ...(current.status === 'login_required' ? { status: 'active' as const } : {}),
        ...(page.hasMore ? {} : { updatesAvailable: false }),
      });
    }
    return [200, { status: 'ok', ...page }];
  } catch (e) {
    if (e instanceof HttpError) throw e;
    if (e instanceof PlaidError && e.code === 'TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION') return [200, { status: 'resync_required' }];
    if (e instanceof PlaidError && e.code === 'PRODUCT_NOT_READY') return [202, { status: 'not_ready' }];
    return plaidToHttp(e, initial);
  }
});

authed('DELETE', /^\/v1\/connections\/([0-9a-f-]{36})$/, async ({ params: [id], user }) => {
  await disconnect(await findConnection(user, id));
  return [200, { connectionId: id, status: 'disconnected' }];
});

// --- Development only ----------------------------------------------------------------

authed('POST', /^\/v1\/dev\/public-token$/, async ({ req }) => {
  if (config.env === 'production') throw new HttpError(404, 'not_found');
  const body = await readJson(req);
  try { return [200, { publicToken: await plaid.createTestPublicToken(country(body.country)) }]; }
  catch (e) { return plaidToHttp(e); }
});

/** Mock only: sends a Plaid-signed webhook for one of the caller's connections through the real verifier. */
authed('POST', /^\/v1\/dev\/webhook$/, async ({ req, user }) => {
  if (!(plaid instanceof MockPlaid)) throw new HttpError(404, 'not_found');
  const body = await readJson(req);
  const conn = await findConnection(user, String(body.connectionId ?? ''));
  const raw = Buffer.from(JSON.stringify({
    webhook_type: body.type, webhook_code: body.code, item_id: conn.itemId,
    error: body.errorCode ? { error_code: body.errorCode } : null,
  }));
  if (!(await webhooks.verify(plaid.signWebhook(raw), raw))) throw new HttpError(500, 'mock_signature_failed');
  await applyWebhook(JSON.parse(raw.toString('utf8')));
  return [200, { ok: true }];
});

// --- Server ------------------------------------------------------------------------------

function clientIp(req: IncomingMessage): string {
  const remote = req.socket.remoteAddress ?? 'unknown';
  if (config.trustProxy && (remote === '127.0.0.1' || remote === '::1' || remote === '::ffff:127.0.0.1')) {
    const fwd = req.headers['x-forwarded-for'];
    const first = (Array.isArray(fwd) ? fwd[0] : fwd)?.split(',')[0]?.trim();
    if (first) return first;
  }
  return remote;
}

const server = createServer(async (req, res) => {
  const started = Date.now();
  const path = (req.url ?? '/').split('?')[0]; // never log query strings
  const ip = clientIp(req);
  let status = 500;
  try {
    const route = routes.find((r) => r.method === req.method && r.pattern.test(path));
    if (!route) throw new HttpError(404, 'not_found');
    let user: AccessClaims | null = null;
    if (route.authenticated) {
      user = accounts.verifyAccess(req.headers.authorization);
      if (!user) throw new HttpError(401, 'unauthorized');
    }
    if (!limiters[route.limiter].allow(user ? `u:${user.sub}` : `ip:${ip}`)) throw new HttpError(429, 'rate_limited', true);
    const params = route.pattern.exec(path)!.slice(1);
    const [s, body] = await route.handler({ req, params, user: user!, ip });
    status = s;
    send(res, s, body);
  } catch (e) {
    if (e instanceof HttpError) { status = e.status; send(res, e.status, { error: e.code, retryable: e.retryable }); }
    else if (e instanceof AuthError) { status = e.status; send(res, e.status, { error: e.code, retryable: e.status === 429 }); }
    else { console.error('internal error', (e as Error).name); send(res, 500, { error: 'internal', retryable: true }); }
  } finally {
    // Metadata only: no bodies, emails, tokens or query strings.
    const shown = path.replace(/[0-9a-f-]{36}/g, ':id');
    console.log(`${new Date().toISOString()} ${req.method} ${shown} ${status} ${Date.now() - started}ms`);
  }
});

server.headersTimeout = 15_000;
server.requestTimeout = 30_000;
server.listen(config.port, config.host, () => {
  console.log(`Card Ledger API (${config.env}, store=${config.store}, sealer=${config.kmsKeyId ? 'kms' : 'local'}) listening on http://${config.host}:${config.port}`);
  if (webhookUrl) console.log(`Plaid webhooks: ${webhookUrl}`);
});
