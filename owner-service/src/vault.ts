import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, mkdirSync, existsSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import type { PlaidEnv } from './config.ts';

export interface Device {
  id: string;
  name: string;
  /** SHA-256 of the device credential; the credential itself is never stored. */
  verifier: string;
  createdAt: string;
  revokedAt?: string;
}

export interface Pairing {
  codeHash: string;
  expiresAt: string;
  attempts: number;
}

export interface LinkedAccount {
  id: string;
  name: string;
  officialName: string | null;
  mask: string | null;
  type: string;
  subtype: string | null;
  currency: string | null;
}

export type ConnectionStatus = 'active' | 'login_required' | 'disconnect_pending' | 'disconnected';

export interface Connection {
  id: string;
  itemId: string;
  /** Plaid Item access token. Removed after a successful disconnect. */
  accessToken?: string;
  institutionId: string | null;
  institutionName: string | null;
  country: 'US' | 'CA';
  accounts: LinkedAccount[];
  clientRequestId: string;
  status: ConnectionStatus;
  createdAt: string;
  lastSuccessfulPull?: string;
}

export interface VaultData {
  version: 1;
  env: PlaidEnv;
  devices: Device[];
  pairing?: Pairing;
  connections: Connection[];
}

/**
 * Host-protected storage: one AES-256-GCM encrypted file per Plaid environment, mode 0600.
 * The key lives in .env (also 0600), so a copied data directory alone reveals nothing.
 */
export class Vault {
  private readonly path: string;
  private readonly key: Buffer;
  private readonly env: PlaidEnv;

  constructor(dataDir: string, env: PlaidEnv, key: Buffer) {
    mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    this.path = join(dataDir, `vault.${env}.bin`);
    this.key = key;
    this.env = env;
  }

  read(): VaultData {
    if (!existsSync(this.path)) return { version: 1, env: this.env, devices: [], connections: [] };
    const blob = readFileSync(this.path);
    const iv = blob.subarray(0, 12);
    const tag = blob.subarray(12, 28);
    const body = blob.subarray(28);
    const decipher = createDecipheriv('aes-256-gcm', this.key, iv);
    decipher.setAAD(Buffer.from(`card-ledger-vault:${this.env}`));
    decipher.setAuthTag(tag);
    const json = Buffer.concat([decipher.update(body), decipher.final()]).toString('utf8');
    const data = JSON.parse(json) as VaultData;
    if (data.env !== this.env) throw new Error('Vault environment mismatch');
    return data;
  }

  write(data: VaultData): void {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    cipher.setAAD(Buffer.from(`card-ledger-vault:${this.env}`));
    const body = Buffer.concat([cipher.update(JSON.stringify(data), 'utf8'), cipher.final()]);
    const tmp = `${this.path}.tmp`;
    writeFileSync(tmp, Buffer.concat([iv, cipher.getAuthTag(), body]), { mode: 0o600 });
    renameSync(tmp, this.path);
    chmodSync(this.path, 0o600);
  }

  /** Read-modify-write. Node is single-threaded, so synchronous updates are serialized. */
  update<T>(fn: (data: VaultData) => T): T {
    const data = this.read();
    const result = fn(data);
    this.write(data);
    return result;
  }
}
