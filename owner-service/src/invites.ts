import { loadConfig } from './config.ts';
import { Accounts, INVITE_TTL_DAYS } from './accounts.ts';
import { DynamoStore } from './dynamoStore.ts';
import { ConsoleMailer } from './mailer.ts';

/**
 * Manage sign-up invites while `SIGNUP=invite`:
 *   node src/invites.ts add someone@example.com [--days 30]
 *   node src/invites.ts remove someone@example.com
 * Only an HMAC of the address is stored, so invites can't be listed back as emails.
 */
const [command, email, ...rest] = process.argv.slice(2);
const daysAt = rest.indexOf('--days');
const days = daysAt >= 0 ? Number(rest[daysAt + 1]) : INVITE_TTL_DAYS;
if ((command !== 'add' && command !== 'remove') || !email) {
  console.error('Usage: node src/invites.ts add|remove <email> [--days N]');
  process.exit(2);
}

const config = await loadConfig();
// An in-memory store belongs to one process, so an invite written here would never reach the running API.
if (config.store !== 'dynamo') throw new Error('Invites need STORE=dynamo. With STORE=memory, use SIGNUP=open.');
const store = new DynamoStore(config.tableName, config.awsRegion);
const accounts = new Accounts(store, new ConsoleMailer(), config.jwtSecret, config.codePepper, config.signup);

if (command === 'add') {
  const invite = await accounts.invite(email, days);
  console.log(`Invited until ${new Date(invite.expiresAt).toISOString().slice(0, 10)}.`);
} else {
  await accounts.revokeInvite(email);
  console.log('Invite removed. An account already created with it is not affected.');
}
if (config.signup !== 'invite') console.log('Note: SIGNUP is open, so invites have no effect until SIGNUP=invite.');
