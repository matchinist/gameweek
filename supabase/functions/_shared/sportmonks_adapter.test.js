// SportMonks v3 fixture parsing — written BEFORE the adapter. The shapes
// follow the documented v3 football API (fixtures with `scores` +
// `state` includes); once the owner's API key exists these get re-verified
// against real payloads and extended.
import { describe, it, expect } from 'vitest';
import { parseFixture, parseLeague } from './sportmonks_adapter.mjs';

const FT_FIXTURE = {
  id: 18535517,
  starting_at: '2026-08-30 14:00:00',
  state: { id: 5, state: 'FT', developer_name: 'FT' },
  scores: [
    { id: 1, fixture_id: 18535517, type_id: 1525, participant_id: 1, description: 'CURRENT', score: { goals: 2, participant: 'home' } },
    { id: 2, fixture_id: 18535517, type_id: 1525, participant_id: 2, description: 'CURRENT', score: { goals: 1, participant: 'away' } },
    { id: 3, fixture_id: 18535517, type_id: 1, participant_id: 1, description: '1ST_HALF', score: { goals: 1, participant: 'home' } },
  ],
};

describe('parseFixture', () => {
  it('extracts the full-time score from a finished fixture', () => {
    const f = parseFixture(FT_FIXTURE);
    expect(f).toMatchObject({ smId: 18535517, finished: true, h: 2, a: 1 });
    expect(f.startingAt).toBe('2026-08-30T14:00:00Z'); // ISO, UTC (v3 returns UTC)
  });

  it('an in-play or upcoming fixture is not finished and carries no result', () => {
    const live = { ...FT_FIXTURE, state: { id: 2, state: 'INPLAY_1ST_HALF', developer_name: 'INPLAY_1ST_HALF' } };
    expect(parseFixture(live).finished).toBe(false);
    const notStarted = { ...FT_FIXTURE, state: { id: 1, state: 'NS', developer_name: 'NS' }, scores: [] };
    const p = parseFixture(notStarted);
    expect(p.finished).toBe(false);
    expect(p.h).toBe(null);
  });

  it('after-extra-time and penalties count as finished', () => {
    for (const s of ['AET', 'FT_PEN']) {
      expect(parseFixture({ ...FT_FIXTURE, state: { developer_name: s } }).finished).toBe(true);
    }
  });

  it('missing scores on a finished fixture yield finished with null score (never 0-0)', () => {
    const f = parseFixture({ ...FT_FIXTURE, scores: [] });
    expect(f.finished).toBe(true);
    expect(f.h).toBe(null);
    expect(f.a).toBe(null);
  });
});

describe('participants + leagues', () => {
  it('extracts home/away participant ids, names and images when included', () => {
    const fx = {
      ...FT_FIXTURE,
      participants: [
        { id: 501, name: 'Besiktas JK', short_code: 'BJK', image_path: 'https://x/bjk.png', meta: { location: 'home' } },
        { id: 502, name: 'Galatasaray', short_code: 'GS', image_path: 'https://x/gs.png', meta: { location: 'away' } },
      ],
    };
    const p = parseFixture(fx);
    expect(p.homeSmId).toBe(501);
    expect(p.awayName).toBe('Galatasaray');
    expect(p.homeImage).toBe('https://x/bjk.png');
    expect(p.homeShort).toBe('BJK');
  });

  it('fixtures without participants still parse (result-only sync path)', () => {
    const p = parseFixture(FT_FIXTURE);
    expect(p.homeSmId).toBe(null);
    expect(p.h).toBe(2);
  });

  it('parseLeague maps id and name', () => {
    expect(parseLeague({ id: 600, name: 'Super Lig', short_code: 'TUR SL' })).toMatchObject({ smId: 600, name: 'Super Lig' });
  });
});
