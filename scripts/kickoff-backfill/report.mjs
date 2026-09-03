// Phase 1.2 — read-only backfill report for gw_dm_events.kickoff -> kickoff_at.
//
// Usage:  node scripts/kickoff-backfill/report.mjs
//
// Fetches every event's kickoff text through the public REST API (anon key —
// dm events are world-readable by design), classifies each row with
// parse-kickoff.mjs, and prints:
//   - counts per kind
//   - every zoneless row with its UTC and Europe/London readings (the
//     customer must pick a policy before these are written)
//   - every date-only row (kickoff_at would be UTC midnight — the 30-min lock
//     then fires at 23:30 the evening before; they deserve real times)
//   - every unparseable row for manual fixing
//
// This script WRITES NOTHING. The write step is a separate, later script that
// runs only after this report has been reviewed (plan: REARCHITECTURE-PHASES
// 1.2, "reports unparseable rows for manual fix before anything depends on it").

import { parseKickoff } from './parse-kickoff.mjs';

export function buildReport(rows) {
  const out = rows.map(({ id, kickoff }) => {
    const p = parseKickoff(kickoff);
    if (p.kind === 'utc') return { id, kind: p.kind, raw: kickoff, proposed: p.iso };
    if (p.kind === 'date-only') return { id, kind: p.kind, raw: kickoff, proposed: p.iso };
    if (p.kind === 'zoneless') return { id, kind: p.kind, raw: kickoff, proposed: null, isoUtc: p.isoUtc, isoLondon: p.isoLondon };
    return { id, kind: 'unparseable', raw: kickoff ?? null, proposed: null };
  });
  const counts = {};
  for (const r of out) counts[r.kind] = (counts[r.kind] || 0) + 1;
  return { total: out.length, counts, rows: out };
}

// ── CLI entrypoint ──────────────────────────────────────────────────────────

const SUPABASE_URL = 'https://mgfzqkesikfdrahherfm.supabase.co';

async function fetchAllEvents(anonKey) {
  const rows = [];
  for (let offset = 0; ; offset += 1000) {
    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/gw_dm_events?select=id,kickoff&order=id&limit=1000&offset=${offset}`,
      { headers: { apikey: anonKey, Authorization: `Bearer ${anonKey}` } },
    );
    if (!res.ok) throw new Error(`REST ${res.status}: ${await res.text()}`);
    const page = await res.json();
    rows.push(...page);
    if (page.length < 1000) return rows;
  }
}

async function main() {
  // The anon key is public by design (RLS is the boundary); read it from the
  // embed page so this script has no config of its own.
  const { readFileSync } = await import('node:fs');
  const anonKey = readFileSync(new URL('../../apps/embed/index.html', import.meta.url), 'utf8')
    .match(/eyJ[A-Za-z0-9_.-]+/)[0];

  const rows = await fetchAllEvents(anonKey);
  const report = buildReport(rows);

  console.log(`total events: ${report.total}`);
  console.log('counts by kind:', report.counts);

  const list = (kind, fmt) => {
    const xs = report.rows.filter(r => r.kind === kind);
    if (!xs.length) return;
    console.log(`\n── ${kind} (${xs.length}) ${'─'.repeat(Math.max(0, 50 - kind.length))}`);
    for (const r of xs) console.log(fmt(r));
  };
  list('unparseable', r => `${r.id}\t${JSON.stringify(r.raw)}`);
  list('zoneless', r => `${r.id}\t${r.raw}\tUTC=${r.isoUtc}\tLondon=${r.isoLondon}`);
  list('date-only', r => `${r.id}\t${r.raw}\t-> ${r.proposed} (midnight — lock fires 23:30 the night before)`);
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop())) {
  main().catch(err => { console.error(err); process.exit(1); });
}
