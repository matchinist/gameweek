// @ts-nocheck — RETIRED scaffolding, kept for history. Its input
// (demo/index.html, the fork) was deleted when 2.5 landed; the generated
// apps/embed/public/demo-data.js is now the canonical source and is edited
// directly. This script can no longer run.
//
// Phase 2.5 — generates apps/embed/demo-data.js from the demo fork's data.
//
// One-time extraction: while demo/index.html still exists, its hand-written
// showcase data (teams, fixtures, results, leaderboard names) is transformed
// into database-shaped rows the REAL embed consumes through a mock
// supabase-js client. After the fork is deleted, the generated file is the
// canonical source and this script is history.
//
//   node scripts/build/generate-demo-data.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { parse } from 'acorn';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const html = readFileSync(join(root, 'demo/index.html'), 'utf8');
const scripts = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);

let LOGO, COMPS, EVENTS;
for (const s of scripts) {
  if (!s.includes('const COMPS')) continue;
  const ast = parse(s, { ecmaVersion: 'latest' });
  const grab = {};
  for (const node of ast.body) {
    if (node.type !== 'VariableDeclaration') continue;
    for (const d of node.declarations) {
      if (d.id.type === 'Identifier' && ['LOGO', 'COMPS', 'EVENTS'].includes(d.id.name)) {
        grab[d.id.name] = s.slice(d.init.start, d.init.end);
      }
    }
  }
  LOGO = new Function(`return (${grab.LOGO})`)();
  const lg = (n) => LOGO[n] || '';
  COMPS = new Function('lg', 'FANTASY_DATA', `return (${grab.COMPS})`)(lg, { rounds: [] });
  EVENTS = new Function('lg', `return (${grab.EVENTS})`)(lg);
}

const compById = Object.fromEntries(COMPS.map(c => [c.id, c]));
const variant = (cid, key) => (compById[cid].sportVariants || []).find(v => v.key === key);

// ── row builders ────────────────────────────────────────────────────────────
const slug = (n) => 'tm_' + n.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');
const teams = new Map(); // name -> row
function teamId(name, logo) {
  if (!teams.has(name)) teams.set(name, { id: slug(name), name, logo: logo || LOGO[name] || '' });
  return teams.get(name).id;
}

const rowsEvents = [];
const rowsRounds = [];
const rowsComps = [];
// D(days, h, m) markers become runtime Date calls in the emitted file.
const D = (days, h = 15, m = 0) => `@@D(${days},${h},${m})@@`;

function addEvent(id, ev, kickoff, result) {
  rowsEvents.push({
    id,
    home_id: teamId(ev.home, ev.homeLogo),
    away_id: teamId(ev.away, ev.awayLogo),
    kickoff: '', kickoff_at: kickoff,
    result: result === undefined ? (ev.res || null) : result,
    status: 'upcoming', line: 2.5, lineup: ev.lineup || null, scorers: ev.scorers || null,
  });
}

function addRound(compId, r, { label, dayOffset, hours = [15, 17], results = true, extras = {} }) {
  const evIds = [];
  (r.eventIds || []).forEach((eid, i) => {
    const ev = EVENTS[eid]; if (!ev) return;
    const id = `dv_${eid}`;
    addEvent(id, ev, D(dayOffset, hours[i % hours.length], (i * 7) % 30), results ? undefined : null);
    evIds.push(id);
  });
  rowsRounds.push({
    id: `dv_${r.id}`, client_key: 'demo', competition_id: compId,
    label: label || r.label, status: results ? 'completed' : 'open',
    deadline: D(dayOffset, hours[0] - 1, 30),
    event_ids: evIds, tournament_names: r.tournamentNames || extras.tournamentNames || [],
    sort_order: rowsRounds.length, ranking_teams: extras.rankingTeams || null,
    prizes: r.prizes || null,
  });
  return evIds;
}

// ── Score Predictor: football GW1/GW2 resulted, GW3 open ────────────────────
{
  const v = variant('c1', 'football');
  rowsComps.push({
    id: 'demo_score', client_key: 'demo', status: 'active', name: 'Score Predictor', mode: 'score',
    color: '#4F46E5', scoring: v.scoring, markets: [], ranking_config: null, lineup_config: null,
    overall_prizes: v.overallPrizes || null, comp_aliases: ['score'], scope_text: 'Premier League',
  });
  const [gw1, gw2, gw3] = v.rounds;
  addRound('demo_score', gw1, { dayOffset: -12, extras: { tournamentNames: v.tournamentNames } });
  addRound('demo_score', gw2, { dayOffset: -5, extras: { tournamentNames: v.tournamentNames } });
  addRound('demo_score', gw3, { dayOffset: 2, results: false, extras: { tournamentNames: v.tournamentNames } });
}
// ── Score variants: volleyball + tennis (set-based pickers) ─────────────────
for (const [key, compId, name] of [['volleyball', 'demo_score_volley', 'Score Predictor · Volleyball'], ['tennis', 'demo_score_tennis', 'Score Predictor · Tennis']]) {
  const v = variant('c1', key);
  rowsComps.push({
    id: compId, client_key: 'demo', status: 'active', name, mode: 'score', color: '#4F46E5',
    scoring: { ...v.scoring, unit: v.scoreUnit, scoreOptions: v.scoreOptions },
    markets: [], ranking_config: null, lineup_config: null,
    overall_prizes: v.overallPrizes || null, comp_aliases: [key], scope_text: v.tournamentNames?.[0] || '',
  });
  addRound(compId, v.rounds[0], { dayOffset: 3, results: false, extras: { tournamentNames: v.tournamentNames } });
}
// ── Betting Markets: football, one resulted + one open round ────────────────
{
  const v = variant('c3', 'football');
  rowsComps.push({
    id: 'demo_betting', client_key: 'demo', status: 'active', name: 'Betting Markets', mode: 'betting',
    color: '#059669', scoring: null, markets: v.markets, ranking_config: null, lineup_config: null,
    overall_prizes: v.overallPrizes || null, comp_aliases: ['betting'], scope_text: 'Premier League',
  });
  addRound('demo_betting', v.rounds[0], { dayOffset: -6, extras: { tournamentNames: v.tournamentNames } });
  addRound('demo_betting', v.rounds[1], { dayOffset: 2, results: false, extras: { tournamentNames: v.tournamentNames } });
}
// ── Ranking: completed round (with synthesized xG fixtures) + open round ────
{
  const v = variant('c4', 'football');
  rowsComps.push({
    id: 'demo_ranking', client_key: 'demo', status: 'active', name: 'Ranking', mode: 'ranking',
    color: '#D97706', scoring: null, markets: [], ranking_config: v.rankingConfig || null, lineup_config: null,
    overall_prizes: v.overallPrizes || null, comp_aliases: ['ranking'], scope_text: 'Premier League',
  });
  const open = v.rounds.find(r => r.status === 'open');
  const done = v.rounds.find(r => r.status === 'completed');
  // The fork precomputed ranking results; the real engine derives them from
  // fixtures' xG. Synthesize one fixture per team pair with xG results for
  // the completed round, and result-less fixtures for the open one.
  const mk = (round, tag, dayOffset, withXg) => {
    const teams6 = round.rankingTeams.map(t => ({ ...t }));
    const evIds = [];
    for (let i = 0; i < teams6.length; i += 2) {
      const id = `dv_rk_${tag}_${i / 2}`;
      const home = teams6[i], away = teams6[i + 1];
      const result = withXg
        ? { h: 2 - (i / 2 % 2), a: i / 2 % 3, home_xg: +(2.6 - i * 0.35).toFixed(1), away_xg: +(0.7 + i * 0.22).toFixed(1) }
        : null;
      rowsEvents.push({
        id, home_id: teamId(home.name, home.logo), away_id: teamId(away.name, away.logo),
        kickoff: '', kickoff_at: D(dayOffset, 14 + (i / 2), 0), result,
        status: 'upcoming', line: 2.5, lineup: null, scorers: null,
      });
      evIds.push(id);
    }
    rowsRounds.push({
      id: `dv_${round.id}`, client_key: 'demo', competition_id: 'demo_ranking',
      label: round.label, status: withXg ? 'completed' : 'open',
      deadline: D(dayOffset, 13, 0), event_ids: evIds,
      tournament_names: v.tournamentNames || [], sort_order: rowsRounds.length,
      ranking_teams: teams6.map(t => ({ ...t, actualXG: null })), prizes: round.prizes || null,
    });
  };
  mk(done, 'done', -7, true);
  mk(open, 'open', 3, false);
}
// ── Lineup Predictor: Liverpool, next fixtures (fork had no scored round) ───
{
  rowsComps.push({
    id: 'demo_lineup', client_key: 'demo', status: 'active', name: 'Lineup Predictor', mode: 'lineup',
    color: '#0EA5E9', scoring: null, markets: [], ranking_config: null,
    lineup_config: { teamId: teamId('Liverpool', LOGO['Liverpool']), teamName: 'Liverpool' },
    overall_prizes: null, comp_aliases: ['lineup'], scope_text: 'Premier League',
  });
  addEvent('dv_erl_lu1', EVENTS['erl_lu1'], D(1, 17, 30), null);
  addEvent('dv_erl_lu2', EVENTS['erl_lu2'], D(15, 16, 0), null);
}

// ── fake community: players, predictions, leagues ───────────────────────────
const USERS = ['footy_oracle', 'stadyum76', 'bvb_predictor', 'kopite4', 'emma_w', 'tahmin_kral', 'nordkurve', 'la_masia'];
const rowsPlayers = [
  { id: 'demo-player', auth_id: 'demo-auth-uid', client_key: 'demo', username: 'demo_user', email: 'demo@gameweek.cloud' },
  ...USERS.map((u, i) => ({ id: `demo-p${i}`, auth_id: `demo-a${i}`, client_key: 'demo', username: u, email: `${u}@demo.gameweek.cloud` })),
];
// deterministic pseudo-random picks so leaderboards are varied but stable
let seed = 42;
const rand = (n) => { seed = (seed * 1103515245 + 12345) % 2147483648; return Math.floor(seed / 65536) % n; };
const rowsPreds = [];
function pred(user, compId, roundId, eventId, prediction) {
  const p = rowsPlayers.find(r => r.username === user);
  rowsPreds.push({
    id: `pr_${rowsPreds.length}`, client_key: 'demo', player_id: p.id, username: user,
    competition_id: compId, round_id: roundId, event_id: eventId, prediction, submitted_at: D(-13, 12, 0),
  });
}
for (const round of rowsRounds) {
  const comp = rowsComps.find(c => c.id === round.competition_id);
  if (comp.mode === 'score' && round.status === 'completed') {
    for (const evId of round.event_ids) {
      const ev = rowsEvents.find(e => e.id === evId);
      for (const u of ['demo_user', ...USERS]) {
        const exact = rand(4) === 0; // some users nail it
        const h = exact ? ev.result.h : rand(4), a = exact ? ev.result.a : rand(3);
        pred(u, comp.id, round.id, evId, { h, a });
      }
    }
  }
  if (comp.mode === 'betting' && round.status === 'completed') {
    for (const evId of round.event_ids) {
      const ev = rowsEvents.find(e => e.id === evId);
      const actual = { '1x2': ev.result.h > ev.result.a ? 'H' : ev.result.h < ev.result.a ? 'A' : 'D', ou25: (ev.result.h + ev.result.a) > 2.5 ? 'O' : 'U', btts: (ev.result.h > 0 && ev.result.a > 0) ? 'Y' : 'N' };
      for (const u of ['demo_user', ...USERS]) {
        const pick = {};
        for (const mkt of comp.markets) {
          const opts = mkt.type === '1x2' ? ['H', 'D', 'A'] : mkt.type === 'ou25' ? ['O', 'U'] : ['Y', 'N'];
          pick[mkt.type] = rand(3) === 0 ? actual[mkt.type] : opts[rand(opts.length)];
        }
        pred(u, comp.id, round.id, evId, pick);
      }
    }
  }
  if (comp.mode === 'ranking' && round.status === 'completed') {
    const ids = round.ranking_teams.map(t => t.id);
    for (const u of ['demo_user', ...USERS]) {
      const order = [...ids];
      for (let i = order.length - 1; i > 0; i--) { if (rand(3) > 0) continue; const j = rand(i + 1); [order[i], order[j]] = [order[j], order[i]]; }
      pred(u, comp.id, round.id, `${round.id}_ranking`, order);
    }
  }
}
// demo_user's own open-round score picks (visible pre-lock in their UI)
const gw3 = rowsRounds.find(r => r.competition_id === 'demo_score' && r.status === 'open');
gw3.event_ids.slice(0, 3).forEach((evId, i) => pred('demo_user', 'demo_score', gw3.id, evId, { h: [3, 2, 1][i], a: 0 }));

const rowsLeagues = [
  { id: 'demo_lg_office', client_key: 'demo', name: 'Office Predictions', code: 'OFFICE1', created_by: 'footy_oracle' },
  { id: 'demo_lg_super', client_key: 'demo', name: 'Süper Fans', code: 'SUPER99', created_by: 'tahmin_kral' },
];
const rowsMembers = [];
const member = (lg, user) => { const p = rowsPlayers.find(r => r.username === user); rowsMembers.push({ league_id: lg, username: user, player_id: p.id }); };
['demo_user', 'footy_oracle', 'stadyum76', 'emma_w'].forEach(u => member('demo_lg_office', u));
['demo_user', 'tahmin_kral', 'bvb_predictor', 'kopite4', 'nordkurve'].forEach(u => member('demo_lg_super', u));

// ── emit ────────────────────────────────────────────────────────────────────
const emit = (v) => JSON.stringify(v, null, 0).replace(/"@@D\((-?\d+),(\d+),(\d+)\)@@"/g, 'D($1,$2,$3)');
const out = `// Generated by scripts/build/generate-demo-data.mjs (Phase 2.5) from the
// retired demo fork's showcase data. Loaded ONLY when the embed runs as
// client=demo: the same app, with this in-memory dataset behind a mock
// supabase-js client — the demo NEVER touches the real backend.
// Dates are computed relative to "now", so the demo stays perpetually live.
window.GW_DEMO = (function () {
  'use strict';
  var DAY = 864e5;
  function D(days, h, m) {
    var t = new Date(Date.now() + days * DAY);
    return new Date(Date.UTC(t.getUTCFullYear(), t.getUTCMonth(), t.getUTCDate(), h, m, 0)).toISOString();
  }

  var DB = {
    gw_dm_teams: ${emit([...teams.values()])},
    gw_dm_tournaments: [],
    gw_dm_players: [],
    gw_dm_events: ${emit(rowsEvents)},
    gw_competitions: ${emit(rowsComps)},
    gw_rounds: ${emit(rowsRounds)},
    gw_operators_public: [{ client_key: 'demo', language: 'en', company_name: null, logo_url: null, accent_color: null, bg_color: null, surface_color: null, text_color: null, domains: [] }],
    gw_players: ${emit(rowsPlayers)},
    gw_predictions: ${emit(rowsPreds)},
    gw_leagues: ${emit(rowsLeagues)},
    gw_league_members: ${emit(rowsMembers)},
  };

  var SESSION = { user: { id: 'demo-auth-uid', email: 'demo@gameweek.cloud', user_metadata: {} } };

  function matches(row, f) {
    if (f.op === 'eq') return row[f.k] === f.v;
    if (f.op === 'in') return f.v.includes(row[f.k]);
    return true;
  }

  function Builder(tableName) {
    this.t = tableName; this.filters = []; this.orderBy = null; this.limitN = null;
    this.selectCols = '*'; this.mode = 'select'; this.payload = null; this.singleMode = null;
  }
  Builder.prototype.select = function (cols) { if (this.mode === 'select') this.selectCols = cols || '*'; return this; };
  Builder.prototype.eq = function (k, v) { this.filters.push({ op: 'eq', k: k, v: v }); return this; };
  Builder.prototype.in = function (k, v) { this.filters.push({ op: 'in', k: k, v: v }); return this; };
  Builder.prototype.order = function (k) { this.orderBy = k; return this; };
  Builder.prototype.limit = function (n) { this.limitN = n; return this; };
  Builder.prototype.maybeSingle = function () { this.singleMode = 'maybe'; return this; };
  Builder.prototype.single = function () { this.singleMode = 'strict'; return this; };
  Builder.prototype.insert = function (rows) { this.mode = 'insert'; this.payload = Array.isArray(rows) ? rows : [rows]; return this; };
  Builder.prototype.update = function (patch) { this.mode = 'update'; this.payload = patch; return this; };
  Builder.prototype.upsert = function (rows) { this.mode = 'insert'; this.payload = Array.isArray(rows) ? rows : [rows]; return this; };
  Builder.prototype.delete = function () { this.mode = 'delete'; return this; };
  Builder.prototype._run = function () {
    var tbl = DB[this.t] || [];
    var self = this;
    if (this.mode === 'insert') {
      this.payload.forEach(function (r) { tbl.push(Object.assign({ id: 'demo_' + Math.random().toString(36).slice(2, 9) }, r)); });
      return { data: this.payload, error: null };
    }
    var rows = tbl.filter(function (r) { return self.filters.every(function (f) { return matches(r, f); }); });
    if (this.mode === 'update') { rows.forEach(function (r) { Object.assign(r, self.payload); }); return { data: rows, error: null }; }
    if (this.mode === 'delete') { DB[this.t] = tbl.filter(function (r) { return rows.indexOf(r) === -1; }); return { data: null, error: null }; }
    if (this.orderBy) rows = rows.slice().sort(function (a, b) { return (a[self.orderBy] > b[self.orderBy]) ? 1 : -1; });
    if (this.limitN != null) rows = rows.slice(0, this.limitN);
    // one nested-select shape is used in the app: gw_league_members joined to gw_leagues
    if (typeof this.selectCols === 'string' && this.selectCols.indexOf('gw_leagues(') !== -1) {
      rows = rows.map(function (r) {
        var lg = DB.gw_leagues.filter(function (l) { return l.id === r.league_id; })[0] || null;
        return Object.assign({}, r, { gw_leagues: lg });
      });
    }
    if (this.singleMode) {
      var row = rows[0] || null;
      if (this.singleMode === 'strict' && !row) return { data: null, error: { message: 'no rows returned' } };
      return { data: row, error: null };
    }
    return { data: rows, error: null };
  };
  Builder.prototype.then = function (resolve, reject) { try { resolve(this._run()); } catch (e) { if (reject) reject(e); } };

  function createClient() {
    return {
      from: function (t) { return new Builder(t); },
      rpc: function (fn, args) {
        return Promise.resolve().then(function () {
          if (fn !== 'save_prediction') return { data: null, error: { message: 'demo: unknown rpc' } };
          var ev = DB.gw_dm_events.filter(function (e) { return e.id === args.p_event_id; })[0];
          if (ev && ev.kickoff_at && Date.now() >= Date.parse(ev.kickoff_at) - 30 * 60e3) {
            return { data: null, error: { message: 'locked' } };
          }
          var existing = DB.gw_predictions.filter(function (p) {
            return p.player_id === 'demo-player' && p.competition_id === args.p_competition_id && p.event_id === args.p_event_id;
          })[0];
          if (existing) { existing.prediction = args.p_prediction; }
          else {
            DB.gw_predictions.push({
              id: 'pr_' + Math.random().toString(36).slice(2, 9), client_key: 'demo',
              player_id: 'demo-player', username: 'demo_user',
              competition_id: args.p_competition_id, round_id: args.p_round_id,
              event_id: args.p_event_id, prediction: args.p_prediction, submitted_at: new Date().toISOString(),
            });
          }
          return { data: null, error: null };
        });
      },
      auth: {
        getSession: function () { return Promise.resolve({ data: { session: SESSION } }); },
        onAuthStateChange: function (cb) {
          setTimeout(function () { cb('INITIAL_SESSION', SESSION); }, 0);
          return { data: { subscription: { unsubscribe: function () {} } } };
        },
        signOut: function () { return Promise.resolve({ error: null }); },
        signUp: function () { return Promise.resolve({ data: null, error: { message: 'This is a demo — accounts are simulated. Get your own embed at gameweek.cloud!' } }); },
        signInWithPassword: function () { return Promise.resolve({ data: null, error: { message: 'This is a demo — you are already signed in as demo_user.' } }); },
        resetPasswordForEmail: function () { return Promise.resolve({ data: null, error: null }); },
        verifyOtp: function () { return Promise.resolve({ data: null, error: { message: 'demo' } }); },
      },
      functions: { invoke: function () { return Promise.resolve({ data: null, error: { message: 'demo' } }); } },
    };
  }

  return { createClient: createClient, DB: DB };
})();
`;
writeFileSync(join(root, 'apps/embed/public/demo-data.js'), out);
console.log(`wrote apps/embed/demo-data.js — teams:${teams.size} events:${rowsEvents.length} rounds:${rowsRounds.length} comps:${rowsComps.length} preds:${rowsPreds.length}`);
