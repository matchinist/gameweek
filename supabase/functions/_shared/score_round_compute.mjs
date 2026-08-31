// Phase 3.2 — the pure compute layer behind the score-round Edge Function.
// DB rows in, points out; no I/O, so vitest covers every mode without Deno.
//
// Semantics mirror the live client paths deliberately (the 3.5 shadow-compare
// diffs stored rows against what the browser computes, so any "improvement"
// here would read as a mismatch), with ONE ratified exception: betting scores
// ALL configured markets (scoreBettingEventAllMarkets), not just the classic
// trio the old client leaderboard knew about.
import {
  scorePoints, scoreBettingEventAllMarkets, computeLineupRoundScore,
  deriveRankingActuals, rankingActualOrder, scoreRankingOrder,
} from './scoring.mjs';

const unwrap = (v) => (v && typeof v === 'object' && 'value' in v) ? v.value : v;

// gw_dm_events row -> the shape packages/scoring expects. Ranking matches
// teams by NAME, so events need home/away names resolved via teamNames.
function toEv(raw, teamNames) {
  if (!raw) return null;
  const hasResult = raw.result && raw.result.h != null && raw.result.a != null;
  return {
    home: teamNames[raw.home_id] || raw.home_id,
    away: teamNames[raw.away_id] || raw.away_id,
    homeId: raw.home_id, awayId: raw.away_id,
    res: hasResult ? raw.result : null,
    lineup: raw.lineup || null,
    scorers: raw.scorers || null,
  };
}

function lineupParts(prediction) {
  const val = unwrap(prediction);
  return {
    pickedArr: Array.isArray(val) ? val : (val && Array.isArray(val.players) ? val.players : []),
    bonusPicks: Array.isArray(val) ? {} : (val && val.bonus ? val.bonus : {}),
  };
}

// Rows come back as {player_id, username, points, correct, total} — the
// gw_leaderboards column set minus the scope keys the caller adds.
export function computeCompScores({ comp, rounds, events, teamNames, predictions, targetRoundId }) {
  const mode = comp.mode;
  const evFor = (id) => toEv(events[id], teamNames);
  const roundById = {}; (rounds || []).forEach((r) => { roundById[r.id] = r; });
  const knownRound = (p) => mode === 'lineup' || !!roundById[p.round_id];
  const comps = (comp.markets ? { markets: comp.markets } : comp);
  const rankingConfig = comp.ranking_config || null;
  const lineupTeamId = comp.lineup_config?.teamId || null;

  // Ranking needs the actual order per completed round, derived from xG.
  const rankingActuals = {};
  if (mode === 'ranking') {
    (rounds || []).forEach((r) => {
      if (!r.ranking_teams || r.status !== 'completed') return;
      const evs = (r.event_ids || []).map(evFor).filter(Boolean);
      const teams = deriveRankingActuals(r.ranking_teams, evs);
      rankingActuals[r.id] = { teams, order: rankingActualOrder(teams) };
    });
  }

  // Per-prediction points, null = unscored (nothing to score against yet).
  const pointsOf = (p) => {
    if (mode === 'score') {
      const ev = evFor(p.event_id);
      if (!ev || !ev.res) return null;
      return scorePoints(unwrap(p.prediction), ev.res, comp.scoring)[0];
    }
    if (mode === 'betting') {
      const ev = evFor(p.event_id);
      if (!ev || !ev.res) return null;
      const val = (p.prediction && typeof p.prediction === 'object') ? p.prediction : {};
      return scoreBettingEventAllMarkets(comps, ev, val).pts;
    }
    if (mode === 'ranking') {
      if (!p.event_id.endsWith('_ranking')) return null;
      const actual = rankingActuals[p.round_id];
      const order = unwrap(p.prediction);
      if (!actual || !Array.isArray(order)) return null;
      return scoreRankingOrder(order, actual.order, actual.teams.length, rankingConfig).pts;
    }
    if (mode === 'lineup') {
      // A lineup "round" IS the tracked team's fixture: round_id = event id.
      const ev = evFor(p.round_id);
      const { pickedArr, bonusPicks } = lineupParts(p.prediction);
      // null squad ids on purpose: the live client passes a non-array where
      // squad ids belong, so squad-gated bonuses never resolve there today.
      // Mirror that until both sides change together.
      const s = computeLineupRoundScore(ev, lineupTeamId, null, pickedArr, bonusPicks);
      return s.anyResolved ? s.totalPts : null;
    }
    return null;
  };

  const predictionPoints = (predictions || [])
    .filter((p) => p.round_id === targetRoundId)
    .map((p) => ({ id: p.id, points: pointsOf(p) }));

  // ── round scope: the target round's leaderboard, client-round semantics ──
  const roundPreds = (predictions || []).filter((p) => p.round_id === targetRoundId);
  const roundUsers = {};
  roundPreds.forEach((p) => {
    const u = p.username || p.player_id;
    (roundUsers[u] = roundUsers[u] || { player_id: p.player_id, preds: [] }).preds.push(p);
  });
  const targetRound = roundById[targetRoundId] || null;
  const roundRows = Object.entries(roundUsers).map(([username, { player_id, preds }]) => {
    if (mode === 'score') {
      let pts = 0, correct = 0;
      preds.forEach((p) => { const e = pointsOf(p); if (e != null) { pts += e; if (e > 0) correct++; } });
      return { player_id, username, points: pts, correct, total: preds.length };
    }
    if (mode === 'betting') {
      let pts = 0;
      preds.forEach((p) => { pts += pointsOf(p) || 0; });
      return { player_id, username, points: pts, correct: null, total: null };
    }
    if (mode === 'ranking') {
      const teamCount = (targetRound?.ranking_teams || []).length;
      const p = preds.find((pp) => pp.event_id === `${targetRoundId}_ranking`);
      const actual = rankingActuals[targetRoundId];
      const order = p ? unwrap(p.prediction) : null;
      if (!p || !actual || !Array.isArray(order)) return { player_id, username, points: 0, correct: 0, total: teamCount };
      const s = scoreRankingOrder(order, actual.order, actual.teams.length, rankingConfig);
      return { player_id, username, points: s.pts, correct: s.correct, total: teamCount };
    }
    // lineup: one prediction per user per round
    const ev = evFor(targetRoundId);
    const { pickedArr, bonusPicks } = lineupParts(preds[0].prediction);
    const s = computeLineupRoundScore(ev, lineupTeamId, null, pickedArr, bonusPicks);
    return {
      player_id, username,
      points: s.anyResolved ? s.totalPts : 0,
      correct: s.xiResolved ? s.correctCount : null,
      total: s.xiResolved ? 11 : null,
    };
  });

  // ── overall scope: all rounds, client-overall semantics ──────────────────
  const overall = {}; // username -> row
  const reg = (p) => {
    const u = p.username || p.player_id;
    return overall[u] = overall[u] || { player_id: p.player_id, username: u, points: 0, correct: 0, total: 0, touched: false };
  };
  (predictions || []).forEach((p) => {
    if (!knownRound(p)) return;
    if (mode === 'ranking' && !p.event_id.endsWith('_ranking')) return;
    const row = reg(p);
    if (mode === 'score') {
      const e = pointsOf(p);
      if (e == null) return; // registered, but unresolved events don't count
      row.points += e; if (e > 0) row.correct++; row.total++; row.touched = true;
    } else if (mode === 'betting' || mode === 'lineup') {
      row.points += pointsOf(p) || 0; row.touched = true;
    } else if (mode === 'ranking') {
      const actual = rankingActuals[p.round_id];
      const order = unwrap(p.prediction);
      if (!actual || !Array.isArray(order)) return;
      const s = scoreRankingOrder(order, actual.order, actual.teams.length, rankingConfig);
      row.points += s.pts; row.correct += s.correct; row.total += actual.teams.length; row.touched = true;
    }
  });
  const overallRows = Object.values(overall).map(({ touched, ...row }) =>
    (mode === 'betting' || mode === 'lineup') ? { ...row, correct: null, total: null } : row);

  return { predictionPoints, roundRows, overallRows };
}
