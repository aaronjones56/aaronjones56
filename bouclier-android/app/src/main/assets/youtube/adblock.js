/*
 * Bouclier : retire les publicités de YouTube dans le lecteur intégré à l'application.
 *
 * Ce script est injecté avant ceux de la page. Il agit en trois temps :
 *  1. il retire les annonces des données du lecteur (adPlacements, playerAds, adSlots…) et les
 *     contenus sponsorisés des listes de vidéos, d'où qu'elles viennent : page initiale,
 *     JSON.parse, fetch ou XMLHttpRequest ;
 *  2. il masque les emplacements publicitaires qui resteraient affichés ;
 *  3. en dernier recours, si une annonce démarre quand même, il la coupe et la saute.
 */
(function () {
  'use strict';
  if (window.__bouclierYoutube) return;
  Object.defineProperty(window, '__bouclierYoutube', { value: true });

  // Champs de la réponse du lecteur qui décrivent les annonces à diffuser.
  var PLAYER_AD_KEYS = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams'];

  // Éléments sponsorisés des listes (accueil, recherche, suggestions, Shorts).
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
  };

  // Indices rapides : on ne parcourt une réponse que si elle peut contenir une annonce.
  var AD_HINT = /"(?:adPlacements|playerAds|adSlots)"|AdRenderer|AdLayoutRenderer|[Pp]romoted\w*Renderer|PyvRenderer|PromoRenderer|adClientParams/;

  var cleaned = typeof WeakSet === 'function' ? new WeakSet() : null;

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

  /** Retire les annonces d'un objet, en profondeur. Renvoie l'objet lui-même. */
  function prune(value, depth) {
    if (!value || typeof value !== 'object' || depth > 64) return value;
    if (Array.isArray(value)) {
      for (var i = value.length - 1; i >= 0; i--) {
        var item = value[i];
        if (item && typeof item === 'object') {
          if (!Array.isArray(item) && isAdItem(item)) {
            value.splice(i, 1);
          } else {
            prune(item, depth + 1);
          }
        }
      }
      return value;
    }
    for (var k = 0; k < PLAYER_AD_KEYS.length; k++) {
      if (PLAYER_AD_KEYS[k] in value) delete value[PLAYER_AD_KEYS[k]];
    }
    for (var key in value) {
      var child = value[key];
      if (child && typeof child === 'object') prune(child, depth + 1);
    }
    return value;
  }

  function clean(value) {
    if (!value || typeof value !== 'object') return value;
    if (cleaned) {
      if (cleaned.has(value)) return value;
      cleaned.add(value);
    }
    try {
      prune(value, 0);
    } catch (e) {
      // Ne jamais casser la page.
    }
    return value;
  }

  // 1a. Données insérées dans la page : « var ytInitialPlayerResponse = {…} ».
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

  // 1b. Réponses analysées avec JSON.parse (page initiale, XMLHttpRequest « text »).
  var nativeParse = JSON.parse;
  JSON.parse = function (text) {
    var value = nativeParse.apply(this, arguments);
    if (typeof text === 'string' && AD_HINT.test(text)) clean(value);
    return value;
  };

  // 1c. Réponses lues avec fetch(…).json().
  if (window.Response && Response.prototype.json) {
    var nativeJson = Response.prototype.json;
    Response.prototype.json = function () {
      return nativeJson.apply(this, arguments).then(clean);
    };
  }

  // 1d. XMLHttpRequest avec responseType = "json".
  try {
    var responseDescriptor = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'response');
    if (responseDescriptor && responseDescriptor.get) {
      Object.defineProperty(XMLHttpRequest.prototype, 'response', {
        configurable: true,
        enumerable: responseDescriptor.enumerable,
        get: function () {
          var value = responseDescriptor.get.call(this);
          return this.responseType === 'json' ? clean(value) : value;
        },
      });
    }
  } catch (e) {
    // navigateur sans accesseur standard
  }

  // 2. Emplacements publicitaires restants. Les sélecteurs « :has » sont dans une règle à part :
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

  // 3. Filet de sécurité : une annonce qui démarre quand même est coupée et accélérée
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
