import { createHash } from 'node:crypto';

export function sha256(s: string): string {
  return createHash('sha256').update(s).digest('hex');
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
