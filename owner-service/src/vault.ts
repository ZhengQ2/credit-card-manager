import { createCipheriv, createDecipheriv, randomBytes, randomUUID } from 'node:crypto';
import {
  readFileSync, writeFileSync, renameSync, mkdirSync, existsSync, chmodSync,
  openSync, closeSync, fsyncSync, unlinkSync, statSync,
} from 'node:fs';
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
  private readonly lockPath: string;
  private readonly key: Buffer;
  private readonly env: PlaidEnv;

  constructor(dataDir: string, env: PlaidEnv, key: Buffer) {
    mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    chmodSync(dataDir, 0o700);
    this.path = join(dataDir, `vault.${env}.bin`);
    this.lockPath = `${this.path}.lock`;
    this.key = key;
    this.env = env;
  }

  private withFileLock<T>(fn: () => T): T {
    const deadline = Date.now() + 5_000;
    const waitBuf = new Int32Array(new SharedArrayBuffer(4));
    let acquired = false;
    while (!acquired) {
      try {
        const fd = openSync(this.lockPath, 'wx', 0o600);
        try { writeFileSync(fd, `${process.pid}\n`); } finally { closeSync(fd); }
        acquired = true;
      } catch (e) {
        const code = (e as NodeJS.ErrnoException).code;
        if (code !== 'EEXIST') throw e;
        try {
          if (Date.now() - statSync(this.lockPath).mtimeMs > 10_000) {
            unlinkSync(this.lockPath);
            continue;
          }
        } catch { /* lock disappeared */ continue; }
        if (Date.now() >= deadline) throw new Error('Timed out waiting for vault lock');
        Atomics.wait(waitBuf, 0, 0, 15);
      }
    }
    try { return fn(); }
    finally { try { unlinkSync(this.lockPath); } catch { /* ignore */ } }
  }

  read(): VaultData {
    if (!existsSync(this.path)) return { version: 1, env: this.env, devices: [], connections: [] };
    const blob = readFileSync(this.path);
    if (blob.length < 28) throw new Error('Vault file is truncated');
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

  private writeUnlocked(data: VaultData): void {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    cipher.setAAD(Buffer.from(`card-ledger-vault:${this.env}`));
    const body = Buffer.concat([cipher.update(JSON.stringify(data), 'utf8'), cipher.final()]);
    const tmp = `${this.path}.${process.pid}.${randomUUID()}.tmp`;
    const payload = Buffer.concat([iv, cipher.getAuthTag(), body]);
    try {
      const fd = openSync(tmp, 'wx', 0o600);
      try {
        writeFileSync(fd, payload);
        fsyncSync(fd);
      } finally {
        closeSync(fd);
      }
      renameSync(tmp, this.path);
      chmodSync(this.path, 0o600);
    } catch (e) {
      try { unlinkSync(tmp); } catch { /* ignore */ }
      throw e;
    }
  }

  write(data: VaultData): void {
    this.withFileLock(() => this.writeUnlocked(data));
  }

  /** Cross-process locked read-modify-write so `pair.ts` and `server.ts` never clobber each other. */
  update<T>(fn: (data: VaultData) => T): T {
    return this.withFileLock(() => {
      const data = this.read();
      const result = fn(data);
      this.writeUnlocked(data);
      return result;
    });
  }
}
