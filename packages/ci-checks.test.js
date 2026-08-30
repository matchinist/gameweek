// Tests for the Phase 2.7 CI gate logic itself — a checker that silently
// passes broken input is worse than no checker.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import {
  findDuplicateDeclarations, findForbiddenPatterns, inlineClassicScripts, APP_PAGES,
} from '../scripts/build/ci-checks.mjs';

describe('duplicate-declaration detection (the H-1 guard)', () => {
  it('flags a function declared twice across separate classic script blocks', () => {
    const html = `<script>function render(){}</script><p></p><script>function render(){}</script>`;
    expect(findDuplicateDeclarations(html)).toStrictEqual(['render declared 2×']);
  });
  it('flags duplicate vars but not let/const or single declarations', () => {
    const html = `<script>var x=1; var x=2; let y=1; function f(){ function inner(){} }</script>`;
    expect(findDuplicateDeclarations(html)).toStrictEqual(['x declared 2×']);
  });
  it('ignores module scripts and nested functions', () => {
    const html = `<script type="module">function dup(){}</script><script>function dup(){}</script>`;
    expect(findDuplicateDeclarations(html)).toStrictEqual([]);
  });
  it('reports a parse error instead of passing unparseable code', () => {
    const out = findDuplicateDeclarations('<script>function {</script>');
    expect(out.length).toBe(1);
    expect(out[0]).toMatch(/PARSE ERROR/);
  });
});

describe('forbidden patterns (the 0.4/0.9 regression guard)', () => {
  it('flags console.log but not console.error', () => {
    expect(findForbiddenPatterns('console.log("x")').length).toBe(1);
    expect(findForbiddenPatterns('console.error("x")').length).toBe(0);
  });
  it('flags every unescaped known sink and accepts the escaped forms', () => {
    for (const bad of ['${row.u}', '${currentPlayer.username}', '${currentPlayer.email}',
                       '${league.name}', '${lg.code}', '${op.company_name}', '${t.logo_url}']) {
      expect(findForbiddenPatterns('x' + bad + 'y').length, bad).toBe(1);
      expect(findForbiddenPatterns('${escapeHtmlLineup(' + bad.slice(2, -1) + ')}').length, bad).toBe(0);
    }
  });
});

describe('the real pages are clean today', () => {
  for (const page of APP_PAGES) {
    it(page, () => {
      const html = readFileSync(new URL('../' + page, import.meta.url), 'utf8');
      expect(findDuplicateDeclarations(html)).toStrictEqual([]);
      expect(findForbiddenPatterns(html)).toStrictEqual([]);
    });
  }
});
