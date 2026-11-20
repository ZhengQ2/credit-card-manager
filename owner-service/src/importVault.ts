import { existsSync } from 'node:fs';
import { loadConfig } from './config.ts';
import { Vault } from './vault.ts';
import { Accounts, normalizeEmail } from './accounts.ts';
import { DynamoStore } from './dynamoStore.ts';
import { MemoryStore } from './store.ts';
import { KmsSealer, LocalSealer } from './sealer.ts';
import { ConsoleMailer } from './mailer.ts';
import { isCreditCard, RealPlaid } from './plaid.ts';

/**
 * One-time migration from the single-owner vault file to accounts:
 *   node src/importVault.ts --email you@example.com --vault /path/vault.production.bin
 * Creates the account if needed, keeps each connection's ID (so the iPhone's account mapping and sync
 * cursors still match), re-seals every Plaid token with KMS and points the Items at the public webhook.
 */
const args = process.argv.slice(2);
const arg = (name: string) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : undefined; };
const email = normalizeEmail(arg('email'));
const vaultPath = arg('vault');
if (!vaultPath || !existsSync(vaultPath)) throw new Error('--vault must point to an existing vault file');

const config = await loadConfig();
if (!config.legacyVaultKey) throw new Error('VAULT_KEY (the old vault key) is required for import');
const store = config.store === 'dynamo' ? new DynamoStore(config.tableName, config.awsRegion) : new MemoryStore();
const sealer = config.kmsKeyId ? new KmsSealer(config.kmsKeyId, config.awsRegion) : new LocalSealer(config.localSealKey!);
const accounts = new Accounts(store, new ConsoleMailer(), config.jwtSecret, config.codePepper);

const match = /vault\.(mock|sandbox|production)\.bin$/.exec(vaultPath);
if (!match) throw new Error('Vault file name must be vault.<env>.bin');
const legacy = new Vault(vaultPath.replace(/\/[^/]+$/, ''), match[1] as 'mock' | 'sandbox' | 'production', config.legacyVaultKey).read();

const key = accounts.emailKey(email);
const userId = (await store.findUserIdByEmailKey(key)) ?? (await store.createUser(key, email)).id;
const plaid = config.env === 'mock' ? null : new RealPlaid(config);
let imported = 0;
for (const c of legacy.connections) {
  if (c.status === 'disconnected' || !c.accessToken) continue;
  if (await store.getConnection(userId, c.id)) { console.log(`skip ${c.institutionName ?? c.id}: already imported`); continue; }
  await store.claimClientRequest(userId, c.clientRequestId, c.id);
  const cards = c.accounts.filter(isCreditCard);
  await store.putConnection({
    userId, id: c.id, itemId: c.itemId,
    sealedAccessToken: await sealer.seal(c.accessToken, { purpose: 'plaid-access-token', userId, connectionId: c.id }),
    institutionId: c.institutionId, institutionName: c.institutionName, country: c.country, accounts: cards,
    clientRequestId: c.clientRequestId, status: c.status === 'disconnect_pending' ? 'active' : c.status,
    createdAt: c.createdAt, lastSuccessfulPull: c.lastSuccessfulPull,
  });
  if (plaid && config.publicUrl) await plaid.setWebhook(c.accessToken, `${config.publicUrl}/v1/plaid/webhook`);
  imported += 1;
  console.log(`imported ${c.institutionName ?? 'connection'} (${cards.length} credit cards)`);
}
console.log(`Done: ${imported} connection(s) now belong to the account for this email.`);
