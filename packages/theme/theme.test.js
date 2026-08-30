// Tests for @gameweek/theme (written BEFORE the package exists — TDD).
//
// Two jobs:
//   1. Pin the contrast-guard behaviour with golden cases. This code is the
//     reason operator-picked colours never render invisible text; the tests
//     make that promise explicit.
//   2. Anti-drift: the apps still carry inline copies of these functions
//     (classic-script pages can't import modules yet — consumption arrives
//     with modularisation; packages/scoring's first consumer is the Phase 3
//     score-round function). This suite extracts the inline copies from the
//     shipped HTML and property-checks them against the package, so the
//     copies cannot drift without a red build — the failure mode that made
//     demo/ a 4,400-line liability can't repeat here.

import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { gwLum, gwContrast, gwReadableText, gwApplySemantics } from './index.js';

// ── golden behaviour ────────────────────────────────────────────────────────

describe('gwLum', () => {
  it('computes WCAG relative luminance', () => {
    expect(gwLum('#FFFFFF')).toBeCloseTo(1, 5);
    expect(gwLum('#000000')).toBeCloseTo(0, 5);
    expect(gwLum('#FF0000')).toBeCloseTo(0.2126, 4);
    expect(gwLum('#00FF00')).toBeCloseTo(0.7152, 4);
  });
  it('expands 3-digit hex and tolerates a missing #', () => {
    expect(gwLum('#fff')).toBeCloseTo(1, 5);
    expect(gwLum('fff')).toBeCloseTo(1, 5);
    expect(gwLum('#abc')).toBeCloseTo(gwLum('#aabbcc'), 10);
  });
  it('returns null for unparseable input', () => {
    expect(gwLum('')).toBeNull();
    expect(gwLum(null)).toBeNull();
    expect(gwLum('#12')).toBeNull();
  });
});

describe('gwContrast', () => {
  it('white on black is 21:1, self on self is 1:1', () => {
    expect(gwContrast('#FFFFFF', '#000000')).toBeCloseTo(21, 5);
    expect(gwContrast('#888888', '#888888')).toBeCloseTo(1, 5);
  });
  it('fails open (21) when a colour is too short to parse', () => {
    expect(gwContrast('', '#FFFFFF')).toBe(21);
    expect(gwContrast('#12', '#FFFFFF')).toBe(21);
  });
  it('documents the long-garbage quirk: ≥6 chars of non-hex yields NaN, and gwReadableText then falls through to #FFFFFF', () => {
    // Real inline behaviour, extracted unchanged: parseInt('ok',16) is NaN,
    // which flows through contrast. Harmless in practice — these functions
    // only ever receive hex from the operator colour pickers — but pinned
    // here so a future "fix" is a deliberate decision, not an accident.
    expect(gwContrast('oklch(0.5 0.1 200)', '#FFFFFF')).toBeNaN();
    expect(gwReadableText('#888888', 'oklch(0.5 0.1 200)')).toBe('#FFFFFF');
  });
});

describe('gwReadableText', () => {
  it('passes a legible pairing through unchanged', () => {
    expect(gwReadableText('#111111', '#FFFFFF')).toBe('#111111');
  });
  it('replaces an illegible pairing with the better of dark/light', () => {
    expect(gwReadableText('#FFFFFF', '#FFFFFF')).toBe('#111111');
    expect(gwReadableText('#000000', '#111111')).toBe('#FFFFFF');
  });
  it('mid-tone surfaces pick whichever pole truly contrasts more', () => {
    const out = gwReadableText('#B0A030', '#A09020');
    expect(['#111111', '#FFFFFF']).toContain(out);
    expect(gwContrast(out, '#A09020')).toBeGreaterThanOrEqual(gwContrast(out === '#111111' ? '#FFFFFF' : '#111111', '#A09020'));
  });
  it('leaves falsy input untouched', () => {
    expect(gwReadableText(null, '#FFFFFF')).toBeNull();
    expect(gwReadableText('#111111', undefined)).toBe('#111111');
  });
});

describe('gwApplySemantics', () => {
  const capture = () => {
    const set = {};
    return { set, root: { setProperty: (k, v) => { set[k] = v; } } };
  };
  it('dark surfaces get the light green/red variants', () => {
    const { set, root } = capture();
    gwApplySemantics(root, '#111111');
    expect(set['--green']).toBe('#4ADE80');
    expect(set['--red']).toBe('#F87171');
  });
  it('light surfaces get the dark variants', () => {
    const { set, root } = capture();
    gwApplySemantics(root, '#FFFFFF');
    expect(set['--green']).toBe('#16A34A');
    expect(set['--red']).toBe('#DC2626');
  });
  it('an unparseable surface is treated as light (safe default)', () => {
    const { set, root } = capture();
    gwApplySemantics(root, 'transparent');
    expect(set['--green']).toBe('#16A34A');
  });
});

// ── anti-drift: package must equal the inline copies in shipped HTML ────────

function inlineCopies(htmlPath) {
  const html = readFileSync(new URL(htmlPath, import.meta.url), 'utf8');
  const grab = (name) => {
    const m = html.match(new RegExp(`function ${name}\\([^)]*\\)\\{[\\s\\S]*?\\n\\}`));
    if (!m) throw new Error(`${name} not found in ${htmlPath}`);
    return m[0];
  };
  const src = ['gwLum', 'gwContrast', 'gwApplySemantics', 'gwReadableText'].map(grab).join('\n');
  return new Function(`${src}; return { gwLum, gwContrast, gwApplySemantics, gwReadableText };`)();
}

const SAMPLE_COLORS = [
  '#FFFFFF', '#000000', '#111111', '#fff', 'fff', '#4F46E5', '#B0A030', '#0a84ff',
  '', null, undefined, '#12', 'not-a-color', 'rgba(0,0,0,0.5)',
  ...Array.from({ length: 200 }, (_, i) => '#' + ((i * 2654435761) >>> 8).toString(16).padStart(6, '0').slice(0, 6)),
];

for (const page of ['../../apps/embed/index.html', '../../apps/widgets/standings/index.html']) {
  describe(`anti-drift vs inline copy in ${page.replace('../../', '')}`, () => {
    const inline = inlineCopies(page);
    it('gwLum agrees on every sample', () => {
      for (const c of SAMPLE_COLORS) expect(gwLum(c), `gwLum(${c})`).toStrictEqual(inline.gwLum(c));
    });
    it('gwContrast agrees on every pair', () => {
      for (const a of SAMPLE_COLORS.slice(0, 30)) for (const b of SAMPLE_COLORS.slice(0, 30)) {
        expect(gwContrast(a, b), `gwContrast(${a},${b})`).toStrictEqual(inline.gwContrast(a, b));
      }
    });
    it('gwReadableText agrees on every pair', () => {
      for (const a of SAMPLE_COLORS.slice(0, 30)) for (const b of SAMPLE_COLORS.slice(0, 30)) {
        expect(gwReadableText(a, b), `gwReadableText(${a},${b})`).toStrictEqual(inline.gwReadableText(a, b));
      }
    });
    it('gwApplySemantics sets identical properties', () => {
      for (const s of SAMPLE_COLORS) {
        const a = {}, b = {};
        gwApplySemantics({ setProperty: (k, v) => { a[k] = v; } }, s);
        inline.gwApplySemantics({ setProperty: (k, v) => { b[k] = v; } }, s);
        expect(a, `gwApplySemantics(${s})`).toStrictEqual(b);
      }
    });
  });
}
