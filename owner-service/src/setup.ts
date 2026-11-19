import { existsSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { resolve } from 'node:path';
import { projectRoot } from './config.ts';

/**
 * Creates or completes .env (mode 0600) for local development: random JWT_SECRET, CODE_PEPPER and
 * LOCAL_SEAL_KEY. Never overwrites an existing value. Production reads these from SSM instead.
 */
const path = resolve(projectRoot, '.env');
let text = existsSync(path) ? readFileSync(path, 'utf8') : [
  '# Card Ledger API, local development. Keep this file private (chmod 600).',
  '# mock | sandbox | production',
  'PLAID_ENV=mock',
  'PLAID_CLIENT_ID=',
  'PLAID_SANDBOX_SECRET=',
  'PLAID_PRODUCTION_SECRET=',
  'HOST=127.0.0.1',
  'PORT=8787',
  '',
].join('\n');

const added: string[] = [];
for (const name of ['JWT_SECRET', 'CODE_PEPPER', 'LOCAL_SEAL_KEY']) {
  if (new RegExp(`^${name}=\\S+`, 'm').test(text)) continue;
  const line = `${name}=${randomBytes(32).toString('base64')}`;
  if (new RegExp(`^${name}=[ \\t]*$`, 'm').test(text)) text = text.replace(new RegExp(`^${name}=[ \\t]*$`, 'm'), line);
  else { if (!text.endsWith('\n')) text += '\n'; text += `${line}\n`; }
  added.push(name);
}
writeFileSync(path, text, { mode: 0o600 });
chmodSync(path, 0o600);
console.log(added.length ? `Added ${added.join(', ')} to .env.` : '.env already has every local secret; nothing changed.');
