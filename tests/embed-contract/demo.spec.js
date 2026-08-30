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

  test('leagues: the list shows overall positions without a round selector; inside a league the selector works', async ({ page }) => {
    await page.goto('http://localhost:4173/embed/?client=demo');
    await expect(page.locator('#hdr-username')).toHaveText('demo_user', { timeout: 15000 });
    await page.evaluate(() => {
      switchComp(COMPS.findIndex((c) => c.id === 'demo_score'));
      switchPredictSubTab('leaderboard');
    });
    // The leagues list ranks by overall points only, so the round selector
    // must not render there — it used to sit above the list doing nothing.
    await expect(page.locator('.league-row').first()).toBeVisible({ timeout: 15000 });
    await expect(page.locator('.round-select')).toHaveCount(0);

    // Enter the General league: selector appears, defaulting to Overall
    await page.locator('.league-row').first().click();
    await expect(page.locator('.lb-table tbody tr').first()).toBeVisible({ timeout: 15000 });
    await expect(page.locator('.round-select')).toHaveCount(1);
    await expect(page.locator('.round-select')).toHaveValue('overall');
    const overallLeader = await page.locator('.lb-table tbody tr').first().innerText();
    expect(overallLeader).toContain('demo_user'); // 19 pts across GW1+GW2

    // Switching to Gameweek 2 re-scores the table for that round only
    await page.locator('.round-select').selectOption('1');
    await expect(page.locator('.lb-table tbody tr').first()).toContainText('stadyum76', { timeout: 15000 }); // GW2 leader
    expect(supabaseRequests).toStrictEqual([]);
  });

  test('the demo embed lays events out in two columns at desktop width', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto('http://localhost:4173/demo/');
    const iframe = page.locator('iframe[title="Gameweek prediction game"]');
    await expect(iframe).toBeVisible({ timeout: 15000 });
    const frame = await (await iframe.elementHandle()).contentFrame();
    await frame.waitForSelector('.event-card', { timeout: 15000 });
    // The shell must give the embed enough width for its own 2-column
    // breakpoint (600px) — the fork ran at 860px and the first cut of the
    // shell capped it at 560px, flattening everything to one long column.
    const columns = await frame.evaluate(() => getComputedStyle(document.querySelector('.events-list')).gridTemplateColumns.trim().split(/\s+/).length);
    expect(columns).toBe(2);
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
