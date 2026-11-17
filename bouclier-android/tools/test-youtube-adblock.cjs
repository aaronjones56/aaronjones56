#!/usr/bin/env node
/*
 * Banc d'essai anti-pub YouTube dans Chromium : script intégré (app/src/main/assets/youtube/adblock.js)
 * et règles AdGuard / uBlock Origin telles que l'application les injecte.
 *
 *   ./gradlew testDebugUnitTest --tests '*YoutubeActivityTest'          # écrit app/build/youtube-scripts/
 *   NODE_PATH=$(npm root -g) node tools/test-youtube-adblock.cjs          # tests hors ligne
 *   NODE_PATH=$(npm root -g) node tools/test-youtube-adblock.cjs --live   # + vrai m.youtube.com
 *
 * Les tests hors ligne simulent les réponses de YouTube (page, fetch, XHR) sur l'origine
 * https://m.youtube.com sans toucher au réseau. Les scripts générés par l'application (script
 * intégré, scriptlets des listes, JavaScript d'AdGuard, CSS) sont testés seuls puis ensemble. Le test « --live » vérifie que la page réelle se
 * charge et que la vidéo démarre avec le script : il ne prouve pas qu'une pub est bloquée,
 * YouTube ne diffusant pas forcément de pub à la machine qui exécute le test.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { chromium, devices } = require('playwright');

const SCRIPT = fs.readFileSync(path.join(__dirname, '../app/src/main/assets/youtube/adblock.js'), 'utf8');
const GENERATED = path.join(__dirname, '../app/build/youtube-scripts');
// Scripts injectés par l'application, dans l'ordre : intégré, scriptlets, JavaScript brut, CSS.
const APP_SCRIPTS = fs.existsSync(GENERATED)
  ? fs.readdirSync(GENERATED).filter((name) => name.endsWith('.js')).sort().map((name) => fs.readFileSync(path.join(GENERATED, name), 'utf8'))
  : null;
// Playwright ne garantit pas l'ordre de plusieurs scripts d'initialisation : on les enchaîne.
const join = (scripts) => scripts.join('\n;\n');
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

const AD_SHORTS = {
  entries: [
    { command: { reelWatchEndpoint: { videoId: 'short-pub', adClientParams: { isAd: true } } } },
    { command: { reelWatchEndpoint: { videoId: 'short' } } },
  ],
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

async function offlineTests(browser, script, label) {
  console.log(`Tests hors ligne (réponses simulées), ${label} :`);
  const context = await browser.newContext({ ...devices['Pixel 7'] });
  const page = await context.newPage();
  const pageErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  await page.addInitScript({ content: script });

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

const WATCH_RESPONSE = [
  { page: 'watch', playerResponse: AD_PLAYER_RESPONSE },
  {
    page: 'watch',
    response: {
      contents: {
        singleColumnWatchNextResults: {
          results: {
            results: {
              contents: [
                {
                  itemSectionRenderer: {
                    contents: [
                      { adSlotRenderer: { slotId: 'pub' } },
                      { videoWithContextRenderer: { videoId: 'v1' } },
                    ],
                  },
                },
              ],
            },
          },
        },
      },
    },
  },
];

/** Règles des listes seules, sans le script intégré : vérifie le moteur AdGuard Scriptlets. */
async function rulesOnlyTests(browser) {
  console.log('Règles AdGuard et uBlock Origin seules (sans le script intégré) :');
  const context = await browser.newContext({ ...devices['Pixel 7'] });
  const page = await context.newPage();
  const pageErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  await page.addInitScript({ content: join(APP_SCRIPTS.slice(1)) });
  const html = `<!doctype html><html><head><title>test</title></head><body>
    <script>var ytInitialPlayerResponse = ${JSON.stringify(AD_PLAYER_RESPONSE)};</script>
    <ytm-rich-item-renderer id="rich-ad"><ad-slot-renderer></ad-slot-renderer></ytm-rich-item-renderer>
    <ytm-rich-item-renderer id="rich-video"><ytm-video-with-context-renderer>vidéo</ytm-video-with-context-renderer></ytm-rich-item-renderer>
  </body></html>`;
  await context.route(`${ORIGIN}/**`, (route) => {
    const url = route.request().url();
    if (url.includes('/youtubei/v1/get_watch')) return route.fulfill({ json: WATCH_RESPONSE });
    if (url.includes('/youtubei/v1/player')) return route.fulfill({ json: AD_PLAYER_RESPONSE });
    if (url.includes('/youtubei/v1/reel/reel_watch_sequence')) return route.fulfill({ json: AD_SHORTS });
    return route.fulfill({ contentType: 'text/html; charset=utf-8', body: html });
  });
  await page.goto(`${ORIGIN}/watch?v=abc`);

  await check('scriptlets exécutés (set-constant google_ad_status)', async () => {
    assert.strictEqual(await page.evaluate(() => window.google_ad_status), 1);
  });
  await check('set-constant : ytInitialPlayerResponse sans annonces avant la lecture', async () => {
    const result = await page.evaluate(() => window.ytInitialPlayerResponse);
    assert.strictEqual(result.adPlacements, undefined);
    assert.strictEqual(result.adSlots, undefined);
    assert.strictEqual(result.playerAds, undefined);
    assert.deepStrictEqual(result.videoDetails, AD_PLAYER_RESPONSE.videoDetails);
  });
  await check('json-prune : JSON.parse sans annonces', async () => {
    const result = await page.evaluate((text) => JSON.parse(text), JSON.stringify({ playerResponse: AD_PLAYER_RESPONSE }));
    assert.strictEqual(result.playerResponse.adPlacements, undefined);
    assert.strictEqual(result.playerResponse.adSlots, undefined);
  });
  await check('get_watch (fetch) : annonces et emplacements publicitaires retirés', async () => {
    const result = await page.evaluate(() => fetch('/youtubei/v1/get_watch?prettyPrint=false', { method: 'POST', body: '{}' }).then((r) => r.json()));
    assert.strictEqual(result[0].playerResponse.adPlacements, undefined);
    assert.strictEqual(result[0].playerResponse.adSlots, undefined);
    const items = result[1].response.contents.singleColumnWatchNextResults.results.results.contents[0].itemSectionRenderer.contents;
    assert.deepStrictEqual(items, [{ videoWithContextRenderer: { videoId: 'v1' } }]);
  });
  await check('get_watch (XHR) : réponse réécrite comme par la règle uBlock « replace= »', async () => {
    const text = await page.evaluate(() => new Promise((resolve) => {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', '/youtubei/v1/get_watch?prettyPrint=false');
      xhr.onload = () => resolve(xhr.responseText);
      xhr.send('{}');
    }));
    assert.ok(!text.includes('"adPlacements"'), text.slice(0, 200));
    assert.ok(!text.includes('"adSlots"'), text.slice(0, 200));
  });
  await check('Shorts : Shorts sponsorisés retirés', async () => {
    const result = await page.evaluate(() => fetch('/youtubei/v1/reel/reel_watch_sequence?prettyPrint=false', { method: 'POST' }).then((r) => r.json()));
    assert.deepStrictEqual(result.entries.map((entry) => entry.command.reelWatchEndpoint.videoId), ['short']);
  });
  await check('JavaScript d\'AdGuard : requête du lecteur marquée comme active (lactMilliseconds)', async () => {
    const body = await page.evaluate(() => JSON.parse(JSON.stringify({
      context: { client: { clientName: 'MWEB' } },
      playbackContext: { contentPlaybackContext: {} },
    })));
    assert.match(String(body.playbackContext.contentPlaybackContext.lactMilliseconds), /^\d+$/);
  });
  await check('CSS des listes : emplacements publicitaires masqués, vidéos visibles', async () => {
    const display = await page.evaluate(() => ['rich-ad', 'rich-video'].map((id) => getComputedStyle(document.getElementById(id).firstElementChild).display));
    assert.strictEqual(display[0], 'none');
    assert.notStrictEqual(display[1], 'none');
  });
  await check('aucune erreur JavaScript dans la page', async () => {
    assert.deepStrictEqual(pageErrors, []);
  });
  await context.close();
}

async function liveTest(browser, script) {
  const label = script ? 'avec les scripts' : 'sans les scripts';
  const context = await browser.newContext({ ...devices['Pixel 7'], locale: 'fr-FR' });
  await context.addCookies([{ name: 'SOCS', value: 'CAI', domain: '.youtube.com', path: '/', secure: true }]);
  if (script) await context.addInitScript({ content: script });
  const page = await context.newPage();
  const pageErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  // Données publicitaires envoyées par YouTube (avant tout script) : page et réponses de l'API.
  const served = [];
  page.on('response', async (response) => {
    const url = response.url();
    if (!/m\.youtube\.com\/(watch|youtubei\/v1\/)/.test(url)) return;
    try {
      const body = await response.text();
      if (/"adPlacements"|"adSlots"|adSlotRenderer|"playerAds"/.test(body)) served.push(new URL(url).pathname);
    } catch (error) {
      // corps indisponible (redirection…)
    }
  });
  await page.goto(`${ORIGIN}/watch?v=dQw4w9WgXcQ`, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForSelector('video', { timeout: 45000 });
  const videoId = await page.evaluate(() => window.ytInitialPlayerResponse && window.ytInitialPlayerResponse.videoDetails && window.ytInitialPlayerResponse.videoDetails.videoId);
  // Lancement de la lecture (sans son, comme le permettent les navigateurs sans geste).
  await page.evaluate(() => { const v = document.querySelector('video'); v.muted = true; return v.play().catch(() => null); });
  await page.waitForTimeout(8000);
  const state = await page.evaluate(() => {
    const v = document.querySelector('video');
    const player = document.querySelector('.html5-video-player');
    const response = window.ytInitialPlayerResponse || {};
    return {
      currentTime: v ? v.currentTime : -1,
      adShowing: !!(player && player.classList.contains('ad-showing')),
      scriptLoaded: window.__bouclierYoutube === true,
      adsInPage: ['adPlacements', 'adSlots', 'playerAds'].filter((key) => response[key] !== undefined),
    };
  });
  await context.close();
  console.log(`  ${label} : videoId=${videoId} lecture=${state.currentTime.toFixed(1)} s pub-affichée=${state.adShowing} ` +
    `pub-envoyée-par-YouTube=${served.length ? [...new Set(served)].join(',') : 'non'} pub-vue-par-la-page=${state.adsInPage.join(',') || 'non'} erreurs=${pageErrors.length}`);
  return { videoId, ...state, served, pageErrors };
}

(async () => {
  const proxy = process.env.HTTPS_PROXY ? { server: process.env.HTTPS_PROXY } : undefined;
  const browser = await chromium.launch({ proxy, args: ['--autoplay-policy=no-user-gesture-required'] });
  const full = APP_SCRIPTS ? join(APP_SCRIPTS) : SCRIPT;
  try {
    await offlineTests(browser, SCRIPT, 'script intégré seul');
    if (APP_SCRIPTS) {
      await rulesOnlyTests(browser);
      await offlineTests(browser, full, 'script intégré + règles des listes');
    } else {
      console.log('  (app/build/youtube-scripts absent : lancez d\'abord le test YoutubeActivityTest)');
    }
    if (live) {
      console.log('Test sur le vrai m.youtube.com :');
      const baseline = await liveTest(browser, null);
      const result = await liveTest(browser, full);
      await check('la page réelle se charge et la vidéo démarre avec le script', async () => {
        assert.strictEqual(result.scriptLoaded, true);
        assert.strictEqual(result.videoId, 'dQw4w9WgXcQ');
        assert.ok(result.currentTime > 1, `lecture bloquée à ${result.currentTime} s`);
      });
      await check('les annonces envoyées par YouTube n\'atteignent pas la page', async () => {
        assert.deepStrictEqual(result.adsInPage, []);
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
