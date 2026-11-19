import { createHash, createHmac, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import type { Store, UserRecord } from './store.ts';
import type { Mailer } from './mailer.ts';

export const ACCESS_TTL_S = 15 * 60;
export const REFRESH_TTL_MS = 60 * 24 * 3600_000;
const CODE_TTL_MS = 10 * 60_000;
const MAX_CODE_ATTEMPTS = 5;
const CODES_PER_HOUR = 5;
const ISSUER = 'card-ledger';
const AUDIENCE = 'card-ledger-ios';

export class AuthError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string) { super(code); this.status = status; this.code = code; }
}

const sha256 = (s: string) => createHash('sha256').update(s).digest('hex');
const b64url = (b: Buffer | string) => Buffer.from(b).toString('base64url');

function safeEqual(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

export function normalizeEmail(raw: unknown): string {
  if (typeof raw !== 'string') throw new AuthError(400, 'email_required');
  const email = raw.trim().toLowerCase();
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) throw new AuthError(400, 'email_invalid');
  return email;
}

export interface Tokens {
  accessToken: string;
  accessTokenExpiresIn: number;
  refreshToken: string;
  user: { id: string; email: string };
}

export interface AccessClaims { sub: string; sid: string; iat: number; exp: number }

/**
 * Email one-time codes, HS256 access tokens and rotating refresh tokens.
 *
 * - Codes: 6 digits, 10 minutes, single use, 5 attempts, at most 5 sent per address per hour. Only an HMAC
 *   of the code is stored, keyed by an HMAC of the email, both with a server-side pepper.
 * - Access tokens: 15 minutes, signed with a secret shared by every API instance (from SSM in production).
 * - Refresh tokens: `<sessionId>.<secret>`, 60 days rolling, rotated on every use. Presenting an already
 *   rotated token revokes the session, which limits the damage of a stolen token.
 */
export class Accounts {
  private readonly store: Store;
  private readonly mailer: Mailer;
  private readonly jwtSecret: Buffer;
  private readonly pepper: Buffer;

  constructor(store: Store, mailer: Mailer, jwtSecret: Buffer, pepper: Buffer) {
    if (jwtSecret.length < 32 || pepper.length < 32) throw new Error('JWT secret and code pepper must be at least 32 bytes');
    this.store = store; this.mailer = mailer; this.jwtSecret = jwtSecret; this.pepper = pepper;
  }

  emailKey(email: string): string {
    return createHmac('sha256', this.pepper).update(`email:${email}`).digest('hex');
  }

  private codeHash(emailKey: string, code: string): string {
    return createHmac('sha256', this.pepper).update(`code:${emailKey}:${code}`).digest('hex');
  }

  /** Sends a code if the address isn't throttled. Never reveals whether the address has an account. */
  async startEmailSignIn(rawEmail: unknown): Promise<void> {
    const email = normalizeEmail(rawEmail);
    const key = this.emailKey(email);
    const now = Date.now();
    const prior = await this.store.getLoginCode(key);
    const inWindow = prior && now - prior.windowStart < 3_600_000;
    const sent = inWindow ? prior.sentInWindow : 0;
    if (sent >= CODES_PER_HOUR) throw new AuthError(429, 'too_many_codes');
    const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
    await this.store.putLoginCode({
      emailKey: key, codeHash: this.codeHash(key, code), expiresAt: now + CODE_TTL_MS, attempts: 0,
      windowStart: inWindow ? prior.windowStart : now, sentInWindow: sent + 1,
    });
    await this.mailer.sendLoginCode(email, code);
  }

  async verifyEmailCode(rawEmail: unknown, rawCode: unknown, rawDeviceName: unknown): Promise<Tokens> {
    const email = normalizeEmail(rawEmail);
    const code = typeof rawCode === 'string' ? rawCode.replace(/\D/g, '') : '';
    const key = this.emailKey(email);
    const record = await this.store.getLoginCode(key);
    if (!record || record.codeHash === '' || record.expiresAt < Date.now()) throw new AuthError(401, 'code_invalid_or_expired');
    if (record.attempts >= MAX_CODE_ATTEMPTS) { await this.consumeCode(key, record); throw new AuthError(401, 'code_locked'); }
    if (code.length !== 6 || !safeEqual(this.codeHash(key, code), record.codeHash)) {
      const attempts = await this.store.recordFailedAttempt(key);
      if (attempts >= MAX_CODE_ATTEMPTS) { await this.consumeCode(key, record); throw new AuthError(401, 'code_locked'); }
      throw new AuthError(401, 'code_invalid_or_expired');
    }
    await this.consumeCode(key, record);
    const user = (await this.store.findUserIdByEmailKey(key).then((id) => (id ? this.store.getUser(id) : null)))
      ?? await this.store.createUser(key, email);
    return this.openSession(user, rawDeviceName);
  }

  /** Burns the code but keeps the hourly send count so deleting a code can't reset throttling. */
  private async consumeCode(key: string, record: { windowStart: number; sentInWindow: number }) {
    await this.store.putLoginCode({
      emailKey: key, codeHash: '', expiresAt: 0, attempts: MAX_CODE_ATTEMPTS,
      windowStart: record.windowStart, sentInWindow: record.sentInWindow,
    });
  }

  private async openSession(user: UserRecord, rawDeviceName: unknown): Promise<Tokens> {
    const deviceName = (typeof rawDeviceName === 'string' ? rawDeviceName : 'iPhone')
      .replace(/[\r\n\x00-\x1f\x7f]/g, ' ').trim().slice(0, 60) || 'iPhone';
    const sessionId = crypto.randomUUID();
    const secret = b64url(randomBytes(32));
    const now = new Date().toISOString();
    await this.store.putSession({
      id: sessionId, userId: user.id, tokenHash: sha256(secret), deviceName,
      createdAt: now, lastUsedAt: now, expiresAt: Date.now() + REFRESH_TTL_MS,
    });
    return this.tokens(user, sessionId, secret);
  }

  private tokens(user: UserRecord, sessionId: string, secret: string): Tokens {
    return {
      accessToken: this.signAccess(user.id, sessionId),
      accessTokenExpiresIn: ACCESS_TTL_S,
      refreshToken: `${sessionId}.${secret}`,
      user: { id: user.id, email: user.email },
    };
  }

  async refresh(rawToken: unknown): Promise<Tokens> {
    const m = /^([0-9a-f-]{36})\.([A-Za-z0-9_-]{40,})$/.exec(typeof rawToken === 'string' ? rawToken : '');
    if (!m) throw new AuthError(401, 'refresh_invalid');
    const [, sessionId, secret] = m;
    const session = await this.store.getSession(sessionId);
    if (!session) throw new AuthError(401, 'refresh_invalid');
    if (session.expiresAt < Date.now()) { await this.store.deleteSession(sessionId); throw new AuthError(401, 'refresh_expired'); }
    const presented = sha256(secret);
    if (session.prevTokenHash && safeEqual(presented, session.prevTokenHash)) {
      // A rotated token came back: someone else holds a copy. End the session for everyone.
      await this.store.deleteSession(sessionId);
      throw new AuthError(401, 'refresh_reused');
    }
    if (!safeEqual(presented, session.tokenHash)) throw new AuthError(401, 'refresh_invalid');
    const user = await this.store.getUser(session.userId);
    if (!user) { await this.store.deleteSession(sessionId); throw new AuthError(401, 'refresh_invalid'); }
    const next = b64url(randomBytes(32));
    const ok = await this.store.rotateSession(sessionId, presented, sha256(next), Date.now() + REFRESH_TTL_MS);
    if (!ok) throw new AuthError(401, 'refresh_invalid');
    return this.tokens(user, sessionId, next);
  }

  async signOut(sessionId: string) { await this.store.deleteSession(sessionId); }

  signAccess(userId: string, sessionId: string, now = Math.floor(Date.now() / 1000)): string {
    const header = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
    const payload = b64url(JSON.stringify({ iss: ISSUER, aud: AUDIENCE, sub: userId, sid: sessionId, iat: now, exp: now + ACCESS_TTL_S }));
    const sig = createHmac('sha256', this.jwtSecret).update(`${header}.${payload}`).digest('base64url');
    return `${header}.${payload}.${sig}`;
  }

  /** Returns the claims of a valid access token, or null. */
  verifyAccess(header: string | undefined, now = Math.floor(Date.now() / 1000)): AccessClaims | null {
    const m = /^Bearer ([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/.exec(header ?? '');
    if (!m) return null;
    const expected = createHmac('sha256', this.jwtSecret).update(`${m[1]}.${m[2]}`).digest('base64url');
    if (!safeEqual(expected, m[3])) return null;
    try {
      const h = JSON.parse(Buffer.from(m[1], 'base64url').toString('utf8'));
      if (h.alg !== 'HS256') return null;
      const p = JSON.parse(Buffer.from(m[2], 'base64url').toString('utf8'));
      if (p.iss !== ISSUER || p.aud !== AUDIENCE || typeof p.sub !== 'string' || typeof p.sid !== 'string') return null;
      if (typeof p.exp !== 'number' || p.exp <= now || typeof p.iat !== 'number' || p.iat > now + 60) return null;
      return { sub: p.sub, sid: p.sid, iat: p.iat, exp: p.exp };
    } catch { return null; }
  }
}
