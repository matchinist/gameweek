// Tests for the backfill report aggregation (written before report.mjs).
// buildReport() takes [{id, kickoff}] rows and groups them by parse kind,
// carrying the proposed kickoff_at value(s) per row so the customer can
// review every non-exact case before anything is written to the DB.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildReport } from './report.mjs';

const ROWS = [
  { id: 'ev1', kickoff: '2026-10-18T00:00:00.000Z' }, // utc
  { id: 'ev2', kickoff: '2026-12-26 14:00:00+00' },   // utc (pg text)
  { id: 'ev3', kickoff: '2027-03-20' },               // date-only
  { id: 'ev4', kickoff: '2026-09-19T20:00' },         // zoneless
  { id: 'ev5', kickoff: 'garbage' },                  // unparseable
  { id: 'ev6', kickoff: null },                       // unparseable
];

test('groups rows by parse kind with correct counts', () => {
  const r = buildReport(ROWS);
  assert.equal(r.counts.utc, 2);
  assert.equal(r.counts['date-only'], 1);
  assert.equal(r.counts.zoneless, 1);
  assert.equal(r.counts.unparseable, 2);
  assert.equal(r.total, 6);
});

test('utc rows carry their exact proposed kickoff_at', () => {
  const r = buildReport(ROWS);
  const ev2 = r.rows.find(x => x.id === 'ev2');
  assert.equal(ev2.kind, 'utc');
  assert.equal(ev2.proposed, '2026-12-26T14:00:00.000Z');
});

test('zoneless rows carry both readings and no single proposal', () => {
  const r = buildReport(ROWS);
  const ev4 = r.rows.find(x => x.id === 'ev4');
  assert.equal(ev4.kind, 'zoneless');
  assert.equal(ev4.proposed, null);
  assert.equal(ev4.isoUtc, '2026-09-19T20:00:00.000Z');
  assert.equal(ev4.isoLondon, '2026-09-19T19:00:00.000Z');
});

test('unparseable rows keep the raw text for manual fixing', () => {
  const r = buildReport(ROWS);
  const bad = r.rows.filter(x => x.kind === 'unparseable');
  assert.deepEqual(bad.map(x => x.raw).sort(), ['garbage', null].sort());
});

test('date-only rows propose UTC midnight but are listed for review', () => {
  const r = buildReport(ROWS);
  const ev3 = r.rows.find(x => x.id === 'ev3');
  assert.equal(ev3.kind, 'date-only');
  assert.equal(ev3.proposed, '2027-03-20T00:00:00.000Z');
});
