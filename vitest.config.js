import { defineConfig } from 'vitest/config';

// Vitest owns packages/ (and future app module tests). The *.test.mjs files
// under scripts/ are node:test suites (zero-dep, run via `node --test`) and
// must not be collected here.
export default defineConfig({
  test: {
    include: ['packages/**/*.test.js', 'apps/**/*.test.js', 'supabase/functions/_shared/*.test.js'],
  },
});
