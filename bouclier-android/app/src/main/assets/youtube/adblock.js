/*
 * Bouclier : protections intégrées contre les publicités de YouTube (lecteur sans pub).
 *
 * Ce script est injecté avant ceux de la page, comme le font les extensions de blocage. Il
 * intercepte les données au moment où le site les reçoit, avant que le lecteur ne les lise :
 *  1. réponses réseau (fetch et XMLHttpRequest) du lecteur, des pages et des listes : les
 *     annonces (adPlacements, adSlots, playerAds…) et les vidéos sponsorisées sont retirées
 *     du texte même de la réponse. Le lecteur n'a alors aucune pub à lancer et démarre la vidéo ;
 *  2. données insérées dans la page (ytInitialPlayerResponse…) et tout JSON.parse ;
 *  3. contournements : une iframe vierge ne permet pas de retrouver des fonctions non filtrées ;
 *  4. emplacements publicitaires restants masqués ;
 *  5. dernier recours : une annonce qui démarrerait quand même est coupée et accélérée.
 *
 * Les règles des listes AdGuard et uBlock Origin sont ajoutées après ce script (voir
 * YoutubeScriptBuilder) : ces protections-ci restent actives même sans elles.
 */
(function () {
  'use strict';
  if (window.__bouclierYoutube) return;
  Object.defineProperty(window, '__bouclierYoutube', { value: true });

  // Champs de la réponse du lecteur qui décrivent les annonces à diffuser.
  var PLAYER_AD_KEYS = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams'];

  // Éléments à retirer des listes : annonces (accueil, recherche, suggestions, Shorts) et
  // fenêtre « Vous regardez toujours ? ».
  var AD_RENDERERS = {
    adSlotRenderer: 1,
    inFeedAdLayoutRenderer: 1,
    promotedSparklesWebRenderer: 1,
    promotedSparklesTextSearchRenderer: 1,
    promotedVideoRenderer: 1,
    compactPromotedVideoRenderer: 1,
    searchPyvRenderer: 1,
    bannerPromoRenderer: 1,
    mealbarPromoRenderer: 1,
    companionAdRenderer: 1,
    actionCompanionAdRenderer: 1,
    playerLegacyDesktopWatchAdsRenderer: 1,
    youThereRenderer: 1,
  };

  // Indice rapide : on ne parcourt une réponse que si elle peut contenir une annonce.
  var AD_HINT = /"(?:adPlacements|playerAds|adSlots|adBreakHeartbeatParams)"|adSlotRenderer|AdRenderer|AdLayoutRenderer|[Pp]romoted\w*Renderer|PyvRenderer|PromoRenderer|adClientParams|youThereRenderer/;

  // Adresses dont les réponses décrivent des vidéos, des pages ou des listes.
  var API_URL = /\/youtubei\/v1\/(?:player|get_watch|next|browse|search|reel|resolve_url|guide)|\/(?:watch|playlist)\?|\/shorts\/|[?&]pbj=1/;

  // Préfixe anti-XSSI que YouTube place parfois devant le JSON.
  var XSSI_PREFIX = ")]}'";

  var nativeParse = JSON.parse;
  var nativeStringify = JSON.stringify;
  var cleaned = new WeakSet();

  function hasAdRenderer(object) {
    for (var key in object) {
      if (AD_RENDERERS[key]) return true;
    }
    return false;
  }

  /** Vrai si l'élément d'une liste est une annonce. */
  function isAdItem(item) {
    if (hasAdRenderer(item)) return true;
    for (var key in item) {
      var value = item[key];
      if (value && typeof value === 'object' && value.content && typeof value.content === 'object' && hasAdRenderer(value.content)) {
        return true;
      }
    }
    // Shorts sponsorisés
    var command = item.command;
    return !!(command && command.reelWatchEndpoint && command.reelWatchEndpoint.adClientParams);
  }

  /** Retire les annonces d'un objet, en profondeur. Renvoie vrai si quelque chose a été retiré. */
  function prune(value, depth) {
    if (!value || typeof value !== 'object' || depth > 64) return false;
    var changed = false;
    if (Array.isArray(value)) {
      for (var i = value.length - 1; i >= 0; i--) {
        var item = value[i];
        if (item && typeof item === 'object') {
          if (!Array.isArray(item) && isAdItem(item)) {
            value.splice(i, 1);
            changed = true;
          } else if (prune(item, depth + 1)) {
            changed = true;
          }
        }
      }
      return changed;
    }
    for (var k = 0; k < PLAYER_AD_KEYS.length; k++) {
      if (PLAYER_AD_KEYS[k] in value) {
        delete value[PLAYER_AD_KEYS[k]];
        changed = true;
      }
    }
    for (var key in value) {
      var child = value[key];
      if (child && typeof child === 'object' && prune(child, depth + 1)) changed = true;
    }
    return changed;
  }

  function clean(value) {
    if (!value || typeof value !== 'object' || cleaned.has(value)) return value;
    cleaned.add(value);
    try {
      prune(value, 0);
    } catch (e) {
      // Ne jamais casser la page.
    }
    return value;
  }

  /** Texte d'une réponse, débarrassé de ses annonces (identique s'il n'y en a pas). */
  function cleanText(text) {
    if (typeof text !== 'string' || !AD_HINT.test(text)) return text;
    var prefix = '';
    var body = text;
    if (body.lastIndexOf(XSSI_PREFIX, 0) === 0) {
      var newline = body.indexOf('\n');
      prefix = body.slice(0, newline + 1);
      body = body.slice(newline + 1);
    }
    try {
      var data = nativeParse(body);
      if (data && typeof data === 'object' && prune(data, 0)) return prefix + nativeStringify(data);
      return text;
    } catch (e) {
      // Pas du JSON entier : on rend les clés publicitaires illisibles, comme uBlock Origin.
      return text.replace(/"(?:adPlacements|adSlots|playerAds)"/g, '"no_ads"');
    }
  }

  /** Remplace une fonction par un Proxy : elle garde son nom et son code « natif » apparent. */
  function wrap(owner, name, apply) {
    var original = owner && owner[name];
    if (typeof original !== 'function') return;
    try {
      owner[name] = new Proxy(original, { apply: apply });
    } catch (e) {
      // propriété non modifiable
    }
  }

  // 1a. fetch : la réponse est réécrite avant que la page ne la lise (json, text, flux…).
  function cleanResponse(response) {
    if (!response || response.type === 'opaque' || response.bodyUsed) return response;
    var type = response.headers.get('content-type') || '';
    if (type && !/json|text|javascript/.test(type)) return response;
    return response.clone().text().then(function (text) {
      var result = cleanText(text);
      if (result === text) return response;
      var headers = new Headers(response.headers);
      headers.delete('content-length');
      headers.delete('content-encoding');
      var copy = new Response(result, { status: response.status, statusText: response.statusText, headers: headers });
      Object.defineProperties(copy, {
        url: { value: response.url },
        redirected: { value: response.redirected },
        type: { value: response.type },
      });
      return copy;
    }).catch(function () {
      return response;
    });
  }

  function requestUrl(input) {
    if (typeof input === 'string') return input;
    if (input && typeof input.url === 'string') return input.url;
    return String(input);
  }

  var fetchHandler = function (target, thisArg, args) {
    var promise = Reflect.apply(target, thisArg, args);
    if (!API_URL.test(requestUrl(args[0]))) return promise;
    return promise.then(cleanResponse);
  };
  wrap(window, 'fetch', fetchHandler);

  // 1b. Réponses lues avec Response.json(), quelle que soit l'adresse.
  if (window.Response) {
    wrap(Response.prototype, 'json', function (target, thisArg, args) {
      return Reflect.apply(target, thisArg, args).then(clean);
    });
  }

  // 1c. XMLHttpRequest : responseText et response sont nettoyés une fois la réponse complète.
  var xhrUrls = new WeakMap();
  var xhrCache = new WeakMap();
  wrap(XMLHttpRequest.prototype, 'open', function (target, xhr, args) {
    xhrUrls.set(xhr, String(args[1]));
    return Reflect.apply(target, xhr, args);
  });

  function cleanedXhrText(xhr, raw) {
    var entry = xhrCache.get(xhr);
    if (entry && entry.raw === raw) return entry.result;
    var result = cleanText(raw);
    xhrCache.set(xhr, { raw: raw, result: result });
    return result;
  }

  function isApiXhr(xhr) {
    return xhr.readyState === 4 && API_URL.test(xhrUrls.get(xhr) || '');
  }

  try {
    var textDescriptor = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'responseText');
    var responseDescriptor = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'response');
    if (textDescriptor && textDescriptor.get) {
      Object.defineProperty(XMLHttpRequest.prototype, 'responseText', {
        configurable: true,
        enumerable: textDescriptor.enumerable,
        get: function () {
          var raw = textDescriptor.get.call(this);
          return isApiXhr(this) ? cleanedXhrText(this, raw) : raw;
        },
      });
    }
    if (responseDescriptor && responseDescriptor.get) {
      Object.defineProperty(XMLHttpRequest.prototype, 'response', {
        configurable: true,
        enumerable: responseDescriptor.enumerable,
        get: function () {
          var value = responseDescriptor.get.call(this);
          if (this.responseType === 'json') return clean(value);
          if ((this.responseType === '' || this.responseType === 'text') && isApiXhr(this)) return cleanedXhrText(this, value);
          return value;
        },
      });
    }
  } catch (e) {
    // navigateur sans accesseurs standard
  }

  // 2a. Tout JSON analysé par la page (dont les données de la page initiale).
  wrap(JSON, 'parse', function (target, thisArg, args) {
    var value = Reflect.apply(target, thisArg, args);
    if (typeof args[0] === 'string' && AD_HINT.test(args[0])) clean(value);
    return value;
  });

  // 2b. Données insérées dans la page : « var ytInitialPlayerResponse = {…} ».
  ['ytInitialPlayerResponse', 'ytInitialData', 'ytInitialReelWatchSequenceResponse'].forEach(function (name) {
    var stored = window[name];
    try {
      Object.defineProperty(window, name, {
        configurable: true,
        enumerable: true,
        get: function () {
          return stored;
        },
        set: function (value) {
          stored = clean(value);
        },
      });
    } catch (e) {
      // propriété déjà verrouillée par la page
    }
  });

  // 3. Contournement par iframe : une iframe vierge fournirait des fetch, JSON.parse et
  // XMLHttpRequest d'origine. On lui donne ceux de la page, déjà protégés.
  function protectFrame(frame) {
    try {
      var frameWindow = frame.contentWindow;
      if (!frameWindow || frameWindow === window || frameWindow.__bouclierYoutube) return;
      Object.defineProperty(frameWindow, '__bouclierYoutube', { value: true });
      frameWindow.fetch = window.fetch;
      frameWindow.XMLHttpRequest = window.XMLHttpRequest;
      frameWindow.JSON.parse = JSON.parse;
      frameWindow.Response.prototype.json = Response.prototype.json;
    } catch (e) {
      // iframe d'une autre origine : inaccessible, et inoffensive
    }
  }

  function protectInserted(node) {
    if (!node || node.nodeType !== 1 && node.nodeType !== 11) return;
    if (node.tagName === 'IFRAME') protectFrame(node);
    if (node.querySelectorAll) {
      var frames = node.querySelectorAll('iframe');
      for (var i = 0; i < frames.length; i++) protectFrame(frames[i]);
    }
  }

  function afterInsertion(target, thisArg, args) {
    var result = Reflect.apply(target, thisArg, args);
    for (var i = 0; i < args.length; i++) protectInserted(args[i]);
    return result;
  }
  wrap(Node.prototype, 'appendChild', afterInsertion);
  wrap(Node.prototype, 'insertBefore', afterInsertion);
  wrap(Node.prototype, 'replaceChild', afterInsertion);
  ['append', 'prepend', 'after', 'before', 'replaceWith'].forEach(function (name) {
    wrap(Element.prototype, name, afterInsertion);
  });

  // 4. Emplacements publicitaires restants. Les sélecteurs « :has » sont dans une règle à part :
  // un navigateur trop ancien pour les comprendre ignorerait sinon toute la règle.
  var css = [
    'ad-slot-renderer', 'ytm-ad-slot-renderer', 'ytm-in-feed-ad-layout-renderer',
    'ytm-promoted-sparkles-web-renderer', 'ytm-promoted-sparkles-text-search-renderer',
    'ytm-promoted-video-renderer', 'ytm-compact-promoted-video-renderer', 'ytm-search-pyv-renderer',
    'ytm-companion-ad-renderer', 'ytm-companion-slot', 'ytm-banner-promo-renderer',
    'ytm-mealbar-promo-renderer', 'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer',
    'ytd-promoted-sparkles-web-renderer', 'ytd-banner-promo-renderer', 'ytd-companion-slot-renderer',
    '.ytp-ad-overlay-container', '.ytp-ad-image-overlay',
  ].join(',\n') + ' { display: none !important; }\n' + [
    'ytm-rich-item-renderer:has(ytm-ad-slot-renderer)', 'ytm-rich-item-renderer:has(ad-slot-renderer)',
    'ytd-rich-item-renderer:has(ytd-ad-slot-renderer)',
  ].join(',\n') + ' { display: none !important; }';

  function injectStyle() {
    var root = document.head || document.documentElement;
    if (!root) return false;
    var style = document.createElement('style');
    style.id = 'bouclier-youtube';
    style.textContent = css;
    root.appendChild(style);
    return true;
  }
  if (!injectStyle()) document.addEventListener('DOMContentLoaded', injectStyle, { once: true });

  // 5. Dernier recours : une annonce qui démarrerait quand même est coupée et accélérée
  // (16 fois : 2 secondes pour 30 secondes de pub), et son bouton « Ignorer » est touché dès
  // qu'il apparaît. On n'avance pas la lecture jusqu'à la fin : au moment précis où l'annonce
  // laisse place à la vidéo, cela risquerait de sauter la vidéo elle-même.
  var adState = null; // état du lecteur avant l'annonce, pour le rétablir ensuite

  function skipAds() {
    var player = document.querySelector('.html5-video-player');
    var video = player && player.querySelector('video');
    if (!video) return;
    var adShowing = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
    if (adShowing) {
      if (!adState) adState = { muted: video.muted, rate: video.playbackRate };
      video.muted = true;
      if (video.playbackRate !== 16) video.playbackRate = 16;
      var skip = document.querySelector(
        '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-container button',
      );
      if (skip) skip.click();
    } else if (adState) {
      video.muted = adState.muted;
      video.playbackRate = adState.rate;
      adState = null;
    }
  }
  window.__bouclierSkipAds = skipAds;
  setInterval(skipAds, 250);
})();
