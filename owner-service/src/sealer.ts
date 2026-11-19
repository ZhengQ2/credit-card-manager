import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { KMSClient, EncryptCommand, DecryptCommand } from '@aws-sdk/client-kms';

/**
 * Seals secrets (Plaid access tokens) at the application layer. The encryption context binds each
 * ciphertext to its owner and record, so a sealed token copied onto another user's record won't open.
 */
export interface Sealer {
  seal(plaintext: string, context: Record<string, string>): Promise<string>;
  open(sealed: string, context: Record<string, string>): Promise<string>;
}

function aad(context: Record<string, string>): Buffer {
  return Buffer.from(JSON.stringify(Object.keys(context).sort().map((k) => [k, context[k]])));
}

/** AES-256-GCM with a local key. For tests, mock mode and local development only. */
export class LocalSealer implements Sealer {
  private readonly key: Buffer;
  constructor(key: Buffer) {
    if (key.length !== 32) throw new Error('Local seal key must be 32 bytes');
    this.key = key;
  }

  async seal(plaintext: string, context: Record<string, string>) {
    const iv = randomBytes(12);
    const c = createCipheriv('aes-256-gcm', this.key, iv);
    c.setAAD(aad(context));
    const body = Buffer.concat([c.update(plaintext, 'utf8'), c.final()]);
    return `l1:${Buffer.concat([iv, c.getAuthTag(), body]).toString('base64')}`;
  }

  async open(sealed: string, context: Record<string, string>) {
    if (!sealed.startsWith('l1:')) throw new Error('Not a locally sealed value');
    const blob = Buffer.from(sealed.slice(3), 'base64');
    const d = createDecipheriv('aes-256-gcm', this.key, blob.subarray(0, 12));
    d.setAAD(aad(context));
    d.setAuthTag(blob.subarray(12, 28));
    return Buffer.concat([d.update(blob.subarray(28)), d.final()]).toString('utf8');
  }
}

/**
 * AWS KMS. Tokens are well under KMS's 4 KB direct-encryption limit, so each is encrypted by the key itself:
 * the plaintext key never leaves KMS, every decrypt is logged in CloudTrail, and access is controlled by IAM.
 */
export class KmsSealer implements Sealer {
  private readonly kms: KMSClient;
  private readonly keyId: string;
  constructor(keyId: string, region: string) {
    this.keyId = keyId;
    this.kms = new KMSClient({ region });
  }

  async seal(plaintext: string, context: Record<string, string>) {
    const r = await this.kms.send(new EncryptCommand({
      KeyId: this.keyId, Plaintext: Buffer.from(plaintext, 'utf8'), EncryptionContext: context,
    }));
    return `k1:${Buffer.from(r.CiphertextBlob!).toString('base64')}`;
  }

  async open(sealed: string, context: Record<string, string>) {
    if (!sealed.startsWith('k1:')) throw new Error('Not a KMS sealed value');
    const r = await this.kms.send(new DecryptCommand({
      KeyId: this.keyId, CiphertextBlob: Buffer.from(sealed.slice(3), 'base64'), EncryptionContext: context,
    }));
    return Buffer.from(r.Plaintext!).toString('utf8');
  }
}
