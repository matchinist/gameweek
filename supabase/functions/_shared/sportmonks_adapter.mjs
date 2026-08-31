// SportMonks v3 football adapter — pure parsing, vitest-covered. The ingest
// Edge Function owns the HTTP; this module owns the shapes, so the mapping
// is testable without a key and re-verifiable against real payloads later.
//
// v3 notes (documented API; unverified against the live account until the
// owner's key arrives):
//   * fixtures carry `starting_at` in UTC ("YYYY-MM-DD HH:MM:SS")
//   * `state.developer_name` is the reliable status enum
//   * `scores` (include=scores) has one row per participant per description;
//     description "CURRENT" is the latest total — at FT that IS the final.

const FINISHED_STATES = new Set(['FT', 'AET', 'FT_PEN']);

export function parseFixture(fx) {
  const state = fx.state?.developer_name || fx.state?.state || '';
  const finished = FINISHED_STATES.has(state);
  let h = null, a = null;
  (fx.scores || []).forEach((s) => {
    if (s.description !== 'CURRENT') return;
    if (s.score?.participant === 'home') h = s.score.goals;
    else if (s.score?.participant === 'away') a = s.score.goals;
  });
  if (h == null || a == null) { h = null; a = null; } // never invent half a score
  return {
    smId: fx.id,
    startingAt: fx.starting_at ? fx.starting_at.replace(' ', 'T') + 'Z' : null,
    state,
    finished,
    h: finished ? h : null,
    a: finished ? a : null,
  };
}
