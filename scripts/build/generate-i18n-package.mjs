// Regenerates packages/i18n/index.js from the inline literals in
// apps/embed/index.html (AST extraction — the literals contain braces inside
// template strings, so regex slicing is not safe). Run after editing the
// inline I18N/RULES_HTML until the embed modularises; the anti-drift tests
// in packages/i18n/i18n.test.js fail whenever the two fall out of sync.
//
//   node scripts/build/generate-i18n-package.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { parse } from 'acorn';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const html = readFileSync(join(root, 'apps/embed/index.html'), 'utf8');
const scripts = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);

function literalSource(name) {
  for (const s of scripts) {
    if (!s.includes(`const ${name}`)) continue;
    const ast = parse(s, { ecmaVersion: 'latest' });
    for (const node of ast.body) {
      if (node.type !== 'VariableDeclaration') continue;
      for (const d of node.declarations) {
        if (d.id.type === 'Identifier' && d.id.name === name) return s.slice(d.init.start, d.init.end);
      }
    }
  }
  throw new Error(`${name} not found`);
}

const out = `// @gameweek/i18n — generated verbatim from apps/embed/index.html by
// scripts/build/generate-i18n-package.mjs (Phase 2.4). Do not hand-edit the
// literals here; edit the inline source and regenerate (the anti-drift tests
// enforce sync). When the embed modularises, this file becomes the only copy
// and the generator retires.
//
// Translations cover fixed UI text only — team names, prize text, round
// labels and anything an operator typed stays exactly as entered. Language
// is per-operator (admin panel), not per-player.

export const LANGS = ['en', 'tr', 'de', 'pt'];

export const I18N = ${literalSource('I18N')};

// NOTE: no Portuguese yet — pt operators fall back to English rules (task 6.5).
export const RULES_HTML = ${literalSource('RULES_HTML')};

// Pure form of the inline t(): language is an argument instead of the page
// global LANG. Same lookup chain and the same first-occurrence-only {var}
// interpolation.
export function t(lang, key, vars){
  let s = (I18N[lang]&&I18N[lang][key]) || I18N.en[key] || key;
  if(vars) Object.entries(vars).forEach(([k,v])=>{ s = s.replace('{'+k+'}', v); });
  return s;
}
`;
mkdirSync(join(root, 'packages/i18n'), { recursive: true });
writeFileSync(join(root, 'packages/i18n/index.js'), out);
console.log('wrote packages/i18n/index.js');
