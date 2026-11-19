import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

export type PlaidEnv = 'mock' | 'sandbox' | 'production';

export interface Config {
  env: PlaidEnv;
  clientId: string;
  secret: string;
  host: string;
  port: number;
  dataDir: string;
  vaultKey: Buffer;
  redirectUri: string | undefined;
  mockMutation: boolean;
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/** Minimal .env reader: KEY=value lines, no interpolation. Values never logged. */
function loadDotEnv(path: string): Record<string, string> {
  if (!existsSync(path)) return {};
  const out: Record<string, string> = {};
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
    if (!m || line.trimStart().startsWith('#')) continue;
    out[m[1]] = m[2].replace(/^['"]|['"]$/g, '');
  }
  return out;
}

export function loadConfig(): Config {
  const file = loadDotEnv(resolve(root, '.env'));
  const get = (k: string, d = '') => process.env[k] ?? file[k] ?? d;

  const env = get('PLAID_ENV', 'mock') as PlaidEnv;
  if (!['mock', 'sandbox', 'production'].includes(env)) throw new Error(`PLAID_ENV must be mock, sandbox or production`);

  const keyB64 = get('VAULT_KEY');
  if (!keyB64) throw new Error('VAULT_KEY is missing. Run `npm run setup` first.');
  const vaultKey = Buffer.from(keyB64, 'base64');
  if (vaultKey.length !== 32) throw new Error('VAULT_KEY must be 32 bytes, base64-encoded.');

  // Credentials are environment-specific so Sandbox and Production never share storage or keys.
  const prefix = env === 'production' ? 'PLAID_PRODUCTION' : 'PLAID_SANDBOX';
  const clientId = get('PLAID_CLIENT_ID') || get(`${prefix}_CLIENT_ID`);
  const secret = get(`${prefix}_SECRET`);
  if (env !== 'mock' && (!clientId || !secret)) {
    throw new Error(`PLAID_CLIENT_ID and ${prefix}_SECRET are required when PLAID_ENV=${env}.`);
  }

  return {
    env,
    clientId,
    secret,
    host: get('HOST', '127.0.0.1'),
    port: Number(get('PORT', '8787')),
    dataDir: resolve(root, get('DATA_DIR', 'data')),
    vaultKey,
    redirectUri: get('PLAID_REDIRECT_URI') || undefined,
    mockMutation: get('MOCK_MUTATION') === '1',
  };
}

export const projectRoot = root;
