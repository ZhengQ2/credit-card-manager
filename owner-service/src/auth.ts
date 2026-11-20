import { createHash } from 'node:crypto';

export function sha256(s: string): string {
  return createHash('sha256').update(s).digest('hex');
}

/**
 * Resolves the client IP for rate limiting. Behind a single trusted reverse proxy on loopback
 * (Caddy, nginx, or an ALB), the proxy appends the real peer address to the right of X-Forwarded-For,
 * so reading the rightmost entry prevents clients from spoofing the leftmost entry.
 */
export function extractClientIp(
  remoteAddress: string | undefined,
  forwardedFor: string | string[] | undefined,
  trustProxy: boolean,
): string {
  const remote = remoteAddress ?? 'unknown';
  if (trustProxy && (remote === '127.0.0.1' || remote === '::1' || remote === '::ffff:127.0.0.1')) {
    const raw = Array.isArray(forwardedFor) ? forwardedFor.join(',') : (forwardedFor ?? '');
    const hops = raw.split(',').map((s) => s.trim()).filter(Boolean);
    if (hops.length) return hops[hops.length - 1];
  }
  return remote;
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
