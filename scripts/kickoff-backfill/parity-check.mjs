// Phase 1.7 — kickoff parity gate.
//
// Compares, for every live gw_dm_events row, the legacy client interpretation
// of the text `kickoff` (what parseKickoffMs computed in a viewer's browser)
// against the backfilled/stored `kickoff_at`, across a spread of viewer
// timezones. The check passes only if every divergence is provably unable to
// change any lock state (kickoff - 30 min) or round-advance boundary
// (last kickoff + 3 h) for any viewer — i.e. the divergent event is far from
// `now` compared to the divergence size.
//
// Usage: node scripts/kickoff-backfill/parity-check.mjs   (exit 0 = parity OK)

import { readFileSync } from 'node:fs';
import { parseKickoff } from './parse-kickoff.mjs';

const SUPABASE_URL = 'https://mgfzqkesikfdrahherfm.supabase.co';
const VIEWER_TZS = ['UTC', 'Europe/London', 'Europe/Istanbul', 'America/New_York', 'Australia/Sydney'];
// A divergent pair of readings is permanently harmless once BOTH readings'
// last boundary (kickoff + 3h round-advance window; the -30min lock is
// earlier) lies in the past: every predicate has crossed under both readings
// and now only moves forward. Divergent readings with any boundary still in
// the future WILL disagree transiently as they cross at different times.
const ADVANCE_MS = 3 * 3600 * 1000;

function tzOffsetMs(ms, tz) {
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  });
  const p = Object.fromEntries(dtf.formatToParts(new Date(ms)).map(x => [x.type, x.value]));
  return Date.UTC(+p.year, p.month - 1, +p.day, p.hour === '24' ? 0 : +p.hour, +p.minute, +p.second) - ms;
}
// Legacy client reading of a zoneless string for a viewer in `tz`
function zonedToUtcMs(localIso, tz) {
  const guess = Date.parse(`${localIso}Z`);
  const off1 = tzOffsetMs(guess, tz);
  let ms = guess - off1;
  const off2 = tzOffsetMs(ms, tz);
  if (off2 !== off1) ms = guess - off2;
  return ms;
}

async function fetchAll(anonKey) {
  const rows = [];
  for (let offset = 0; ; offset += 1000) {
    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/gw_dm_events?select=id,kickoff,kickoff_at&order=id&limit=1000&offset=${offset}`,
      { headers: { apikey: anonKey, Authorization: `Bearer ${anonKey}` } },
    );
    if (!res.ok) throw new Error(`REST ${res.status}`);
    const page = await res.json();
    rows.push(...page);
    if (page.length < 1000) return rows;
  }
}

const anonKey = readFileSync(new URL('../../embed/index.html', import.meta.url), 'utf8')
  .match(/eyJ[A-Za-z0-9_.-]+/)[0];
const rows = await fetchAll(anonKey);
const now = Date.now();

let identical = 0, divergentSafe = 0;
const unsafe = [];
let maxDelta = 0, nearestDivergentGapMs = Infinity;

for (const { id, kickoff, kickoff_at } of rows) {
  const storedMs = kickoff_at ? Date.parse(kickoff_at) : null;
  const p = parseKickoff(kickoff);
  if (p.kind === 'unparseable') {
    if (storedMs !== null) unsafe.push({ id, kickoff, reason: 'stored value but legacy parser saw nothing' });
    continue;
  }
  // Legacy readings per viewer tz. utc/date-only are tz-independent.
  const legacyReadings = p.kind === 'zoneless'
    ? VIEWER_TZS.map(tz => zonedToUtcMs(kickoff.trim(), tz))
    : [Date.parse(p.kind === 'utc' ? p.iso : p.iso)];

  let rowDiverges = false;
  for (const legacyMs of legacyReadings) {
    const delta = Math.abs(legacyMs - storedMs);
    if (delta === 0) continue;
    rowDiverges = true;
    maxDelta = Math.max(maxDelta, delta);
    const lastBoundary = Math.max(legacyMs, storedMs) + ADVANCE_MS;
    nearestDivergentGapMs = Math.min(nearestDivergentGapMs, Math.abs(now - lastBoundary));
    if (lastBoundary >= now) {
      unsafe.push({ id, kickoff, kickoff_at, deltaH: delta / 3.6e6, boundaryInH: (lastBoundary - now) / 3.6e6 });
    }
  }
  if (rowDiverges) divergentSafe++; else identical++;
}

console.log(`rows: ${rows.length}`);
console.log(`identical under every viewer tz: ${identical}`);
console.log(`divergent but boundary-safe:     ${divergentSafe} (max delta ${(maxDelta / 3.6e6).toFixed(1)}h, nearest to now ${(nearestDivergentGapMs / 86400e3).toFixed(1)} days away)`);
console.log(`divergent and UNSAFE:            ${unsafe.length}`);
for (const u of unsafe.slice(0, 20)) console.log('  UNSAFE', JSON.stringify(u));
if (unsafe.length) { console.error('PARITY FAIL'); process.exit(1); }
console.log('PARITY OK — kickoff_at cannot flip any lock or round boundary for any viewer');
