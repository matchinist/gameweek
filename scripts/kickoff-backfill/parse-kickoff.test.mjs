// Tests for the kickoff-text parser behind the Phase 1.2 backfill
// (gw_dm_events.kickoff text -> kickoff_at timestamptz).
//
// Written BEFORE the implementation (TDD). Every input shape below comes from
// a census of all 2,254 live rows (2026-08-29):
//   1300  ISO datetime with Z        e.g. 2026-10-18T00:00:00.000Z
//    431  ISO date T hh:mm, no zone  e.g. 2026-09-19T20:00   <- ambiguous!
//    310  ISO date only              e.g. 2027-03-20
//    213  Postgres timestamptz text  e.g. 2026-12-26 14:00:00+00
//
// The zoneless form is the dangerous one: the embed parses it with new Date(),
// i.e. the PLAYER'S local timezone, so two players in different zones lock at
// different absolute times today. The backfill must not guess silently — it
// classifies those rows and proposes both the UTC and Europe/London readings
// for the operator to choose from.
//
// Run: node --test scripts/kickoff-backfill/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseKickoff } from './parse-kickoff.mjs';

// ── Unambiguous UTC forms ───────────────────────────────────────────────────

test('ISO datetime with Z parses as exact UTC', () => {
  const r = parseKickoff('2026-10-18T00:00:00.000Z');
  assert.equal(r.kind, 'utc');
  assert.equal(r.iso, '2026-10-18T00:00:00.000Z');
});

test('ISO datetime with Z keeps sub-minute precision', () => {
  const r = parseKickoff('2026-11-07T22:59:59.999Z');
  assert.equal(r.kind, 'utc');
  assert.equal(r.iso, '2026-11-07T22:59:59.999Z');
});

test('Postgres timestamptz text (+00, space separator) parses as exact UTC', () => {
  const r = parseKickoff('2026-12-26 14:00:00+00');
  assert.equal(r.kind, 'utc');
  assert.equal(r.iso, '2026-12-26T14:00:00.000Z');
});

test('Postgres timestamptz text with millis parses as exact UTC', () => {
  const r = parseKickoff('2026-12-30 18:44:59.999+00');
  assert.equal(r.kind, 'utc');
  assert.equal(r.iso, '2026-12-30T18:44:59.999Z');
});

// ── Date-only: parseable but imprecise ──────────────────────────────────────
// The embed's new Date('YYYY-MM-DD') reads these as UTC midnight, which makes
// the 30-min lock fire at 23:30 the evening BEFORE the match. Classified
// separately so the report can flag them for a real kickoff time.

test('date-only parses as UTC midnight and is flagged date-only', () => {
  const r = parseKickoff('2027-03-20');
  assert.equal(r.kind, 'date-only');
  assert.equal(r.iso, '2027-03-20T00:00:00.000Z');
});

// ── Zoneless datetimes: ambiguous, never silently guessed ───────────────────

test('zoneless datetime is classified ambiguous with both readings', () => {
  const r = parseKickoff('2026-12-26T14:00');
  assert.equal(r.kind, 'zoneless');
  assert.equal(r.isoUtc, '2026-12-26T14:00:00.000Z');
  // December: Europe/London is GMT (UTC+0), so both readings coincide.
  assert.equal(r.isoLondon, '2026-12-26T14:00:00.000Z');
});

test('zoneless datetime in BST differs by an hour under the London reading', () => {
  const r = parseKickoff('2026-09-19T20:00');
  assert.equal(r.kind, 'zoneless');
  assert.equal(r.isoUtc, '2026-09-19T20:00:00.000Z');
  // September: Europe/London is BST (UTC+1); 20:00 London = 19:00 UTC.
  assert.equal(r.isoLondon, '2026-09-19T19:00:00.000Z');
});

test('zoneless datetime around the spring DST gap stays deterministic', () => {
  // 2027-03-28 01:30 does not exist in Europe/London (clocks jump 01:00->02:00).
  // The converter must still return a value rather than throw; we document the
  // post-transition reading (00:30 UTC would render as 01:30 GMT pre-gap; the
  // Intl-based converter resolves inside the gap to the pre-transition offset).
  const r = parseKickoff('2027-03-28T01:30');
  assert.equal(r.kind, 'zoneless');
  assert.equal(r.isoUtc, '2027-03-28T01:30:00.000Z');
  assert.ok(['2027-03-28T01:30:00.000Z', '2027-03-28T00:30:00.000Z'].includes(r.isoLondon));
});

// ── Rejected forms ──────────────────────────────────────────────────────────

test('null and empty are unparseable', () => {
  assert.equal(parseKickoff(null).kind, 'unparseable');
  assert.equal(parseKickoff('').kind, 'unparseable');
  assert.equal(parseKickoff('   ').kind, 'unparseable');
});

test('garbage is unparseable', () => {
  assert.equal(parseKickoff('not a date').kind, 'unparseable');
  assert.equal(parseKickoff('2026-13-45T99:99').kind, 'unparseable');
});

test('legacy display form (no year) is unparseable for backfill purposes', () => {
  // The embed has a "D Mon HH:MM" fallback that infers a year at parse time.
  // A backfill must never write a value that depends on when the script ran,
  // and the census found zero such rows live — so these go to the report.
  assert.equal(parseKickoff('15 Mar 20:00').kind, 'unparseable');
});

// ── Round-trip sanity against the live census shapes ────────────────────────

test('every live format shape classifies into a non-unparseable kind', () => {
  const shapes = [
    '2026-10-18T00:00:00.000Z',
    '2026-09-19T20:00',
    '2027-03-20',
    '2026-12-26 14:00:00+00',
    '2026-12-30 18:44:59.999+00',
  ];
  for (const s of shapes) {
    assert.notEqual(parseKickoff(s).kind, 'unparseable', `should parse: ${s}`);
  }
});
