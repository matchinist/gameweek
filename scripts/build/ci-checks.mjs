// Phase 2.7 — repo-quality gates that block the deploy.
//
//   node scripts/build/ci-checks.mjs        exit 0 = clean
//
// 1. Duplicate top-level declarations. Classic <script> blocks share one
//    global scope per page, and a duplicated `function name` silently wins by
//    hoisting order — the exact H-1 bug class deleted in Phase 0.8. Every
//    app page is parsed (acorn) and top-level function/var names are counted
//    across all its inline classic scripts.
// 2. Forbidden patterns:
//    - console.log in shipped app code (console.warn/error stay allowed)
//    - the exact unescaped user-string sinks fixed in Phase 0.4 — a
//      regression of any of them must fail CI, not wait for a pentest.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { parse } from 'acorn';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

export const APP_PAGES = [
  'apps/embed/index.html', 'apps/admin/index.html', 'apps/data/index.html',
  'apps/widgets/standings/index.html', 'apps/widgets/top-scorers/index.html',
  'apps/widgets/squad-analytics/index.html', 'apps/marketing/demo/index.html',
];

// Known user- or operator-controlled strings that must never be interpolated
// raw into HTML. Each entry is a regex for the FORBIDDEN (unescaped) form.
export const FORBIDDEN_PATTERNS = [
  { name: 'console.log in shipped code', re: /console\.log\(/ },
  { name: 'unescaped ${row.u}', re: /\$\{row\.u\}/ },
  { name: 'unescaped username interpolation', re: /\$\{currentPlayer\.username\}/ },
  { name: 'unescaped email interpolation', re: /\$\{currentPlayer\.email\}/ },
  { name: 'unescaped league name', re: /\$\{(league|lg)\.name\}/ },
  { name: 'unescaped league code', re: /\$\{(league|lg)\.code\}/ },
  { name: 'unescaped operator branding', re: /\$\{(op|t)\.(company_name|logo_url)\}/ },
];

export function inlineClassicScripts(html) {
  return [...html.matchAll(/<script(?![^>]*\bsrc=)([^>]*)>([\s\S]*?)<\/script>/g)]
    .filter(m => !/type\s*=\s*["']module["']/.test(m[1]))
    .map(m => m[2]);
}

export function findDuplicateDeclarations(html) {
  const counts = new Map();
  for (const src of inlineClassicScripts(html)) {
    let ast;
    try { ast = parse(src, { ecmaVersion: 'latest' }); }
    catch (e) { return [`PARSE ERROR: ${e.message}`]; }
    for (const node of ast.body) {
      if (node.type === 'FunctionDeclaration' && node.id) {
        counts.set(node.id.name, (counts.get(node.id.name) || 0) + 1);
      }
      if (node.type === 'VariableDeclaration') {
        for (const d of node.declarations) {
          if (d.id.type === 'Identifier') {
            // let/const redeclaration throws at runtime; var silently merges —
            // count only function+var (the hoisting trap), not let/const.
            if (node.kind === 'var') counts.set(d.id.name, (counts.get(d.id.name) || 0) + 1);
          }
        }
      }
    }
  }
  return [...counts.entries()].filter(([, n]) => n > 1).map(([name, n]) => `${name} declared ${n}×`);
}

export function findForbiddenPatterns(html) {
  const hits = [];
  for (const { name, re } of FORBIDDEN_PATTERNS) {
    const lines = html.split('\n');
    lines.forEach((line, i) => {
      if (re.test(line)) hits.push(`${name} at line ${i + 1}`);
    });
  }
  return hits;
}

const isMain = process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop());
if (isMain) {
  let failed = false;
  for (const page of APP_PAGES) {
    const html = readFileSync(join(root, page), 'utf8');
    const dups = findDuplicateDeclarations(html);
    const bad = findForbiddenPatterns(html);
    for (const d of dups) { console.error(`FAIL ${page}: duplicate declaration — ${d}`); failed = true; }
    for (const b of bad) { console.error(`FAIL ${page}: ${b}`); failed = true; }
    if (!dups.length && !bad.length) console.log(`ok   ${page}`);
  }
  if (failed) process.exit(1);
  console.log('ci-checks clean');
}
