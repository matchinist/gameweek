#!/usr/bin/env bash
# Phase 2.1 gate — the build must reproduce today's site exactly.
#
# Written BEFORE the scaffold exists (TDD). `pnpm build` must produce _site/
# such that:
#   1. every URL the live site serves exists at the same path
#   2. every built HTML page is BYTE-IDENTICAL to its source file
#      (2.1 is deliberately zero behaviour change; the first intentional
#      transformation arrives with 2.2+ and this check evolves then)
#   3. nothing outside the allowlist leaks into _site/ (the assemble step IS
#      the deploy allowlist from Phase 0.6)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

rm -rf _site
pnpm build >/dev/null

FAILED=0
pair() { # <url-path-in-_site> <source-file>
  if [ ! -f "_site/$1" ]; then echo "FAIL  missing _site/$1"; FAILED=1; return; fi
  if cmp -s "_site/$1" "$2"; then echo "PASS  $1 byte-identical to $2"
  else echo "FAIL  $1 differs from $2:"; diff <(head -c 100000 "$2") <(head -c 100000 "_site/$1") | head -5; FAILED=1; fi
}

# apps
pair embed/index.html                     apps/embed/index.html
pair admin/index.html                     apps/admin/index.html
pair data/index.html                      apps/data/index.html
pair widgets/standings/index.html         apps/widgets/standings/index.html
pair widgets/top-scorers/index.html       apps/widgets/top-scorers/index.html
pair widgets/squad-analytics/index.html   apps/widgets/squad-analytics/index.html
pair index.html                           apps/marketing/index.html
for p in contact privacy terms pricingtest cs2fantasy welcome reset reset-password; do
  pair "$p/index.html" "apps/marketing/$p/index.html"
done
# statics + the demo fork (still a plain copy until 2.5)
pair demo/index.html demo/index.html
for f in embed.js robots.txt sitemap.xml favicon.png og-image.png CNAME llms.txt; do
  pair "$f" "$f"
done

# allowlist: nothing else may leak
LEAKS=$(cd _site && find . -type f \
  ! -path './embed/*' ! -path './admin/*' ! -path './data/*' ! -path './demo/*' \
  ! -path './widgets/*' ! -path './contact/*' ! -path './privacy/*' ! -path './terms/*' \
  ! -path './pricingtest/*' ! -path './cs2fantasy/*' ! -path './welcome/*' \
  ! -path './reset/*' ! -path './reset-password/*' \
  ! -name index.html ! -name embed.js ! -name robots.txt ! -name sitemap.xml \
  ! -name favicon.png ! -name og-image.png ! -name CNAME ! -name llms.txt | sort)
if [ -n "$LEAKS" ]; then echo "FAIL  unexpected files in _site:"; echo "$LEAKS" | head; FAILED=1
else echo "PASS  no non-allowlisted files in _site"; fi
for bad in sso-test.html CLAUDE.md package.json vite.config.js; do
  if find _site -name "$bad" | grep -q .; then echo "FAIL  $bad leaked into _site"; FAILED=1; fi
done
find _site -path "*docs*" -o -path "*supabase*" -o -path "*scripts*" -o -path "*node_modules*" | grep -q . \
  && { echo "FAIL  internal directory leaked into _site"; FAILED=1; } || echo "PASS  no internal directories in _site"

TOTAL=$(find _site -type f | wc -l)
echo "files in _site: $TOTAL"
[ "$FAILED" -eq 0 ] && echo "ALL GREEN" || { echo "FAILURES"; exit 1; }
