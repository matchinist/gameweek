import { defineConfig } from '@playwright/test';

// Embed-contract regression tests (Phase 2.9). Two origins, like production:
//   :4173  the built site (_site) — the app origin embed.js derives
//   :4174  a stub "operator site" hosting the seamless embed
// All Supabase traffic is intercepted in the tests — CI needs no backend.
export default defineConfig({
  testDir: '.',
  timeout: 30000,
  retries: process.env.CI ? 1 : 0,
  use: { headless: true },
  webServer: [
    {
      command: 'node tests/embed-contract/server.mjs 4173 _site',
      url: 'http://localhost:4173/embed/?client=x',
      reuseExistingServer: !process.env.CI,
      cwd: '../..',
    },
    {
      command: 'node tests/embed-contract/server.mjs 4174 tests/embed-contract/host',
      url: 'http://localhost:4174/allowed.html',
      reuseExistingServer: !process.env.CI,
      cwd: '../..',
    },
  ],
});
