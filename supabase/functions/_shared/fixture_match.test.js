// Fixture-to-event matching for the provider mapping UI — written BEFORE
// the module. Provider fixtures (with participant names + kickoff) get
// matched against our hand-curated events by kickoff proximity and
// normalized team-name similarity; the admin reviews every suggestion
// before anything is linked.
import { describe, it, expect } from 'vitest';
import { normalizeTeamName, nameScore, suggestFixtureLinks } from './fixture_match.mjs';

describe('normalizeTeamName', () => {
  it('strips diacritics, punctuation and club suffixes', () => {
    expect(normalizeTeamName('Beşiktaş JK')).toBe('besiktas');
    expect(normalizeTeamName('Fenerbahçe SK')).toBe('fenerbahce');
    expect(normalizeTeamName('Arsenal FC')).toBe('arsenal');
    expect(normalizeTeamName('F.C. Porto')).toBe('porto');
  });
});

describe('nameScore', () => {
  it('is 1 for equal normalized names and high for containment', () => {
    expect(nameScore('Beşiktaş', 'Besiktas JK')).toBe(1);
    expect(nameScore('Manchester United', 'Man United')).toBeGreaterThanOrEqual(0.5);
    expect(nameScore('Arsenal', 'Chelsea')).toBeLessThan(0.4);
  });
});

describe('suggestFixtureLinks', () => {
  const teams = { tmA: { name: 'Beşiktaş' }, tmB: { name: 'Galatasaray' }, tmC: { name: 'Trabzonspor' } };
  const events = [
    { id: 'ev1', homeId: 'tmA', awayId: 'tmB', kickoffAt: '2026-09-05T17:00:00Z' },
    { id: 'ev2', homeId: 'tmC', awayId: 'tmA', kickoffAt: '2026-09-12T17:00:00Z' },
  ];
  const fixtures = [
    { smId: 111, homeName: 'Besiktas JK', awayName: 'Galatasaray SK', startingAt: '2026-09-05T16:00:00Z' },
    { smId: 222, homeName: 'Kasimpasa', awayName: 'Rizespor', startingAt: '2026-09-05T14:00:00Z' },
  ];

  it('links a fixture to the event with matching names near the same kickoff', () => {
    const out = suggestFixtureLinks(fixtures, events, teams);
    const m = out.find((s) => s.smId === 111);
    expect(m.eventId).toBe('ev1');
    expect(m.score).toBeGreaterThan(0.8);
  });

  it('leaves unknown fixtures unmatched instead of forcing a bad link', () => {
    const out = suggestFixtureLinks(fixtures, events, teams);
    expect(out.find((s) => s.smId === 222).eventId).toBe(null);
  });

  it('never matches across a large kickoff gap even when names agree', () => {
    const far = [{ smId: 333, homeName: 'Besiktas', awayName: 'Galatasaray', startingAt: '2026-11-01T17:00:00Z' }];
    expect(suggestFixtureLinks(far, events, teams)[0].eventId).toBe(null);
  });
});
