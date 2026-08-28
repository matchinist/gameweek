# Gameweek — Codebase Assessment

**Repository:** `matchinist/gameweek` · **Branch:** `main` @ `f25d78a` · **Date:** 2026-08-27
**Scope:** all 24 tracked files (~1.1 MB of HTML/JS/CSS, 467 commits, 2026-06-16 → 2026-08-18)

> **Status update (2026-08-28, `a06b055`)** — this is a point-in-time assessment; the body below is unchanged. Since the baseline:
>
> - **Closed:** C-3 (player emails) — fixed via RLS lockdown + `gw_operators_public` view, **verified against production**. The live leak was actually wider than assessed: `gw_operators.email` and Stripe IDs also leaked to the anon key; both closed. The username TOCTOU race (§5.1) is closed by a unique index on `gw_players(client_key, username)`.
> - **Partially closed:** C-5 — operator/player policies are now committed and current; `gw_admins`, `gw_dm_players`, `gw_client_coverage`, `gw_campaigns`, `gw_billing_current` still have no policy in the repo. H-7 — usernames can no longer collide, but `players_update_own` still restricts no columns and `client_key` is still mutable.
> - **Still open:** C-1 (cheatable predictions), C-2 (globally writable `gw_dm_*`), C-4 (XSS — `${row.u}` now at `embed:5288`), H-1 (duplicate functions, now `embed:3116`/`:4201` etc.), H-2, H-6, M-8 (unpinned `supabase-js@2`, no SRI), L-2 (session emails still logged at `admin:4171`, `data:2930`).
> - **New since baseline:** private leagues (`gw_leagues`, `gw_league_members`) — created ad hoc, **no RLS in the repo**, membership keyed on username (§5.3 applies); `sso-test.html` and four more `.sql` files are now publicly served (M-2 got wider); host-page SSO adds the first server-side component (see [SSO.md](./SSO.md)) and one deliberate fail-open (origin check with an empty domain list).
> - Portuguese added — i18n counts in §12 now cover 4 languages.
>
> Current state and delta detail: [ARCHITECTURE.md §11](./ARCHITECTURE.md#11-addendum--changes-since-f25d78a-as-of-a06b055-2026-08-28).

---

## 1. Executive summary

Gameweek is a white-label, embeddable free-to-play sports prediction game. It is a **fully client-side application**: 24 static HTML files served from GitHub Pages, talking directly to Supabase from the browser. There is no server, no build step, no test suite, and no application code that the operator or player cannot read and replay.

That architecture has bought real velocity — 467 commits in nine weeks, sub-minute deploys, zero build-toolchain maintenance — and for a small team shipping a product to early customers it was a defensible trade. The code itself is better than its structure suggests: the comments are unusually good, capturing *why* at exactly the decisions where a future reader would guess wrong.

The problem is that the trade has now been made in one place it cannot survive: **the security and integrity model.** Because every rule lives in the browser and every write goes straight to the database, the game's core promise — that a prediction was made before kick-off — is not enforced anywhere. A player with the browser devtools open can win any competition on any operator's site. Alongside that sit four other critical issues, including a policy that lets any registered player rewrite the shared sports database for the entire platform, and one that exposes every player's email address to anyone who views the page source.

None of this requires abandoning the architecture. It requires moving a small number of decisions — deadline enforcement, scoring, and identity — behind Supabase Edge Functions and RLS policies that the client cannot bypass. That is a focused, bounded piece of work, and it is the single highest-value thing this codebase needs.

### Scorecard

| Dimension | Rating | One-line assessment |
|---|---|---|
| Architecture | ⚠️ Adequate, at its ceiling | Right call at 0 customers; the no-server constraint is now the binding limit |
| **Security** | 🔴 **Critical** | 5 critical findings; game integrity and player PII are both unprotected |
| Data integrity | 🔴 Critical | No server-side deadline; predictions accepted at any time |
| Reliability | ⚠️ Fragile | No tests, no CI gate, no rollback path, unpinned CDN dependency |
| Performance | ⚠️ Degrading | Every pageview downloads the whole platform's fixture database |
| Scalability | 🔴 Structural limit | Per-visitor cost grows with total platform size; revenue is capped |
| Code quality | ⚠️ Mixed | Excellent comments, poor structure; ~300 lines of dead code that reads as live |
| Readability | ✅ Good | Genuinely strong explanatory comments; consistent style |
| Maintainability | ⚠️ Strained | 5k-line files, hand-duplicated demo, no shared modules |
| Extendability | ⚠️ Costly | Each new game mode requires parallel edits in 3–4 files |
| Accessibility | 🔴 Absent | Zero ARIA, zero roles, zero focus management in the player app |
| i18n | ✅ Good | Clean `t()` with English fallback, near-parity across 3 languages |
| SEO | ⚠️ Gaps | Primary CTA page has no metadata; orphan pages are crawlable |
| Operations | 🔴 Thin | Push-to-prod, no staging, no monitoring, no error reporting |
| Privacy/compliance | 🔴 Critical | Full player email table is publicly readable |
| Documentation | ⚠️ Improving | No README; `CLAUDE.md` and this report are the first docs |

### The five things that matter most

1. **Enforce prediction deadlines server-side.** Everything else is secondary; without this the product does not work as advertised.
2. **Fix the four RLS policies** that expose player emails, allow global sports-data writes, allow cross-tenant player edits, and permit username spoofing.
3. **Escape user-controlled strings** before they enter `innerHTML` (stored XSS in leaderboards).
4. **Scope the embed's data load to the tenant.** It currently fetches the entire platform's events and teams on every pageview.
5. **Delete the duplicate function definitions in `embed/index.html`** before someone edits the copy that never runs.

---

## 2. Scope and method

Everything in this report was derived by reading the repository at `f25d78a`. Findings are labelled by confidence:

- **Verified** — read directly in the committed source; file and line numbers given.
- **Inferred** — follows from `supabase-migration.sql`, which is the only schema-of-record in the repo. **This file is known to be out of date** (see §5.4), so policy findings need confirmation against the live Supabase project before being treated as either present or absent.
- **Needs verification** — depends on live infrastructure state not visible from the repo (Supabase dashboard, Storage bucket policies, Stripe account mode, GitHub Pages settings).

I did not have access to the running Supabase project, so no finding here was confirmed by execution against production.

---

## 3. Architecture

### 3.1 Shape

```
Browser (operator's site)
   └── <iframe src="gameweek.cloud/embed?client=KEY&comp=IDS">
          └── embed/index.html   ── supabase-js (UMD, CDN) ──▶ Supabase (Postgres + Auth + Storage)
                                                                        ▲
   gameweek.cloud/admin  ── operator dashboard ────────────────────────┤
   gameweek.cloud/data   ── platform-admin data manager ───────────────┘
   gameweek.cloud/widgets/{standings,top-scorers,squad-analytics}  ─────┘
```

There is no application server, no API layer, and no backend code in this repository. Supabase is reached directly from every page using the public anon key, which is hardcoded in each file. That is the correct way to use an anon key — **but it means Row Level Security is the entire authorization system.** There is no second line of defence.

### 3.2 Surfaces

| Path | Audience | Size | Role |
|---|---|---|---|
| `embed/` | Players | 317 KB / 80 KB gz | The product — predictions, leaderboards, auth, theming |
| `demo/` | Prospects | 310 KB / 84 KB gz | Self-contained marketing demo, hardcoded data, no Supabase |
| `admin/` | Operators | 223 KB / 49 KB gz | Competitions, rounds, branding, embed snippet, billing, sponsorship |
| `data/` | Platform staff | 174 KB / 42 KB gz | Global sports database: teams, tournaments, fixtures, squads, standings |
| `widgets/*/` | Players | 16–23 KB | Standalone embeddable standings / top-scorers / squad analytics |
| `index.html`, `contact/`, `privacy/`, `terms/` | Public | 8–27 KB | Marketing and legal |
| `welcome/`, `reset/`, `reset-password/` | Auth | 8 KB | Supabase auth callback landings |
| `pricingtest/`, `cs2fantasy/` | — | 4–36 KB | **Orphaned** — deployed, crawlable, unlinked |

### 3.3 The two-layer data model

This is the strongest architectural idea in the codebase and it is worth preserving.

**Global layer** (`gw_dm_teams`, `gw_dm_tournaments`, `gw_dm_events`, `gw_dm_players`) — one shared sports database maintained by Gameweek staff in `/data`, reused by every operator. Tournaments carry a nested `seasons` JSON blob holding team lists, round groupings and standings.

**Tenant layer** (`gw_operators`, `gw_competitions`, `gw_rounds`, `gw_players`, `gw_predictions`, `gw_campaigns`) — keyed by `client_key`, one row-set per operator.

**`gw_client_coverage`** bridges them, restricting which global tournaments and teams a given operator can see (`null` = everything).

The payoff is real: an operator configuring a Premier League competition picks from fixtures someone has already entered once, centrally. The cost is equally real and is discussed in §7.2 and §8.3 — the global layer has no tenant key, so it cannot be filtered per-request, and it is maintained by hand.

### 3.4 Three isolated auth sessions

Each surface constructs its Supabase client with a distinct `storageKey`:

| Surface | `storageKey` | Gate |
|---|---|---|
| `embed/` | `gw-player` | row in `gw_players` matching `auth_id` + `client_key` |
| `admin/`, `reset/` | `gw-operator` | row in `gw_operators` matching `auth_id` (auto-created on first login) |
| `data/` | `gw-admin` | row in `gw_admins` matching `auth_id` |

This is a subtle and correct decision — an operator who also plays on their own embed would otherwise have one session overwrite the other. It is the kind of detail that is easy to get wrong and expensive to debug. Preserve it.

### 3.5 Architectural assessment

The no-server design is the right starting point for this product and the wrong ending point. Specifically:

- **What it does well:** zero build risk, zero infrastructure to operate, instant deploys, trivially cheap hosting, and a codebase any single developer can hold in their head.
- **What it cannot do:** enforce any rule the player must not be able to break (§4.1), keep data private that the client must not read (§4.3), scope a query the client shouldn't be able to widen (§7.2), or execute anything on a schedule.

The fix is not a rewrite. Supabase Edge Functions can absorb the four or five operations that genuinely need to be authoritative — write a prediction, compute a score, register a player, read a leaderboard — while everything else stays exactly as it is. That is a bounded change that removes every critical finding in this report.

---

## 4. Security

> Five critical findings. Items 4.1–4.4 are exploitable by any person who can load an operator's embed. I would treat 4.1, 4.2 and 4.3 as requiring action before the next customer is onboarded.

### 4.1 🔴 CRITICAL — Prediction deadlines are not enforced anywhere but the browser

**Verified.** Three facts combine into a total break of the game's integrity:

1. Locks are computed client-side only:
   `embed/index.html:3066`, `:3138`, `:4106`, `:4178` —
   `const isLocked = ko != null ? (Date.now() >= ko - 30*60*1000) : (ev.locked || false)`
2. Writes go straight from the browser to Postgres with no time check:
   `embed/index.html:1274` `savePred()` → `supa.from('gw_predictions').upsert({...})`.
   The governing policy (`supabase-migration.sql:104`) checks only that the row's `player_id` belongs to the caller. It does not consider kick-off time, round status, or whether a result already exists.
3. Points are never stored. They are recomputed in the browser at render time from the stored prediction and the actual result (`embed/index.html:3049` / `:4089` `scorePoints`, `:1936` `computeLineupRoundScore`).

**Consequence:** a player opens devtools after full-time, issues a single `upsert` against `gw_predictions` with the correct scoreline, and every other player's browser renders them a perfect score. No tampering with points is needed — the client computes them honestly from a dishonest prediction. This works for every mode and it is invisible to the operator.

There is no partial mitigation available in client code, because the client is the attacker.

**Fix.** Route prediction writes through a Supabase Edge Function that validates `now() < kickoff - 30 min` server-side, then revoke direct `INSERT`/`UPDATE` on `gw_predictions` from the anon role. As a defence-in-depth second layer, add a `WITH CHECK` clause that joins to `gw_dm_events` and rejects rows whose event has already kicked off. Long-term, points should be computed and persisted server-side once results land, so leaderboards read a stored integer rather than replaying scoring logic in every visitor's browser.

### 4.2 🔴 CRITICAL — Any authenticated user can rewrite the global sports database

**Inferred** from `supabase-migration.sql:117-119`:

```sql
create policy "dm_teams_write"       on gw_dm_teams       for all using (auth.uid() is not null);
create policy "dm_tournaments_write" on gw_dm_tournaments for all using (auth.uid() is not null);
create policy "dm_events_write"      on gw_dm_events      for all using (auth.uid() is not null);
```

`FOR ALL` covers `INSERT`, `UPDATE` and `DELETE`. When `WITH CHECK` is omitted, Postgres reuses the `USING` expression for inserts as well. The predicate is simply "is signed in".

**Consequence:** anyone who registers a free player account on *any* operator's embed — including the public `demo` client — receives a token that can modify or delete every team, tournament, fixture, kick-off time and result on the platform. That is simultaneously a denial-of-service against every customer, a way to fabricate results and therefore leaderboard outcomes, and an unrecoverable data-loss risk given there is no visible backup or audit trail.

The `data/` UI gates on a `gw_admins` row, but that gate is cosmetic — it controls what the page renders, not what the database accepts.

**Fix.** Replace the predicate with an existence check against `gw_admins`:
`using (exists (select 1 from gw_admins where auth_id = auth.uid()))`, and add the matching `with check`. Verify against the live project, since the migration file is stale.

### 4.3 🔴 CRITICAL — Every player's email address is publicly readable

**Inferred** from `supabase-migration.sql:96-97`:

```sql
create policy "players_read_public" on gw_players for select using (true);
```

RLS policies are permissive and OR'd together, so this policy overrides the narrower `players_read_own` alongside it. `gw_players` contains `email` (written at `embed/index.html:1103`).

**Consequence:** anyone who reads the page source — the anon key is right there at `embed/index.html:516` — can enumerate the full `gw_players` table: every registered player's email, username and `client_key`, across every operator. This is a personal-data breach under GDPR, and the `client_key` column makes it trivially segmentable by operator, which raises it from "a list of emails" to "your competitor's customer list".

The intent was clearly to let the leaderboard read other players' usernames. That is a legitimate need served by a much narrower grant.

**Fix.** Drop `players_read_public`. Expose a view containing only `id` and `username`, or drop the join entirely — the leaderboard already reads `username` denormalized onto `gw_predictions` (`embed/index.html:2308`, `:2377`, `:2452`) and does not need `gw_players` at all. Then confirm whether the table was ever enumerated, since disclosure obligations may follow.

### 4.4 🔴 CRITICAL — Stored XSS through leaderboard usernames

**Verified.** The chain:

- Username charset is validated **only in the browser**: `embed/index.html:1085` — `/^[a-zA-Z0-9_]+$/`.
- The username is denormalized onto every prediction row the player writes: `embed/index.html:1283` — `username: currentPlayer.username`.
- The governing RLS policy constrains *which rows* a player may write, not *what values* the columns hold (`supabase-migration.sql:104`).
- Leaderboard rows interpolate it into HTML unescaped: `embed/index.html:4681` — `<span class="lb-uname ...">${row.u}</span>`.

**Consequence:** a player sets `username` to `<img src=x onerror=...>` via a direct API call, then saves one prediction. Every other player who opens that leaderboard executes the payload — inside an iframe on the operator's own domain, with access to that player's Supabase session in `localStorage` under `gw-player`. Account takeover across the tenant follows.

This is not the only unescaped sink. `embed/index.html:482`, `:483`, `:5006`, `:5008` interpolate `logo_url` and `company_name` into `innerHTML`; `admin/index.html:3548`, `:3573` do the same for campaign logos; `data/index.html:1926` for `company_name`. Those are operator-controlled rather than player-controlled, so the severity is lower, but the pattern is the same. Across the four main files there are 183 `innerHTML` assignments and exactly three escaping helpers (`embed:1714`, `admin:3454`, `widgets/standings:193`), none of which is applied to the leaderboard path.

**Fix.** Escape at every interpolation of any value that came from the database. The immediate hot spot is `embed/index.html:4681`. Enforce the username charset with a Postgres `CHECK` constraint so the database, not the browser, is the arbiter.

### 4.5 🔴 CRITICAL (needs verification) — Five live tables have no RLS definition in the repo

**Verified** that they are absent from the schema file; **needs verification** against the live project.

`supabase-migration.sql` enables RLS on 8 tables. Five more are in active use and appear nowhere in it:

| Table | Used at | Sensitivity |
|---|---|---|
| `gw_admins` | `data/index.html:2935`, `:2974` | **Platform-admin privilege boundary** |
| `gw_dm_players` | 8 call sites in `data/` | Personal data: name, birthday, nationality, photo |
| `gw_client_coverage` | `admin:2565`, `data:1882`, widgets | Per-tenant configuration |
| `gw_campaigns` | `admin:3529`–`3648`, `widgets/standings:211` | Commercial/sponsorship data |
| `gw_billing_current` | `admin:1624` | Revenue data |

`gw_admins` is the critical one. If RLS is disabled or permissive on it, any authenticated user can insert their own `auth_id` and become a platform administrator — which, combined with §4.2, means full control of the platform's data. `gw_dm_players` holding minors' or players' birthdays and photographs is a data-protection concern in its own right.

The repository itself contains evidence the schema file is stale: `data/index.html:1820` warns *"check RLS allows gw_admins to read all operators"*, a policy that does not exist in the migration file.

**Fix.** Export the live policy set (`select * from pg_policies`) and commit it as the schema-of-record. Confirm RLS is enabled with an explicit admin-only predicate on all five tables. See §5.4 on making schema drift structurally impossible.

### 4.6 🟠 HIGH — Predictions are world-readable before kick-off

**Inferred** from `supabase-migration.sql:101` — `create policy "predictions_read" on gw_predictions for select using (true)`.

Any anonymous caller can read every prediction on the platform, including picks for matches that have not started. In a prediction game, being able to see other players' picks before the deadline is a competitive integrity problem in its own right, separate from §4.1. It also exposes usernames and per-operator participation volumes to competitors.

**Fix.** Serve leaderboards from an Edge Function or a view that only exposes rows for rounds whose deadline has passed, plus the caller's own rows.

### 4.7 🟠 HIGH — Players can move themselves between tenants and rename themselves freely

**Inferred** from `supabase-migration.sql:92-93` — `players_update_own` permits a player to update their own row with no column restrictions. That row includes `client_key` and `username`.

A player can therefore reassign themselves to another operator's tenant, or rename themselves to match another player's username — which, because leaderboards key on the denormalized `username` string (`embed/index.html:2324`, `:2392`, `:2457` all fall back to `p.username || p.player_id`), merges two players' scores under one identity.

**Fix.** Restrict updatable columns via a trigger or a narrow `WITH CHECK`; treat `client_key` as immutable after insert. Key leaderboards on `player_id`, resolving the display name separately.

### 4.8 🟠 HIGH — The domain allowlist is collected but never enforced

**Verified.** `admin/index.html:3639-3686` provides a full UI for operators to add and remove allowed domains, persisted to `gw_operators.domains`. The string `domains` appears **zero times** in `embed/index.html`. There is no `document.referrer` check, no `ancestorOrigins` check, and no `frame-ancestors` policy anywhere in the repository.

**Consequence:** two problems, one technical and one commercial. Any third party can iframe any operator's branded game on any site. And because billing is per Monthly Active User, a competitor or a prankster embedding an operator's game on a high-traffic page drives that operator's bill toward the $150 cap with traffic they never asked for.

It is also actively misleading: the operator is shown a security control that does nothing.

**Fix.** Either enforce it — check `document.referrer` / `location.ancestorOrigins` against the stored list on load, and mirror the check server-side once predictions move behind an Edge Function — or remove the UI until it does something. GitHub Pages cannot send a `Content-Security-Policy: frame-ancestors` header, which is a genuine constraint of the hosting choice; a CDN in front of Pages (Cloudflare) would restore it.

### 4.9 🟡 MEDIUM — Ancillary security observations

- **No security headers are possible.** GitHub Pages serves static files with no header control: no CSP, no `X-Frame-Options`, no `Referrer-Policy`, no HSTS beyond what Pages sets by default. Fronting the site with Cloudflare would fix this without changing the architecture.
- **No Subresource Integrity on any CDN script** (0 `integrity=` attributes). Three third-party scripts execute with full page privileges: `supabase-js@2` (unpinned major range), `xlsx@0.18.5`, and Stripe's pricing table. A compromised or hijacked jsDelivr path would run arbitrary code in the operator dashboard and the player app. See §14.2.
- **Session email logged to console** at `admin/index.html:3893` and `data/index.html:2930` (`console.log('GW: Session restored for', session.user.email)`), alongside four other production `console.log` calls.
- **No rate limiting is achievable** on any operation, since all traffic goes browser→Supabase. Registration and password reset rely entirely on Supabase Auth's built-in limits. Prediction writes have none.
- **Stripe is in test mode.** `admin/index.html:994` uses `pk_test_51TlREt…`. If this dashboard is live to customers, the paywall cannot take real payments. **Needs verification** against the Stripe account.

---

## 5. Data model and integrity

### 5.1 Trust model

Every constraint that matters is currently expressed in JavaScript that the person it constrains can edit:

| Rule | Where it lives | Enforceable? |
|---|---|---|
| Prediction must precede kick-off | `embed:3066` and 3 siblings | ❌ Client only |
| Username charset and length | `embed:1085-1086` | ❌ Client only |
| Username uniqueness within a tenant | `embed:1093-1095` (SELECT-then-INSERT) | ❌ Race-prone, client only |
| Terms acceptance | `embed:1089` | ❌ Client only |
| Points awarded | `embed:3049` / `:4089`, recomputed per render | ❌ Client only |
| Rounds may not overlap | `admin:2821` `validateRoundOverlap` | ❌ Client only |
| Result values are sane | `admin:1941` `isNaN` check | ❌ Client only, and on a dead path (§6.3) |

The username uniqueness check is additionally a classic TOCTOU race: `SELECT` then `INSERT` with no unique constraint visible in the schema file. Two simultaneous registrations with the same name both pass.

### 5.2 Scoring is recomputed, never stored

Points are derived at render time in every visitor's browser. This has two consequences beyond §4.1:

- **Cost:** every leaderboard view re-runs scoring for every player's every prediction, client-side. An overall leaderboard pulls all predictions for a competition (`embed:4908`) and scores them all, per viewer, per view.
- **Auditability:** there is no historical record of what a player scored or why. If scoring rules change, every past leaderboard silently changes with them. Disputes cannot be settled from the data.

Storing computed points on result entry — with the raw prediction kept alongside — would fix both, and is a prerequisite for the leaderboard ever being paginated or cached.

### 5.3 Denormalization without a source of truth

`username` is copied onto every `gw_predictions` row at write time. Leaderboards read the copy (`p.username || p.player_id`). Because `gw_players.username` is separately updatable (§4.7), the copy and the original can diverge, and one player's historical rows can carry several different names. There is no reconciliation.

### 5.4 The schema file is not the schema

`supabase-migration.sql` is described in its header as a one-shot migration ("Run in Supabase SQL Editor in one go") and begins with five `truncate ... cascade` statements. It is therefore **not runnable against production** — executing it would destroy all customer data. It also omits five live tables (§4.5), the unique constraint that `savePred`'s `onConflict:'player_id,competition_id,event_id'` (`embed:1285`) depends on, and at least one policy the code expects (`data:1820`).

The repository has no way to tell what the database actually looks like, which means no reviewer — human or automated — can reason about authorization correctly.

**Fix.** Adopt sequential, additive migration files (`supabase/migrations/NNNN_*.sql`), never destructive. Export current live policies and schema as the baseline. Rename the existing file to `docs/legacy/2026-initial-auth-migration.sql` with a header warning that it is destructive and historical.

---

## 6. Reliability

### 6.1 No automated verification of any kind

No tests, no linter, no type checker, no formatter, no pre-commit hook, no CI check. The only workflow (`.github/workflows/deploy.yml`) uploads the repository to GitHub Pages on every push to `main`; it never runs anything that can fail for a code reason.

For a 5,000-line file with hand-managed global state and no module boundaries, this means every regression is found by a user. The commit history reads that way — a substantial share of recent commits are fixes for visual and logic regressions (`Fix invisible points pill background…`, `Fix invisible active-tab text on light accents`, `Fix invisible dropdown arrows on mobile Chrome`, `Fix standings widget theme not applying for real iframe visitors`, `Fix standings parser failing on tab-separated table copy-paste`).

Even a minimal gate would pay for itself: HTML validity, a JS syntax parse of each inline script, a duplicate-function-name check (which would have caught §8.1), and a grep for `console.log` and unescaped interpolation.

### 6.2 Deployment has no safety net

`push to main` → live, worldwide, in under a minute. There is no staging environment, no preview deploy, no canary, no feature flags, and no rollback other than `git revert && git push`. There is no error reporting (no Sentry or equivalent), so a JavaScript exception in the embed on a customer's site is invisible until the customer complains. There is no uptime or synthetic monitoring on the embed.

Combined with §14.2 (unpinned `supabase-js@2`), a breaking change published to that CDN tag reaches every customer simultaneously with no signal and no test to catch it.

### 6.3 🟠 HIGH — The operator result-entry modal is dead and would crash

**Verified.** In `admin/index.html`:

- `state.events` is initialized to `[]` at line 1445 and **never assigned anywhere** (`grep 'state.events *='` → no matches).
- `getEvent(id)` (line 1507) reads `state.events.find(...)` and therefore always returns `undefined`.
- `getEvent` is called from exactly three places — lines 1924, 1932, 1942 — all inside the result modal.
- `openResultModal` (line 1922) **has no call site.** The modal markup exists at 1324–1350 with working close buttons and no opener.
- If it were reachable, `saveResult()` (line 1938) would throw at `ev.result = {h,a}` on `undefined`.

Real result entry lives in `data/index.html:2742` `saveResultTab()`, which correctly persists via `saveEventFields`. So the feature works — but only for platform staff, and this ~35-line block plus its modal is broken code sitting in the operator dashboard.

There is a product consequence worth stating plainly: **operators cannot enter their own results.** Every result, for every operator, must be typed by Gameweek staff into `/data`. That is the real scaling limit on the business, discussed in §7.4.

### 6.4 Error handling

Error handling is more disciplined than typical for this kind of codebase — 58 `console.error` calls and 167 `toast()` notifications across the three main files, with save failures consistently surfaced to the user and rolled back in memory (`admin:3667-3670` `addDomain` is a good example of optimistic-update-with-rollback).

Weak points:

- **9 empty catch blocks** (`embed:412`, `:484`, `:2616`, `:4996`, `:5044`; `widgets/standings:124`, `:169`). Most guard `localStorage`, which is defensible, but `embed:4996` swallows a failure to load the player's own saved predictions — the player sees an empty prediction form with no indication anything went wrong.
- **`.single()` used 11 times** where zero rows is a normal outcome — `embed:1094` (username availability), `embed:4996`, `admin:1625` (billing), `data:2935`. `.single()` returns an error object on zero rows; several call sites destructure only `data` and silently proceed, which happens to work but obscures real failures. `maybeSingle()` is used correctly in 6 other places; the inconsistency is the issue.
- **Fire-and-forget write** at `admin:1951` — `supa.from('gw_dm_events').update({kickoff}).then(()=>{})` discards both success and error (on the dead path from §6.3, but the pattern is worth not repeating).

### 6.5 Timing and correctness edge cases

`parseKickoffMs` (`embed:1371`) has an inconsistency: the ISO branch (`new Date(s.replace(' ','T'))`) parses in the browser's **local** timezone, while the no-year fallback builds the date with `Date.UTC(...)`. The same nominal kick-off can therefore resolve to different instants depending on which branch handles it. The fallback also applies a "if this lands in the past, assume next year" heuristic, which will silently mis-date a genuinely historical fixture by twelve months.

The comments around it (lines 1381–1388) show this code has already been the subject of at least one production bug. Given that lock times, round advancement and scoring all depend on it, it is worth normalizing every kickoff to ISO-8601 UTC at write time in `/data` and deleting the fallback path entirely.

### 6.6 ID generation is inconsistent

`admin/index.html:1509` uses `crypto.randomUUID()`, with a comment recording exactly why: the previous 6-character `Math.random()` ID collided across operators, and *"deleting one operator's competition was able to delete another's."*

`data/index.html:1368` still uses the unhardened form: `'x' + Date.now().toString(36) + Math.random().toString(36).slice(2,5)` — three random characters. This generates IDs for teams, tournaments and events in the **global, cross-tenant** table, which is the blast radius that caused the original incident.

---

## 7. Performance and scalability

### 7.1 Page weight

| Page | Raw | Gzipped | Budget guidance |
|---|---|---|---|
| `embed/` | 317 KB | **80 KB** | Acceptable today; single request, no waterfall |
| `demo/` | 310 KB | 84 KB | Marketing page — heavy for a top-of-funnel asset |
| `admin/` | 223 KB | 49 KB | Fine for an authenticated dashboard |
| `data/` | 174 KB | 42 KB | Fine |
| `index.html` | 27 KB | 7 KB | Good |
| `widgets/*` | 16–23 KB | ~6 KB | Good |

Everything is inlined into one file per page, so there is exactly one HTML request and no CSS/JS waterfall. That is genuinely efficient for first paint. The cost is that nothing is cacheable across pages and any change busts the whole file — a one-character CSS fix re-downloads 80 KB.

### 7.2 🟠 HIGH — Every embed pageview downloads the entire platform's fixture database

**Verified**, and acknowledged in the code's own comment. `embed/index.html:815-826`:

```js
supa.from('gw_dm_teams').select('*').limit(10000),
// ...this table has no client_key column to filter by, so every client page
// currently pulls the entire shared event pool. Raised the cap as an
// immediate fix; the real long-term fix is scoping this query...
supa.from('gw_dm_events').select('*').limit(10000),
supa.from('gw_dm_tournaments').select('id,name,seasons'),
```

Three compounding problems:

1. **Unbounded fan-out.** Every visitor of every operator downloads up to 10,000 events and 10,000 teams — the *whole platform's* data, not their operator's. A visitor to a single-competition Turkish football embed downloads every basketball, volleyball and esports fixture ever entered for every other customer.
2. **`seasons` blobs.** `gw_dm_tournaments.seasons` is a nested JSON structure holding team lists, round groupings and full standings tables for every season. Selecting it for every tournament pulls a large and rapidly growing payload.
3. **Accidental quadratic.** `embed:858-860` defines `teamById = id => (teams||[]).find(t => t.id === id)` and calls it twice inside a `forEach` over every event — an O(teams × events) linear scan on the main thread during page load. At 2,000 teams and 10,000 events that is 40 million comparisons before first render.

**Consequence:** load time, bandwidth cost and CPU all scale with **total platform size**, not tenant size. Every new customer makes every existing customer's embed slower. This is the single clearest scaling wall in the codebase.

**Fix, in order of effort:** (1) replace `teamById` with a `Map` — a five-line change eliminating the quadratic; (2) select only needed columns instead of `*`; (3) fetch only events referenced by this client's rounds, plus the fixture list for a lineup-mode competition's team — the event IDs are already known from `gw_rounds.event_ids`; (4) add `client_key` or a coverage join to the global tables so filtering is possible in the database.

### 7.3 Serial initialization delays first data

`embed/index.html:4976-5000` awaits, in sequence: session restoration (with a **3-second** `setTimeout` fallback), then `buildCompsFromRealData()`, then the player row, then the operator theme. Worst case the first data query does not start until three seconds after script execution. The auth restore and the data load are independent and could run concurrently.

The theme-caching design partly compensates — cached colours and logo are applied pre-paint from `localStorage` (`embed:381-412`, `:466-486`) so repeat visitors see no flash. That is a nice piece of work; the data path deserves the same care.

### 7.4 Unit economics and the human bottleneck

Two scalability observations that are not about code:

- **Revenue is capped, cost is not.** Pricing is $0.30/MAU capped at $150/month (`llms.txt`, `pricingtest/index.html`). Supabase egress is billed per byte and, per §7.2, each pageview transfers the whole platform's fixture data. Pageviews are unbounded (no domain enforcement, §4.8; no caching). Gross margin therefore degrades as the platform grows, and an operator with heavy traffic or a hostile embedder can generate unbounded egress against a fixed $150 ceiling. Fixing §7.2 fixes most of this.
- **Data entry is manual and centralized.** Every fixture, result, squad and standing for every operator is typed into `/data` by Gameweek staff (§6.3). Operators cannot enter their own results. The recent Excel/CSV import work (`b6c57a9`, `25c6ade`, `5b3676b`) is clearly a response to this pressure and is the right direction. The structural answer is a sports-data API feed; the intermediate answer is letting operators enter results for their own competitions.

### 7.5 Query hygiene

37 uses of `.select('*')` and 42 queries with no `limit()` or `range()`. Leaderboards fetch every prediction for a competition (`embed:4908`) with no pagination and score them all client-side. This is fine at hundreds of players and will not be at tens of thousands.

---

## 8. Code quality

### 8.1 🟠 HIGH — Three functions are defined twice in `embed/index.html`; only the second copy runs

**Verified.**

| Function | First definition | Second definition | Bodies differ by |
|---|---|---|---|
| `renderPredictionsPane` | line 2748 | line 3833 | **401 lines** |
| `renderEventCard` | line 3063 | line 4103 | 44 lines |
| `scorePoints` | line 3049 | line 4089 | identical |

Both copies are top-level declarations in the same `<script>` block. JavaScript function declarations hoist, and the **last definition wins** — so lines 2748–3228 are dead code, and the live implementations sit ~1,000 lines further down under a section banner that says `// ── LEADERBOARD ──`.

The two copies have genuinely diverged: the dead `renderEventCard` contains a whole betting-markets rendering branch (lines 91–107 of that function) that the live one does not. This is almost certainly the residue of a copy-paste during the Soccer Roulette work (the duplicate block begins immediately after the `// ── SOCCER ROULETTE ──` section at line 3555).

**Why this matters more than ordinary dead code:** the dead copy is the one a reader finds first — it appears earlier, under a more plausible section heading, and searching for `renderEventCard` returns it first. Anyone editing it, human or AI, will make a correct-looking change that has no effect, then debug the wrong file region. This is a trap.

`admin/index.html` has the same problem in benign form: `getDMTournaments`, `getDMEvents` and `getDMTeams` are each defined twice (lines 1499–1501 and 2241–2243) with identical bodies.

**Fix.** Delete lines 2748–3228 from `embed/index.html` after confirming the live copies are the intended ones, and delete `admin:2241-2243`. Add a duplicate-declaration check to CI.

### 8.2 File and function size

| File | Lines | Longest function |
|---|---|---|
| `embed/index.html` | 5,066 | `renderPredictionsPane` (~300 lines) |
| `demo/index.html` | 4,289 | — |
| `admin/index.html` | 4,009 | `renderCompDetail` (~180) |
| `data/index.html` | 3,059 | `renderTournamentView` (~129) |

All four exceed any reasonable file-size guideline by 4–6×, and the largest render functions are 3–6× a reasonable function limit. These are string-building functions that emit hundreds of lines of HTML through template literals with embedded inline styles and inline event handlers.

The practical cost is navigational: a change to how an event card looks requires finding the right one of two implementations (§8.1) inside a 300-line template literal inside a 5,000-line file.

### 8.3 Duplication

- **`embed/` ↔ `demo/`:** 75 functions share names across both files, with 68 unique to `embed` and 76 unique to `demo`. The demo is a hand-maintained fork of the player app with mock data. There is no sync mechanism, and the commit history contains explicit re-sync commits (`c8f98f2` — *"sync demo with live control-band"*). Every player-facing UI change is a two-file change that nothing enforces.
- **Sport and market catalogues** are duplicated between `admin/index.html:1970` and `data/index.html:731`, with a comment at `admin:1968` acknowledging they are *"kept in sync manually since these are separate static files."*
- **Country lists** are duplicated between `data:1386` and flag-code maps in both `embed:1790` and `demo:1262`.
- **The Supabase client bootstrap** is repeated verbatim in 8 files.

This is the direct cost of the no-build constraint: there is no way to share a module between pages without either a build step or splitting the JS into separate `<script src>` files (which is possible today and would cost one extra request).

### 8.4 Readability — the codebase's real strength

This deserves to be said as clearly as the criticisms. The comments in this repository are unusually good. They consistently explain *why* at exactly the points where a reader would otherwise guess wrong, and several encode the history of a real bug so it cannot recur:

- `admin:1509-1515` — why IDs moved to `crypto.randomUUID`, including the cross-operator deletion incident it caused.
- `embed:1410-1424` — why an unknown kickoff must be treated as "not yet" (`+Infinity`) rather than "already passed", with the cascade bug that motivated it.
- `embed:342-380` — why correct/incorrect stay green and red rather than following the accent, and why the shade must vary with surface lightness.
- `data:719-722` — why `saveEventFields` updates a narrow column set rather than bulk-upserting, so one tab's schema problem cannot block another tab's save.
- `embed:815-821` — an honest description of the unbounded-query problem, the interim fix, and the correct long-term fix.

Naming is clear and consistent (`camelCase` functions, `UPPER_SNAKE` constants, `gw`-prefixed globals), section banners are used consistently, and the style is uniform across all four large files. A new reader can orient quickly despite the file sizes.

### 8.5 Other quality observations

- **Presentation is entirely inline.** Colours, spacing and layout are written as `style="..."` attributes inside template literals rather than classes. CSS custom properties are defined and used for the theme system, but most one-off styling bypasses them, which is why theme regressions (invisible text on certain operator colours) recur so often in the history.
- **Global mutable state.** `embed` declares ~20 module-level `let` bindings (`COMPS`, `EVENTS`, `preds`, `lineupPicks`, `lineupSaved`, `lineupBonusPicks`, `predsDirty`, …). Render functions read and write them freely. There is no single source of truth for "what is on screen".
- **Full re-render on every interaction.** `renderPredict()` is called from 22 sites and rebuilds the entire pane's HTML via `innerHTML`. Simple and predictable, but it destroys focus, scroll position and in-progress input, and it re-runs scoring for every row.
- **6 `console.log` calls** remain in production code (`admin:2490` logs `'(v2)'`, a debugging marker).

---

## 9. Maintainability

The dominant maintenance cost is **change amplification**: a single logical change usually requires several coordinated edits that nothing verifies.

| Change | Files/places to touch |
|---|---|
| Player-facing UI tweak | `embed/` + `demo/` (manually) |
| New game mode | `embed/` (render + score + rules + i18n), `admin/` (picker + config UI + save mapping), `demo/` (mock), sometimes `data/` |
| New language | `I18N` + `RULES_HTML` in `embed/`, language picker in `admin/`, `demo/` |
| New sport | `admin:1970` + `data:731` (explicitly hand-synced) |
| Schema change | Live SQL editor + `supabase-migration.sql` (which is stale and destructive) |

Compounding factors: no tests to catch a missed edit, no CI, 5,000-line files, three duplicate function definitions that silently absorb edits (§8.1), and a schema file that does not describe the schema (§5.4).

**Bus factor is 1.** 466 of 467 commits are by a single author. Nothing in the repository documents the Supabase project structure, the storage bucket layout, the Stripe configuration, the deployment settings, or the operational runbook. Until this session there was no `README`, no `docs/`, and no `CLAUDE.md`.

Also missing: `.gitignore` (the repo relies on the developer's global gitignore to keep `.claude/`, `.serena/` and `.remember/` out — a different machine would commit them, and **every tracked file is published to the public site**), `LICENSE`, and `CONTRIBUTING.md`.

---

## 10. Extendability

**What extends well.** The two-layer data model absorbs new sports and tournaments without code changes — `data/` already supports 21 sports (`data:731`). The coverage mechanism cleanly scopes what an operator sees. The theming system adapts to arbitrary operator colours without per-customer code. The widget pattern (`widgets/*`) is a good, small template for new embeddable surfaces. The `t()` helper with English fallback (`embed:689`) means a partially translated language degrades gracefully rather than showing raw keys.

**What resists extension.**

- **Game modes are the hard case.** Mode logic is spread through `if (mode === 'x')` branches across render, scoring, explainer, rules and admin configuration — 59 `mode==='score'`, 46 `mode==='lms'`, 46 `mode==='betting'`, 28 `mode==='lineup'`, 25 `mode==='ranking'`. Adding a sixth mode means finding and extending every one of those sites in three files. A mode registry — one object per mode holding `{ render, score, explain, rulesKey, adminConfig }` — would turn a scattered change into a single new entry.
- **Legacy modes are still shipped.** `lms`, `fantasy` and `matchups` render paths remain in `embed/` but can no longer be created (the admin picker at `admin:1017` offers only `score`, `betting`, `ranking`, `lineup`, `roulette`). `roulette` *is* creatable but has no translations and no rules text — `embed:4688` explicitly notes the legacy modes are left English-only. Every one of these adds branches to already-large functions.
- **No module boundaries.** Nothing can be imported, unit-tested, or reused. Splitting the inline `<script>` blocks into separate `.js` files served alongside the HTML would cost one request and immediately enable sharing between `embed` and `demo`, and testing in isolation — without introducing a build step.

---

## 11. Accessibility

This is the weakest dimension in the codebase, and unlike most findings here it carries direct legal exposure — the product is sold to media publishers in the EU and UK, where accessibility obligations (EAA, EN 301 549) increasingly apply to the publisher, who will pass the requirement to their vendor.

Measured across `embed/`, `admin/` and `data/`:

| Signal | embed | admin | data |
|---|---|---|---|
| `aria-*` attributes | **0** | 1 | **0** |
| `role=` attributes | **0** | **0** | **0** |
| `tabindex` | **0** | **0** | **0** |
| Inline `onclick` handlers | 84 | 88 | 77 |
| `<button>` elements | 109 | 84 | 69 |
| `<img>` with `alt` | 10 of ~38 | 1 | 1 |
| `prefers-reduced-motion` | **0** | **0** | **0** |

Specific problems:

- **No landmarks, no headings structure, no labels.** A screen-reader user has no way to navigate the prediction app.
- **Interactive `<div>`s.** Many `onclick` handlers sit on non-focusable elements (`toggleProfile()` on a header `div` at `embed:488`, modal overlays, comp tabs), making them unreachable by keyboard.
- **Modals trap nothing.** The auth modal, lineup picker and bonus picker have no focus trap, no `role="dialog"`, no `aria-modal`, and no focus restoration on close. Escape-to-close is not bound.
- **`<html lang="en">` on every page**, including the embed rendering Turkish or German content. Screen readers will pronounce Turkish with English phonetics. This is a one-line fix per language: set `document.documentElement.lang = LANG` in `applyTranslations()`.
- **Colour-only status.** Correct/incorrect is conveyed by green/red fills with no text or icon alternative — the `gwApplySemantics` system carefully preserves the *hue* across themes but never adds a non-colour channel.
- **No images carry `width`/`height`** (0 of 38), guaranteeing layout shift as team badges load, and none use `loading="lazy"`.
- **No reduced-motion support** despite countdown animations, drag-to-reorder, and transitions throughout.

The good news is that the markup is semantic where it counts — 109 real `<button>` elements in `embed` rather than divs — so a large share of this is reachable with additive changes rather than restructuring.

---

## 12. Internationalization

Well executed, and the most complete non-core system in the codebase.

- `t(key, vars)` at `embed:689` resolves `I18N[LANG][key] → I18N.en[key] → key`, so a missing translation degrades to English rather than showing a raw identifier.
- Key parity is close: **en ~203, tr ~204, de ~202**.
- Language is set per operator (`gw_operators.language`) rather than per player, which is the right call for a white-label embed — the operator's audience is known.
- The boundary is explicit and correct: only fixed UI strings are translated; anything the operator typed (team names, prize text, round labels) is preserved verbatim. `admin:706` communicates this to the operator directly.
- `RULES_HTML` holds long-form per-mode rules per language, separate from the short-string table.

Gaps: `<html lang>` is never updated (§11); `roulette` mode is creatable but untranslated; the legacy `lms`/`fantasy` rules are English-only by explicit decision (`embed:4688`); dates are formatted with hardcoded `'en-GB'`/`'en-US'` locales (`data:1373`, `embed:801`) regardless of `LANG`; and there is no RTL consideration, which would matter if Arabic or Hebrew is ever a target.

---

## 13. SEO and public surface

**Strong on the homepage.** `index.html` carries three JSON-LD blocks (`SoftwareApplication`, `Organization`, `FAQPage`), a canonical URL, a full Open Graph set (6 tags) and Twitter Card tags (4). `llms.txt` is a thoughtful, well-written addition — an explicit summary for AI answer engines — and `robots.txt` deliberately allows GPTBot, ClaudeBot, PerplexityBot, Applebot and others while blocking `/admin/`, `/data/` and `/embed/`. This is a deliberate, current approach to AI-era discoverability and it is done well.

**Weak everywhere else.**

| Page | description | OG | Twitter | canonical |
|---|---|---|---|---|
| `index.html` | ✅ | ✅ 6 | ✅ 4 | ✅ |
| `demo/` | ❌ | ❌ | ❌ | ❌ |
| `contact/` | ✅ | ❌ | ❌ | ✅ |
| `privacy/` | ❌ | ❌ | ❌ | ❌ |
| `terms/` | ❌ | ❌ | ❌ | ❌ |
| `pricingtest/` | ❌ | ❌ | ❌ | ❌ |
| `cs2fantasy/` | ❌ | ❌ | ❌ | ❌ |

`/demo/` is the primary conversion target — 7 inbound links from the marketing pages, `priority 0.8` in the sitemap — and has **no meta description, no Open Graph tags and no canonical**. Shared on social or Slack it renders as a bare URL. This is the highest-value SEO fix and it is fifteen minutes of work.

**Orphaned pages are deployed and crawlable.** `/pricingtest/`, `/cs2fantasy/` and `/reset/` are linked from nowhere, absent from `sitemap.xml`, and not disallowed in `robots.txt` — so they are indexable. Two specific concerns:

- `/pricingtest/` is the **only page on the site carrying concrete prices** ($0.30/MAU, $150/month cap — matching `llms.txt`, while `index.html` mentions pricing without figures). An A/B-test page that outranks or contradicts the real pricing page is a commercial liability.
- `/reset/` is superseded by `/reset-password/` — the only `redirectTo` in the codebase (`embed:1038`) points to the latter. `/reset/` is a stale auth page still publicly reachable.

`sitemap.xml` lists only two URLs (`/` and `/demo/`), omitting `/contact/`, `/privacy/` and `/terms/`. No `lastmod` values are present on either entry.

---

## 14. Operations, dependencies, and supply chain

### 14.1 Deployment

`.github/workflows/deploy.yml` checks out the repo, uploads `path: '.'` — **the entire repository** — and deploys to GitHub Pages. Implications:

- Every tracked file is publicly served, including `supabase-migration.sql`, which discloses the full RLS policy set to anyone who requests `https://www.gameweek.cloud/supabase-migration.sql`. That is a roadmap of §4.2, §4.3, §4.6 and §4.7 handed to an attacker. **Move it out of the deployed root or exclude it from the artifact.**
- With no `.gitignore`, any local tooling directory that gets committed is published. The current machine is protected only by a global gitignore.

There is no environment separation, no preview builds, no deployment approval, and no rollback mechanism beyond `git revert`.

### 14.2 Third-party dependencies

| Dependency | Version | Loaded by | Risk |
|---|---|---|---|
| `@supabase/supabase-js` | **`@2`** (unpinned major range) | 8 pages | Any upstream release changes production instantly, untested |
| `xlsx` (SheetJS) | `0.18.5` | `data/` | Version predates published advisories for prototype pollution (fixed 0.19.3) and ReDoS (fixed 0.20.2) — **verify with `npm audit` / the SheetJS advisory page** |
| Stripe pricing table | latest | `admin/` | Test-mode key (§4.9) |
| Google Fonts | — | marketing pages | Third-party request; consider self-hosting |
| Wikipedia/Wikimedia images | — | `demo/` | ~60 hotlinked team badges; no guarantee of availability or hotlink permission |

**None of the three scripts uses Subresource Integrity** (0 `integrity=` attributes repo-wide). A compromised CDN path executes arbitrary code in the operator dashboard and the player app, with access to both Supabase sessions.

Pin `supabase-js` to an exact version, add SRI hashes to all three, and schedule a deliberate upgrade cadence. Given there are no tests, an unpinned dependency is the single most likely cause of a sudden unexplained outage.

### 14.3 Observability

There is none. No error reporting, no analytics on the embed (Google Analytics is on the marketing homepage only, `index.html:5`), no performance monitoring, no uptime checks, no logging of failed writes. A JavaScript exception in a customer's embed is invisible until the customer reports it. Given §6.1, this is the second half of the same gap: nothing catches regressions before release, and nothing detects them after.

Adding a lightweight error reporter to `embed/` would be the highest-leverage single operational change available.

---

## 15. Privacy and compliance

The product collects email addresses, usernames and behavioural data from end users on behalf of EU/UK publishers, which makes Gameweek a data processor with real obligations.

- **§4.3 is a live personal-data exposure.** The full `gw_players` table — emails, usernames, tenant keys — is readable by anyone with the public anon key. If confirmed against the live database, this likely triggers notification obligations under GDPR Art. 33/34.
- **`gw_dm_players` (§4.5)** stores names, birthdays, nationalities and photographs of real athletes with no RLS policy in the repo. Depending on the leagues covered, some may be minors.
- **No data-deletion path exists.** There is no "delete my account" flow in `embed/`, and no operator-facing tool to erase a player. GDPR Art. 17 requires one.
- **No data-export path** (Art. 20 portability).
- **Consent is client-side only.** The terms checkbox at `embed:1089` is validated in the browser and nothing records *when* or *which version* was accepted. An acceptance timestamp and policy version should be persisted at registration.
- **Cross-tenant identity leakage.** `errNotRegisteredHere` (`embed:551`) tells a visitor that their email exists on the platform but is not registered on *this* site — a user-enumeration oracle that also reveals participation on another publisher's property.
- `privacy/` and `terms/` pages exist. I have not assessed their legal adequacy; that is a lawyer's job, but they should be checked against what the code actually does, particularly around the points above.

---

## 16. What is genuinely good

It would misrepresent this codebase to list only its problems. Several things here are done better than in most production code:

1. **The comments.** Consistently explain *why*, and several encode the specific bug that motivated the current design so it cannot silently recur (`admin:1509`, `embed:1410`, `embed:815`, `data:719`). This is rare and valuable.
2. **The white-label contrast system.** `gwLum` / `gwContrast` / `gwReadableText` / `gwApplySemantics` (`embed:342-380`) solve a genuinely hard problem — arbitrary operator colours must never produce unreadable text — using real WCAG relative-luminance maths, while deliberately preserving green/red semantics across light and dark surfaces.
3. **Pre-paint theme caching.** Caching the operator theme in `localStorage` and applying it from inline `<head>` script (`embed:381-412`) eliminates the flash of default branding on repeat visits. Thoughtful attention to perceived quality.
4. **Separate auth `storageKey` per surface.** A subtle correctness decision that prevents a whole class of confusing bugs.
5. **Kickoff-derived round state.** `computeCurrentRoundIdx` (`embed:1410`) deliberately derives "which round is current" from real fixture times rather than trusting a mutable admin-set status, and documents why. That is the more resilient design.
6. **`saveEventFields` isolation.** Narrowing a save to the fields one tab owns, so an unrelated schema problem cannot block it, is mature defensive thinking.
7. **The i18n fallback chain.** Degrades to English rather than exposing raw keys.
8. **`llms.txt` and the AI-crawler policy.** A current, well-judged approach to discoverability that many larger products have not addressed.
9. **Shipping velocity.** 467 commits in nine weeks with five game modes, three languages, three widgets, spreadsheet import, standings parsing and a billing integration is substantial output.

---

## 17. Prioritized roadmap

### Now — before onboarding another customer (days)

| # | Action | Addresses |
|---|---|---|
| 1 | Confirm live RLS state; export `pg_policies` and commit as schema-of-record | §4.5, §5.4 |
| 2 | Drop `players_read_public`; expose only `id`+`username` via a view | §4.3 |
| 3 | Restrict `gw_dm_*` write policies to `gw_admins` membership | §4.2 |
| 4 | Escape `${row.u}` at `embed:4681`; add a `CHECK` constraint on `username` | §4.4 |
| 5 | Remove `supabase-migration.sql` from the deployed artifact | §14.1 |
| 6 | Restrict `players_update_own` columns; make `client_key` immutable | §4.7 |
| 7 | Verify the Stripe key is intentionally test-mode | §4.9 |

### Next 30 days — close the integrity gap

| # | Action | Addresses |
|---|---|---|
| 8 | **Move prediction writes behind an Edge Function that enforces the deadline; revoke direct write access** | §4.1 |
| 9 | Persist computed points on result entry; serve leaderboards from stored values | §5.2, §7.5 |
| 10 | Gate prediction reads until a round's deadline passes | §4.6 |
| 11 | Delete `embed:2748-3228` and `admin:2241-2243` duplicate definitions | §8.1 |
| 12 | Replace `teamById` with a `Map`; select explicit columns; scope the event query to the tenant's round IDs | §7.2 |
| 13 | Add error reporting (Sentry or equivalent) to `embed/` | §14.3 |
| 14 | Pin `supabase-js` to an exact version; add SRI to all CDN scripts; audit `xlsx` | §14.2 |
| 15 | Add meta description + OG + canonical to `/demo/`; remove or `noindex` orphan pages | §13 |
| 16 | Add `.gitignore`, `README.md`, `LICENSE` | §9 |

### Next 90 days — remove the structural limits

| # | Action | Addresses |
|---|---|---|
| 17 | Introduce a minimal CI gate: JS syntax parse, duplicate-declaration check, `console.log` and unescaped-interpolation greps | §6.1 |
| 18 | Split inline `<script>` into shared `.js` files; make `embed`/`demo` share one rendering module | §8.3, §10 |
| 19 | Introduce a mode registry to replace scattered `mode === 'x'` branching; delete `lms`/`fantasy`/`matchups` paths | §10 |
| 20 | Accessibility pass on `embed/`: landmarks, labels, focus management in modals, keyboard reachability, `lang` attribute, reduced-motion | §11 |
| 21 | Let operators enter results for their own competitions; delete the dead admin modal | §6.3, §7.4 |
| 22 | Enforce the domain allowlist, or remove the UI | §4.8 |
| 23 | Adopt additive, non-destructive migration files | §5.4 |
| 24 | Front the site with a CDN to enable CSP and `frame-ancestors` | §4.9 |
| 25 | GDPR: account deletion, data export, consent timestamping | §15 |
| 26 | Front `admin`/`data` with staging; add preview deploys | §6.2 |
| 27 | Normalize all kickoffs to ISO-8601 UTC at write; delete the fallback parser branch | §6.5 |
| 28 | Harden `data:1368` `uid()` to `crypto.randomUUID` | §6.6 |

---

## 18. Findings register

| ID | Sev | Finding | Evidence | Confidence |
|---|---|---|---|---|
| C-1 | 🔴 | Prediction deadlines enforced client-side only; game is trivially cheatable | `embed:3066,1274,3049`; `migration:104` | Verified |
| C-2 | 🔴 | Any authenticated user can write/delete the global sports database | `migration:117-119` | Inferred |
| C-3 | 🔴 | Full player table (incl. email) publicly readable | `migration:96`; `embed:1103` | Inferred |
| C-4 | 🔴 | Stored XSS via username in leaderboards | `embed:1085,1283,4681` | Verified |
| C-5 | 🔴 | 5 live tables incl. `gw_admins` have no RLS in the repo's schema file | `migration` vs. 13 tables in use | Verified (absence) |
| H-1 | 🟠 | 3 functions defined twice in `embed`; only the later copy runs | `embed:2748/3833`, `3063/4103`, `3049/4089` | Verified |
| H-2 | 🟠 | Every pageview downloads the whole platform's events + teams; O(n·m) scan | `embed:815-826,858-860` | Verified |
| H-3 | 🟠 | Domain allowlist collected but never enforced | `admin:3639`; 0 refs in `embed` | Verified |
| H-4 | 🟠 | Admin result modal is dead and would throw; `state.events` never populated | `admin:1445,1507,1922,1938` | Verified |
| H-5 | 🟠 | Stripe paywall uses a test-mode publishable key | `admin:994` | Verified |
| H-6 | 🟠 | All predictions world-readable before kick-off | `migration:101` | Inferred |
| H-7 | 🟠 | Players can change their own `client_key` and `username` | `migration:92` | Inferred |
| M-1 | 🟡 | No tests, linting, types, or CI gate; push-to-prod with no rollback | `.github/workflows/deploy.yml` | Verified |
| M-2 | 🟡 | `supabase-migration.sql` is publicly served from the site root | `deploy.yml` `path: '.'` | Verified |
| M-3 | 🟡 | `demo/` is a hand-maintained fork of `embed/`; 75 shared functions, no sync | function-name diff | Verified |
| M-4 | 🟡 | Accessibility effectively absent: 0 aria/role/tabindex in `embed` | counts in §11 | Verified |
| M-5 | 🟡 | `<html lang="en">` on pages rendering tr/de | all files | Verified |
| M-6 | 🟡 | Orphan pages deployed and indexable; `/pricingtest/` is the only priced page | `sitemap.xml`, link graph | Verified |
| M-7 | 🟡 | `/demo/` — the primary CTA — has no description/OG/canonical | `demo/index.html` head | Verified |
| M-8 | 🟡 | Unpinned `supabase-js@2` and no SRI on any CDN script | 8 files, 0 `integrity=` | Verified |
| M-9 | 🟡 | `xlsx@0.18.5` predates published security advisories | `data:690` | Needs verification |
| M-10 | 🟡 | 37 `select('*')`, 42 unbounded queries, unpaginated leaderboards | repo-wide | Verified |
| M-11 | 🟡 | `data:1368` `uid()` still collision-prone in the cross-tenant table | `data:1368` vs `admin:1509` | Verified |
| M-12 | 🟡 | Timezone inconsistency + "add a year" heuristic in `parseKickoffMs` | `embed:1371-1398` | Verified |
| M-13 | 🟡 | 9 empty catch blocks; `.single()` misused 11× where 0 rows is normal | listed in §6.4 | Verified |
| M-14 | 🟡 | No error reporting, uptime, or performance monitoring | repo-wide | Verified |
| M-15 | 🟡 | No GDPR deletion/export path; consent not timestamped | `embed:1089` | Verified |
| L-1 | ⚪ | No README, LICENSE, .gitignore, CONTRIBUTING | repo root | Verified |
| L-2 | ⚪ | 6 `console.log` in production, incl. user email | `admin:3893`, `data:2930` | Verified |
| L-3 | ⚪ | Bus factor 1 (466/467 commits, single author) | `git shortlog` | Verified |
| L-4 | ⚪ | Legacy modes still shipped; `roulette` creatable but untranslated | `embed:4688`, `admin:1017` | Verified |
| L-5 | ⚪ | `sitemap.xml` omits `/contact/`, `/privacy/`, `/terms/`; no `lastmod` | `sitemap.xml` | Verified |
| L-6 | ⚪ | ~60 hotlinked Wikimedia badge images in `demo/` | `demo:357-420` | Verified |
| L-7 | ⚪ | No CSP / security headers possible on GitHub Pages | hosting constraint | Verified |

---

*Prepared by analysis of the repository at `f25d78a`. Findings marked "Inferred" derive from `supabase-migration.sql`, which is known to be out of date; confirm against the live Supabase project before acting on or dismissing them.*
