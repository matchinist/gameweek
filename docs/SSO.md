# Single Sign-On (SSO)

Host-page SSO signs a player into the embedded game using the account they
already have on the customer's own site — no separate Gameweek registration and
no repeated logins. It exists for customers (e.g. Shopify stores) whose visitors
are already authenticated and shouldn't have to sign in again inside the widget.

This document has two halves:

- **Part A — Customer integration guide** (§1–§4): safe to share with customers.
  How to turn SSO on and wire it into any site, with copy-paste examples.
- **Part B — Internal reference** (§5–§9): architecture, security model,
  deployment, the Edge Function API, and troubleshooting.

---

## Contents

- Part A — Customer guide
  - [1. What SSO does](#1-what-sso-does)
  - [2. Turn SSO on (admin)](#2-turn-sso-on-admin)
  - [3. Add it to your site](#3-add-it-to-your-site)
  - [4. Keeping the secret safe](#4-keeping-the-secret-safe)
- Part B — Internal
  - [5. How it works](#5-how-it-works)
  - [6. Security model](#6-security-model)
  - [7. Reference](#7-reference)
  - [8. Deployment](#8-deployment)
  - [9. Troubleshooting](#9-troubleshooting)
  - [10. Known limitations](#10-known-limitations)

---

# Part A — Customer integration guide

## 1. What SSO does

When a visitor is logged in on your site and opens a page with the Gameweek
game, SSO signs them into the game automatically as the same person. The **first
time** a visitor plays, a game account is created for them; **every visit after**
signs them straight back into that same account. It works across devices and
survives browsers clearing the embed's storage, so a returning customer never
has to log in twice.

You keep full control: SSO is opt-in per customer, and a visitor can still sign
in manually — a manual login always takes precedence over SSO.

**Requirements at a glance**

- Your site can render a value into the page **server-side** (Shopify, WordPress,
  a custom backend — anything that isn't purely static).
- You use the **seamless script embed** (`embed.js`), or a custom iframe that
  posts the identity in (see §3.4).
- You add your site's domain under **Allowed Domains** in the admin.

## 2. Turn SSO on (admin)

1. Sign in to the admin panel and open **Embed & Integration**.
2. Under **Allowed Domains**, add the domain where the game is embedded
   (e.g. `shop.example.com`). SSO is only accepted from these domains.
3. In the **Single Sign-On** card, click **Enable SSO**. This reveals **Your SSO
   secret** and a ready-made **Shopify snippet**.
4. Copy the secret (or the snippet) and integrate it into your site (§3).

Buttons in that card:

- **Show / Copy** — reveal or copy the secret.
- **Regenerate secret** — issues a new secret; snippets using the old one stop
  working until updated. Use this if the secret is ever exposed.
- **Disable** — turns SSO off; visitors fall back to manual sign-in.

## 3. Add it to your site

Whatever the platform, you render four attributes on the embed container, from
your **currently logged-in** user:

| Attribute | Value |
|---|---|
| `data-sso-id` | The user's unique id on your site (stable, never reused) |
| `data-sso-email` | The user's email |
| `data-sso-name` | Display name (used only when first creating their game account) |
| `data-sso-sig` | The signature — hex **HMAC-SHA256** of `id + ":" + email`, using your SSO secret, **computed on your server** |

The signature is what proves the identity is genuine. It **must be computed
server-side** — never in the browser (see §4).

### 3.1 Shopify (no app required)

Shopify's Liquid has a built-in `hmac_sha256` filter, so the whole thing works
from your theme with no app and no backend code. Paste this in place of your
normal embed snippet (it's also generated for you in the admin SSO card):

```liquid
{% if customer %}
<div data-gameweek data-client="YOUR_CLIENT_KEY"
     data-sso-id="{{ customer.id }}"
     data-sso-email="{{ customer.email }}"
     data-sso-name="{{ customer.first_name }}"
     data-sso-sig="{{ customer.id | append: ':' | append: customer.email | hmac_sha256: 'YOUR_SSO_SECRET' }}"></div>
{% else %}
<div data-gameweek data-client="YOUR_CLIENT_KEY"></div>
{% endif %}
<script async src="https://www.gameweek.cloud/embed.js"></script>
```

The `{% else %}` branch is important: logged-out visitors get the plain embed and
can register/sign in manually.

### 3.2 Other platforms

On any other stack, compute the signature server-side and render the same
attributes. The message signed is exactly `id + ":" + email`, and the output is
**lowercase hex**.

```php
// PHP / WordPress
$sig = hash_hmac('sha256', $id . ':' . $email, $secret);
```
```js
// Node.js
const sig = require('crypto').createHmac('sha256', secret).update(id + ':' + email).digest('hex');
```
```python
# Python
import hmac, hashlib
sig = hmac.new(secret.encode(), f"{id}:{email}".encode(), hashlib.sha256).hexdigest()
```
```ruby
# Ruby
sig = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{id}:#{email}")
```
```csharp
// C# / .NET
using var h = new System.Security.Cryptography.HMACSHA256(Encoding.UTF8.GetBytes(secret));
var sig = Convert.ToHexString(h.ComputeHash(Encoding.UTF8.GetBytes($"{id}:{email}"))).ToLowerInvariant();
```

Then render the container (server-side, from the logged-in user):

```html
<div data-gameweek data-client="YOUR_CLIENT_KEY"
     data-sso-id="123" data-sso-email="alex@example.com" data-sso-name="Alex"
     data-sso-sig="<computed server-side>"></div>
<script async src="https://www.gameweek.cloud/embed.js"></script>
```

### 3.3 What must match exactly

- The message is `id + ":" + email` — same id and email you put in the
  attributes, joined by a single colon, in that order.
- Output is hexadecimal, lowercase, 64 characters.
- The `id` must not contain a colon (`:`).

### 3.4 Advanced: a custom iframe instead of the script embed

SSO is delivered to the game by a `postMessage` — the `embed.js` loader does
this for you. If you run your own iframe instead of the script embed, you send
that message yourself:

```html
<iframe id="gw" src="https://www.gameweek.cloud/embed?client=YOUR_CLIENT_KEY"></iframe>
<script>
  const gw = document.getElementById('gw');
  gw.addEventListener('load', () => {
    gw.contentWindow.postMessage({
      __gameweek: true, type: 'sso',
      id: '123', email: 'alex@example.com', name: 'Alex',
      sig: '<computed server-side>'
    }, 'https://www.gameweek.cloud');
  });
</script>
```

The identity is **never** passed in the URL — only via `postMessage`, from a page
whose origin is one of your Allowed Domains. A bare `<iframe>` with nothing else
cannot do SSO. The seamless script embed is recommended: less code, and it
auto-sizes to its content instead of a fixed-height scroll box.

## 4. Keeping the secret safe

The secret is the master key to your SSO — anyone who has it can sign in as any
of your users. Treat it like an API key or password.

**The one rule: compute the signature server-side; never expose the secret to
the browser.**

- ✅ **Safe:** the secret sits in server-rendered template code (Liquid, PHP,
  etc.). The browser only ever receives the resulting *signature*, which is a
  one-way hash — the secret itself never leaves your server.
- ❌ **Not safe:** the secret appears anywhere the visitor can see it — in the
  page's delivered HTML, in a `data-` attribute, in client-side JavaScript, or
  in a JSON/API response. Anyone can then read it and impersonate any user.

**How to check you did it right:** open the live page, use View Source /
DevTools, and search for your secret. You should find the `data-sso-sig` value
(which changes per user) but **never the secret itself**. If the secret is
visible, stop and **Regenerate** it.

If a secret is ever exposed, click **Regenerate secret** in the admin and update
your site's snippet. Rotation is also how you revoke access — signatures do not
expire on their own.

---

# Part B — Internal reference

## 5. How it works

SSO is the product's only server-side component: a Supabase Edge Function that
holds the HMAC check the client cannot be trusted with. Everything else is the
existing static embed.

```mermaid
sequenceDiagram
    participant Host as Customer page
    participant JS as embed.js (loader)
    participant Game as embed iframe
    participant Fn as sso-login (Edge Fn)
    participant Auth as Supabase Auth

    Host->>Host: server-renders data-sso-* (sig = HMAC(id:email, secret))
    Host->>JS: page loads, embed.js scans containers
    JS->>Game: injects iframe, postMessage({type:'sso', id,email,name,sig})
    Game->>Game: checks sender origin ∈ Allowed Domains
    Game->>Fn: invoke('sso-login', {client,id,email,name,sig})
    Fn->>Fn: look up gw_customers.sso_secret; verify HMAC (constant-time)
    Fn->>Auth: createUser(synthetic email) [first visit] + generateLink(magiclink)
    Fn-->>Game: { token_hash }
    Game->>Auth: verifyOtp(token_hash) → real session
    Game->>Game: find/create gw_players row → player signed in
```

Key points:

- A **real Supabase session** is minted (not just a `gw_players` row), because
  RLS on `gw_players` / `gw_predictions` is keyed to `auth.uid()`. This is also
  what makes the same host user resolve to the same player on every device.
- The auth user's email is a **synthetic, deterministic** address
  (`sso-…@sso.gameweek.cloud`), never the real one — see §6.
- The player's **real** email is stored on `gw_players.email` so the customer's
  Users list still shows a contactable address.

### Files

| Path | Role |
|---|---|
| `supabase/functions/sso-login/index.ts` | The Edge Function (verifies the signature, mints the session). |
| `docs/legacy/supabase-sso.sql` | (applied; kept for history) Added `gw_customers.sso_enabled` / `sso_secret`, re-created `gw_customers_public` with `domains`, added the username unique index. Now captured in the `supabase/migrations/` baseline. |
| `embed.js` | Reads `data-sso-*`, posts the identity into the iframe on load. |
| `embed/index.html` | Receives the identity, origin-checks it, calls the function, verifies the token, creates/loads the player. |
| `admin/index.html` | The Single Sign-On admin card (enable, secret, snippet, domains). |

## 6. Security model

**Signature verification is server-side.** The anon key cannot forge a session;
only a signature made with the customer's `sso_secret` is accepted, and the
secret is only ever read by the Edge Function (service role) — it is excluded
from the anon-facing `gw_customers_public` view and the base table is
anon-revoked.

**Synthetic identities prevent account takeover.** Possession of an customer
secret proves the secret was used — it says nothing about who owns an email
address. So the Edge Function maps every SSO user to a namespaced synthetic
address under `@sso.gameweek.cloud` (see §7.4) rather than their real email. A
leaked customer secret can therefore only mint sessions inside *that customer's*
SSO namespace — never for a real-email account (another player's, an customer's,
or a platform admin's). No password is ever set on these users, so the function
is the only way in.

**Origin restriction stops signature replay (login CSRF).** A valid signature is
necessary but not sufficient: the identity must also arrive by `postMessage` from
a page whose origin is one of the customer's **Allowed Domains**. This is what
stops someone who can read their own valid signature from embedding the loader on
a page they control and forcing visitors into their account. The identity is
never read from the URL, so it also can't leak into logs/history or be put in a
shareable link.

**The origin check fails closed.** If an customer has SSO enabled but **no**
Allowed Domains configured, the embed rejects the identity (with a console
warning naming the fix) instead of accepting any origin. At least one Allowed
Domain is therefore a hard requirement for SSO to function — the admin UI's
"requires an Allowed Domain" is enforced by code.

**Other properties**

- Constant-time signature comparison (no timing oracle on a guessed prefix).
- The signed message `id:email` is unambiguous: an `id` containing `:` is
  rejected, so one signature can't vouch for two identities.
- Manual (password) logins take precedence over SSO; an explicit logout
  suppresses SSO auto-login for the rest of that page load.

**Accepted trade-offs** (by design, not bugs)

- **No signature expiry.** A signature is a long-lived bearer credential for that
  user; revoke by rotating the secret. (Origin-gating limits where it can be
  replayed from.)
- **CORS `*` on the function.** Its response is only useful to a caller who
  already holds a valid signature, and non-browser callers bypass CORS anyway.

## 7. Reference

### 7.1 Data model (`gw_customers`)

| Column | Type | Notes |
|---|---|---|
| `sso_enabled` | boolean, default `false` | Master switch for the client. |
| `sso_secret` | text | HMAC key. Readable only via the customer's own RLS row and platform admins; **excluded** from `gw_customers_public`. |

`gw_customers_public` additionally exposes `domains` (for the embed's origin
check). `gw_players` has a unique index on `(client_key, username)`.

### 7.2 Signature spec

```
sig = lowercase_hex( HMAC_SHA256( key = sso_secret, message = id + ":" + email ) )
```

64 hex chars. The `email` is included even though `id` is the true identity, so
the signature also binds the email the customer asserts.

### 7.3 Edge Function API — `POST /functions/v1/sso-login`

Called via `supabase.functions.invoke` (sends the anon key; JWT verification
stays **on**). Request body:

```json
{ "client": "client_key", "id": "123", "email": "a@b.com", "name": "Alex", "sig": "<64 hex>" }
```

Responses:

| Status | Body | Meaning |
|---|---|---|
| 200 | `{ "token_hash": "...", "external_id": "123" }` | Verified; redeem `token_hash` with `verifyOtp`. |
| 400 | `{ "error": "invalid_json" \| "missing_fields" \| "field_too_long" \| "invalid_id" }` | Malformed request (see codes). |
| 401 | `{ "error": "bad_signature" }` | Signature wrong, or not 64-hex. |
| 403 | `{ "error": "sso_not_enabled" }` | `sso_enabled` is false or no secret for this `client`. |
| 405 | `{ "error": "method_not_allowed" }` | Non-POST. |
| 500 | `{ "error": "server_error" }` | Customer lookup / user create / link generation failed. |

Env vars (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`) are injected automatically
by the Edge runtime — nothing to configure.

### 7.4 Synthetic identity

```
email        = sso-<slug(client)>-<slug(externalId)>-<hash10>@sso.gameweek.cloud
hash10       = first 10 hex of sha256("<client> <externalId>")
user_metadata = { sso_client, sso_external_id, sso_source_email, sso_name }
```

`slug()` lowercases, replaces non-alphanumerics with `-`, trims, and caps at 20
chars; the hash suffix guarantees two distinct identities can't collide after
slugging.

### 7.5 Client-side behaviour (`embed/index.html`)

- Identity accepted only via the `sso` `postMessage`; origin checked against
  `customerDomains` (loaded from `gw_customers_public.domains`).
- Session precedence in `maybeSsoLogin()`: same SSO user → no-op; a genuine
  manual login (no `sso_client` metadata) → left alone; a different or
  foreign-tenant SSO session → signed out and replaced.
- On first visit, `ensureSsoPlayer()` creates the `gw_players` row: username
  derived from the host name (sanitised to `[A-Za-z0-9_]`, deduped with a
  suffix), email set to the real host email.

## 8. Deployment

Two manual steps, both independent of the (auto-deploying) static frontend. SSO
is opt-in per customer, so pushing the frontend first is safe — it degrades to
normal manual login until these are done.

1. **Run the SQL.** *(Done on live — kept for a from-scratch rebuild, where the
   `supabase/migrations/` baseline covers it.)* Paste `docs/legacy/supabase-sso.sql` into the Supabase SQL editor and
   run it. It adds the columns, re-creates `gw_customers_public` with `domains`,
   and adds the `(client_key, username)` unique index.
   - The unique index errors only if duplicate usernames already exist for a
     client; dedupe and re-run if so. The column changes above it apply first.

2. **Deploy the Edge Function** from the repo root:
   ```bash
   npx supabase login
   npx supabase functions deploy sso-login --project-ref <project-ref>
   ```
   Smoke test (expect `401 {"error":"bad_signature"}`):
   ```bash
   curl -i -X POST https://<project-ref>.supabase.co/functions/v1/sso-login \
     -H "Authorization: Bearer <anon key>" -H "Content-Type: application/json" \
     -d '{"client":"someclient","id":"1","sig":"<64 hex>"}'
   ```

Then enable SSO per customer in the admin and hand them the snippet.

### Testing

The way to test without a real store is a local "fake customer site": a page
that renders the embed with a valid signature and posts it in. Serve it over
http (a `file://` origin is rejected), point it at an customer you've enabled,
and confirm:

- `sso-login` → 200, `auth/v1/verify` → 200, `gw_players` insert → 201 (first
  visit) or select → 200 (returning visit, **no** duplicate).
- Same `id` returns the same `auth_id`; a different `id` creates a new account.

Because the game runs in a cross-origin iframe, confirm the signed-in state by
the game header (shows the user, not a "Sign in" button), not by reading the
frame's DOM.

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `403 sso_not_enabled` | The `client_key` isn't SSO-enabled, or you're pointing at the wrong customer. Enable it, or use the enabled customer's key. |
| `401 bad_signature` | The secret used to sign ≠ the customer's secret, or the message wasn't exactly `id:email` lowercase-hex. |
| Console: `SSO identity ignored — … not an allowed domain` | The page's origin isn't under Allowed Domains. Add it. |
| Console: `SSO: no Allowed Domains configured — rejecting identity` | SSO is enabled but the domain list is empty; the origin check fails closed. Add the embedding site under Allowed Domains. |
| `500 server_error` | Usually the SQL migration hasn't run (columns missing). The columns are in the `supabase/migrations/` baseline (originally `docs/legacy/supabase-sso.sql`). |
| Nothing happens / no sign-in | Not using the script embed and not posting the identity yourself; or the signature is in the URL (unsupported) instead of `postMessage`. |
| Secret visible in View Source | The signature was computed client-side. Move it server-side and **Regenerate** the secret. |
| `406` on `gw_players` `select=*...single()` | Expected — it's the "no existing player" / "username free" check returning zero rows. Not an error. |

## 10. Known limitations

- **No signature expiry / nonce.** Revocation is via secret rotation only. A
  short-lived nonce would tighten replay resistance further but adds server
  state.
- **Username is set once, at creation.** Changing the host `name` later does not
  rename the existing player (the `id` is the identity).
