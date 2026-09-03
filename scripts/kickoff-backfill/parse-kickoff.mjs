// Phase 1.2 — classifier/parser for gw_dm_events.kickoff text values.
//
// Four kinds, matching the live-data census (see parse-kickoff.test.mjs):
//   utc         Z-suffixed ISO or Postgres "+00" text  -> exact instant
//   date-only   YYYY-MM-DD                             -> UTC midnight, needs a real time
//   zoneless    YYYY-MM-DDTHH:MM[:SS[.mmm]]            -> ambiguous; both readings offered
//   unparseable anything else (incl. the year-less display fallback — a
//               backfilled value must never depend on when the script ran)
//
// The zoneless kind is never resolved here: the embed currently reads those
// with new Date() in the PLAYER'S timezone, so there is no single "correct"
// instant recorded anywhere. The backfill report shows both the UTC and the
// Europe/London reading and the customer picks the policy.

const UTC_RE = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d{1,3})?)?(Z|[+-]\d{2}(:?\d{2})?)$/;
const DATE_ONLY_RE = /^\d{4}-\d{2}-\d{2}$/;
const ZONELESS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,3})?)?$/;

export function parseKickoff(s) {
  if (typeof s !== 'string' || !s.trim()) return { kind: 'unparseable' };
  const t = s.trim();

  if (UTC_RE.test(t)) {
    // Normalise Postgres text form: space separator, bare "+00" offset.
    const ms = Date.parse(t.replace(' ', 'T').replace(/([+-]\d{2})$/, '$1:00'));
    if (Number.isNaN(ms)) return { kind: 'unparseable' };
    return { kind: 'utc', iso: new Date(ms).toISOString() };
  }

  if (DATE_ONLY_RE.test(t)) {
    const ms = Date.parse(`${t}T00:00:00.000Z`);
    if (Number.isNaN(ms)) return { kind: 'unparseable' };
    return { kind: 'date-only', iso: new Date(ms).toISOString() };
  }

  if (ZONELESS_RE.test(t)) {
    const msUtc = Date.parse(`${t}Z`);
    if (Number.isNaN(msUtc)) return { kind: 'unparseable' };
    return {
      kind: 'zoneless',
      isoUtc: new Date(msUtc).toISOString(),
      isoLondon: new Date(zonedToUtcMs(t, 'Europe/London')).toISOString(),
    };
  }

  return { kind: 'unparseable' };
}

// Interpret a zoneless local ISO string in a named IANA timezone and return
// the UTC epoch ms. Two-pass offset resolution; inside a DST gap the second
// pass wins deterministically.
function zonedToUtcMs(localIso, tz) {
  const guess = Date.parse(`${localIso}Z`);
  const off1 = tzOffsetMs(guess, tz);
  let ms = guess - off1;
  const off2 = tzOffsetMs(ms, tz);
  if (off2 !== off1) ms = guess - off2;
  return ms;
}

function tzOffsetMs(ms, tz) {
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone: tz, hour12: false,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  });
  const p = Object.fromEntries(dtf.formatToParts(new Date(ms)).map(x => [x.type, x.value]));
  const asUtc = Date.UTC(+p.year, p.month - 1, +p.day, p.hour === '24' ? 0 : +p.hour, +p.minute, +p.second);
  return asUtc - ms;
}
