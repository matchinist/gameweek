// Tests for @gameweek/i18n (written BEFORE the package — TDD).
//
// The package holds the I18N + RULES_HTML literals verbatim (generated from
// the inline embed source by scripts/build/generate-i18n-package.mjs) plus a
// pure t(). Anti-drift: this suite AST-extracts the inline literals from
// apps/embed/index.html on every run and deep-compares — the inline copy and
// the package cannot diverge without a red build.

import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { parse } from 'acorn';
import { I18N, RULES_HTML, LANGS, t } from './index.js';

function extractInline(name) {
  const html = readFileSync(new URL('../../apps/embed/index.html', import.meta.url), 'utf8');
  const scripts = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  for (const s of scripts) {
    if (!s.includes(`const ${name}`)) continue;
    const ast = parse(s, { ecmaVersion: 'latest' });
    for (const node of ast.body) {
      if (node.type !== 'VariableDeclaration') continue;
      for (const d of node.declarations) {
        if (d.id.name === name) {
          return new Function(`return (${s.slice(d.init.start, d.init.end)})`)();
        }
      }
    }
  }
  throw new Error(`${name} not found inline`);
}

describe('language parity', () => {
  it('I18N carries identical key sets in all four languages', () => {
    const en = Object.keys(I18N.en).sort();
    expect(en.length).toBeGreaterThan(100);
    for (const lang of ['tr', 'de', 'pt']) {
      expect(Object.keys(I18N[lang]).sort(), lang).toStrictEqual(en);
    }
  });
  it('LANGS lists exactly the supported languages', () => {
    expect(LANGS).toStrictEqual(['en', 'tr', 'de', 'pt']);
  });
  it('RULES_HTML covers the four active modes in en/tr/de — and pt is a KNOWN GAP', () => {
    for (const lang of ['en', 'tr', 'de']) {
      expect(Object.keys(RULES_HTML[lang]).sort(), lang).toStrictEqual(['betting', 'ranking', 'score', 'lineup'].sort());
    }
    // Portuguese customers currently get the English rules fallback. Pinned
    // deliberately: adding pt rules (task 6.5) will flip this expectation,
    // which is exactly the reminder it exists to be.
    expect(RULES_HTML.pt).toBeUndefined();
  });
});

describe('t()', () => {
  it('translates in the requested language with en fallback and key passthrough', () => {
    expect(t('tr', 'createLeague')).toBe(I18N.tr.createLeague);
    expect(t('pt', 'nope_not_a_key')).toBe('nope_not_a_key');
    expect(t('xx', 'createLeague')).toBe(I18N.en.createLeague);
  });
  it('interpolates {vars} — first occurrence only, matching the inline quirk', () => {
    // The inline t() uses String.replace with a plain string, which replaces
    // only the first occurrence. Pinned so a "fix" is deliberate.
    expect(t('en', 'pickMore', { n: 3 })).toBe(I18N.en.pickMore.replace('{n}', 3));
  });
});

describe('anti-drift vs inline embed copies', () => {
  it('I18N is byte-equal to the inline literal', () => {
    expect(I18N).toStrictEqual(extractInline('I18N'));
  });
  it('RULES_HTML is byte-equal to the inline literal', () => {
    expect(RULES_HTML).toStrictEqual(extractInline('RULES_HTML'));
  });
  it('t() behaves exactly like the inline t() for every key in every language', () => {
    const inlineI18N = extractInline('I18N');
    const html = readFileSync(new URL('../../apps/embed/index.html', import.meta.url), 'utf8');
    const m = html.match(/function t\(key, vars\)\{[\s\S]*?\n\}/);
    const makeInlineT = (lang) => new Function('I18N', 'LANG', `${m[0]}; return t;`)(inlineI18N, lang);
    for (const lang of ['en', 'tr', 'de', 'pt', 'xx']) {
      const inlineT = makeInlineT(lang);
      for (const key of [...Object.keys(inlineI18N.en), 'missing_key']) {
        expect(t(lang, key), `${lang}:${key}`).toBe(inlineT(key));
      }
    }
  });
});
