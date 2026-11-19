import { createHash, randomBytes, randomInt, randomUUID, timingSafeEqual } from 'node:crypto';
import type { Vault, Device } from './vault.ts';

const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // no 0/O/1/I/L
const CODE_TTL_MS = 10 * 60_000;
const MAX_CODE_ATTEMPTS = 5;

export function sha256(s: string): string {
  return createHash('sha256').update(s).digest('hex');
}

function safeEqualHex(a: string, b: string): boolean {
  const x = Buffer.from(a, 'hex');
  const y = Buffer.from(b, 'hex');
  return x.length === y.length && timingSafeEqual(x, y);
}

/** Short-lived, single-use pairing code. Only its hash is stored. */
export function issuePairingCode(vault: Vault): { code: string; expiresAt: string } {
  const code = Array.from({ length: 8 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join('');
  const expiresAt = new Date(Date.now() + CODE_TTL_MS).toISOString();
  vault.update((d) => { d.pairing = { codeHash: sha256(code), expiresAt, attempts: 0 }; });
  return { code: `${code.slice(0, 4)}-${code.slice(4)}`, expiresAt };
}

export type PairResult =
  | { ok: true; deviceId: string; credential: string }
  | { ok: false; reason: 'no_code' | 'expired' | 'invalid' | 'locked' };

export function redeemPairingCode(vault: Vault, rawCode: string, deviceName: string): PairResult {
  const code = rawCode.toUpperCase().replace(/[^A-Z0-9]/g, '');
  return vault.update((d): PairResult => {
    const p = d.pairing;
    if (!p) return { ok: false, reason: 'no_code' };
    if (Date.parse(p.expiresAt) < Date.now()) { d.pairing = undefined; return { ok: false, reason: 'expired' }; }
    if (p.attempts >= MAX_CODE_ATTEMPTS) { d.pairing = undefined; return { ok: false, reason: 'locked' }; }
    if (!safeEqualHex(sha256(code), p.codeHash)) {
      p.attempts += 1;
      if (p.attempts >= MAX_CODE_ATTEMPTS) { d.pairing = undefined; return { ok: false, reason: 'locked' }; }
      return { ok: false, reason: 'invalid' };
    }
    d.pairing = undefined; // single use
    const credential = randomBytes(32).toString('base64url');
    const cleanName = deviceName.replace(/[\r\n\x00-\x1f\x7f]/g, ' ').trim().slice(0, 60) || 'iPhone';
    const device: Device = {
      id: randomUUID(), name: cleanName,
      verifier: sha256(credential), createdAt: new Date().toISOString(),
    };
    d.devices.push(device);
    return { ok: true, deviceId: device.id, credential };
  });
}

/** Authorization: Bearer <deviceId>.<credential> */
export function authenticate(vault: Vault, header: string | undefined): Device | null {
  const m = /^Bearer ([0-9a-f-]{36})\.([A-Za-z0-9_-]{20,})$/.exec(header ?? '');
  if (!m) return null;
  const device = vault.read().devices.find((x) => x.id === m[1] && !x.revokedAt);
  if (!device) return null;
  return safeEqualHex(sha256(m[2]), device.verifier) ? device : null;
}

/** Fixed-window limiter keyed by client address, with periodic pruning of expired entries. */
export class RateLimiter {
  private readonly hits = new Map<string, { n: number; reset: number }>();
  private readonly limit: number;
  private readonly windowMs: number;
  private nextPrune = 0;
  constructor(limit: number, windowMs: number) { this.limit = limit; this.windowMs = windowMs; }

  allow(key: string): boolean {
    const now = Date.now();
    if (now >= this.nextPrune) {
      for (const [k, v] of this.hits) { if (v.reset < now) this.hits.delete(k); }
      this.nextPrune = now + this.windowMs;
    }
    const h = this.hits.get(key);
    if (!h || h.reset < now) { this.hits.set(key, { n: 1, reset: now + this.windowMs }); return true; }
    h.n += 1;
    return h.n <= this.limit;
  }
}
