import { loadConfig } from './config.ts';
import { Vault } from './vault.ts';
import { issuePairingCode } from './auth.ts';

const args = process.argv.slice(2);
const config = loadConfig();
const vault = new Vault(config.dataDir, config.env, config.vaultKey);

if (args[0] === 'list') {
  for (const d of vault.read().devices) console.log(`${d.id}  ${d.name}  paired ${d.createdAt}${d.revokedAt ? `  REVOKED ${d.revokedAt}` : ''}`);
} else if (args[0] === 'revoke' && args[1]) {
  const ok = vault.update((d) => {
    const dev = d.devices.find((x) => x.id === args[1]);
    if (dev) dev.revokedAt = new Date().toISOString();
    return !!dev;
  });
  console.log(ok ? 'Device revoked.' : 'No such device.');
} else {
  const { code, expiresAt } = issuePairingCode(vault);
  console.log(`Pairing code (${config.env}): ${code}`);
  console.log(`Single use. Expires ${new Date(expiresAt).toLocaleTimeString()}.`);
}
