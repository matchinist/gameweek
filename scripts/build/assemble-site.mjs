// Assemble _site/ from the app builds plus the explicit static allowlist.
// This script IS the deploy allowlist (Phase 0.6): a file reaches production
// only by being listed here. scripts/build/parity-test.sh enforces the shape.
import { cpSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const site = join(root, '_site');

rmSync(site, { recursive: true, force: true });
mkdirSync(site, { recursive: true });

// App build outputs -> their public URL prefixes. Marketing owns the root.
const appDist = {
  'apps/marketing/dist': '.',
  'apps/embed/dist': 'embed',
  'apps/admin/dist': 'admin',
  'apps/data/dist': 'data',
  'apps/widgets/dist': 'widgets',
};
for (const [from, to] of Object.entries(appDist)) {
  const src = join(root, from);
  if (!existsSync(src)) throw new Error(`missing build output: ${from} — did an app build fail?`);
  cpSync(src, join(site, to), { recursive: true });
}


// Root static allowlist.
for (const f of ['embed.js', 'robots.txt', 'sitemap.xml', 'favicon.png', 'og-image.png', 'CNAME', 'llms.txt', '_headers']) {
  cpSync(join(root, f), join(site, f));
}

console.log('assembled _site/');
