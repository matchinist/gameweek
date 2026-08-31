// Fixture-to-event matching for the provider mapping UI — pure, vitest-
// covered. Suggestions only: the admin confirms every link before anything
// is written, so this optimises for "obviously right or honestly unsure",
// never for forcing a match.

const CLUB_SUFFIXES = new Set(['fc', 'cf', 'afc', 'sk', 'sc', 'jk', 'cd', 'ac', 'as', 'ss', 'club', 'clube', 'de', 'the']);

export function normalizeTeamName(name) {
  return String(name || '')
    .normalize('NFD').replace(/[̀-ͯ]/g, '') // diacritics
    .toLowerCase()
    .replace(/[^a-z0-9 ]+/g, ' ')
    .split(/\s+/)
    .filter((w) => w.length > 1 && !CLUB_SUFFIXES.has(w)) // single letters are punctuation shrapnel ("F.C.")
    .join(' ')
    .trim();
}

export function nameScore(a, b) {
  const na = normalizeTeamName(a), nb = normalizeTeamName(b);
  if (!na || !nb) return 0;
  if (na === nb) return 1;
  if (na.includes(nb) || nb.includes(na)) return 0.8;
  const ta = new Set(na.split(' ')), tb = new Set(nb.split(' '));
  let hit = 0;
  ta.forEach((w) => { if (tb.has(w)) hit++; });
  return hit / Math.max(ta.size, tb.size);
}

const KICKOFF_WINDOW_MS = 24 * 3600 * 1000; // same fixture, tolerant of TZ/date-entry drift
const MIN_LINK_SCORE = 0.55;                // both teams must clear this

// fixtures: [{smId, homeName, awayName, startingAt}]
// events:   [{id, homeId, awayId, kickoffAt}]   teams: {id: {name}}
// -> [{smId, eventId|null, score}]
export function suggestFixtureLinks(fixtures, events, teams) {
  return (fixtures || []).map((fx) => {
    let best = { eventId: null, score: 0 };
    const fxKo = fx.startingAt ? new Date(fx.startingAt).getTime() : null;
    for (const ev of events || []) {
      if (fxKo != null && ev.kickoffAt) {
        if (Math.abs(new Date(ev.kickoffAt).getTime() - fxKo) > KICKOFF_WINDOW_MS) continue;
      }
      const hs = nameScore(fx.homeName, teams[ev.homeId]?.name);
      const as = nameScore(fx.awayName, teams[ev.awayId]?.name);
      if (hs < MIN_LINK_SCORE || as < MIN_LINK_SCORE) continue;
      const score = (hs + as) / 2;
      if (score > best.score) best = { eventId: ev.id, score };
    }
    return { smId: fx.smId, eventId: best.eventId, score: best.score };
  });
}
