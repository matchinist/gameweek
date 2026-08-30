// Phase 2.5 follow-up — invariants for the bundled demo dataset. These pin
// the fixes from the first post-ship review of the new demo: a dead crest
// URL and a demo_user who looked hopeless in the betting standings.
import { describe, test, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'public', 'demo-data.js'), 'utf8');
const fakeWindow = {};
new Function('window', src)(fakeWindow);
const DB = fakeWindow.GW_DEMO.DB;

describe('demo dataset', () => {
  test('every team logo URL is https or empty, and Aston Villa uses the live crest', () => {
    // Arrange
    const teams = DB.gw_dm_teams;

    // Act
    const villa = teams.find((t) => t.name === 'Aston Villa');

    // Assert — Wikipedia deleted the 2016 crest file the old fork linked;
    // the demo must point at a crest that actually resolves.
    expect(villa.logo).toBe('https://upload.wikimedia.org/wikipedia/en/9/9a/Aston_Villa_FC_new_crest.svg');
    teams.forEach((t) => {
      expect(t.logo === '' || t.logo.startsWith('https://'), `${t.name}: ${t.logo}`).toBe(true);
    });
  });

  test('demo_user places a natural 3rd in the betting standings, not last', () => {
    // Arrange — score the betting predictions exactly the way the embed does
    const comp = DB.gw_competitions.find((c) => c.id === 'demo_betting');
    const events = Object.fromEntries(DB.gw_dm_events.map((e) => [e.id, e]));
    const actualOf = (res, type) => {
      if (type === '1x2') return res.h > res.a ? 'H' : res.h < res.a ? 'A' : 'D';
      if (type === 'ou25') return res.h + res.a > 2.5 ? 'O' : 'U';
      if (type === 'btts') return res.h > 0 && res.a > 0 ? 'Y' : 'N';
      return null;
    };

    // Act
    const totals = {};
    DB.gw_predictions
      .filter((p) => p.competition_id === 'demo_betting')
      .forEach((p) => {
        const res = events[p.event_id]?.result;
        if (!res || res.h == null) return;
        totals[p.username] = totals[p.username] || 0;
        comp.markets.forEach((m) => {
          if (p.prediction[m.type] && p.prediction[m.type] === actualOf(res, m.type)) totals[p.username] += m.points;
        });
      });
    const ranked = Object.entries(totals).sort((a, b) => b[1] - a[1]);
    const demoIdx = ranked.findIndex(([u]) => u === 'demo_user');

    // Assert — the showcase player should look competent (old fork kept them
    // near the top), and nobody above may tie them so the rank reads clean.
    expect(totals.demo_user).toBe(11);
    expect(demoIdx).toBe(2);
  });

  test('every league member username belongs to a user with predictions', () => {
    // Arrange
    const predictors = new Set(DB.gw_predictions.map((p) => p.username));

    // Act & Assert — a member without predictions would render as a ghost
    // (in the count, never in the table).
    DB.gw_league_members.forEach((m) => {
      expect(predictors.has(m.username), m.username).toBe(true);
    });
  });
});
