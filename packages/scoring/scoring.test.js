// Tests for @gameweek/scoring (written BEFORE the package — TDD).
//
// The golden fixtures were captured on 2026-08-30 by running the PRODUCTION
// page's own scoring functions (the post-0.8 live implementations) over real
// database rows in the production browser:
//   - 60 real betting predictions (wpet 1x2/ou25/btts rounds, resulted)
//   - 36 marketActual cases incl. the winner/margin/custom-bucket types
//   - 12 real lineup predictions (sadecebeikta + gw_gam, with the exact
//     squad ids squadFor() resolved at capture time — both comps fall back
//     to the hardcoded LIV squad because their teams have no squad rows)
//   - 388 score-mode cases (synthetic input grid, production scorePoints as
//     the oracle — no live score comp had resulted predictions to capture)
//   - 1 real ranking round (open/uncompleted — the only surviving one)
// Extraction therefore cannot silently change results: every number below is
// what production computed.
//
// Anti-drift: the pure functions still live inline in apps/embed/index.html;
// they are extracted from the HTML here and equality-checked against the
// package over the full golden inputs, so the copies cannot drift.

import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import {
  scorePoints, marketMetricValue, marketBucketKey, marketActual,
  buildBettingEventHistory, scoreBettingEventAllMarkets, flattenLineupSlots,
  firstGoalScorerId, firstSubOutPlayerIds, lineupBonusAnswers,
  computeLineupRoundScore,
  deriveRankingActuals, rankingActualOrder, scoreRankingOrder,
} from './index.js';

const g1 = JSON.parse(readFileSync(new URL('./golden/captured-2026-08-30.json', import.meta.url)));
const g2 = JSON.parse(readFileSync(new URL('./golden/captured-2-score-ranking.json', import.meta.url)));

// ── score mode: 388+ production-oracle cases ────────────────────────────────

describe('scorePoints', () => {
  it(`reproduces all ${g2.scoreCases.length} production-oracle cases`, () => {
    for (const c of g2.scoreCases) {
      expect(scorePoints(c.pred, c.res, c.scoring), JSON.stringify(c)).toStrictEqual(c.expected);
    }
  });
  it('spot checks stay human-readable', () => {
    expect(scorePoints({h:2,a:1}, {h:2,a:1}, null)).toStrictEqual([5, 'Exact score correct']);
    expect(scorePoints({h:2,a:0}, {h:2,a:1}, null)).toStrictEqual([2, 'Home team goals correct']);
    expect(scorePoints({h:0,a:1}, {h:2,a:1}, null)).toStrictEqual([2, 'Away team goals correct']);
    expect(scorePoints({h:3,a:0}, {h:2,a:1}, null)).toStrictEqual([1, 'Total goals correct']);
    expect(scorePoints({h:0,a:0}, {h:2,a:1}, null)).toStrictEqual([0, 'No points scored']);
    expect(scorePoints({h:2,a:1}, {h:2,a:1}, {exactScore:10,homeGoals:3,awayGoals:3,totalGoals:2,unit:'sets'})[1]).toBe('Exact score correct');
    expect(scorePoints({h:2,a:0}, {h:2,a:1}, {exactScore:10,homeGoals:3,awayGoals:3,totalGoals:2,unit:'sets'})).toStrictEqual([3, 'Home team sets correct']);
  });
});

// ── betting: real leaderboard cases + the card-path market oracle ───────────

describe('betting', () => {
  it(`reproduces all ${g1.betCases.length} real leaderboard cases`, () => {
    for (const c of g1.betCases) {
      const built = buildBettingEventHistory({ markets: c.markets }, { home: 'H', away: 'A', res: c.res }, c.picks);
      expect(built.evPts, JSON.stringify(c)).toBe(c.expected.evPts);
      expect(built.markets.map(m => ({ type: m.mkt.type, pick: m.pick, isRight: m.isRight, pts: m.pts })))
        .toStrictEqual(c.expected.perMarket);
    }
  });
  it(`reproduces all ${g1.marketActualCases.length} marketActual cases (incl. winner/margin/buckets)`, () => {
    for (const c of g1.marketActualCases) {
      expect(marketActual(c.mkt, c.res), JSON.stringify(c)).toStrictEqual(c.expected);
    }
  });
  it('documents the live leaderboard-vs-card inconsistency: winner/custom markets score 0 on the leaderboard path', () => {
    // buildBettingEventHistory (the leaderboard/overall path) only evaluates
    // 1x2/ou25/btts; renderEventCard's inline block also handles winner and
    // bucket markets via marketActual. Live comps (cheeseheadtv, demarco,
    // basketballireland) USE winner+margin — their leaderboards ignore those
    // markets today. Pinned so the Phase 3 score-round decision is explicit.
    const winnerMkt = { type: 'winner', points: 3 };
    const res = { h: 24, a: 10 };
    expect(marketActual(winnerMkt, res)).toBe('H'); // card path scores it
    const built = buildBettingEventHistory({ markets: [winnerMkt] }, { res }, { winner: 'H' });
    expect(built.evPts).toBe(0); // leaderboard path does not
  });
  it('a metric beyond every bucket max falls to the last option', () => {
    const capped = { type: 'margin', metric: 'margin', options: [{ key: 'a', max: 6 }, { key: 'b', max: 13 }] };
    expect(marketBucketKey(capped, { h: 40, a: 0 })).toBe('b');
  });
  it('bucket markets resolve via metric thresholds', () => {
    const margin = { type: 'margin', metric: 'margin', options: [{ key: 'a', max: 6 }, { key: 'b', max: 13 }, { key: 'c', max: null }] };
    expect(marketBucketKey(margin, { h: 24, a: 10 })).toBe('c');
    expect(marketBucketKey(margin, { h: 3, a: 0 })).toBe('a');
    expect(marketMetricValue({ metric: 'total' }, { h: 2, a: 1 })).toBe(3);
    expect(marketMetricValue({ metric: 'other' }, { h: 2, a: 1 })).toBeNull();
  });
});

// ── lineup: real cases with the exact squads production resolved ────────────

describe('lineup', () => {
  it(`reproduces all ${g1.lineupCases.length} real cases`, () => {
    for (const c of g1.lineupCases) {
      const s = computeLineupRoundScore(c.ev, c.teamId, c.squadIds, c.pickedArr, c.bonusPicks);
      for (const k of ['totalPts', 'xiPts', 'correctCount', 'xiResolved', 'bonusCorrectCount', 'bonusPts', 'anyResolved']) {
        expect(s[k], `${k} for ${JSON.stringify(c.pickedArr.slice(0,2))}…`).toStrictEqual(c.expected[k]);
      }
      expect(s.bonusAnswers).toStrictEqual(c.expected.bonusAnswers);
    }
  });
  it('scores 10 per correct pick, +30 for a perfect XI, +30 per correct bonus', () => {
    const xi = Array.from({ length: 11 }, (_, i) => `p${i}`);
    const ev = { homeId: 't1', awayId: 't2', lineup: { home: xi }, res: { mvp_home: 'p3' },
      scorers: [{ type: 'goal', playerId: 'p5', minute: 12 }, { type: 'sub', outId: 'p7', minute: 60 }] };
    const squad = [...xi, 'p95'];
    const perfect = computeLineupRoundScore(ev, 't1', squad, xi, { firstGoal: 'p5', mvp: 'p3', firstSubOut: 'p7' });
    expect(perfect.xiPts).toBe(11 * 10 + 30);
    expect(perfect.bonusPts).toBe(3 * 30);
    expect(perfect.totalPts).toBe(230);
    const partial = computeLineupRoundScore(ev, 't1', squad, [...xi.slice(0, 9), 'x1', 'x2'], {});
    expect(partial.xiPts).toBe(90);
    expect(partial.bonusCorrectCount).toBe(0);
  });
  it('unresolved XI (no lineup data or not 11 picks) never scores the XI', () => {
    const ev = { homeId: 't1', awayId: 't2', lineup: null, scorers: [] };
    const s = computeLineupRoundScore(ev, 't1', ['p1'], ['p1'], {});
    expect(s.xiResolved).toBe(false);
    expect(s.xiPts).toBe(0);
  });
  it('bonus answers gate on squad membership (the fallback-squad quirk)', () => {
    // A real scorer whose id is not in the resolved squad produces NO
    // first-goal answer — exactly what happens live for lineup comps whose
    // team has no squad rows (squadFor falls back to the LIV squad).
    const scorers = [{ type: 'goal', playerId: 'real_dm_id', minute: 5 }];
    expect(firstGoalScorerId(scorers, ['liv1', 'liv2'])).toBeNull();
    expect(firstGoalScorerId(scorers, ['real_dm_id'])).toBe('real_dm_id');
  });
  it('same-minute double substitutions are all winning answers', () => {
    const scorers = [
      { type: 'sub', outId: 'a', minute: 46 }, { type: 'sub', outId: 'b', minute: 46 },
      { type: 'sub', outId: 'c', minute: 70 },
    ];
    expect(firstSubOutPlayerIds(scorers, ['a', 'b', 'c']).sort()).toStrictEqual(['a', 'b']);
  });
  it('an away-side tracked team reads the away lineup; goal minutes sort', () => {
    const xi = Array.from({ length: 11 }, (_, i) => `q${i}`);
    const ev = { homeId: 'other', awayId: 'tracked', lineup: { home: ['x'], away: xi },
      scorers: [{ playerId: 'q2', minute: 30 }, { playerId: 'q1', minute: 10 }] };
    const s = computeLineupRoundScore(ev, 'tracked', xi, xi, { firstGoal: 'q1' });
    expect(s.xiResolved).toBe(true);
    expect(s.xiPts).toBe(140);
    expect(s.bonusAnswers.firstGoal).toBe('q1'); // earlier minute wins despite input order
    expect(s.bonusCorrect.firstGoal).toBe(true);
  });
  it('flattenLineupSlots accepts arrays and slot objects', () => {
    expect(flattenLineupSlots(['a', 'b'])).toStrictEqual(['a', 'b']);
    expect(flattenLineupSlots({ s1: 'a', s2: null, s3: 'b' })).toStrictEqual(['a', 'b']);
    expect(flattenLineupSlots(null)).toBeNull();
  });
});

// ── ranking: verbatim port of the (anonymous) inline logic ──────────────────

describe('ranking', () => {
  const teams = [{ id: 'A', name: 'Alpha' }, { id: 'B', name: 'Beta' }, { id: 'C', name: 'Gamma' }];
  const events = [
    { home: 'Alpha', away: 'Beta', res: { home_xg: '2.5', away_xg: '1.1' } },
    { home: 'Gamma', away: 'Alpha', res: { home_xg: 0.4, away_xg: 3.0 } },
  ];
  it('derives each team actualXG from its first resulted match, home or away', () => {
    const t = deriveRankingActuals(teams, events);
    expect(t.find(x => x.id === 'A').actualXG).toBe(2.5); // first match wins, not the 3.0
    expect(t.find(x => x.id === 'B').actualXG).toBe(1.1);
    expect(t.find(x => x.id === 'C').actualXG).toBe(0.4);
  });
  it('orders by actualXG descending, missing values as 0', () => {
    const t = deriveRankingActuals(teams, events);
    expect(rankingActualOrder(t)).toStrictEqual(['A', 'B', 'C']);
    expect(rankingActualOrder([{ id: 'X' }, { id: 'Y', actualXG: 1 }])).toStrictEqual(['Y', 'X']);
  });
  it('scores position matches × pointsPerCorrect, with the perfect bonus', () => {
    expect(scoreRankingOrder(['A', 'B', 'C'], ['A', 'B', 'C'], 3, null)).toStrictEqual({ pts: 3 * 2 + 5, correct: 3 });
    expect(scoreRankingOrder(['A', 'C', 'B'], ['A', 'B', 'C'], 3, null)).toStrictEqual({ pts: 2, correct: 1 });
    expect(scoreRankingOrder(['C', 'A', 'B'], ['A', 'B', 'C'], 3, { pointsPerCorrect: 4, perfectBonus: 10 }))
      .toStrictEqual({ pts: 0, correct: 0 });
    expect(scoreRankingOrder(['A', 'B'], ['A', 'B'], 2, { pointsPerCorrect: 1, perfectBonus: 100 }))
      .toStrictEqual({ pts: 102, correct: 2 });
  });
  it('the surviving live round is open — no actual order exists yet', () => {
    // Captured fixture: gw_gam c1cc0622edac2 r7480d6c01e0f, status 'open'.
    // The inline view only computes actualOrder when status==='completed';
    // engine callers must do the same.
    const { round } = g2.rankingFixture;
    expect(round.status).not.toBe('completed');
  });
});

// ── anti-drift vs the inline copies in apps/embed/index.html ────────────────

function inlineScoring() {
  const html = readFileSync(new URL('../../apps/embed/index.html', import.meta.url), 'utf8');
  const grab = (name) => {
    const m = html.match(new RegExp(`function ${name}\\([^)]*\\)\\{[\\s\\S]*?\\n\\}`));
    if (!m) throw new Error(`${name} not found inline`);
    return m[0];
  };
  const src = ['scorePoints', 'marketMetricValue', 'marketBucketKey', 'marketActual', 'buildBettingEventHistory', 'flattenLineupSlots'].map(grab).join('\n');
  return new Function(`${src}; return { scorePoints, marketMetricValue, marketBucketKey, marketActual, buildBettingEventHistory, flattenLineupSlots };`)();
}

describe('anti-drift vs inline embed copies', () => {
  const inline = inlineScoring();
  it('scorePoints agrees on every golden case', () => {
    for (const c of g2.scoreCases) {
      expect(scorePoints(c.pred, c.res, c.scoring)).toStrictEqual(inline.scorePoints(c.pred, c.res, c.scoring));
    }
  });
  it('marketActual + bucket helpers agree on every golden case', () => {
    for (const c of g1.marketActualCases) {
      expect(marketActual(c.mkt, c.res)).toStrictEqual(inline.marketActual(c.mkt, c.res));
    }
  });
  it('buildBettingEventHistory agrees on every real case', () => {
    for (const c of g1.betCases) {
      const a = buildBettingEventHistory({ markets: c.markets }, { home: 'H', away: 'A', res: c.res }, c.picks);
      const b = inline.buildBettingEventHistory({ markets: c.markets }, { home: 'H', away: 'A', res: c.res }, c.picks);
      expect(a).toStrictEqual(b);
    }
  });
});

// ── Phase 3.2: canonical betting semantics (owner-ratified 2026-08-31) ──────
// Every configured market scores via marketActual — winner and bucket
// (margin/total) markets included. This is what score-round stores; the
// legacy client path above keeps ignoring them until the 3.5 cutover.
describe('scoreBettingEventAllMarkets', () => {
  const comp = { markets: [
    { type: '1x2', points: 3 },
    { type: 'winner', points: 3 },
    { type: 'margin', metric: 'margin', points: 4, options: [
      { key: '1-5', max: 5 }, { key: '6-10', max: 10 }, { key: '11+', max: null },
    ] },
    { type: 'ou25', points: 2 },
    { type: 'btts', points: 2 },
  ] };

  it('scores winner and margin buckets, not just the classic trio', () => {
    // Arrange — basketball-style result: home by 8
    const ev = { res: { h: 100, a: 92 } };
    const val = { winner: 'H', margin: '6-10', '1x2': 'H' };

    // Act
    const { pts, perMarket } = scoreBettingEventAllMarkets(comp, ev, val);

    // Assert — 1x2 (3) + winner (3) + margin bucket (4); no ou25/btts picks
    expect(pts).toBe(10);
    expect(perMarket.find((m) => m.type === 'winner').isRight).toBe(true);
    expect(perMarket.find((m) => m.type === 'margin').isRight).toBe(true);
  });

  it('wrong bucket and missing picks score zero without throwing', () => {
    const ev = { res: { h: 101, a: 90 } }; // margin 11 -> '11+'
    const { pts } = scoreBettingEventAllMarkets(comp, ev, { margin: '6-10' });
    expect(pts).toBe(0);
  });

  it('unresulted event scores nothing and marks nothing right', () => {
    const { pts, perMarket } = scoreBettingEventAllMarkets(comp, { res: null }, { winner: 'H' });
    expect(pts).toBe(0);
    expect(perMarket.every((m) => !m.isRight)).toBe(true);
  });

  it('agrees with buildBettingEventHistory on classic-trio-only comps', () => {
    for (const c of g1.betCases) {
      const legacy = buildBettingEventHistory({ markets: c.markets }, { home: 'H', away: 'A', res: c.res }, c.picks);
      const canonical = scoreBettingEventAllMarkets({ markets: c.markets }, { res: c.res }, c.picks);
      expect(canonical.pts).toBe(legacy.evPts);
    }
  });
});
