import { existsSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { resolve } from 'node:path';
import { projectRoot } from './config.ts';

/** Creates .env (mode 0600) with a fresh vault key. Never overwrites an existing key. */
const path = resolve(projectRoot, '.env');
let text = existsSync(path) ? readFileSync(path, 'utf8') : '';

if (/^VAULT_KEY=/m.test(text)) {
  console.log('.env already has VAULT_KEY; leaving it unchanged.');
} else {
  if (!text) {
    text = [
      '# Card Ledger owner service. Keep this file private (chmod 600).',
      '# mock | sandbox | production',
      'PLAID_ENV=mock',
      'PLAID_CLIENT_ID=',
      'PLAID_SANDBOX_SECRET=',
      'PLAID_PRODUCTION_SECRET=',
      '# Bind to the LAN/VPN interface only; 127.0.0.1 for simulator testing.',
      'HOST=127.0.0.1',
      'PORT=8787',
      '# Exact OAuth redirect registered with Plaid (https, Universal Link). Optional for non-OAuth banks.',
      'PLAID_REDIRECT_URI=',
      '',
    ].join('\n');
  }
  text += `VAULT_KEY=${randomBytes(32).toString('base64')}\n`;
  writeFileSync(path, text, { mode: 0o600 });
  console.log('Created .env with a new VAULT_KEY.');
}
chmodSync(path, 0o600);
