import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SSMClient, GetParametersByPathCommand } from '@aws-sdk/client-ssm';
import type { PasskeyConfig } from './accountFactors.ts';

export type PlaidEnv = 'mock' | 'sandbox' | 'production';

export interface Config {
  env: PlaidEnv;
  clientId: string;
  secret: string;
  host: string;
  port: number;
  redirectUri: string | undefined;
  mockMutation: boolean;
  billAlerts: boolean;
  /** `memory` for tests and mock mode; `dynamo` for anything that must survive a restart. */
  store: 'memory' | 'dynamo';
  awsRegion: string;
  tableName: string;
  /** KMS key ARN or alias for sealing Plaid tokens and authenticator seeds. */
  kmsKeyId: string | undefined;
  localSealKey: Buffer | undefined;
  mailer: 'console' | 'ses';
  mailFrom: string;
  jwtSecret: Buffer;
  codePepper: Buffer;
  /** Public HTTPS origin (e.g. https://api.example.com). Enables Plaid webhooks. */
  publicUrl: string | undefined;
  passkeys?: PasskeyConfig;
  /** Trust X-Forwarded-For from a reverse proxy on loopback (Caddy). */
  trustProxy: boolean;
  /** Only for importing a pre-accounts vault file. */
  legacyVaultKey: Buffer | undefined;
  dataDir: string;
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/** Minimal .env reader: KEY=value lines, no interpolation. Values are never logged. */
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

/** Secrets from SSM Parameter Store (SecureString), e.g. /card-ledger/prod/PLAID_SECRET. */
async function loadSsm(path: string, region: string): Promise<Record<string, string>> {
  const ssm = new SSMClient({ region });
  const out: Record<string, string> = {};
  let token: string | undefined;
  do {
    const r = await ssm.send(new GetParametersByPathCommand({ Path: path, WithDecryption: true, Recursive: false, NextToken: token }));
    for (const p of r.Parameters ?? []) {
      const name = p.Name?.split('/').pop();
      if (name && p.Value !== undefined) out[name] = p.Value;
    }
    token = r.NextToken;
  } while (token);
  return out;
}

function key(name: string, b64: string, min = 32): Buffer {
  const k = Buffer.from(b64, 'base64');
  if (k.length < min) throw new Error(`${name} must be at least ${min} bytes, base64-encoded. Run \`npm run setup\`.`);
  return k;
}

export async function loadConfig(): Promise<Config> {
  const file = loadDotEnv(resolve(root, '.env'));
  const early = (k: string, d = '') => process.env[k] || file[k] || d;
  const awsRegion = early('AWS_REGION', 'ca-central-1');
  const ssmPath = early('SSM_PARAMETER_PATH');
  const ssm = ssmPath ? await loadSsm(ssmPath, awsRegion) : {};
  // Precedence: process environment, then SSM, then .env. Empty values count as unset.
  const get = (k: string, d = '') => process.env[k] || ssm[k] || file[k] || d;

  const env = get('PLAID_ENV', 'mock') as PlaidEnv;
  if (!['mock', 'sandbox', 'production'].includes(env)) throw new Error('PLAID_ENV must be mock, sandbox or production');

  // Credentials are environment-specific so Sandbox and Production never share keys.
  const prefix = env === 'production' ? 'PLAID_PRODUCTION' : 'PLAID_SANDBOX';
  const clientId = get('PLAID_CLIENT_ID') || get(`${prefix}_CLIENT_ID`);
  const secret = get('PLAID_SECRET') || get(`${prefix}_SECRET`);
  if (env !== 'mock' && (!clientId || !secret)) throw new Error(`PLAID_CLIENT_ID and the ${env} secret are required.`);

  const port = Number(get('PORT', '8787'));
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be an integer between 1 and 65535.');

  const store = get('STORE', env === 'mock' ? 'memory' : 'dynamo') as Config['store'];
  if (store !== 'memory' && store !== 'dynamo') throw new Error('STORE must be memory or dynamo');
  const mailer = get('MAILER', env === 'mock' ? 'console' : 'ses') as Config['mailer'];
  if (mailer !== 'console' && mailer !== 'ses') throw new Error('MAILER must be console or ses');
  // The console mailer prints sign-in codes; anything holding real bank data must email them.
  if (mailer === 'console' && env !== 'mock') throw new Error('MAILER=console is only allowed with PLAID_ENV=mock');

  const kmsKeyId = get('KMS_KEY_ID') || undefined;
  const localSealKeyB64 = get('LOCAL_SEAL_KEY');
  if (env === 'production' && (!kmsKeyId || store !== 'dynamo')) {
    throw new Error('Production requires STORE=dynamo and KMS_KEY_ID.');
  }
  if (!kmsKeyId && !localSealKeyB64) throw new Error('Set KMS_KEY_ID, or LOCAL_SEAL_KEY for local development.');

  const publicUrl = get('PUBLIC_URL') || undefined;
  if (publicUrl && !/^https:\/\/[a-z0-9.-]+(:\d+)?$/i.test(publicUrl)) throw new Error('PUBLIC_URL must be an https origin with no path');
  const rpID = get('PASSKEY_RP_ID').toLowerCase();
  const appID = get('PASSKEY_APP_ID');
  let passkeys: PasskeyConfig | undefined;
  if (rpID || appID) {
    if (!publicUrl || new URL(publicUrl).hostname !== rpID || !/^[a-z0-9-]+(?:\.[a-z0-9-]+)+$/.test(rpID)
      || !/^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$/.test(appID)) {
      throw new Error('Passkeys need PASSKEY_RP_ID matching the PUBLIC_URL host and PASSKEY_APP_ID (app prefix plus bundle ID).');
    }
    passkeys = { rpID, appID, origin: new URL(publicUrl).origin };
  }

  const jwt = get('JWT_SECRET');
  const pepper = get('CODE_PEPPER');
  if (!jwt || !pepper) throw new Error('JWT_SECRET and CODE_PEPPER are required. Run `npm run setup`.');
  const legacy = get('VAULT_KEY');

  return {
    env, clientId, secret,
    host: get('HOST', '127.0.0.1'),
    port,
    redirectUri: get('PLAID_REDIRECT_URI') || undefined,
    mockMutation: get('MOCK_MUTATION') === '1',
    billAlerts: get('PLAID_BILL_ALERTS', env === 'mock' ? '1' : '0') === '1',
    store, awsRegion,
    tableName: get('TABLE_NAME', 'card-ledger'),
    kmsKeyId,
    localSealKey: localSealKeyB64 ? key('LOCAL_SEAL_KEY', localSealKeyB64) : undefined,
    mailer,
    mailFrom: get('MAIL_FROM', 'Card Ledger <no-reply@localhost>'),
    jwtSecret: key('JWT_SECRET', jwt),
    codePepper: key('CODE_PEPPER', pepper),
    publicUrl, passkeys,
    trustProxy: get('TRUST_PROXY') === '1',
    legacyVaultKey: legacy ? key('VAULT_KEY', legacy) : undefined,
    dataDir: resolve(root, get('DATA_DIR', 'data')),
  };
}

export const projectRoot = root;
