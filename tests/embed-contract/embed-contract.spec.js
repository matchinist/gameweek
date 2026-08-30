// Phase 2.9 — the embed contract, pinned in CI forever (P3: live customers
// never notice a phase happening).
//
//   1. The classic fixed-height iframe URL renders.
//   2. The seamless embed (`embed.js` + inline=1) performs the height
//      handshake: the app posts {type:'height'} and the loader sizes the
//      iframe and releases the reserved min-height.
//   3. The SSO postMessage is acted on from an operator-registered origin
//      (the app calls the sso-login Edge Function) and REJECTED from any
//      other origin (fails closed — Phase 0.10).
//
// Hermetic: every Supabase request is intercepted, so the suite runs with no
// backend and cannot flake on live data.

import { test, expect } from '@playwright/test';

const SUPA = 'https://mgfzqkesikfdrahherfm.supabase.co';

// The fixture operator rows. `cttest` registers localhost (the stub host
// origin), `ctdenied` registers only an unrelated domain.
const OPERATORS = {
  cttest: { company_name: 'CT Test', logo_url: null, accent_color: null, bg_color: null, surface_color: null, text_color: null, language: 'en', domains: ['localhost'] },
  ctdenied: { company_name: 'CT Denied', logo_url: null, accent_color: null, bg_color: null, surface_color: null, text_color: null, language: 'en', domains: ['operator-site.example'] },
};

async function interceptSupabase(context, state) {
  await context.route(`${SUPA}/**`, async (route) => {
    const url = new URL(route.request().url());
    const wantsObject = (route.request().headers()['accept'] || '').includes('pgrst.object');
    if (url.pathname.includes('/functions/v1/sso-login')) {
      state.ssoLoginCalls.push(JSON.parse(route.request().postData() || '{}'));
      return route.fulfill({ status: 403, contentType: 'application/json', body: JSON.stringify({ error: 'sso_not_enabled' }) });
    }
    if (url.pathname.includes('/rest/v1/gw_operators_public')) {
      const m = (url.searchParams.get('client_key') || '').match(/eq\.(.+)/);
      const op = OPERATORS[m?.[1]] || null;
      const sel = url.searchParams.get('select') || '';
      const row = op ? Object.fromEntries(sel.split(',').map(k => [k, op[k] ?? null])) : null;
      if (wantsObject) {
        return op
          ? route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(row) })
          : route.fulfill({ status: 406, contentType: 'application/json', body: JSON.stringify({ message: 'no rows' }) });
      }
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(op ? [row] : []) });
    }
    if (url.pathname.startsWith('/rest/v1/')) {
      return wantsObject
        ? route.fulfill({ status: 406, contentType: 'application/json', body: JSON.stringify({ message: 'no rows' }) })
        : route.fulfill({ status: 200, contentType: 'application/json', body: '[]' });
    }
    if (url.pathname.startsWith('/auth/v1/')) {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    }
    return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
  });
}

test.describe('embed contract', () => {
  let state;
  test.beforeEach(async ({ context }) => {
    state = { ssoLoginCalls: [] };
    await interceptSupabase(context, state);
  });

  test('classic iframe URL renders the app shell', async ({ page }) => {
    const errors = [];
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto('http://localhost:4173/embed/?client=cttest');
    await expect(page.locator('#hdr-username')).toBeVisible();
    await expect(page.locator('#hdr-operator-badge')).toContainText('CT Test', { timeout: 15000 });
    expect(errors).toStrictEqual([]);
  });

  test('seamless embed performs the height handshake', async ({ page }) => {
    await page.goto('http://localhost:4174/allowed.html');
    const iframe = page.locator('iframe[title="Gameweek prediction game"]');
    await expect(iframe).toBeVisible();
    // the loader reserves min-height:480px, then releases it after the first
    // {type:'height'} report and drives height from content measurements
    await expect(iframe).toHaveCSS('min-height', '0px', { timeout: 20000 });
    const height = await iframe.evaluate((el) => parseFloat(el.style.height));
    expect(height).toBeGreaterThan(0);
    // the app URL carries the inline flag
    expect(await iframe.getAttribute('src')).toContain('inline=1');
  });

  test('SSO identity from a registered origin reaches the sso-login function', async ({ page }) => {
    await page.goto('http://localhost:4174/allowed.html');
    await expect
      .poll(() => state.ssoLoginCalls.length, { timeout: 20000, message: 'sso-login should be called' })
      .toBeGreaterThan(0);
    expect(state.ssoLoginCalls[0]).toMatchObject({ client: 'cttest', id: '42' });
  });

  test('SSO identity from an unregistered origin is rejected and never leaves the page', async ({ page }) => {
    const warnings = [];
    page.on('console', (msg) => { if (msg.type() === 'warning') warnings.push(msg.text()); });
    await page.goto('http://localhost:4174/denied.html');
    const iframe = page.locator('iframe[title="Gameweek prediction game"]');
    await expect(iframe).toHaveCSS('min-height', '0px', { timeout: 20000 }); // app booted
    await page.waitForTimeout(2500); // grace period in which a call would have fired
    expect(state.ssoLoginCalls).toStrictEqual([]);
    expect(warnings.join('\n')).toMatch(/not an allowed domain|rejecting identity/i);
  });
});
