import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { randomUUID } from 'node:crypto';
import { loadConfig } from './config.ts';
import { Vault, type Connection } from './vault.ts';
import { authenticate, redeemPairingCode, RateLimiter } from './auth.ts';
import { PlaidError, RealPlaid, type PlaidAdapter } from './plaid.ts';
import { MockPlaid } from './mockPlaid.ts';

const config = loadConfig();
const vault = new Vault(config.dataDir, config.env, config.vaultKey);
const plaid: PlaidAdapter = config.env === 'mock' ? new MockPlaid(config.mockMutation) : new RealPlaid(config);
const pairLimiter = new RateLimiter(10, 60_000);
const healthLimiter = new RateLimiter(60, 60_000);
const apiLimiter = new RateLimiter(120, 60_000);
/** Per-Item serialization of Plaid calls (design §7). */
const itemLocks = new Map<string, Promise<unknown>>();
/** Per-clientRequestId serialization so concurrent connection retries don't race. */
const connectLocks = new Map<string, Promise<unknown>>();

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

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const c of req) {
    size += (c as Buffer).length;
    if (size > 64 * 1024) throw new HttpError(413, 'body_too_large');
    chunks.push(c as Buffer);
  }
  if (!chunks.length) return {};
  try {
    const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      throw new HttpError(400, 'invalid_json');
    }
    return parsed as Record<string, unknown>;
  } catch (e) {
    if (e instanceof HttpError) throw e;
    throw new HttpError(400, 'invalid_json');
  }
}

function country(v: unknown): 'US' | 'CA' {
  if (v === 'US' || v === 'CA') return v;
  throw new HttpError(400, 'country_must_be_US_or_CA');
}

function publicConnection(c: Connection) {
  return {
    connectionId: c.id,
    institution: c.institutionName,
    country: c.country,
    status: c.status,
    accounts: c.accounts,
    lastSuccessfulPull: c.lastSuccessfulPull ?? null,
  };
}

function findConnection(id: string): Connection {
  const c = vault.read().connections.find((x) => x.id === id);
  if (!c) throw new HttpError(404, 'connection_not_found');
  return c;
}

async function withLock<T>(locks: Map<string, Promise<unknown>>, key: string, fn: () => Promise<T>): Promise<T> {
  const prev = locks.get(key) ?? Promise.resolve();
  const next = prev.catch(() => undefined).then(fn);
  locks.set(key, next);
  try { return await next; } finally { if (locks.get(key) === next) locks.delete(key); }
}

function withItemLock<T>(itemId: string, fn: () => Promise<T>): Promise<T> {
  return withLock(itemLocks, itemId, fn);
}

function plaidToHttp(e: unknown, connectionId?: string): never {
  if (e instanceof PlaidError) {
    if (e.code === 'ITEM_LOGIN_REQUIRED' && connectionId) {
      vault.update((d) => { const c = d.connections.find((x) => x.id === connectionId); if (c) c.status = 'login_required'; });
      throw new HttpError(409, 'ITEM_LOGIN_REQUIRED');
    }
    if (e.code === 'RATE_LIMIT_EXCEEDED') throw new HttpError(429, e.code, true);
    if (e.code === 'INVALID_PUBLIC_TOKEN') throw new HttpError(400, e.code);
    if (e.code === 'ITEM_NOT_FOUND') throw new HttpError(410, e.code);
    throw new HttpError(502, e.code, e.retryable);
  }
  throw e;
}

type Handler = (req: IncomingMessage, params: string[]) => Promise<[number, unknown]>;
type RouteAuth = 'auth' | 'pair' | 'health';
const routes: Array<[string, RegExp, Handler, RouteAuth]> = [];
function route(method: string, pattern: RegExp, handler: Handler, auth: RouteAuth = 'auth') { routes.push([method, pattern, handler, auth]); }

// --- Public (unauthenticated) ------------------------------------------------

route('GET', /^\/v1\/health$/, async () => [200, { ok: true, service: 'card-ledger-owner-service', environment: config.env }], 'health');

route('POST', /^\/v1\/pair$/, async (req) => {
  const body = await readJson(req);
  const code = typeof body.code === 'string' ? body.code : '';
  const deviceName = typeof body.deviceName === 'string' ? body.deviceName : 'iPhone';
  const result = redeemPairingCode(vault, code, deviceName);
  if (!result.ok) throw new HttpError(result.reason === 'invalid' ? 401 : 410, `pairing_${result.reason}`);
  return [201, { deviceId: result.deviceId, credential: result.credential, environment: config.env }];
}, 'pair');

// --- Authenticated --------------------------------------------------------------

route('POST', /^\/v1\/link-token$/, async (req) => {
  const body = await readJson(req);
  const c = country(body.country);
  let accessToken: string | undefined;
  if (typeof body.connectionId === 'string') {
    const conn = findConnection(body.connectionId);
    if (!conn.accessToken || conn.status === 'disconnected') throw new HttpError(410, 'connection_disconnected');
    accessToken = conn.accessToken; // update mode for the existing Item
  }
  try {
    const t = await plaid.createLinkToken({ country: c, accessToken });
    return [200, { linkToken: t.linkToken, expiration: t.expiration, environment: config.env }];
  } catch (e) { plaidToHttp(e); }
});

route('POST', /^\/v1\/connections$/, async (req) => {
  const body = await readJson(req);
  const publicToken = typeof body.publicToken === 'string' ? body.publicToken : '';
  const clientRequestId = typeof body.clientRequestId === 'string' ? body.clientRequestId : '';
  const c = country(body.country);
  if (!publicToken || !/^[A-Za-z0-9-]{8,64}$/.test(clientRequestId)) throw new HttpError(400, 'publicToken_and_clientRequestId_required');

  return withLock(connectLocks, clientRequestId, async (): Promise<[number, unknown]> => {
    // Idempotent: a retried request with the same client request ID returns the stored connection,
    // retrying account fetch if a prior attempt persisted the token before getAccounts failed.
    const existing = vault.read().connections.find((x) => x.clientRequestId === clientRequestId);
    if (existing) {
      if (existing.accounts.length === 0 && existing.accessToken && existing.status !== 'disconnected') {
        try {
          const info = await plaid.getAccounts(existing.accessToken, existing.country);
          const repaired = vault.update((d) => {
            const x = d.connections.find((y) => y.id === existing.id);
            if (!x) return existing;
            x.accounts = info.accounts; x.institutionId = info.institutionId; x.institutionName = info.institutionName;
            return x;
          });
          return [200, publicConnection(repaired)];
        } catch (e) { plaidToHttp(e, existing.id); }
      }
      return [200, publicConnection(existing)];
    }

    try {
      const { accessToken, itemId } = await plaid.exchangePublicToken(publicToken);
      // Persist the Item token before acknowledging.
      const conn: Connection = {
        id: randomUUID(), itemId, accessToken, institutionId: null, institutionName: null, country: c,
        accounts: [], clientRequestId, status: 'active', createdAt: new Date().toISOString(),
      };
      vault.update((d) => { d.connections.push(conn); });
      const info = await plaid.getAccounts(accessToken, c);
      const saved = vault.update((d) => {
        const x = d.connections.find((y) => y.id === conn.id)!;
        x.accounts = info.accounts; x.institutionId = info.institutionId; x.institutionName = info.institutionName;
        return x;
      });
      return [201, publicConnection(saved)];
    } catch (e) { plaidToHttp(e); }
  });
});

route('GET', /^\/v1\/connections$/, async () => {
  return [200, { connections: vault.read().connections.filter((c) => c.status !== 'disconnected').map(publicConnection) }];
});

route('POST', /^\/v1\/connections\/([0-9a-f-]{36})\/sync$/, async (req, [id]) => {
  const body = await readJson(req);
  const cursor = body.cursor == null ? null : String(body.cursor);
  const initial = findConnection(id);
  if (!initial.accessToken || initial.status === 'disconnected') throw new HttpError(410, 'connection_disconnected');
  try {
    const page = await withItemLock(initial.itemId, async () => {
      const fresh = findConnection(id);
      if (!fresh.accessToken || fresh.status === 'disconnected') throw new HttpError(410, 'connection_disconnected');
      return plaid.syncTransactions(fresh.accessToken, cursor);
    });
    vault.update((d) => {
      const x = d.connections.find((y) => y.id === id);
      if (x && x.status !== 'disconnected') {
        x.lastSuccessfulPull = new Date().toISOString();
        if (x.status === 'login_required') x.status = 'active';
      }
    });
    return [200, { status: 'ok', ...page }];
  } catch (e) {
    if (e instanceof HttpError) throw e;
    if (e instanceof PlaidError && e.code === 'TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION') return [200, { status: 'resync_required' }];
    if (e instanceof PlaidError && e.code === 'PRODUCT_NOT_READY') return [202, { status: 'not_ready' }];
    plaidToHttp(e, id);
  }
});

route('DELETE', /^\/v1\/connections\/([0-9a-f-]{36})$/, async (_req, [id]) => {
  const initial = findConnection(id);
  if (initial.status === 'disconnected' || !initial.accessToken) return [200, { connectionId: id, status: 'disconnected' }];
  await withItemLock(initial.itemId, async () => {
    const conn = findConnection(id);
    if (conn.status === 'disconnected' || !conn.accessToken) return;
    vault.update((d) => { const x = d.connections.find((y) => y.id === id); if (x) x.status = 'disconnect_pending'; });
    try {
      await plaid.removeItem(conn.accessToken);
    } catch (e) {
      // Keep the token so revocation can be retried.
      const retryable = !(e instanceof PlaidError) || e.retryable;
      throw new HttpError(503, 'disconnect_retry_required', retryable);
    }
    vault.update((d) => {
      const x = d.connections.find((y) => y.id === id);
      if (x) { delete x.accessToken; x.status = 'disconnected'; }
    });
  });
  return [200, { connectionId: id, status: 'disconnected' }];
});

// Sandbox / mock only: create a public token without Plaid Link (simulator testing).
route('POST', /^\/v1\/dev\/public-token$/, async (req) => {
  if (config.env === 'production') throw new HttpError(404, 'not_found');
  const body = await readJson(req);
  try { return [200, { publicToken: await plaid.createTestPublicToken(country(body.country)) }]; }
  catch (e) { plaidToHttp(e); }
});

// --- Server ---------------------------------------------------------------------

const server = createServer(async (req, res) => {
  const started = Date.now();
  const path = (req.url ?? '/').split('?')[0]; // never log query strings
  const client = req.socket.remoteAddress ?? 'unknown';
  let status = 500;
  try {
    const match = routes.find(([m, p]) => m === req.method && p.test(path));
    if (!match) throw new HttpError(404, 'not_found');
    const [, pattern, handler, authMode] = match;
    const limiter = authMode === 'auth' ? apiLimiter : authMode === 'health' ? healthLimiter : pairLimiter;
    if (!limiter.allow(client)) throw new HttpError(429, 'rate_limited', true);
    if (authMode === 'auth' && !authenticate(vault, req.headers.authorization)) throw new HttpError(401, 'unauthorized');
    const params = pattern.exec(path)!.slice(1);
    const [s, body] = await handler(req, params);
    status = s;
    send(res, s, body);
  } catch (e) {
    if (e instanceof HttpError) { status = e.status; send(res, e.status, { error: e.code, retryable: e.retryable }); }
    else { console.error('internal error', (e as Error).name); send(res, 500, { error: 'internal', retryable: true }); }
  } finally {
    // Metadata only: no bodies, tokens, or query strings.
    const shown = path.replace(/[0-9a-f-]{36}/g, ':id');
    console.log(`${new Date().toISOString()} ${req.method} ${shown} ${status} ${Date.now() - started}ms`);
  }
});

server.listen(config.port, config.host, () => {
  console.log(`Card Ledger owner service (${config.env}) listening on http://${config.host}:${config.port}`);
  if (config.env === 'mock') console.log('Using the mock Plaid adapter with synthetic data.');
});
