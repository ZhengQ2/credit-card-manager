import { createHash, createPublicKey, timingSafeEqual, verify } from 'node:crypto';

/** Resolves Plaid's webhook verification key by key ID (`/webhook_verification_key/get`). */
export type KeyResolver = (kid: string) => Promise<JsonWebKey & { expired_at?: number | null }>;

const MAX_AGE_S = 5 * 60;

/**
 * Verifies the `Plaid-Verification` header: an ES256 JWT whose payload carries the SHA-256 of the raw
 * request body and an issued-at time. Rejects anything else, so forged webhooks can't change state.
 * See https://plaid.com/docs/api/webhooks/webhook-verification/
 */
export class WebhookVerifier {
  private readonly resolve: KeyResolver;
  private readonly cache = new Map<string, { key: JsonWebKey & { expired_at?: number | null }; fetched: number }>();

  constructor(resolve: KeyResolver) { this.resolve = resolve; }

  async verify(header: string | undefined, rawBody: Buffer, now = Math.floor(Date.now() / 1000)): Promise<boolean> {
    const parts = (header ?? '').split('.');
    if (parts.length !== 3) return false;
    let jwtHeader: { alg?: string; kid?: string };
    let payload: { iat?: number; request_body_sha256?: string };
    try {
      jwtHeader = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
      payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    } catch { return false; }
    if (jwtHeader.alg !== 'ES256' || typeof jwtHeader.kid !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(jwtHeader.kid)) return false;

    const jwk = await this.key(jwtHeader.kid);
    if (!jwk || (jwk.expired_at != null && jwk.expired_at < now)) return false;
    let ok = false;
    try {
      const { expired_at: _e, ...pub } = jwk as JsonWebKey & { expired_at?: unknown; created_at?: unknown };
      delete (pub as Record<string, unknown>).created_at;
      ok = verify('sha256', Buffer.from(`${parts[0]}.${parts[1]}`),
        { key: createPublicKey({ key: pub, format: 'jwk' }), dsaEncoding: 'ieee-p1363' },
        Buffer.from(parts[2], 'base64url'));
    } catch { return false; }
    if (!ok) return false;
    if (typeof payload.iat !== 'number' || now - payload.iat > MAX_AGE_S || payload.iat - now > 60) return false;
    const digest = createHash('sha256').update(rawBody).digest('hex');
    const claimed = String(payload.request_body_sha256 ?? '');
    return claimed.length === digest.length && timingSafeEqual(Buffer.from(claimed), Buffer.from(digest));
  }

  private async key(kid: string) {
    const hit = this.cache.get(kid);
    if (hit && Date.now() - hit.fetched < 24 * 3600_000) return hit.key;
    try {
      const key = await this.resolve(kid);
      this.cache.set(kid, { key, fetched: Date.now() });
      return key;
    } catch { return null; }
  }
}

export interface PlaidWebhook {
  webhook_type?: string;
  webhook_code?: string;
  item_id?: string;
  error?: { error_code?: string } | null;
}

export type WebhookEffect =
  | { kind: 'updates_available' }
  | { kind: 'login_required' }
  | { kind: 'repaired' }
  | { kind: 'revoked' }
  | { kind: 'ignore' };

/** Maps a verified Plaid webhook to the change it implies for the connection. */
export function webhookEffect(w: PlaidWebhook): WebhookEffect {
  const type = w.webhook_type ?? '';
  const code = w.webhook_code ?? '';
  if (type === 'TRANSACTIONS' && (code === 'SYNC_UPDATES_AVAILABLE' || code === 'DEFAULT_UPDATE' || code === 'HISTORICAL_UPDATE')) {
    return { kind: 'updates_available' };
  }
  if (type === 'ITEM') {
    if (code === 'ERROR' && w.error?.error_code === 'ITEM_LOGIN_REQUIRED') return { kind: 'login_required' };
    if (code === 'PENDING_EXPIRATION' || code === 'PENDING_DISCONNECT') return { kind: 'login_required' };
    if (code === 'LOGIN_REPAIRED') return { kind: 'repaired' };
    if (code === 'USER_PERMISSION_REVOKED' || code === 'USER_ACCOUNT_REVOKED') return { kind: 'revoked' };
  }
  return { kind: 'ignore' };
}
