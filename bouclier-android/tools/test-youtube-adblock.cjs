#!/usr/bin/env node
/*
 * Banc d'essai du script anti-pub YouTube (app/src/main/assets/youtube/adblock.js) dans Chromium.
 *
 *   NODE_PATH=$(npm root -g) node tools/test-youtube-adblock.cjs          # tests hors ligne
 *   NODE_PATH=$(npm root -g) node tools/test-youtube-adblock.cjs --live   # + vrai m.youtube.com
 *
 * Les tests hors ligne simulent les réponses de YouTube (page, fetch, XHR) sur l'origine
 * https://m.youtube.com sans toucher au réseau. Le test « --live » vérifie que la page réelle se
 * charge et que la vidéo démarre avec le script : il ne prouve pas qu'une pub est bloquée,
 * YouTube ne diffusant pas forcément de pub à la machine qui exécute le test.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { chromium, devices } = require('playwright');

const SCRIPT = fs.readFileSync(path.join(__dirname, '../app/src/main/assets/youtube/adblock.js'), 'utf8');
const ORIGIN = 'https://m.youtube.com';
const live = process.argv.includes('--live');

const AD_PLAYER_RESPONSE = {
  playabilityStatus: { status: 'OK' },
  videoDetails: { videoId: 'abc', title: 'Vidéo' },
  adPlacements: [{ adPlacementRenderer: { config: {} } }],
  playerAds: [{ playerLegacyDesktopWatchAdsRenderer: {} }],
  adSlots: [{ adSlotRenderer: {} }],
  streamingData: { formats: [{ itag: 18 }] },
};

const AD_FEED = {
  contents: [
    { richItemRenderer: { content: { videoRenderer: { videoId: 'v1' } } } },
    { richItemRenderer: { content: { adSlotRenderer: { slotId: 'pub' } } } },
    { promotedSparklesWebRenderer: { title: 'pub' } },
    { videoWithContextRenderer: { videoId: 'v2' } },
    { command: { reelWatchEndpoint: { videoId: 'short-pub', adClientParams: { isAd: true } } } },
    { command: { reelWatchEndpoint: { videoId: 'short' } } },
  ],
};

let failures = 0;
async function check(name, run) {
  try {
    await run();
    console.log(`  ✓ ${name}`);
  } catch (error) {
    failures++;
    console.log(`  ✗ ${name}\n      ${error.message.split('\n').join('\n      ')}`);
  }
}

function expectClean(result) {
  assert.strictEqual(result.adPlacements, undefined, 'adPlacements présent');
  assert.strictEqual(result.playerAds, undefined, 'playerAds présent');
  assert.strictEqual(result.adSlots, undefined, 'adSlots présent');
  assert.deepStrictEqual(result.videoDetails, AD_PLAYER_RESPONSE.videoDetails);
  assert.deepStrictEqual(result.streamingData, AD_PLAYER_RESPONSE.streamingData);
}

async function offlineTests(browser) {
  console.log('Tests hors ligne (réponses simulées) :');
  const context = await browser.newContext({ ...devices['Pixel 7'] });
  const page = await context.newPage();
  const pageErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  await page.addInitScript({ content: SCRIPT });

  const html = `<!doctype html><html><head><title>test</title></head><body>
    <script>var ytInitialPlayerResponse = null;</script>
    <script>var ytInitialPlayerResponse = ${JSON.stringify(AD_PLAYER_RESPONSE)};</script>
    <script>var ytInitialData = ${JSON.stringify(JSON.stringify(AD_FEED))};
      window['ytInitialData'] = JSON.parse(window['ytInitialData']);</script>
    <ytm-ad-slot-renderer id="slot">pub</ytm-ad-slot-renderer>
    <ytm-rich-item-renderer id="rich-ad"><ytm-ad-slot-renderer></ytm-ad-slot-renderer></ytm-rich-item-renderer>
    <ytm-rich-item-renderer id="rich-video"><ytm-video-with-context-renderer>vidéo</ytm-video-with-context-renderer></ytm-rich-item-renderer>
    <div id="player" class="html5-video-player"><video id="video"></video></div>
  </body></html>`;
  await context.route(`${ORIGIN}/**`, (route) => {
    const url = route.request().url();
    if (url.includes('/youtubei/v1/player')) return route.fulfill({ json: AD_PLAYER_RESPONSE });
    if (url.includes('/youtubei/v1/browse')) return route.fulfill({ json: AD_FEED });
    return route.fulfill({ contentType: 'text/html; charset=utf-8', body: html });
  });
  await page.goto(`${ORIGIN}/watch?v=abc`);

  await check('le script est chargé', async () => {
    assert.strictEqual(await page.evaluate(() => window.__bouclierYoutube), true);
  });
  await check('page initiale : ytInitialPlayerResponse sans annonces', async () => {
    expectClean(await page.evaluate(() => window.ytInitialPlayerResponse));
  });
  await check('page initiale : ytInitialData sans contenus sponsorisés', async () => {
    const data = await page.evaluate(() => window.ytInitialData);
    assert.deepStrictEqual(
      data.contents.map((item) => JSON.stringify(item)),
      [AD_FEED.contents[0], AD_FEED.contents[3], AD_FEED.contents[5]].map((item) => JSON.stringify(item)),
    );
  });
  await check('JSON.parse : annonces retirées, y compris en profondeur', async () => {
    const result = await page.evaluate((text) => JSON.parse(text), JSON.stringify({ playerResponse: AD_PLAYER_RESPONSE }));
    expectClean(result.playerResponse);
  });
  await check('JSON.parse : un JSON sans annonce reste identique', async () => {
    const sample = { a: [1, 2, { b: 'adPlacements' }], playerAds: 'texte' };
    const result = await page.evaluate((text) => JSON.parse(text), JSON.stringify(sample));
    // Seule la clé « playerAds » disparaît ; le reste, même s'il contient le mot, est intact.
    assert.deepStrictEqual(result, { a: sample.a });
  });
  await check('JSON.parse : reviver toujours transmis', async () => {
    const result = await page.evaluate(() => JSON.parse('{"n":1}', (key, value) => (key === 'n' ? value + 1 : value)));
    assert.deepStrictEqual(result, { n: 2 });
  });
  await check('fetch(...).json() : réponse du lecteur nettoyée', async () => {
    expectClean(await page.evaluate(() => fetch('/youtubei/v1/player?key=x').then((r) => r.json())));
  });
  await check('fetch(...).text() + JSON.parse : nettoyée', async () => {
    expectClean(await page.evaluate(() => fetch('/youtubei/v1/player').then((r) => r.text()).then(JSON.parse)));
  });
  await check('XMLHttpRequest (responseType json) : nettoyée', async () => {
    const result = await page.evaluate(() => new Promise((resolve) => {
      const xhr = new XMLHttpRequest();
      xhr.open('GET', '/youtubei/v1/player');
      xhr.responseType = 'json';
      xhr.onload = () => resolve(xhr.response);
      xhr.send();
    }));
    expectClean(result);
  });
  await check('XMLHttpRequest (texte) + JSON.parse : nettoyée', async () => {
    const result = await page.evaluate(() => new Promise((resolve) => {
      const xhr = new XMLHttpRequest();
      xhr.open('GET', '/youtubei/v1/browse');
      xhr.onload = () => resolve(JSON.parse(xhr.responseText));
      xhr.send();
    }));
    assert.strictEqual(result.contents.length, 3);
  });
  await check('CSS : emplacements publicitaires masqués, vidéos visibles', async () => {
    const display = await page.evaluate(() => ['slot', 'rich-ad', 'rich-video'].map((id) => getComputedStyle(document.getElementById(id)).display));
    assert.deepStrictEqual(display.slice(0, 2), ['none', 'none']);
    assert.notStrictEqual(display[2], 'none');
  });
  await check('pub qui démarre : coupée, accélérée, bouton « Ignorer » touché, puis lecteur rétabli', async () => {
    await page.evaluate(() => {
      const player = document.getElementById('player');
      const button = document.createElement('button');
      button.className = 'ytp-skip-ad-button';
      button.onclick = () => { window.skipClicked = true; };
      player.appendChild(button);
      player.classList.add('ad-showing');
    });
    await page.waitForTimeout(400);
    const during = await page.evaluate(() => {
      const video = document.getElementById('video');
      return { muted: video.muted, rate: video.playbackRate, clicked: window.skipClicked === true };
    });
    assert.deepStrictEqual(during, { muted: true, rate: 16, clicked: true });
    await page.evaluate(() => document.getElementById('player').classList.remove('ad-showing'));
    await page.waitForTimeout(400);
    const after = await page.evaluate(() => {
      const video = document.getElementById('video');
      return { muted: video.muted, rate: video.playbackRate };
    });
    assert.deepStrictEqual(after, { muted: false, rate: 1 });
  });
  await check('aucune erreur JavaScript dans la page', async () => {
    assert.deepStrictEqual(pageErrors, []);
  });
  await context.close();
}

async function liveTest(browser, withScript) {
  const label = withScript ? 'avec le script' : 'sans le script';
  const context = await browser.newContext({ ...devices['Pixel 7'], locale: 'fr-FR' });
  await context.addCookies([{ name: 'SOCS', value: 'CAI', domain: '.youtube.com', path: '/', secure: true }]);
  if (withScript) await context.addInitScript({ content: SCRIPT });
  const page = await context.newPage();
  const pageErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  await page.goto(`${ORIGIN}/watch?v=dQw4w9WgXcQ`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForSelector('video', { timeout: 45000 });
  const videoId = await page.evaluate(() => window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.videoDetails && window.ytInitialPlayerResponse.videoDetails.videoId);
  // Lancement de la lecture (sans son, comme le permettent les navigateurs sans geste).
  await page.evaluate(() => { const v = document.querySelector('video'); v.muted = true; return v.play().catch(() => null); });
  await page.waitForTimeout(8000);
  const state = await page.evaluate(() => {
    const v = document.querySelector('video');
    const player = document.querySelector('.html5-video-player');
    return {
      currentTime: v ? v.currentTime : -1,
      adShowing: !!(player && player.classList.contains('ad-showing')),
      scriptLoaded: window.__bouclierYoutube === true,
    };
  });
  await context.close();
  console.log(`  ${label} : videoId=${videoId} lecture=${state.currentTime.toFixed(1)} s pub-affichée=${state.adShowing} erreurs=${pageErrors.length}`);
  return { videoId, ...state, pageErrors };
}

(async () => {
  const proxy = process.env.HTTPS_PROXY ? { server: process.env.HTTPS_PROXY } : undefined;
  const browser = await chromium.launch({ proxy, args: ['--autoplay-policy=no-user-gesture-required'] });
  try {
    await offlineTests(browser);
    if (live) {
      console.log('Test sur le vrai m.youtube.com :');
      const baseline = await liveTest(browser, false);
      const result = await liveTest(browser, true);
      await check('la page réelle se charge et la vidéo démarre avec le script', async () => {
        assert.strictEqual(result.scriptLoaded, true);
        assert.strictEqual(result.videoId, 'dQw4w9WgXcQ');
        assert.ok(result.currentTime > 1, `lecture bloquée à ${result.currentTime} s`);
      });
      await check('le script n\'ajoute aucune erreur JavaScript', async () => {
        const added = result.pageErrors.filter((message) => !baseline.pageErrors.includes(message));
        assert.deepStrictEqual(added, []);
      });
    }
  } finally {
    await browser.close();
  }
  console.log(failures === 0 ? 'Tout est vert.' : `${failures} échec(s).`);
  process.exit(failures === 0 ? 0 : 1);
})();
