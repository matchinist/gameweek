// Per-language display names — written BEFORE the inline implementation.
// gw_dm_* rows carry name_i18n ({lang: override}); the embed shows the
// operator-language override and falls back to the canonical name. The
// helper lives inline in the page and is extracted here like the
// shadow-compare and anti-drift suites.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');

function extract() {
  const m = html.match(/function gwLocName\([^)]*\)\{[\s\S]*?\n\}/);
  if (!m) throw new Error('gwLocName not found inline in the embed');
  return new Function(`${m[0]}; return gwLocName;`)();
}

describe('gwLocName', () => {
  const loc = extract();
  const row = { name: 'Fenerbahce SK', name_i18n: { tr: 'Fenerbahçe', de: 'Fenerbahçe Istanbul' } };

  it('returns the override for the chosen language', () => {
    expect(loc(row, 'tr')).toBe('Fenerbahçe');
    expect(loc(row, 'de')).toBe('Fenerbahçe Istanbul');
  });

  it('falls back to the canonical name when the language has no override', () => {
    expect(loc(row, 'pt')).toBe('Fenerbahce SK');
    expect(loc({ name: 'Arsenal' }, 'tr')).toBe('Arsenal');
    expect(loc({ name: 'Arsenal', name_i18n: null }, 'tr')).toBe('Arsenal');
  });

  it('never throws on missing rows', () => {
    expect(loc(null, 'tr')).toBe('');
    expect(loc(undefined, 'tr')).toBe('');
  });
});

describe('localization wiring', () => {
  it('events, tournaments, ranking teams and squads all resolve through gwLocName', () => {
    // one call site per surface keeps display consistent — ranking matches
    // team names between EVENTS and rankingTeams, so both must localize
    // through the same map or client-side ranking scoring breaks.
    expect(html.match(/gwLocName\(/g).length).toBeGreaterThanOrEqual(5);
    expect(html).toContain('rankingNameLoc'); // canonical->localized map for operator-typed ranking team names
  });
});
