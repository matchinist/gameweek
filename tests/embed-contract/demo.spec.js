// Phase 2.5 — the demo contract: /demo is the REAL embed in demo mode, and
// it must work with ZERO backend traffic. A demo bug can never touch real
// data because no request ever leaves the page.
import { test, expect } from '@playwright/test';

test.describe('demo mode', () => {
  let supabaseRequests;
  test.beforeEach(async ({ context }) => {
    supabaseRequests = [];
    // Not fulfilled with fixtures — BLOCKED. The demo must never need them.
    await context.route('https://mgfzqkesikfdrahherfm.supabase.co/**', (route) => {
      supabaseRequests.push(route.request().url());
      return route.abort();
    });
    await context.route('https://browser.sentry-cdn.com/**', (r) => r.fulfill({ status: 200, contentType: 'text/javascript', body: '' }));
    await context.route('https://*.ingest.de.sentry.io/**', (r) => r.fulfill({ status: 200, contentType: 'application/json', body: '{}' }));
  });

  test('the demo embed boots from the bundled dataset with no backend', async ({ page }) => {
    await page.goto('http://localhost:4173/embed/?client=demo');
    // signed in as the demo player, competitions present, cards rendered
    await expect(page.locator('#hdr-username')).toHaveText('demo_user', { timeout: 15000 });
    await expect(page.locator('.event-card').first()).toBeVisible({ timeout: 15000 });
    const comps = await page.evaluate(() => COMPS.map((c) => c.id).sort());
    expect(comps).toContain('demo_score');
    expect(comps).toContain('demo_betting');
    expect(comps).toContain('demo_ranking');
    expect(comps).toContain('demo_lineup');
    expect(supabaseRequests).toStrictEqual([]);
  });

  test('a prediction saves through the mock rpc and leaderboards score for real', async ({ page }) => {
    await page.goto('http://localhost:4173/embed/?client=demo');
    await expect(page.locator('#hdr-username')).toHaveText('demo_user', { timeout: 15000 });
    const result = await page.evaluate(async () => {
      const idx = COMPS.findIndex((c) => c.id === 'demo_score');
      switchComp(idx);
      await new Promise((r) => setTimeout(r, 400));
      const round = COMPS[idx].rounds[selectedRound[idx]];
      const openEv = (round.eventIds || []).find((id) => EVENTS[id] && !EVENTS[id].res);
      const saved = await savePred(openEv, { h: 2, a: 1 });
      switchPredictSubTab('leaderboard');
      await new Promise((r) => setTimeout(r, 600));
      document.querySelector('.league-row').click();
      await new Promise((r) => setTimeout(r, 600));
      changeLBSelection(0);
      await new Promise((r) => setTimeout(r, 600));
      const pts = [...document.querySelectorAll('.lb-pts-btn')].slice(0, 3).map((e) => parseInt(e.textContent));
      return { saved, pts };
    });
    expect(result.saved).toBe(true);
    expect(result.pts.length).toBeGreaterThan(0);
    expect(Math.max(...result.pts)).toBeGreaterThan(0); // real scoring, not fake rows
    expect(supabaseRequests).toStrictEqual([]);
  });

  test('the /demo shell mounts the seamless embed in demo mode', async ({ page }) => {
    await page.goto('http://localhost:4173/demo/');
    const iframe = page.locator('iframe[title="Gameweek prediction game"]');
    await expect(iframe).toBeVisible({ timeout: 15000 });
    expect(await iframe.getAttribute('src')).toContain('client=demo');
    expect(await iframe.getAttribute('src')).toContain('inline=1');
    // the height handshake sizes the frame from the demo content
    await expect(iframe).toHaveCSS('min-height', '0px', { timeout: 20000 });
    // switching feature remounts with the right comp filter
    await page.selectOption('#f-feature', 'betting');
    const iframe2 = page.locator('iframe[title="Gameweek prediction game"]');
    await expect(iframe2).toBeVisible({ timeout: 15000 });
    expect(await iframe2.getAttribute('src')).toContain('comp=betting');
    expect(supabaseRequests).toStrictEqual([]);
  });
});
