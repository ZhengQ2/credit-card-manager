import { createHmac, randomBytes, scrypt } from 'node:crypto';
import { Secret, TOTP } from 'otpauth';
import {
  generateAuthenticationOptions, generateRegistrationOptions, verifyAuthenticationResponse, verifyRegistrationResponse,
  type AuthenticationResponseJSON, type RegistrationResponseJSON,
} from '@simplewebauthn/server';
import { AuthError, CHALLENGE_TTL_S, normalizeEmail, safeEqual, type AccessClaims, type Accounts } from './accounts.ts';
import { RateLimiter } from './auth.ts';
import type { Sealer } from './sealer.ts';
import type { AccountSecurity, AuthChallenge, Store, UserRecord } from './store.ts';

export interface PasskeyConfig { rpID: string; origin: string; appID: string }
const RECENT_SIGN_IN_MS = 10 * 60_000;
const MAX_PASSKEYS = 10;
const PASSWORD_COST = { N: 2 ** 15, r: 8, p: 3, maxmem: 64 * 1024 * 1024 };
const MAX_PASSWORD_WORK = 3;
const emptySecurity = (): AccountSecurity => ({ revision: 0, epoch: 0, passkeys: [] });
const secretContext = (userId: string) => ({ purpose: 'account-totp', userId });
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;

function challengeID(value: unknown): string {
  if (typeof value !== 'string' || !uuid.test(value)) throw new AuthError(401, 'challenge_invalid_or_expired');
  return value;
}

function authenticator(secret: string, email: string) {
  return new TOTP({ issuer: 'Card Ledger', label: email, algorithm: 'SHA1', digits: 6, period: 30,
                    secret: Secret.fromBase32(secret) });
}

function timeStep(totp: TOTP, code: unknown): number | null {
  if (typeof code !== 'string' || !/^\d{6}$/.test(code)) return null;
  const timestamp = Date.now();
  const offset = totp.validate({ token: code, timestamp, window: 1 });
  return offset === null ? null : Math.floor(timestamp / 30_000) + offset;
}

function normalizedPassword(value: unknown): string | null {
  if (typeof value !== 'string' || value.length > 256) return null;
  const normalized = value.normalize('NFC');
  const size = [...normalized].length;
  return size >= 15 && size <= 128 ? normalized : null;
}

export class AccountFactors {
  private readonly store: Store;
  private readonly accounts: Accounts;
  private readonly sealer: Sealer;
  private readonly pepper: Buffer;
  private readonly passkeys?: PasskeyConfig;
  private readonly passwordAttempts = new RateLimiter(12, 15 * 60_000);
  private readonly dummySalt = randomBytes(16).toString('base64url');
  private passwordWork = 0;

  constructor(store: Store, accounts: Accounts, sealer: Sealer, pepper: Buffer, passkeys?: PasskeyConfig) {
    this.store = store;
    this.accounts = accounts;
    this.sealer = sealer;
    this.pepper = pepper;
    this.passkeys = passkeys;
  }

  status(user: UserRecord) {
    return {
      totpEnabled: !!user.security?.totp,
      passwordEnabled: !!user.security?.password,
      passkeysEnabled: !!this.passkeys,
      passkeys: (user.security?.passkeys ?? []).map(({ id, createdAt }) => ({ id, createdAt })),
    };
  }

  private async recent(claims: AccessClaims) {
    const { session, user } = await this.accounts.requireSession(claims);
    if (!(Date.now() - Date.parse(session.createdAt) < RECENT_SIGN_IN_MS)) {
      throw new AuthError(403, 'recent_sign_in_required');
    }
    return user;
  }

  private async newChallenge(kind: AuthChallenge['kind'], user?: UserRecord, sessionId?: string, value?: string) {
    const id = crypto.randomUUID();
    await this.store.putAuthChallenge({
      id, kind, userId: user?.id, sessionId, value, epoch: user ? user.security?.epoch ?? 0 : undefined,
      expiresAt: Date.now() + CHALLENGE_TTL_S * 1000, attempts: 0,
    });
    return id;
  }

  private async take(id: unknown, kind: AuthChallenge['kind'], sessionId?: string) {
    const challenge = await this.store.takeAuthChallenge(challengeID(id), kind, Date.now(), sessionId);
    if (!challenge) throw new AuthError(401, 'challenge_invalid_or_expired');
    return challenge;
  }

  private async attempt(id: unknown, kind: AuthChallenge['kind'], sessionId?: string) {
    const challenge = await this.store.attemptAuthChallenge(challengeID(id), kind, Date.now(), sessionId);
    if (!challenge) throw new AuthError(401, 'challenge_invalid_or_expired');
    return challenge;
  }

  private async save(user: UserRecord, security: AccountSecurity): Promise<UserRecord> {
    const current = user.security?.revision ?? 0;
    const next = { ...security, revision: current + 1 };
    if (!await this.store.saveSecurity(user.id, current, next)) throw new AuthError(409, 'security_changed');
    return { ...user, security: next };
  }

  private hashRecovery(userId: string, code: string) {
    return createHmac('sha256', this.pepper).update('recovery:').update(userId).update(':').update(code).digest('hex');
  }

  private async hashPassword(password: string, salt: string) {
    if (this.passwordWork >= MAX_PASSWORD_WORK) throw new AuthError(429, 'rate_limited');
    this.passwordWork++;
    try {
      const input = createHmac('sha256', this.pepper).update('password:v1:').update(password).digest();
      return await new Promise<string>((resolve, reject) => {
        scrypt(input, Buffer.from(salt, 'base64url'), 32, PASSWORD_COST, (error, key) => {
          if (error) reject(error);
          else resolve(key.toString('base64url'));
        });
      });
    } finally { this.passwordWork--; }
  }

  async setPassword(claims: AccessClaims, rawPassword: unknown) {
    const user = await this.recent(claims);
    const password = normalizedPassword(rawPassword);
    if (!password) throw new AuthError(400, 'password_length');
    const comparable = password.toLowerCase().replace(/[\s!._-]/g, '');
    const email = user.email.replace(/[\s!._-]/g, '');
    if (!comparable || comparable === email || comparable === email.split('@')[0]
      || /^(.)\1+$|^(?:password|cardledger|1234567890|qwerty)+$/u.test(comparable)) {
      throw new AuthError(400, 'password_weak');
    }
    const salt = randomBytes(16).toString('base64url');
    const hash = await this.hashPassword(password, salt);
    const security = user.security ?? emptySecurity();
    const updated = await this.save(user, { ...security, epoch: security.epoch + 1, password: { salt, hash, version: 1 } });
    return this.accounts.openSession(updated);
  }

  async verifyPassword(rawEmail: unknown, rawPassword: unknown) {
    const email = normalizeEmail(rawEmail);
    const password = normalizedPassword(rawPassword);
    if (!password) throw new AuthError(401, 'password_invalid');
    const emailKey = this.accounts.emailKey(email);
    if (!this.passwordAttempts.allow(emailKey)) throw new AuthError(429, 'rate_limited');
    const userId = await this.store.findUserIdByEmailKey(emailKey);
    const user = userId ? await this.store.getUser(userId) : null;
    const stored = user?.security?.password;
    const hash = await this.hashPassword(password, stored?.salt ?? this.dummySalt);
    if (!user || !stored || !safeEqual(hash, stored.hash)) throw new AuthError(401, 'password_invalid');
    return this.accounts.completeFirstFactor(user);
  }

  async removePassword(claims: AccessClaims) {
    const user = await this.recent(claims);
    const security = user.security;
    if (!security?.password) throw new AuthError(404, 'password_not_enabled');
    const next = { ...security, epoch: security.epoch + 1 };
    delete next.password;
    return this.accounts.openSession(await this.save(user, next));
  }

  async startTOTP(claims: AccessClaims) {
    const user = await this.recent(claims);
    if (user.security?.totp) throw new AuthError(409, 'totp_already_enabled');
    const secret = new Secret({ size: 20 }).base32;
    const sealed = await this.sealer.seal(secret, secretContext(user.id));
    const id = await this.newChallenge('totp-setup', user, claims.sid, sealed);
    return { id, expiresIn: CHALLENGE_TTL_S, secret, uri: authenticator(secret, user.email).toString() };
  }

  async enableTOTP(claims: AccessClaims, id: unknown, code: unknown) {
    const user = await this.recent(claims);
    const security = user.security ?? emptySecurity();
    if (security.totp) throw new AuthError(409, 'totp_already_enabled');
    const challenge = await this.attempt(id, 'totp-setup', claims.sid);
    if (challenge.userId !== user.id || challenge.epoch !== security.epoch || !challenge.value) {
      throw new AuthError(401, 'challenge_invalid_or_expired');
    }
    const step = timeStep(authenticator(await this.sealer.open(challenge.value, secretContext(user.id)), user.email), code);
    if (step === null) throw new AuthError(401, 'totp_invalid');
    await this.take(id, 'totp-setup', claims.sid);
    const rawCodes = Array.from({ length: 10 }, () => randomBytes(8).toString('hex'));
    const updated = await this.save(user, {
      ...security, epoch: security.epoch + 1,
      totp: { sealedSecret: challenge.value, lastStep: step, recoveryHashes: rawCodes.map((c) => this.hashRecovery(user.id, c)) },
    });
    return { tokens: await this.accounts.openSession(updated),
             recoveryCodes: rawCodes.map((c) => c.match(/.{4}/g)!.join('-').toUpperCase()) };
  }

  async verifySecondFactor(id: unknown, code: unknown) {
    const challenge = await this.attempt(id, 'totp-login');
    const user = challenge.userId ? await this.store.getUser(challenge.userId) : null;
    const security = user?.security;
    const factor = security?.totp;
    if (!user || !security || !factor || security.epoch !== challenge.epoch) {
      throw new AuthError(401, 'challenge_invalid_or_expired');
    }
    const candidate = typeof code === 'string' ? code.replace(/[\s-]/g, '').toLowerCase() : '';
    const next = { ...factor };
    if (/^[0-9a-f]{16}$/.test(candidate)) {
      const hash = this.hashRecovery(user.id, candidate);
      const index = factor.recoveryHashes.findIndex((stored) => safeEqual(stored, hash));
      if (index < 0) throw new AuthError(401, 'totp_invalid');
      next.recoveryHashes = factor.recoveryHashes.filter((_, i) => i !== index);
    } else {
      const step = timeStep(authenticator(await this.sealer.open(factor.sealedSecret, secretContext(user.id)), user.email), candidate);
      if (step === null || step <= factor.lastStep) throw new AuthError(401, 'totp_invalid');
      next.lastStep = step;
    }
    await this.take(id, 'totp-login');
    const updated = await this.save(user, { ...security, totp: next });
    return this.accounts.openSession(updated);
  }

  async disableTOTP(claims: AccessClaims) {
    const user = await this.recent(claims);
    const security = user.security;
    if (!security?.totp) throw new AuthError(404, 'totp_not_enabled');
    const next = { ...security, epoch: security.epoch + 1 };
    delete next.totp;
    const updated = await this.save(user, next);
    return this.accounts.openSession(updated);
  }

  private passkeyConfig() {
    if (!this.passkeys) throw new AuthError(404, 'passkeys_unavailable');
    return this.passkeys;
  }

  async startPasskeyRegistration(claims: AccessClaims) {
    const { rpID } = this.passkeyConfig();
    const user = await this.recent(claims);
    const passkeys = user.security?.passkeys ?? [];
    if (passkeys.length >= MAX_PASSKEYS) throw new AuthError(409, 'passkey_limit');
    const options = await generateRegistrationOptions({
      rpID, rpName: 'Card Ledger', userID: Buffer.from(user.id), userName: user.email,
      timeout: CHALLENGE_TTL_S * 1000, attestationType: 'none', supportedAlgorithmIDs: [-7],
      authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
      excludeCredentials: passkeys.map(({ id }) => ({ id })),
    });
    const id = await this.newChallenge('passkey-register', user, claims.sid, options.challenge);
    return { id, rpID, challenge: options.challenge, userID: options.user.id, name: user.email,
             excludedCredentialIDs: passkeys.map(({ id }) => id) };
  }

  async registerPasskey(claims: AccessClaims, id: unknown, response: unknown) {
    const { rpID, origin } = this.passkeyConfig();
    const user = await this.recent(claims);
    const security = user.security ?? emptySecurity();
    const challenge = await this.take(id, 'passkey-register', claims.sid);
    if (challenge.userId !== user.id || challenge.epoch !== security.epoch || !challenge.value) {
      throw new AuthError(401, 'challenge_invalid_or_expired');
    }
    if (security.passkeys.length >= MAX_PASSKEYS) throw new AuthError(409, 'passkey_limit');
    let result: Awaited<ReturnType<typeof verifyRegistrationResponse>>;
    try {
      result = await verifyRegistrationResponse({
        response: response as RegistrationResponseJSON,
        expectedChallenge: challenge.value, expectedOrigin: origin, expectedRPID: rpID,
        requireUserVerification: true, supportedAlgorithmIDs: [-7],
      });
    } catch { throw new AuthError(401, 'passkey_invalid'); }
    if (!result.verified || !result.registrationInfo) throw new AuthError(401, 'passkey_invalid');
    const credential = result.registrationInfo.credential;
    if (security.passkeys.some((p) => p.id === credential.id)) throw new AuthError(409, 'passkey_already_registered');
    return this.status(await this.save(user, { ...security, passkeys: [...security.passkeys, {
      id: credential.id, counter: credential.counter, publicKey: Buffer.from(credential.publicKey).toString('base64url'),
      createdAt: new Date().toISOString(),
    }] }));
  }

  async startPasskeySignIn() {
    const { rpID } = this.passkeyConfig();
    const options = await generateAuthenticationOptions({ rpID, userVerification: 'required', timeout: CHALLENGE_TTL_S * 1000 });
    const id = await this.newChallenge('passkey-login', undefined, undefined, options.challenge);
    return { id, rpID, challenge: options.challenge };
  }

  async verifyPasskey(id: unknown, raw: unknown) {
    const { rpID, origin } = this.passkeyConfig();
    const challenge = await this.take(id, 'passkey-login');
    const response = raw as AuthenticationResponseJSON | undefined;
    const handle = response?.response?.userHandle;
    if (typeof handle !== 'string' || !/^[A-Za-z0-9_-]{48}$/.test(handle) || !challenge.value) {
      throw new AuthError(401, 'passkey_invalid');
    }
    const userId = Buffer.from(handle, 'base64url').toString('utf8');
    const user = uuid.test(userId) ? await this.store.getUser(userId) : null;
    const security = user?.security;
    const key = security?.passkeys.find((p) => p.id === response?.id);
    if (!user || !security || !key || !response) throw new AuthError(401, 'passkey_invalid');
    let result: Awaited<ReturnType<typeof verifyAuthenticationResponse>>;
    try {
      result = await verifyAuthenticationResponse({
        response, expectedChallenge: challenge.value, expectedOrigin: origin, expectedRPID: rpID,
        requireUserVerification: true,
        credential: { id: key.id, counter: key.counter, publicKey: Buffer.from(key.publicKey, 'base64url') },
      });
    } catch { throw new AuthError(401, 'passkey_invalid'); }
    if (!result.verified) throw new AuthError(401, 'passkey_invalid');
    const counter = result.authenticationInfo.newCounter;
    const current = counter === key.counter ? user : await this.save(user, {
      ...security, passkeys: security.passkeys.map((p) => p.id === key.id ? { ...p, counter } : p),
    });
    return this.accounts.openSession(current);
  }

  async removePasskey(claims: AccessClaims, id: string) {
    const user = await this.recent(claims);
    const security = user.security;
    if (!security?.passkeys.some((p) => p.id === id)) throw new AuthError(404, 'passkey_not_found');
    const updated = await this.save(user, {
      ...security, epoch: security.epoch + 1, passkeys: security.passkeys.filter((p) => p.id !== id),
    });
    return this.accounts.openSession(updated);
  }
}
