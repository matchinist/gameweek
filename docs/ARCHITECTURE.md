# Gameweek — Architecture

Diagrams of the system **as it exists today**, at commit `f25d78a`. Nothing here is aspirational — every edge was traced from the committed source, and the tables each surface touches were derived by enumerating its Supabase calls.

Companion document: [CODEBASE-ASSESSMENT.md](./CODEBASE-ASSESSMENT.md).

---

## 1. System context

There is no application server. Twenty-four static HTML files are served from GitHub Pages; each one opens its own connection to Supabase from the browser using the public anon key.

```mermaid
flowchart TB
    subgraph visitors["People"]
        player["Player<br/><i>on operator's website</i>"]
        operator["Operator<br/><i>customer</i>"]
        staff["Gameweek staff<br/><i>platform admin</i>"]
        prospect["Prospect<br/><i>evaluating</i>"]
    end

    subgraph pages["GitHub Pages — www.gameweek.cloud (static, no server)"]
        direction LR
        embed["/embed<br/><b>player app</b><br/>5,066 lines"]
        widgets["/widgets/*<br/>standings · top-scorers<br/>squad-analytics"]
        admin["/admin<br/><b>operator dashboard</b><br/>4,009 lines"]
        data["/data<br/><b>data manager</b><br/>3,059 lines"]
        marketing["/ · /demo · /contact<br/>/privacy · /terms"]
        authpages["/welcome · /reset<br/>/reset-password"]
    end

    subgraph supabase["Supabase project mgfzqkesikfdrahherfm"]
        direction LR
        pg[("Postgres<br/>13 tables<br/><b>RLS = the only<br/>authorization layer</b>")]
        auth["Auth<br/>email + password"]
        storage["Storage<br/>bucket: player-photos"]
    end

    subgraph third["Third-party — no SRI on any of these"]
        cdn["jsDelivr<br/>supabase-js@2 · xlsx@0.18.5"]
        stripe["Stripe<br/>pricing table"]
    end

    player -->|iframe| embed
    player -->|iframe| widgets
    operator --> admin
    staff --> data
    prospect --> marketing
    player -.->|email link| authpages
    operator -.->|email link| authpages

    embed --> pg
    embed --> auth
    widgets --> pg
    admin --> pg
    admin --> auth
    admin --> storage
    admin --> stripe
    data --> pg
    data --> auth
    data --> storage
    authpages --> auth
    authpages --> pg

    pages -.->|"every page loads"| cdn

    style pg fill:#fdf0ee,stroke:#a3201a,stroke-width:2px
    style supabase fill:#f5f8f6,stroke:#1e6b5e
    style pages fill:#f5f8f6,stroke:#1e6b5e
    style third fill:#faf6f0,stroke:#b4671c
```

**`/demo` is deliberately disconnected.** It runs entirely on hardcoded fixture data and never contacts Supabase, which is why it can be shown to a prospect with no account and no tenant.

---

## 2. Deployment

```mermaid
flowchart LR
    dev["Developer<br/>edits an .html file"] -->|"git push origin main"| gh["GitHub<br/>matchinist/gameweek"]
    gh --> wf[".github/workflows/deploy.yml<br/>on: push branches main"]
    wf --> up["upload-pages-artifact<br/><b>path: '.'</b><br/>the entire repository"]
    up --> pages["GitHub Pages<br/>www.gameweek.cloud"]
    pages --> live["Live, worldwide<br/><i>under 60 seconds</i>"]

    style up fill:#faf6f0,stroke:#b4671c,stroke-width:2px
    style live fill:#f5f8f6,stroke:#1e6b5e
```

No build step, no tests, no staging, no preview, no approval gate. Rollback is `git revert && git push`.

Because the artifact is the whole repository, every tracked file is publicly served — including `supabase-migration.sql`, which is reachable at `https://www.gameweek.cloud/supabase-migration.sql` and discloses the full RLS policy set.

---

## 3. Data model

Two layers with different ownership, joined by a coverage table.

```mermaid
erDiagram
    GW_DM_TOURNAMENTS ||--o{ GW_DM_EVENTS : "seasons.rounds[].eventIds"
    GW_DM_TEAMS       ||--o{ GW_DM_EVENTS : "home_id / away_id"
    GW_DM_TEAMS       ||--o{ GW_DM_PLAYERS : "team_id"

    GW_OPERATORS    ||--o{ GW_COMPETITIONS : client_key
    GW_OPERATORS    ||--o{ GW_PLAYERS      : client_key
    GW_OPERATORS    ||--o{ GW_CAMPAIGNS    : client_key
    GW_OPERATORS    ||--|| GW_CLIENT_COVERAGE : client_key
    GW_COMPETITIONS ||--o{ GW_ROUNDS       : competition_id
    GW_ROUNDS       ||--o{ GW_PREDICTIONS  : round_id
    GW_PLAYERS      ||--o{ GW_PREDICTIONS  : player_id

    GW_DM_TEAMS {
        text id PK
        text name
        text short
        text logo
        text sport
        int  fd_home "fixture difficulty"
        int  fd_away
    }
    GW_DM_TOURNAMENTS {
        text id PK
        text name
        text country
        text sport
        json seasons "teamIds, rounds, standings"
    }
    GW_DM_EVENTS {
        text id PK
        text home_id FK
        text away_id FK
        text kickoff
        json result "h, a, xg, shots, mvp"
        json lineup
        json scorers
        text status
    }
    GW_DM_PLAYERS {
        text id PK
        text team_id FK
        text full_name
        date birthday
        text nationality
        text photo_url
    }
    GW_OPERATORS {
        uuid auth_id FK
        text client_key UK
        text company_name
        text language "en tr de"
        text accent_color
        text bg_color
        text surface_color
        text text_color
        text logo_url
        json domains "collected, never enforced"
    }
    GW_CLIENT_COVERAGE {
        text client_key PK
        json tournament_ids "null = all"
        json team_ids "null = all"
    }
    GW_COMPETITIONS {
        text id PK
        text client_key FK
        text mode "score betting ranking lineup roulette"
        text sport
        json scoring
        json markets
        json ranking_config
        json lineup_config
        json overall_prizes
    }
    GW_ROUNDS {
        text id PK
        text competition_id FK
        text client_key FK
        text label
        text deadline
        json event_ids
        json ranking_teams
        json prizes
        int  sort_order
    }
    GW_PLAYERS {
        text id PK
        uuid auth_id FK
        text client_key
        text username
        text email
    }
    GW_PREDICTIONS {
        text player_id FK
        text client_key
        text competition_id
        text round_id
        text event_id
        text username "denormalized copy"
        json prediction
    }
    GW_CAMPAIGNS {
        text id PK
        text client_key FK
        text brand_name
        text logo_url
        json widget_keys
        text status
    }
    GW_ADMINS {
        uuid auth_id FK "platform staff gate"
    }
```

### Layer ownership

| Layer | Tables | Written by | Scoped by |
|---|---|---|---|
| **Global** | `gw_dm_teams`, `gw_dm_tournaments`, `gw_dm_events`, `gw_dm_players` | Gameweek staff, in `/data` | nothing — **no tenant key exists** |
| **Bridge** | `gw_client_coverage` | Gameweek staff, in `/data` | `client_key` |
| **Tenant** | `gw_operators`, `gw_competitions`, `gw_rounds`, `gw_players`, `gw_predictions`, `gw_campaigns` | Operators in `/admin`, players in `/embed` | `client_key` |
| **Platform** | `gw_admins`, `gw_billing_current` | out of band | — |

The global layer having no `client_key` is the root of the load problem in §6: a tenant's page cannot filter it in the database, so it downloads all of it.

---

## 4. Who touches what

Every edge below was derived by enumerating each file's `supa.from(...)` calls.

```mermaid
flowchart LR
    embed["/embed"]
    admin["/admin"]
    data["/data"]
    widgets["/widgets/*"]
    welcome["/welcome"]

    subgraph global["Global layer"]
        teams[(gw_dm_teams)]
        tourns[(gw_dm_tournaments)]
        events[(gw_dm_events)]
        dmplayers[(gw_dm_players)]
    end

    subgraph tenant["Tenant layer"]
        ops[(gw_operators)]
        comps[(gw_competitions)]
        rounds[(gw_rounds)]
        players[(gw_players)]
        preds[(gw_predictions)]
        camps[(gw_campaigns)]
        cover[(gw_client_coverage)]
    end

    subgraph platform["Platform"]
        admins[(gw_admins)]
        billing[(gw_billing_current)]
    end

    embed -->|read| teams
    embed -->|read| tourns
    embed -->|read| events
    embed -->|read| dmplayers
    embed -->|read| ops
    embed -->|read| comps
    embed -->|read| rounds
    embed -->|read| players
    embed ==>|"READ + WRITE"| preds

    admin -->|read| teams
    admin -->|read| tourns
    admin -->|"read + write*"| events
    admin ==>|"read + write"| ops
    admin ==>|"read + write"| comps
    admin ==>|"read + write"| rounds
    admin ==>|"read + write"| camps
    admin -->|read| players
    admin -->|"read + DELETE"| preds
    admin -->|read| cover
    admin -->|read| billing

    data ==>|"read + write"| teams
    data ==>|"read + write"| tourns
    data ==>|"read + write"| events
    data ==>|"read + write"| dmplayers
    data ==>|"read + write"| cover
    data ==>|"read + write"| ops
    data -->|read| admins

    widgets -->|read| teams
    widgets -->|read| tourns
    widgets -->|read| events
    widgets -->|read| dmplayers
    widgets -->|read| ops
    widgets -->|read| camps
    widgets -->|read| cover

    welcome ==>|write| ops

    style preds fill:#fdf0ee,stroke:#a3201a,stroke-width:2px
    style global fill:#f5f8f6,stroke:#1e6b5e
    style tenant fill:#f5f8f6,stroke:#1e6b5e
    style platform fill:#faf6f0,stroke:#b4671c
```

`gw_predictions` is the only table an unprivileged end user can write, which makes it the system's entire integrity surface.

\* `/admin` → `gw_dm_events` is the one edge that does not fire in practice. Its only write is `admin:1951`, which sits inside the result-entry modal that has no call site and would throw if it were reached — see §6.3 of the assessment. Operators cannot enter results; all fixture and result writes go through `/data`.

---

## 5. Session isolation

Each surface constructs its Supabase client with a distinct `storageKey`, so an operator who also plays on their own embed never has one session overwrite the other.

```mermaid
flowchart TB
    subgraph browser["One browser, one localStorage"]
        k1["gw-player"]
        k2["gw-operator"]
        k3["gw-admin"]
    end

    embed["/embed"] --> k1
    admin["/admin"] --> k2
    reset["/reset"] --> k2
    data["/data"] --> k3

    k1 --> g1{"row in gw_players<br/>auth_id + client_key"}
    k2 --> g2{"row in gw_operators<br/>auth_id"}
    k3 --> g3{"row in gw_admins<br/>auth_id"}

    g1 -->|yes| p1["Player session"]
    g2 -->|yes| p2["Operator session"]
    g2 -->|no| p2b["Row auto-created<br/>on first login"]
    g3 -->|yes| p3["Platform admin session"]
    g3 -->|no| p3b["Access refused<br/><i>UI only — the database<br/>still accepts writes</i>"]

    style p3b fill:#fdf0ee,stroke:#a3201a,stroke-width:2px
```

Accounts are **per-embed, not per-platform**: the same email registering on two operators' sites produces two separate `gw_players` rows against one Supabase Auth user. The `/data` gate is enforced in the page, not in the database.

---

## 6. Embed cold load

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant LS as localStorage
    participant CDN as jsDelivr
    participant DB as Supabase

    B->>B: Parse HTML, inline CSS
    B->>LS: read gw_theme_{client}
    LS-->>B: cached colors + logo
    Note over B: Theme applied pre-paint —<br/>no flash on repeat visits
    B->>CDN: supabase-js@2 (unpinned)
    CDN-->>B: UMD bundle

    B->>DB: onAuthStateChange → INITIAL_SESSION
    Note over B,DB: Blocks here — 3s setTimeout fallback
    DB-->>B: session or null

    par Six queries in parallel
        B->>DB: gw_dm_teams  select * limit 10000
        B->>DB: gw_dm_events select * limit 10000
        B->>DB: gw_dm_tournaments id,name,seasons
        B->>DB: gw_competitions where client_key
        B->>DB: gw_rounds where client_key
        B->>DB: gw_operators.language where client_key
    end
    DB-->>B: entire platform fixture pool

    Note over B: teamById() linear scan per event —<br/>O(teams × events) on main thread
    B->>B: Build COMPS / EVENTS, applyTranslations()

    opt signed in
        B->>DB: gw_players where auth_id + client_key
        B->>DB: gw_predictions where client_key + player_id
    end

    opt client ≠ demo
        B->>DB: gw_operators theme columns
        B->>LS: write gw_theme_{client}
    end

    B->>B: renderCompTabs(), goTab('predict')
```

Steps 5–8 are serial and independent: the auth restore and the data load could run concurrently. Steps 9–14 fetch the whole platform's global data because those tables carry no tenant key.

---

## 7. Round and lock timing

Round state is **derived from real kick-off times**, not from the stored `round.status` — a deliberate choice, since the admin-set status can drift out of sync with reality.

```mermaid
stateDiagram-v2
    direction LR
    [*] --> Future
    Future --> Current: previous round's last kickoff + 3h
    Current --> Past: this round's last kickoff + 3h
    Past --> [*]

    note right of Current
        Within the current round, each
        event locks independently:
        now >= kickoff - 30 min
    end note

    note left of Future
        Round creation enforces a 6h gap,
        so rounds can never overlap.
        Unknown kickoff = "not yet",
        never "already passed".
    end note
```

| Rule | Value | Source |
|---|---|---|
| Event lock | kickoff − 30 min | `embed:3066`, `:3138`, `:4106`, `:4178` |
| Round advance | previous round's last kickoff + 3 h | `embed:1410` `computeCurrentRoundIdx` |
| Minimum round gap | 6 h, enforced at creation | `admin:2821` `validateRoundOverlap` |
| Fallback when no kickoff data | last round with `status === 'open'` | `embed:1429` `getDefaultRoundIdx` |

---

## 8. Where rules are enforced

The same picture as §1, drawn by trust boundary rather than by component. Everything inside the dashed box runs on hardware the player controls.

```mermaid
flowchart TB
    subgraph untrusted["Player-controlled — editable, replayable"]
        direction TB
        ui["Rendered UI"]
        lock["Deadline check<br/>Date.now() >= kickoff - 30min"]
        valid["Username charset · length<br/>Terms acceptance"]
        score["Scoring<br/>scorePoints() at render time"]
        uniq["Username uniqueness<br/>SELECT then INSERT"]
    end

    subgraph boundary["Trust boundary"]
        rls["Supabase RLS<br/><i>the only server-side rule</i>"]
    end

    subgraph trusted["Server-side"]
        db[("Postgres")]
    end

    ui --> lock --> rls
    valid --> rls
    score -.->|"never persisted —<br/>recomputed per viewer"| ui
    uniq --> rls
    rls --> db

    rls -.-> chk1["Checks: does this row's<br/>player_id belong to the caller?"]
    rls -.-> chk2["Does NOT check: kick-off time,<br/>round status, username value,<br/>client_key, competition_id"]

    style untrusted fill:#fdf0ee,stroke:#a3201a,stroke-width:2px
    style chk2 fill:#fdf0ee,stroke:#a3201a
    style trusted fill:#f5f8f6,stroke:#1e6b5e
```

Every rule that makes the game a game currently lives in the untrusted box. `gw_predictions` accepts a write from any authenticated player at any time, and points are recomputed from that row by every other player's browser. See [§4.1 of the assessment](./CODEBASE-ASSESSMENT.md) for the consequence and the fix.

---

## 9. Embed URL contract

```
https://www.gameweek.cloud/embed?client=<client_key>&comp=<id,id,...>
```

| Parameter | Required | Effect |
|---|---|---|
| `client` | no — defaults to `demo` | Selects the tenant. Drives theme, language, competitions, player scope. |
| `comp` | no | Comma-separated competition IDs. Narrows the embed; when it resolves to exactly one, the competition tab strip is hidden. An unmatched value renders a "competition not found" state. |

Widgets take `client`, and `standings` additionally accepts `tournament` and `season`. The operator copies the generated `<iframe>` from `/admin` → Embed.

---

## 10. File map

| Path | Lines | Talks to Supabase | Notes |
|---|---:|---|---|
| `embed/index.html` | 5,066 | yes — 8 tables | The product |
| `demo/index.html` | 4,289 | **no** | Hardcoded data; hand-maintained fork of `embed` |
| `admin/index.html` | 4,009 | yes — 10 tables | Operator dashboard |
| `data/index.html` | 3,059 | yes — 7 tables | Platform data manager; the only place results are entered |
| `index.html` | 517 | no | Marketing homepage; JSON-LD, GA |
| `cs2fantasy/index.html` | — | no | **Orphaned** — unlinked, crawlable |
| `widgets/squad-analytics/` | — | yes — 5 tables | Embeddable |
| `widgets/top-scorers/` | — | yes — 5 tables | Embeddable |
| `widgets/standings/` | — | yes — 4 tables | Embeddable, renders sponsor banner |
| `welcome/index.html` | — | yes — writes `gw_operators` | Post-signup setup |
| `reset-password/index.html` | — | auth only | The live reset target |
| `reset/index.html` | — | auth only | **Orphaned** — superseded |
| `pricingtest/index.html` | — | no | **Orphaned** — the only page with prices |
| `contact/` `privacy/` `terms/` | — | no | Static |
| `supabase-migration.sql` | — | — | Stale, destructive, **publicly served** |
| `llms.txt` | — | — | Product summary for AI answer engines |

---

*Traced from the repository at `f25d78a`. Table access was derived by enumerating `supa.from(...)` calls per file; RLS behaviour is inferred from `supabase-migration.sql`, which is known to be out of date.*
