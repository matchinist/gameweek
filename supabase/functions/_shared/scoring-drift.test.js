// The Edge Function bundle can't reach outside supabase/functions/, so
// score-round runs on a byte-copy of packages/scoring. This pin makes the
// copy impossible to forget: edit the package, re-copy, or CI fails.
import { test, expect } from 'vitest';
import { readFileSync } from 'node:fs';

test('scoring.mjs is a byte-identical copy of packages/scoring/index.js', () => {
  const pkg = readFileSync(new URL('../../../packages/scoring/index.js', import.meta.url), 'utf8');
  const copy = readFileSync(new URL('./scoring.mjs', import.meta.url), 'utf8');
  expect(copy).toBe(pkg);
});
