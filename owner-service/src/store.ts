import type { LinkedAccount } from './vault.ts';

/**
 * Multi-user persistence. Every record that belongs to a user is keyed by that user's ID, and every
 * read of user data takes the authenticated user ID, so one user can never address another's records.
 *
 * Implementations: `MemoryStore` (tests, mock mode) and `DynamoStore` (production). Both are safe to run
 * behind several API instances: uniqueness and token rotation use conditional writes, not in-process locks.
 */

export interface UserRecord {
  id: string;
  email: string;
  createdAt: string;
  security?: AccountSecurity;
}

export interface PasskeyRecord {
  id: string;
  publicKey: string;
  counter: number;
  createdAt: string;
}

export interface AccountSecurity {
  revision: number;
  epoch: number;
  password?: { salt: string; hash: string; version: 1 };
  totp?: { sealedSecret: string; lastStep: number; recoveryHashes: string[] };
  passkeys: PasskeyRecord[];
}

export interface AuthChallenge {
  id: string;
  kind: 'totp-login' | 'totp-setup' | 'passkey-register' | 'passkey-login';
  userId?: string;
  sessionId?: string;
  epoch?: number;
  value?: string;
  expiresAt: number;
  attempts: number;
}

export interface LoginCodeRecord {
  /** HMAC of the normalized email; the email itself isn't part of the key. */
  emailKey: string;
  codeHash: string;
  expiresAt: number;
  attempts: number;
  /** Throttle: codes sent since `windowStart` (epoch ms). */
  windowStart: number;
  sentInWindow: number;
}

export interface SessionRecord {
  id: string;
  userId: string;
  /** SHA-256 of the current refresh secret. */
  tokenHash: string;
  /** SHA-256 of the previous secret, kept to detect reuse of a rotated token. */
  prevTokenHash?: string;
  createdAt: string;
  expiresAt: number;
  securityEpoch?: number;
}

export type ConnectionStatus = 'active' | 'login_required' | 'disconnect_pending' | 'disconnected';

export interface BillConsent {
  id: string;
  /** Pending Link approval expires. A completed approval has no expiry in Card Ledger. */
  expiresAt?: number;
}

export interface ConnectionRecord {
  userId: string;
  id: string;
  itemId: string;
  /** Plaid access token sealed with KMS (or the local key in dev). Removed after disconnect. */
  sealedAccessToken?: string;
  institutionId: string | null;
  institutionName: string | null;
  country: 'US' | 'CA';
  accounts: LinkedAccount[];
  clientRequestId: string;
  status: ConnectionStatus;
  createdAt: string;
  lastSuccessfulPull?: string;
  /** Set by Plaid's SYNC_UPDATES_AVAILABLE webhook, cleared once the app has synced to the end. */
  updatesAvailable?: boolean;
  billConsent?: BillConsent;
}

/** Fields of a connection that may change after creation. `null` removes the field. */
export type ConnectionPatch = Partial<{
  sealedAccessToken: string | null;
  institutionId: string | null;
  institutionName: string | null;
  accounts: LinkedAccount[];
  status: ConnectionStatus;
  lastSuccessfulPull: string;
  updatesAvailable: boolean;
  billConsent: BillConsent | null;
}>;

export interface Store {
  // Users
  findUserIdByEmailKey(emailKey: string): Promise<string | null>;
  /** Creates the user, or returns the existing one if another request created it first. */
  createUser(emailKey: string, email: string): Promise<UserRecord>;
  getUser(userId: string): Promise<UserRecord | null>;
  saveSecurity(userId: string, expectedRevision: number, security: AccountSecurity): Promise<boolean>;
  /** Removes the user, their email mapping, sessions, connections and idempotency claims. */
  deleteUser(userId: string, emailKey: string): Promise<void>;

  // One-time sign-in codes
  getLoginCode(emailKey: string): Promise<LoginCodeRecord | null>;
  putLoginCode(record: LoginCodeRecord, expected: LoginCodeRecord | null): Promise<boolean>;

  putAuthChallenge(challenge: AuthChallenge): Promise<void>;
  /** Atomically counts an attempt on an unexpired, correctly scoped challenge. */
  attemptAuthChallenge(id: string, kind: AuthChallenge['kind'], now: number, sessionId?: string): Promise<AuthChallenge | null>;
  /** Atomically consumes the challenge. Exactly one caller can obtain it. */
  takeAuthChallenge(id: string, kind: AuthChallenge['kind'], now: number, sessionId?: string): Promise<AuthChallenge | null>;

  // Refresh-token sessions
  putSession(session: SessionRecord): Promise<void>;
  getSession(sessionId: string): Promise<SessionRecord | null>;
  /** Atomically replaces the token hash if it still equals `expectedHash`. False if another refresh won. */
  rotateSession(sessionId: string, expectedHash: string, newHash: string, expiresAt: number): Promise<boolean>;
  deleteSession(sessionId: string): Promise<void>;

  // Bank connections
  /** Records `clientRequestId` → `connectionId` once. Returns the connection ID that owns the claim. */
  claimClientRequest(userId: string, clientRequestId: string, connectionId: string): Promise<string>;
  putConnection(connection: ConnectionRecord): Promise<void>;
  getConnection(userId: string, connectionId: string): Promise<ConnectionRecord | null>;
  listConnections(userId: string): Promise<ConnectionRecord[]>;
  updateConnection(userId: string, connectionId: string, patch: ConnectionPatch): Promise<ConnectionRecord | null>;
  confirmBillConsent(userId: string, connectionId: string, id: string, now: number): Promise<boolean>;
  /** Webhooks arrive by Plaid Item ID; returns the (normally single) connection for that Item. */
  findConnectionsByItemId(itemId: string): Promise<ConnectionRecord[]>;
}

export function applyPatch<T extends object>(target: T, patch: Record<string, unknown>): T {
  const out = { ...target } as Record<string, unknown>;
  for (const [k, v] of Object.entries(patch)) {
    if (v === undefined) continue;
    if (v === null && (k === 'sealedAccessToken' || k === 'billConsent')) delete out[k];
    else out[k] = v;
  }
  return out as T;
}

const clone = <T>(v: T): T => structuredClone(v);

/** In-process store for tests and mock mode. Data is lost on restart. */
export class MemoryStore implements Store {
  private readonly emails = new Map<string, string>();
  private readonly users = new Map<string, UserRecord>();
  private readonly codes = new Map<string, LoginCodeRecord>();
  private readonly sessions = new Map<string, SessionRecord>();
  private readonly authChallenges = new Map<string, AuthChallenge>();
  private readonly connections = new Map<string, ConnectionRecord>();
  private readonly claims = new Map<string, string>();

  async findUserIdByEmailKey(emailKey: string) { return this.emails.get(emailKey) ?? null; }

  async createUser(emailKey: string, email: string) {
    const existing = this.emails.get(emailKey);
    if (existing) return clone(this.users.get(existing)!);
    const user: UserRecord = { id: crypto.randomUUID(), email, createdAt: new Date().toISOString() };
    this.emails.set(emailKey, user.id);
    this.users.set(user.id, user);
    return clone(user);
  }

  async getUser(userId: string) { const u = this.users.get(userId); return u ? clone(u) : null; }

  async saveSecurity(userId: string, expectedRevision: number, security: AccountSecurity) {
    const user = this.users.get(userId);
    if (!user || (user.security?.revision ?? 0) !== expectedRevision) return false;
    user.security = clone(security);
    return true;
  }

  async deleteUser(userId: string, emailKey: string) {
    this.users.delete(userId);
    if (this.emails.get(emailKey) === userId) this.emails.delete(emailKey);
    this.codes.delete(emailKey);
    for (const [id, s] of this.sessions) if (s.userId === userId) this.sessions.delete(id);
    for (const [id, c] of this.authChallenges) if (c.userId === userId) this.authChallenges.delete(id);
    for (const [k, c] of this.connections) if (c.userId === userId) this.connections.delete(k);
    for (const k of this.claims.keys()) if (k.startsWith(`${userId}/`)) this.claims.delete(k);
  }

  async getLoginCode(emailKey: string) { const c = this.codes.get(emailKey); return c ? clone(c) : null; }
  async putLoginCode(record: LoginCodeRecord, expected: LoginCodeRecord | null) {
    const current = this.codes.get(record.emailKey) ?? null;
    if (current?.codeHash !== expected?.codeHash || current?.attempts !== expected?.attempts
      || current?.windowStart !== expected?.windowStart || current?.sentInWindow !== expected?.sentInWindow) return false;
    this.codes.set(record.emailKey, clone(record));
    return true;
  }

  async putAuthChallenge(challenge: AuthChallenge) {
    for (const [id, entry] of this.authChallenges) if (entry.expiresAt <= Date.now()) this.authChallenges.delete(id);
    this.authChallenges.set(challenge.id, clone(challenge));
  }

  async attemptAuthChallenge(id: string, kind: AuthChallenge['kind'], now: number, sessionId?: string) {
    const c = this.authChallenges.get(id);
    if (!c || c.kind !== kind || c.sessionId !== sessionId || c.expiresAt <= now || c.attempts >= 5) return null;
    c.attempts += 1;
    return clone(c);
  }

  async takeAuthChallenge(id: string, kind: AuthChallenge['kind'], now: number, sessionId?: string) {
    const c = this.authChallenges.get(id);
    if (!c || c.kind !== kind || c.sessionId !== sessionId || c.expiresAt <= now) return null;
    this.authChallenges.delete(id);
    return clone(c);
  }

  async putSession(session: SessionRecord) { this.sessions.set(session.id, clone(session)); }
  async getSession(sessionId: string) { const s = this.sessions.get(sessionId); return s ? clone(s) : null; }
  async rotateSession(sessionId: string, expectedHash: string, newHash: string, expiresAt: number) {
    const s = this.sessions.get(sessionId);
    if (!s || s.tokenHash !== expectedHash) return false;
    s.prevTokenHash = s.tokenHash;
    s.tokenHash = newHash;
    s.expiresAt = expiresAt;
    return true;
  }
  async deleteSession(sessionId: string) { this.sessions.delete(sessionId); }

  async claimClientRequest(userId: string, clientRequestId: string, connectionId: string) {
    const key = `${userId}/${clientRequestId}`;
    const existing = this.claims.get(key);
    if (existing) return existing;
    this.claims.set(key, connectionId);
    return connectionId;
  }

  async putConnection(connection: ConnectionRecord) {
    this.connections.set(`${connection.userId}/${connection.id}`, clone(connection));
  }
  async getConnection(userId: string, connectionId: string) {
    const c = this.connections.get(`${userId}/${connectionId}`);
    return c ? clone(c) : null;
  }
  async listConnections(userId: string) {
    return [...this.connections.values()].filter((c) => c.userId === userId).map(clone)
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }
  async updateConnection(userId: string, connectionId: string, patch: ConnectionPatch) {
    const key = `${userId}/${connectionId}`;
    const c = this.connections.get(key);
    if (!c) return null;
    const next = applyPatch(c, patch);
    this.connections.set(key, next);
    return clone(next);
  }

  async confirmBillConsent(userId: string, connectionId: string, id: string, now: number) {
    const conn = this.connections.get(`${userId}/${connectionId}`);
    if (!conn || conn.status !== 'active' || conn.billConsent?.id !== id) return false;
    if (conn.billConsent.expiresAt !== undefined && conn.billConsent.expiresAt <= now) return false;
    conn.billConsent = { id };
    return true;
  }
  async findConnectionsByItemId(itemId: string) {
    return [...this.connections.values()].filter((c) => c.itemId === itemId).map(clone);
  }
}
