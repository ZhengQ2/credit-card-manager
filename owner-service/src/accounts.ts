import { createHash, createHmac, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import type { InviteRecord, Store, UserRecord } from './store.ts';
import type { Mailer } from './mailer.ts';

export const ACCESS_TTL_S = 15 * 60;
export const REFRESH_TTL_MS = 60 * 24 * 3600_000;
export const CHALLENGE_TTL_S = 5 * 60;
const CODE_TTL_MS = 10 * 60_000;
const MAX_CODE_ATTEMPTS = 5;
const CODES_PER_HOUR = 5;
const ISSUER = 'card-ledger';
const AUDIENCE = 'card-ledger-ios';
export const INVITE_TTL_DAYS = 30;

/** `open`: any verified email gets an account. `invite`: only addresses with an unexpired invite. */
export type SignupMode = 'open' | 'invite';

export class AuthError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string) { super(code); this.status = status; this.code = code; }
}

const sha256 = (s: string) => createHash('sha256').update(s).digest('hex');
const b64url = (b: Buffer | string) => Buffer.from(b).toString('base64url');

export function safeEqual(a: string, b: string): boolean {
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
export interface SecondFactorRequired { secondFactor: { id: string; expiresIn: number } }

/**
 * Email one-time codes, HS256 access tokens and rotating refresh tokens.
 *
 * - Codes: 6 digits, 10 minutes, single use, 5 attempts, at most 5 sent per address per hour. Only an HMAC
 *   of the code is stored, keyed by an HMAC of the email, both with a server-side pepper.
 * - Access tokens: 15 minutes, signed with a secret shared by every API instance (from SSM in production).
 * - Refresh tokens: `<sessionId>.<secret>`, 60 days rolling, rotated on every use. Presenting an already
 *   rotated token revokes the session, which limits the damage of a stolen token.
 * - Sign-up: in `invite` mode a new address needs an unexpired invite. Existing accounts are unaffected.
 */
export class Accounts {
  private readonly store: Store;
  private readonly mailer: Mailer;
  private readonly jwtSecret: Buffer;
  private readonly pepper: Buffer;
  private readonly signup: SignupMode;

  constructor(store: Store, mailer: Mailer, jwtSecret: Buffer, pepper: Buffer, signup: SignupMode = 'open') {
    if (jwtSecret.length < 32 || pepper.length < 32) throw new Error('JWT secret and code pepper must be at least 32 bytes');
    this.store = store; this.mailer = mailer; this.jwtSecret = jwtSecret; this.pepper = pepper; this.signup = signup;
  }

  emailKey(email: string): string {
    return createHmac('sha256', this.pepper).update(`email:${email}`).digest('hex');
  }

  private codeHash(emailKey: string, code: string): string {
    return createHmac('sha256', this.pepper).update(`code:${emailKey}:${code}`).digest('hex');
  }

  /** Lets `email` create an account while sign-up is invite-only. Replaces any earlier invite for it. */
  async invite(rawEmail: unknown, days = INVITE_TTL_DAYS, now = Date.now()): Promise<InviteRecord> {
    if (!Number.isInteger(days) || days < 1 || days > 365) throw new AuthError(400, 'invite_days_invalid');
    const invite = {
      emailKey: this.emailKey(normalizeEmail(rawEmail)), createdAt: new Date(now).toISOString(), expiresAt: now + days * 86_400_000,
    };
    await this.store.putInvite(invite);
    return invite;
  }

  /** Withdraws an unredeemed invite. An account the address already created is not affected. */
  async revokeInvite(rawEmail: unknown): Promise<void> {
    await this.store.deleteInvite(this.emailKey(normalizeEmail(rawEmail)));
  }

  /**
   * Whether this address may receive a sign-in code: it has an account, or sign-up is open, or it's invited.
   * Both lookups always run, so the store work doesn't depend on the answer.
   */
  private async maySignIn(emailKey: string, now: number): Promise<boolean> {
    const [userId, invite] = await Promise.all([this.store.findUserIdByEmailKey(emailKey), this.store.getInvite(emailKey)]);
    if (this.signup === 'open' || userId) return true;
    return !!invite && invite.expiresAt > now;
  }

  /**
   * Sends a code if the address may sign in and isn't throttled. The response never reveals whether the
   * address has an account or an invite. Every address is counted against the same hourly limit and gets the
   * same reads and write; one that may not sign in gets a record with no code, and no email.
   */
  async startEmailSignIn(rawEmail: unknown): Promise<void> {
    const email = normalizeEmail(rawEmail);
    const key = this.emailKey(email);
    const eligible = await this.maySignIn(key, Date.now());
    for (let tryCount = 0; tryCount < 8; tryCount++) {
      const now = Date.now();
      const prior = await this.store.getLoginCode(key);
      const inWindow = prior && now - prior.windowStart < 3_600_000;
      const sent = inWindow ? prior.sentInWindow : 0;
      if (sent >= CODES_PER_HOUR) throw new AuthError(429, 'too_many_codes');
      const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
      const hash = this.codeHash(key, code);
      // An empty code hash never verifies, so an ineligible address can't sign in with any code.
      if (!await this.store.putLoginCode({
        emailKey: key, codeHash: eligible ? hash : '', expiresAt: eligible ? now + CODE_TTL_MS : 0,
        attempts: 0, windowStart: inWindow ? prior.windowStart : now, sentInWindow: sent + 1,
      }, prior)) continue;
      // Persist the code before delivery, but keep the mail provider out of the response timing.
      if (eligible) void this.deliverLoginCode(email, code);
      return;
    }
    throw new AuthError(429, 'rate_limited');
  }

  private async deliverLoginCode(email: string, code: string): Promise<void> {
    try {
      await this.mailer.sendLoginCode(email, code);
    } catch {
      // Provider errors can include the recipient and request data.
      console.error('Sign-in code email delivery failed');
    }
  }

  async verifyEmailCode(rawEmail: unknown, rawCode: unknown): Promise<Tokens | SecondFactorRequired> {
    const email = normalizeEmail(rawEmail);
    const code = typeof rawCode === 'string' ? rawCode.replace(/\D/g, '') : '';
    const key = this.emailKey(email);
    for (let tryCount = 0; tryCount < 8; tryCount++) {
      const record = await this.store.getLoginCode(key);
      if (!record || !record.codeHash || record.expiresAt <= Date.now()) throw new AuthError(401, 'code_invalid_or_expired');
      if (record.attempts >= MAX_CODE_ATTEMPTS) throw new AuthError(401, 'code_locked');
      const valid = code.length === 6 && safeEqual(this.codeHash(key, code), record.codeHash);
      const attempts = record.attempts + 1;
      const next = valid || attempts >= MAX_CODE_ATTEMPTS
        ? { ...record, codeHash: '', expiresAt: 0, attempts: MAX_CODE_ATTEMPTS }
        : { ...record, attempts };
      if (!await this.store.putLoginCode(next, record)) continue;
      if (!valid) throw new AuthError(401, attempts >= MAX_CODE_ATTEMPTS ? 'code_locked' : 'code_invalid_or_expired');
      const id = await this.store.findUserIdByEmailKey(key);
      const user = (id && await this.store.getUser(id)) || await this.createAccount(key, email);
      return this.completeFirstFactor(user);
    }
    throw new AuthError(429, 'rate_limited');
  }

  /** Fails closed: in invite mode, an invite revoked or expired after the code was sent blocks the account. */
  private async createAccount(emailKey: string, email: string): Promise<UserRecord> {
    if (this.signup === 'open') return this.store.createUser(emailKey, email);
    const user = await this.store.createInvitedUser(emailKey, email, Date.now());
    if (!user) throw new AuthError(403, 'invite_required');
    return user;
  }

  async completeFirstFactor(user: UserRecord): Promise<Tokens | SecondFactorRequired> {
    if (!user.security?.totp) return this.openSession(user);
    const id = crypto.randomUUID();
    await this.store.putAuthChallenge({
      id, kind: 'totp-login', userId: user.id, epoch: user.security.epoch,
      expiresAt: Date.now() + CHALLENGE_TTL_S * 1000, attempts: 0,
    });
    return { secondFactor: { id, expiresIn: CHALLENGE_TTL_S } };
  }

  async openSession(user: UserRecord): Promise<Tokens> {
    const sessionId = crypto.randomUUID();
    const secret = b64url(randomBytes(32));
    const now = new Date().toISOString();
    await this.store.putSession({
      id: sessionId, userId: user.id, tokenHash: sha256(secret),
      securityEpoch: user.security?.epoch ?? 0,
      createdAt: now, expiresAt: Date.now() + REFRESH_TTL_MS,
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
    if (!user || (user.security?.epoch ?? 0) !== (session.securityEpoch ?? 0)) {
      await this.store.deleteSession(sessionId);
      throw new AuthError(401, 'refresh_invalid');
    }
    const next = b64url(randomBytes(32));
    const ok = await this.store.rotateSession(sessionId, presented, sha256(next), Date.now() + REFRESH_TTL_MS);
    if (!ok) throw new AuthError(401, 'refresh_invalid');
    return this.tokens(user, sessionId, next);
  }

  async signOut(sessionId: string) { await this.store.deleteSession(sessionId); }

  async requireSession(claims: AccessClaims) {
    const [session, user] = await Promise.all([this.store.getSession(claims.sid), this.store.getUser(claims.sub)]);
    if (!session || !user || session.userId !== user.id || session.expiresAt <= Date.now()
      || (session.securityEpoch ?? 0) !== (user.security?.epoch ?? 0)) throw new AuthError(401, 'unauthorized');
    return { session, user };
  }

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
