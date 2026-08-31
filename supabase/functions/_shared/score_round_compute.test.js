// Phase 3.2 — tests for the score-round compute layer, written BEFORE the
// module. The Edge Function stays thin I/O; everything that turns DB rows
// into points lives here where vitest can reach it.
//
// Oracles:
//   * score + betting: the bundled demo dataset (DB-shaped rows) with totals
//     verified against the production engine running in a real browser on
//     2026-08-30/31 (demo_score overall + Gameweek 2; demo_betting after the
//     demo_user pick retune).
//   * ranking / lineup / winner+margin: small hand-computed fixtures.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { computeCompScores } from './score_round_compute.mjs';

const fakeWindow = {};
new Function('window', readFileSync(new URL('../../../apps/embed/public/demo-data.js', import.meta.url), 'utf8'))(fakeWindow);
const DB = fakeWindow.GW_DEMO.DB;

function demoInput(compId, targetRoundId) {
  return {
    comp: DB.gw_competitions.find((c) => c.id === compId),
    rounds: DB.gw_rounds.filter((r) => r.competition_id === compId),
    events: Object.fromEntries(DB.gw_dm_events.map((e) => [e.id, e])),
    teamNames: Object.fromEntries(DB.gw_dm_teams.map((t) => [t.id, t.name])),
    predictions: DB.gw_predictions.filter((p) => p.competition_id === compId),
    targetRoundId,
  };
}
const byU = (rows) => Object.fromEntries(rows.map((r) => [r.username, r]));

describe('score mode (demo_score oracle)', () => {
  const out = computeCompScores(demoInput('demo_score', 'dv_r0b'));

  it('round rows match the production engine for Gameweek 2', () => {
    const r = byU(out.roundRows);
    expect(out.roundRows.length).toBe(9);
    expect(r.stadyum76).toMatchObject({ points: 12, correct: 3, total: 4 });
    expect(r.demo_user).toMatchObject({ points: 7, correct: 2, total: 4 });
    expect(r.emma_w).toMatchObject({ points: 7, correct: 2, total: 4 });
    expect(r.footy_oracle).toMatchObject({ points: 5, correct: 3, total: 4 });
  });

  it('overall rows match the production engine across all rounds', () => {
    const o = byU(out.overallRows);
    expect(o.demo_user).toMatchObject({ points: 19, correct: 6, total: 8 });
    expect(o.stadyum76).toMatchObject({ points: 18, correct: 6, total: 8 });
    expect(o.kopite4).toMatchObject({ points: 18, correct: 5, total: 8 });
    expect(o.la_masia).toMatchObject({ points: 16, correct: 5, total: 8 });
    expect(o.nordkurve).toMatchObject({ points: 15, correct: 7, total: 8 });
    expect(o.footy_oracle).toMatchObject({ points: 14, correct: 6, total: 8 });
    expect(o.tahmin_kral).toMatchObject({ points: 14, correct: 6, total: 8 });
    expect(o.emma_w).toMatchObject({ points: 13, correct: 5, total: 8 });
    expect(o.bvb_predictor).toMatchObject({ points: 10, correct: 4, total: 8 });
  });

  it('prediction points cover exactly the target round, null when unresolved', () => {
    const preds = DB.gw_predictions.filter((p) => p.competition_id === 'demo_score' && p.round_id === 'dv_r0b');
    expect(out.predictionPoints.length).toBe(preds.length);
    // every id belongs to the target round and every resolved event got a number
    const ids = new Set(preds.map((p) => p.id));
    out.predictionPoints.forEach((pp) => {
      expect(ids.has(pp.id)).toBe(true);
      expect(typeof pp.points).toBe('number');
    });
    // an open round scores nothing yet
    const open = computeCompScores(demoInput('demo_score', 'dv_r1'));
    open.predictionPoints.forEach((pp) => expect(pp.points).toBe(null));
  });
});

describe('betting mode (demo_betting oracle, canonical all-markets semantics)', () => {
  const out = computeCompScores(demoInput('demo_betting', 'dv_r5a'));

  it('overall rows match the browser-verified totals', () => {
    const o = byU(out.overallRows);
    expect(o.stadyum76.points).toBe(12);
    expect(o.emma_w.points).toBe(12);
    expect(o.demo_user.points).toBe(11);
    expect(o.footy_oracle.points).toBe(10);
    expect(o.tahmin_kral.points).toBe(6);
  });

  it('winner and margin markets score in stored points', () => {
    // Hand fixture: one resulted event, one round, margin by 8
    const comp = { id: 'c', mode: 'betting', markets: [
      { type: 'winner', points: 3 },
      { type: 'margin', metric: 'margin', points: 4, options: [{ key: '1-5', max: 5 }, { key: '6-10', max: 10 }, { key: '11+', max: null }] },
    ] };
    const out2 = computeCompScores({
      comp,
      rounds: [{ id: 'r1', competition_id: 'c', status: 'completed', event_ids: ['e1'] }],
      events: { e1: { id: 'e1', result: { h: 100, a: 92 } } },
      teamNames: {},
      predictions: [
        { id: 'p1', round_id: 'r1', event_id: 'e1', player_id: 'u1', username: 'ann', prediction: { winner: 'H', margin: '6-10' } },
        { id: 'p2', round_id: 'r1', event_id: 'e1', player_id: 'u2', username: 'bob', prediction: { winner: 'A', margin: '1-5' } },
      ],
      targetRoundId: 'r1',
    });
    expect(byU(out2.roundRows).ann.points).toBe(7);
    expect(byU(out2.roundRows).bob.points).toBe(0);
    expect(out2.predictionPoints.find((p) => p.id === 'p1').points).toBe(7);
  });
});

describe('ranking mode', () => {
  // Hand fixture: 3 teams, xG-derived actual order T2 > T1 > T3.
  // ann predicts the exact order: 3 correct × 2 + perfect bonus 5 = 11.
  // bob gets only T3's slot right: 1 × 2 = 2.
  const comp = { id: 'c', mode: 'ranking', ranking_config: { pointsPerCorrect: 2, perfectBonus: 5 } };
  const rounds = [{
    id: 'r1', competition_id: 'c', status: 'completed', event_ids: ['e1', 'e2'],
    ranking_teams: [{ id: 't1', name: 'Alpha' }, { id: 't2', name: 'Beta' }, { id: 't3', name: 'Gamma' }],
  }];
  const events = {
    e1: { id: 'e1', home_id: 'tmA', away_id: 'tmB', result: { h: 1, a: 2, home_xg: 1.4, away_xg: 2.6 } },
    e2: { id: 'e2', home_id: 'tmC', away_id: 'tmA', result: { h: 0, a: 1, home_xg: 0.7, away_xg: 1.9 } },
  };
  const teamNames = { tmA: 'Alpha', tmB: 'Beta', tmC: 'Gamma' };
  const predictions = [
    { id: 'p1', round_id: 'r1', event_id: 'r1_ranking', player_id: 'u1', username: 'ann', prediction: ['t2', 't1', 't3'] },
    { id: 'p2', round_id: 'r1', event_id: 'r1_ranking', player_id: 'u2', username: 'bob', prediction: ['t1', 't2', 't3'] },
  ];

  it('scores against the xG-derived actual order with the perfect bonus', () => {
    const out = computeCompScores({ comp, rounds, events, teamNames, predictions, targetRoundId: 'r1' });
    expect(byU(out.roundRows).ann).toMatchObject({ points: 11, correct: 3, total: 3 });
    expect(byU(out.roundRows).bob).toMatchObject({ points: 2, correct: 1, total: 3 });
    expect(byU(out.overallRows).ann).toMatchObject({ points: 11, correct: 3, total: 3 });
  });

  it('an uncompleted round stores null points and zero rows', () => {
    const openRounds = [{ ...rounds[0], status: 'open' }];
    const out = computeCompScores({ comp, rounds: openRounds, events, teamNames, predictions, targetRoundId: 'r1' });
    out.predictionPoints.forEach((pp) => expect(pp.points).toBe(null));
    expect(byU(out.roundRows).ann.points).toBe(0);
  });
});

describe('lineup mode', () => {
  // Hand fixture: tracked team is home; saved XI = x1..x11. ann picked 9 of
  // them (9×10=90) and the right MVP (+30) = 120. Squad-gated bonuses
  // (firstGoal/firstSubOut) deliberately stay unresolved — the live client
  // passes a non-array where squad ids belong, so nothing resolves there
  // today; the server mirrors that until both sides change together.
  const xi = ['x1','x2','x3','x4','x5','x6','x7','x8','x9','x10','x11'];
  const comp = { id: 'c', mode: 'lineup', lineup_config: { teamId: 'tmH' } };
  const events = {
    e1: {
      id: 'e1', home_id: 'tmH', away_id: 'tmA',
      result: { h: 2, a: 0, mvp_home: 'x7' },
      lineup: { home: xi, away: null },
      scorers: [{ type: 'goal', playerId: 'x9', minute: 12 }],
    },
  };
  const predictions = [
    { id: 'p1', round_id: 'e1', event_id: 'e1_lineup', player_id: 'u1', username: 'ann',
      prediction: { players: [...xi.slice(0, 9), 'z1', 'z2'], bonus: { mvp: 'x7', firstGoal: 'x9' } } },
    { id: 'p2', round_id: 'e1', event_id: 'e1_lineup', player_id: 'u2', username: 'bob',
      prediction: { players: ['z1','z2','z3','z4','z5','z6','z7','z8','z9','z10','z11'], bonus: { mvp: 'x1' } } },
  ];

  it('scores XI hits + mvp; squad-gated bonuses stay unresolved (client mirror)', () => {
    const out = computeCompScores({ comp, rounds: [], events, teamNames: {}, predictions, targetRoundId: 'e1' });
    expect(byU(out.roundRows).ann).toMatchObject({ points: 120, correct: 9, total: 11 });
    expect(byU(out.roundRows).bob).toMatchObject({ points: 0, correct: 0, total: 11 });
    expect(out.predictionPoints.find((p) => p.id === 'p1').points).toBe(120);
    expect(byU(out.overallRows).ann.points).toBe(120);
  });

  it('no saved lineup and no mvp -> unscored, not zero', () => {
    const evs = { e1: { ...events.e1, lineup: null, result: { h: 2, a: 0 }, scorers: [] } };
    const out = computeCompScores({ comp, rounds: [], events: evs, teamNames: {}, predictions, targetRoundId: 'e1' });
    expect(out.predictionPoints.find((p) => p.id === 'p1').points).toBe(null);
  });
});
