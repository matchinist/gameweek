// Phase 3.5 — tests for the leaderboard shadow-compare diff, written BEFORE
// the inline implementation. The embed renders leaderboards client-side and
// (for one release) diffs them against stored gw_leaderboards rows; the diff
// is pure, lives inline in the page, and is extracted here the same way the
// anti-drift suite extracts the scoring functions.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';

function extractDiff() {
  const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');
  const m = html.match(/function diffLeaderboardRows\([^)]*\)\{[\s\S]*?\n\}/);
  if (!m) throw new Error('diffLeaderboardRows not found inline in the embed');
  return new Function(`${m[0]}; return diffLeaderboardRows;`)();
}

describe('diffLeaderboardRows', () => {
  const diff = extractDiff();

  it('agreeing rows produce no diffs', () => {
    const client = [{ u: 'ann', pts: 12, correct: 3 }, { u: 'bob', pts: 7, correct: 2 }];
    const stored = [{ username: 'bob', points: 7, correct: 2 }, { username: 'ann', points: 12, correct: 3 }];
    expect(diff(client, stored)).toStrictEqual([]);
  });

  it('flags point disagreements with both values', () => {
    const out = diff([{ u: 'ann', pts: 12 }], [{ username: 'ann', points: 9 }]);
    expect(out).toStrictEqual([{ u: 'ann', kind: 'points', client: 12, stored: 9 }]);
  });

  it('flags rows missing on either side', () => {
    const out = diff([{ u: 'ann', pts: 5 }], [{ username: 'bob', points: 5 }]);
    expect(out.map((d) => d.kind).sort()).toStrictEqual(['missing-client', 'missing-stored']);
  });

  it("treats the lineup '-' placeholder as stored zero", () => {
    expect(diff([{ u: 'ann', pts: '-' }], [{ username: 'ann', points: 0 }])).toStrictEqual([]);
  });

  it('flags correct-count disagreement only when both sides carry one', () => {
    expect(diff([{ u: 'ann', pts: 5, correct: 2 }], [{ username: 'ann', points: 5, correct: 1 }]))
      .toStrictEqual([{ u: 'ann', kind: 'correct', client: 2, stored: 1 }]);
    // stored betting rows have correct=null — never a mismatch
    expect(diff([{ u: 'ann', pts: 5 }], [{ username: 'ann', points: 5, correct: null }])).toStrictEqual([]);
  });
});

describe('shadow wiring', () => {
  const html = readFileSync(new URL('./index.html', import.meta.url), 'utf8');

  it('demo mode never shadow-compares (zero-backend contract)', () => {
    const m = html.match(/async function shadowCompareLeaderboard[\s\S]{0,400}/);
    expect(m, 'shadowCompareLeaderboard missing').toBeTruthy();
    expect(m[0]).toContain('IS_DEMO');
  });

  it('every unfiltered leaderboard path calls the shadow', () => {
    // round + overall for the regular modes, round + overall for lineup
    expect(html.match(/shadowCompareLeaderboard\(/g).length).toBeGreaterThanOrEqual(5);
  });
});
