/*
 * Photobooth : interface de la borne.
 *
 * Machine à états : loading -> home -> frames -> preview (compte à rebours) -> processing -> result.
 * Toute la logique matérielle est côté serveur ; ce fichier gère l'affichage, l'aperçu caméra,
 * l'inactivité, l'impression et l'accès administrateur caché (5 touches dans le coin haut gauche,
 * Ctrl+Alt+A pour l'administration, Ctrl+Alt+Q pour quitter le kiosk).
 */
(() => {
  'use strict';

  const PREVIEW_INTERVAL_MS = 70;
  const LOADING_MIN_MS = 1400;
  const IDLE_WARNING_MS = 10000;
  const SECRET_TAPS = 5;
  const SECRET_WINDOW_MS = 3000;
  const HEALTH_INTERVAL_MS = 15000;
  const IDLE_SCREENS = new Set(['frames', 'preview', 'result']);
  const CHECK_SVG = '<svg viewBox="0 0 24 24" aria-hidden="true"><polyline points="20 6 9 17 4 12"/></svg>';

  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => Array.from(document.querySelectorAll(selector));
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  const els = {
    screens: $$('.screen'),
    loadingText: $('#loading-text'),
    loadingRetry: $('#loading-retry'),
    checkItems: $$('#checklist li'),
    homeStart: $('#home-start'),
    homeEvent: $('#home-event'),
    framesGrid: $('#frames-grid'),
    framesBack: $('#frames-back'),
    framesContinue: $('#frames-continue'),
    previewStage: $('#preview-stage'),
    previewCanvas: $('#preview-canvas'),
    previewPlaceholder: $('#preview-placeholder'),
    previewPlaceholderText: $('#preview-placeholder-text'),
    previewTitle: $('#preview-title'),
    previewSubtitle: $('#preview-subtitle'),
    shotBadge: $('#shot-badge'),
    shotStrip: $('#shot-strip'),
    countdown: $('#countdown'),
    countdownValue: $('#countdown-value'),
    btnShoot: $('#btn-shoot'),
    btnShootLabel: $('#btn-shoot-label'),
    btnPreviewBack: $('#btn-preview-back'),
    processingText: $('#processing-text'),
    resultPhoto: $('#result-photo'),
    resultQr: $('#result-qr'),
    resultCode: $('#result-code'),
    resultUrl: $('#result-url'),
    resultNotice: $('#result-notice'),
    btnPrint: $('#btn-print'),
    btnPrintLabel: $('#btn-print-label'),
    btnAgain: $('#btn-again'),
    btnFinish: $('#btn-finish'),
    printStatus: $('#print-status'),
    idleWarning: $('#idle-warning'),
    idleProgress: $('#idle-progress'),
    idleText: $('#idle-text'),
    flash: $('#flash'),
    toast: $('#toast'),
    modalError: $('#modal-error'),
    errorTitle: $('#error-title'),
    errorMessage: $('#error-message'),
    errorRetry: $('#error-retry'),
    errorHome: $('#error-home'),
    modalCopies: $('#modal-copies'),
    copiesValue: $('#copies-value'),
    copiesMinus: $('#copies-minus'),
    copiesPlus: $('#copies-plus'),
    copiesHint: $('#copies-hint'),
    copiesCancel: $('#copies-cancel'),
    copiesConfirm: $('#copies-confirm'),
    modalPin: $('#modal-pin'),
    pinTitle: $('#pin-title'),
    pinDots: $('#pin-dots'),
    pinError: $('#pin-error'),
    keypad: $('#keypad'),
    pinCancel: $('#pin-cancel'),
    modalMenu: $('#modal-menu'),
    menuAdmin: $('#menu-admin'),
    menuQuit: $('#menu-quit'),
    menuClose: $('#menu-close'),
    offline: $('#offline'),
    goodbye: $('#goodbye'),
    secretCorner: $('#secret-corner'),
  };
  const modals = [els.modalError, els.modalCopies, els.modalPin, els.modalMenu];

  const state = {
    screen: 'loading',
    ui: {
      session_timeout: 45,
      countdown_seconds: 3,
      print_enabled: true,
      auto_print: false,
      print_max_copies: 1,
      preview_mirror: true,
      sound_enabled: true,
      camera_preview: true,
      crop_centering: [0.5, 0.5],
      notice: "Les photos seront disponibles après l'événement.",
    },
    event: null,
    frames: [],
    frame: null,
    session: null,
    photo: null,
    busy: false,
    printing: false,
    copies: 1,
    copiesMax: 1,
    offline: false,
    quitting: false,
  };

  // ---------------------------------------------------------------------------
  // Appels au serveur
  // ---------------------------------------------------------------------------

  class ApiError extends Error {
    constructor(message, status, code) {
      super(message);
      this.status = status;
      this.code = code;
    }
  }

  async function api(method, url, body = null, { timeout = 30000 } = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeout);
    const options = { method, cache: 'no-store', signal: controller.signal, headers: { Accept: 'application/json' } };
    if (method !== 'GET') {
      options.headers['Content-Type'] = 'application/json';
      options.body = JSON.stringify(body || {});
    }
    try {
      let response;
      try {
        response = await fetch(url, options);
      } catch (error) {
        probeConnection();
        const message = error.name === 'AbortError' ? 'Le serveur ne répond pas.' : 'Connexion au serveur impossible.';
        throw new ApiError(message, 0, 'network');
      }
      let data = null;
      try {
        data = await response.json();
      } catch (_) {
        data = null;
      }
      if (!response.ok || (data && data.ok === false)) {
        throw new ApiError((data && data.error) || `Erreur ${response.status}`, response.status, data && data.code);
      }
      return data || {};
    } finally {
      clearTimeout(timer);
    }
  }

  function loadImage(url) {
    return new Promise((resolve, reject) => {
      const image = new Image();
      image.onload = () => resolve(image);
      image.onerror = () => reject(new Error(`Image introuvable : ${url}`));
      image.src = url;
    });
  }

  // ---------------------------------------------------------------------------
  // Sons (générés, aucun fichier audio nécessaire)
  // ---------------------------------------------------------------------------

  const sound = {
    context: null,

    ensure() {
      if (!state.ui.sound_enabled) return null;
      const AudioContextClass = window.AudioContext || window.webkitAudioContext;
      if (!AudioContextClass) return null;
      if (!this.context) this.context = new AudioContextClass();
      if (this.context.state === 'suspended') this.context.resume().catch(() => {});
      return this.context;
    },

    beep(frequency = 660, duration = 0.12, volume = 0.25) {
      const context = this.ensure();
      if (!context) return;
      const oscillator = context.createOscillator();
      const gain = context.createGain();
      oscillator.type = 'sine';
      oscillator.frequency.value = frequency;
      gain.gain.setValueAtTime(0.0001, context.currentTime);
      gain.gain.exponentialRampToValueAtTime(volume, context.currentTime + 0.01);
      gain.gain.exponentialRampToValueAtTime(0.0001, context.currentTime + duration);
      oscillator.connect(gain).connect(context.destination);
      oscillator.start();
      oscillator.stop(context.currentTime + duration + 0.05);
    },

    shutter() {
      const context = this.ensure();
      if (!context) return;
      const length = Math.floor(context.sampleRate * 0.18);
      const buffer = context.createBuffer(1, length, context.sampleRate);
      const data = buffer.getChannelData(0);
      for (let index = 0; index < length; index += 1) {
        data[index] = (Math.random() * 2 - 1) * (1 - index / length) ** 3;
      }
      const source = context.createBufferSource();
      const filter = context.createBiquadFilter();
      const gain = context.createGain();
      source.buffer = buffer;
      filter.type = 'highpass';
      filter.frequency.value = 900;
      gain.gain.value = 0.5;
      source.connect(filter).connect(gain).connect(context.destination);
      source.start();
    },
  };

  // ---------------------------------------------------------------------------
  // Écrans, notifications et fenêtres
  // ---------------------------------------------------------------------------

  function showScreen(name) {
    state.screen = name;
    els.screens.forEach((screen) => screen.classList.toggle('is-active', screen.dataset.screen === name));
    idle.reset();
  }

  let toastTimer = null;
  function toast(message, kind = 'info', duration = 3800) {
    els.toast.textContent = message;
    els.toast.className = `toast is-visible is-${kind}`;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      els.toast.className = 'toast';
    }, duration);
  }

  function openModal(modal) {
    modal.hidden = false;
    idle.reset();
  }

  function closeModal(modal) {
    modal.hidden = true;
    idle.reset();
  }

  const anyModalOpen = () => modals.some((modal) => !modal.hidden);

  function closeAllModals() {
    modals.forEach((modal) => {
      modal.hidden = true;
    });
  }

  let errorRetryAction = null;
  function showError(message, { title = 'Oups !', retry = null, retryLabel = 'RÉESSAYER' } = {}) {
    els.errorTitle.textContent = title;
    els.errorMessage.textContent = message;
    els.errorRetry.textContent = retryLabel;
    els.errorRetry.hidden = !retry;
    errorRetryAction = retry;
    openModal(els.modalError);
  }

  function triggerFlash() {
    els.flash.classList.remove('is-active');
    void els.flash.offsetWidth;
    els.flash.classList.add('is-active');
  }

  // ---------------------------------------------------------------------------
  // Inactivité : retour automatique à l'accueil
  // ---------------------------------------------------------------------------

  const idle = {
    deadline: Date.now(),

    timeoutMs() {
      return Math.max(10, Number(state.ui.session_timeout) || 45) * 1000;
    },

    reset() {
      this.deadline = Date.now() + this.timeoutMs();
      els.idleWarning.hidden = true;
    },

    tick() {
      const watched = IDLE_SCREENS.has(state.screen) || anyModalOpen();
      if (!watched || state.busy || state.printing || state.offline) {
        this.reset();
        return;
      }
      const remaining = this.deadline - Date.now();
      if (remaining <= 0) {
        const wasAdmin = !els.modalMenu.hidden;
        closeAllModals();
        if (wasAdmin) api('POST', '/admin/logout', {}).catch(() => {});
        goHome();
        return;
      }
      if (remaining <= IDLE_WARNING_MS && state.screen !== 'home') {
        const seconds = Math.ceil(remaining / 1000);
        els.idleText.textContent = `Retour à l'accueil dans ${seconds} s — touchez l'écran pour continuer`;
        els.idleProgress.style.transform = `scaleX(${remaining / IDLE_WARNING_MS})`;
        els.idleWarning.hidden = false;
      } else {
        els.idleWarning.hidden = true;
      }
    },
  };

  // ---------------------------------------------------------------------------
  // Aperçu caméra : même recadrage que la photo finale (ce que l'on voit = ce que l'on obtient)
  // ---------------------------------------------------------------------------

  function drawCover(context, image, dx, dy, dw, dh, mirror, centering) {
    const scale = Math.max(dw / image.width, dh / image.height);
    const cropWidth = dw / scale;
    const cropHeight = dh / scale;
    const sx = (image.width - cropWidth) * centering[0];
    const sy = (image.height - cropHeight) * centering[1];
    context.save();
    context.beginPath();
    context.rect(dx, dy, dw, dh);
    context.clip();
    if (mirror) {
      context.translate(dx + dw, dy);
      context.scale(-1, 1);
      context.drawImage(image, sx, sy, cropWidth, cropHeight, 0, 0, dw, dh);
    } else {
      context.drawImage(image, sx, sy, cropWidth, cropHeight, dx, dy, dw, dh);
    }
    context.restore();
  }

  const preview = {
    canvas: els.previewCanvas,
    context: els.previewCanvas.getContext('2d'),
    token: 0,
    running: false,
    paused: false,
    bitmap: null,
    overlay: null,
    shot: 0,
    errors: 0,
    scale: 1,

    isMulti() {
      return Boolean(state.frame && state.frame.shots > 1);
    },

    layoutSize() {
      const frame = state.frame;
      if (!frame) return [2, 3];
      if (this.isMulti()) return frame.shot_sizes[Math.min(this.shot, frame.shots - 1)];
      return [frame.width, frame.height];
    },

    async start() {
      this.stop();
      const token = this.token;
      this.shot = 0;
      this.errors = 0;
      this.overlay = null;
      const frame = state.frame;
      if (frame && frame.overlay_url && frame.shots === 1) {
        this.overlay = await loadImage(frame.overlay_url).catch(() => null);
        if (token !== this.token) return;
      }
      this.resize();
      if (!state.ui.camera_preview) {
        this.setPlaceholder(true, "Regardez l'appareil photo");
        return;
      }
      this.setPlaceholder(true, 'Démarrage de la caméra…');
      this.running = true;
      this.loop(token);
    },

    stop() {
      this.running = false;
      this.token += 1;
      if (this.bitmap && this.bitmap.close) this.bitmap.close();
      this.bitmap = null;
    },

    setShot(index) {
      this.shot = index;
      this.resize();
    },

    async loop(token) {
      while (this.running && token === this.token) {
        if (this.paused || document.hidden) {
          await sleep(120);
          continue;
        }
        const started = performance.now();
        try {
          const response = await fetch(`/api/camera/preview?t=${Date.now()}`, { cache: 'no-store' });
          if (token !== this.token) break;
          if (response.status === 204) {
            this.setPlaceholder(true, "Regardez l'appareil photo");
            await sleep(1500);
            continue;
          }
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          const bitmap = await createImageBitmap(await response.blob());
          if (token !== this.token) {
            if (bitmap.close) bitmap.close();
            break;
          }
          if (this.bitmap && this.bitmap.close) this.bitmap.close();
          this.bitmap = bitmap;
          this.errors = 0;
          this.setPlaceholder(false);
          this.render();
        } catch (_) {
          this.errors += 1;
          if (this.errors >= 4) this.setPlaceholder(true, 'Aperçu indisponible : la photo sera quand même prise');
          await sleep(600);
        }
        await sleep(Math.max(0, PREVIEW_INTERVAL_MS - (performance.now() - started)));
      }
    },

    setPlaceholder(visible, text) {
      els.previewPlaceholder.hidden = !visible;
      if (text) els.previewPlaceholderText.textContent = text;
    },

    resize() {
      const [width, height] = this.layoutSize();
      const boxWidth = els.previewStage.clientWidth;
      const boxHeight = els.previewStage.clientHeight;
      if (!boxWidth || !boxHeight) return;
      const scale = Math.min(boxWidth / width, boxHeight / height);
      const cssWidth = Math.max(1, Math.floor(width * scale));
      const cssHeight = Math.max(1, Math.floor(height * scale));
      const ratio = window.devicePixelRatio || 1;
      this.canvas.style.width = `${cssWidth}px`;
      this.canvas.style.height = `${cssHeight}px`;
      this.canvas.width = Math.round(cssWidth * ratio);
      this.canvas.height = Math.round(cssHeight * ratio);
      this.scale = this.canvas.width / width;
      els.shotBadge.style.top = `${this.canvas.offsetTop + 16}px`;
      this.render();
    },

    render() {
      const { context, canvas } = this;
      const frame = state.frame;
      context.setTransform(1, 0, 0, 1, 0, 0);
      context.fillStyle = '#15121f';
      context.fillRect(0, 0, canvas.width, canvas.height);
      if (!frame) return;
      const mirror = Boolean(state.ui.preview_mirror);
      const centering = state.ui.crop_centering || [0.5, 0.5];
      if (this.isMulti()) {
        if (this.bitmap) drawCover(context, this.bitmap, 0, 0, canvas.width, canvas.height, mirror, centering);
        return;
      }
      for (const slot of frame.slots) {
        const x = slot.x * this.scale;
        const y = slot.y * this.scale;
        const w = slot.width * this.scale;
        const h = slot.height * this.scale;
        if (this.bitmap) {
          drawCover(context, this.bitmap, x, y, w, h, mirror, centering);
        } else {
          context.fillStyle = '#221c31';
          context.fillRect(x, y, w, h);
        }
      }
      if (this.overlay) context.drawImage(this.overlay, 0, 0, canvas.width, canvas.height);
    },
  };

  // ---------------------------------------------------------------------------
  // Démarrage et accueil
  // ---------------------------------------------------------------------------

  function applyConfig(data) {
    if (data.ui) Object.assign(state.ui, data.ui);
    if (data.event) {
      state.event = data.event;
      els.homeEvent.textContent = data.event.name;
    }
  }

  async function refreshConfig() {
    try {
      applyConfig(await api('GET', '/api/config', null, { timeout: 8000 }));
    } catch (_) {
      // La configuration précédente reste valable.
    }
  }

  async function revealChecks(checks) {
    for (const item of els.checkItems) {
      await sleep(260);
      const result = checks[item.dataset.check];
      if (!result) continue;
      item.classList.add('is-done', `is-${result.state}`);
      item.querySelector('.check-detail').textContent = result.message || '';
    }
  }

  async function boot() {
    showScreen('loading');
    els.loadingRetry.hidden = true;
    els.loadingText.textContent = 'Initialisation…';
    els.checkItems.forEach((item) => {
      item.className = '';
      item.querySelector('.check-detail').textContent = '';
    });
    const minimumDelay = sleep(LOADING_MIN_MS);
    let status = null;
    while (!status) {
      try {
        status = await api('GET', '/api/status', null, { timeout: 25000 });
      } catch (_) {
        els.loadingText.textContent = 'Connexion au serveur…';
        await sleep(2000);
      }
    }
    state.offline = false;
    els.offline.hidden = true;
    applyConfig(status);
    els.loadingText.textContent = 'Vérification du matériel…';
    await revealChecks(status.checks);
    await minimumDelay;

    const blocking = ['database', 'storage'].some((name) => !status.checks[name].ok);
    if (blocking) {
      els.loadingText.textContent = 'Problème détecté : appelez un responsable.';
      els.loadingRetry.hidden = false;
      return;
    }
    const warnings = Object.values(status.checks).some((check) => !check.ok);
    els.loadingText.textContent = warnings ? 'Démarrage malgré une alerte…' : 'Tout est prêt !';
    await sleep(warnings ? 2600 : 700);
    goHome();
  }

  function abandonSession() {
    const session = state.session;
    state.session = null;
    if (session) api('POST', '/api/session/reset', { session_id: session.id }).catch(() => {});
  }

  function goHome() {
    preview.stop();
    if (!state.busy) abandonSession();
    state.frame = null;
    state.photo = null;
    els.idleWarning.hidden = true;
    showScreen('home');
    refreshConfig();
  }

  // ---------------------------------------------------------------------------
  // Choix du cadre
  // ---------------------------------------------------------------------------

  async function openFrames() {
    sound.ensure();
    let frames;
    try {
      frames = (await api('GET', '/api/frames')).frames || [];
    } catch (error) {
      showError(error.message, { retry: openFrames });
      return;
    }
    state.frames = frames;
    if (frames.length === 1) {
      state.frame = frames[0];
      openPreview();
      return;
    }
    renderFrames();
    showScreen('frames');
  }

  function createFrameCard(frame, index) {
    const card = document.createElement('button');
    card.type = 'button';
    card.className = 'frame-card';
    card.dataset.frameId = frame.id;
    card.style.setProperty('--ratio', `${frame.width} / ${frame.height}`);
    card.style.setProperty('--index', String(index));

    const thumb = document.createElement('span');
    thumb.className = 'frame-thumb';
    const image = document.createElement('img');
    image.src = frame.preview_url;
    image.alt = '';
    image.draggable = false;
    image.decoding = 'async';
    thumb.append(image);

    const name = document.createElement('span');
    name.className = 'frame-name';
    name.textContent = frame.name;

    const check = document.createElement('span');
    check.className = 'frame-check';
    check.innerHTML = CHECK_SVG;

    card.append(thumb, name, check);
    if (frame.shots > 1) {
      const badge = document.createElement('span');
      badge.className = 'frame-badge';
      badge.textContent = `${frame.shots} photos`;
      card.append(badge);
    }
    card.addEventListener('click', () => selectFrame(frame.id));
    return card;
  }

  function renderFrames() {
    const selectedId = state.frame && state.frame.id;
    state.frame = state.frames.find((frame) => frame.id === selectedId) || null;
    els.framesGrid.replaceChildren(...state.frames.map(createFrameCard));
    els.framesGrid.scrollTop = 0;
    updateFrameSelection();
  }

  function selectFrame(frameId) {
    state.frame = state.frames.find((frame) => frame.id === frameId) || null;
    updateFrameSelection();
    if (state.frame) sound.beep(880, 0.06, 0.15);
  }

  function updateFrameSelection() {
    const selectedId = state.frame && state.frame.id;
    $$('.frame-card').forEach((card) => card.classList.toggle('is-selected', card.dataset.frameId === selectedId));
    els.framesGrid.classList.toggle('has-selection', Boolean(selectedId));
    els.framesContinue.disabled = !selectedId;
  }

  // ---------------------------------------------------------------------------
  // Aperçu, compte à rebours et prise de vue
  // ---------------------------------------------------------------------------

  function setPreviewControls(enabled) {
    els.btnShoot.disabled = !enabled;
    els.btnPreviewBack.disabled = !enabled;
  }

  function renderShotStrip(count) {
    els.shotStrip.hidden = count < 2;
    els.shotStrip.replaceChildren(
      ...Array.from({ length: count }, (_, index) => {
        const item = document.createElement('span');
        item.className = 'shot-thumb';
        item.textContent = String(index + 1);
        return item;
      }),
    );
  }

  function markShot(index, url = null) {
    Array.from(els.shotStrip.children).forEach((item, position) => {
      item.classList.toggle('is-current', position === index && !url);
      if (position === index && url) {
        item.style.backgroundImage = `url("${url}")`;
        item.classList.add('is-done');
      }
    });
  }

  function openPreview() {
    if (!state.frame) return;
    const shots = state.frame.shots;
    const multi = shots > 1;
    els.previewTitle.textContent = multi ? `${shots} photos à la suite !` : 'Prêts ?';
    els.previewSubtitle.textContent = multi
      ? 'Changez de pose entre chaque photo.'
      : "Placez-vous face à l'écran et souriez !";
    els.btnShootLabel.textContent = multi ? "C'EST PARTI !" : 'PRENDRE LA PHOTO';
    renderShotStrip(multi ? shots : 0);
    els.shotBadge.hidden = true;
    els.countdown.classList.remove('is-visible');
    setPreviewControls(true);
    showScreen('preview');
    preview.start();
  }

  function showCountdown(text, smile) {
    const element = els.countdownValue;
    element.textContent = text;
    element.className = `countdown-value${smile ? ' is-smile' : ''}`;
    void element.offsetWidth;
    element.classList.add('is-animating');
  }

  async function runCountdown(seconds) {
    els.countdown.classList.add('is-visible');
    for (let value = seconds; value >= 1; value -= 1) {
      showCountdown(String(value), false);
      sound.beep(value === 1 ? 880 : 660);
      await sleep(1000);
    }
    showCountdown('SOURIEZ !', true);
    sound.beep(1320, 0.2);
    await sleep(450);
  }

  async function shoot() {
    if (state.busy || !state.frame) return;
    state.busy = true;
    setPreviewControls(false);
    sound.ensure();
    try {
      const started = await api('POST', '/api/session/start', { frame_id: state.frame.id });
      state.session = started.session;
      const total = state.session.shots_total;
      for (let shot = 0; shot < total; shot += 1) {
        const last = shot === total - 1;
        if (total > 1) {
          preview.setShot(shot);
          els.shotBadge.textContent = `Photo ${shot + 1} / ${total}`;
          els.shotBadge.hidden = false;
          markShot(shot);
        }
        await runCountdown(Number(state.ui.countdown_seconds) || 3);
        preview.paused = true;
        triggerFlash();
        sound.shutter();
        setTimeout(() => els.countdown.classList.remove('is-visible'), 250);
        if (last) {
          // L'écran d'attente n'apparaît que si le traitement dure (reflex, gros montage).
          els.processingText.textContent = total > 1 ? 'Assemblage de vos photos…' : 'Développement de votre photo…';
          setTimeout(() => {
            if (state.busy && state.screen === 'preview') showScreen('processing');
          }, 900);
        }
        const result = await api('POST', '/api/capture', { session_id: state.session.id }, { timeout: 120000 });
        if (result.done) {
          state.session = null;
          preview.stop();
          showResult(result.photo);
          return;
        }
        markShot(shot, result.shot_url);
        preview.paused = false;
        els.shotBadge.textContent = 'Changez de pose !';
        await sleep(1500);
      }
    } catch (error) {
      handleCaptureError(error);
    } finally {
      state.busy = false;
      preview.paused = false;
      els.countdown.classList.remove('is-visible');
      idle.reset();
    }
  }

  function handleCaptureError(error) {
    abandonSession();
    if (state.offline) return;
    openPreview();
    showError(error.message || "L'appareil photo n'a pas répondu.", {
      title: 'La photo a échoué',
      retry: shoot,
    });
  }

  // ---------------------------------------------------------------------------
  // Résultat et impression
  // ---------------------------------------------------------------------------

  function setPrintStatus(message, kind = '') {
    els.printStatus.textContent = message;
    els.printStatus.className = `print-status${kind ? ` is-${kind}` : ''}`;
  }

  function updatePrintButton() {
    const photo = state.photo;
    const enabled = Boolean(state.ui.print_enabled);
    els.btnPrint.hidden = !enabled;
    if (!enabled || !photo) return;
    els.btnPrint.disabled = state.printing || photo.prints_remaining === 0;
    els.btnPrint.classList.toggle('is-busy', state.printing);
    if (state.printing) {
      els.btnPrintLabel.textContent = 'IMPRESSION…';
    } else if (photo.prints_remaining === 0) {
      els.btnPrintLabel.textContent = 'IMPRESSIONS ÉPUISÉES';
    } else {
      els.btnPrintLabel.textContent = photo.print_count > 0 ? 'RÉIMPRIMER' : 'IMPRIMER';
    }
  }

  function showResult(photo) {
    state.photo = photo;
    state.copies = 1;
    els.resultPhoto.src = photo.final_url;
    els.resultQr.src = photo.qr_url;
    els.resultCode.textContent = photo.display_code;
    els.resultUrl.textContent = photo.public_url.replace(/^https?:\/\//, '');
    els.resultNotice.textContent = state.ui.notice;
    els.resultPhoto.style.animation = 'none';
    void els.resultPhoto.offsetWidth;
    els.resultPhoto.style.animation = '';
    setPrintStatus('');
    updatePrintButton();
    showScreen('result');
    if (state.ui.print_enabled && state.ui.auto_print) printPhoto(1, true);
  }

  function requestPrint() {
    if (!state.photo || state.printing) return;
    const remaining = state.photo.prints_remaining;
    const max = Math.min(Number(state.ui.print_max_copies) || 1, remaining == null ? Infinity : remaining);
    if (max <= 1) {
      printPhoto(1);
      return;
    }
    state.copies = 1;
    state.copiesMax = max;
    renderCopies();
    openModal(els.modalCopies);
  }

  function renderCopies() {
    els.copiesValue.textContent = String(state.copies);
    els.copiesMinus.disabled = state.copies <= 1;
    els.copiesPlus.disabled = state.copies >= state.copiesMax;
    els.copiesHint.textContent = `Jusqu'à ${state.copiesMax} tirages`;
  }

  async function printPhoto(copies, automatic = false) {
    if (!state.photo || state.printing) return;
    const code = state.photo.code;
    state.printing = true;
    updatePrintButton();
    setPrintStatus(automatic ? 'Impression automatique en cours…' : 'Impression en cours…', 'busy');
    try {
      const data = await api('POST', `/api/print/${encodeURIComponent(code)}`, { copies }, { timeout: 120000 });
      if (state.photo && state.photo.code === code) state.photo = data.photo;
      const message = copies > 1
        ? `${copies} tirages lancés : récupérez-les à l'imprimante !`
        : "C'est parti ! Récupérez votre photo à l'imprimante.";
      setPrintStatus(message, 'success');
      toast('Impression lancée', 'success');
    } catch (error) {
      setPrintStatus(error.message, 'error');
      toast(`Impression impossible : ${error.message}`, 'error', 5000);
    } finally {
      state.printing = false;
      updatePrintButton();
      idle.reset();
    }
  }

  // ---------------------------------------------------------------------------
  // Accès administrateur (PIN) et fermeture du kiosk
  // ---------------------------------------------------------------------------

  const pin = {
    mode: 'menu',
    value: '',

    open(mode) {
      this.mode = mode;
      this.value = '';
      els.pinTitle.textContent = mode === 'quit' ? 'Quitter le kiosk' : 'Code administrateur';
      els.pinError.textContent = '';
      this.render();
      closeAllModals();
      openModal(els.modalPin);
    },

    close() {
      this.value = '';
      closeModal(els.modalPin);
    },

    press(key) {
      if (key === 'ok') {
        this.submit();
        return;
      }
      if (key === 'back') this.value = this.value.slice(0, -1);
      else if (/^\d$/.test(key) && this.value.length < 12) this.value += key;
      els.pinError.textContent = '';
      this.render();
    },

    render() {
      els.pinDots.replaceChildren(...Array.from(this.value, () => document.createElement('span')));
    },

    async submit() {
      if (!this.value) return;
      try {
        await api('POST', '/admin/login', { pin: this.value });
      } catch (error) {
        this.value = '';
        this.render();
        els.pinError.textContent = error.message;
        els.pinDots.classList.remove('is-shaking');
        void els.pinDots.offsetWidth;
        els.pinDots.classList.add('is-shaking');
        return;
      }
      const mode = this.mode;
      this.close();
      if (mode === 'admin') window.location.href = '/admin';
      else if (mode === 'quit') quitKiosk();
      else openModal(els.modalMenu);
    },
  };

  async function quitKiosk() {
    try {
      await api('POST', '/api/kiosk/quit', {});
    } catch (error) {
      toast(error.message, 'error');
      return;
    }
    state.quitting = true;
    preview.stop();
    els.goodbye.hidden = false;
  }

  let secretTaps = [];
  function onSecretTap(event) {
    event.preventDefault();
    event.stopPropagation();
    const now = Date.now();
    secretTaps = secretTaps.filter((time) => now - time < SECRET_WINDOW_MS);
    secretTaps.push(now);
    if (secretTaps.length >= SECRET_TAPS) {
      secretTaps = [];
      pin.open('menu');
    }
  }

  function onKeyDown(event) {
    const key = (event.key || '').toLowerCase();
    if (event.ctrlKey && event.altKey && (key === 'q' || key === 'a')) {
      event.preventDefault();
      pin.open(key === 'q' ? 'quit' : 'admin');
      return;
    }
    if (!els.modalPin.hidden) {
      if (/^\d$/.test(event.key)) pin.press(event.key);
      else if (event.key === 'Backspace') pin.press('back');
      else if (event.key === 'Enter') pin.press('ok');
      else if (event.key === 'Escape') pin.close();
      event.preventDefault();
      return;
    }
    // Un gros bouton USB (clavier Entrée/Espace) peut servir de déclencheur.
    if ((event.key === 'Enter' || event.key === ' ') && !anyModalOpen()) {
      event.preventDefault();
      if (state.screen === 'home') openFrames();
      else if (state.screen === 'frames' && state.frame) openPreview();
      else if (state.screen === 'preview') shoot();
    }
  }

  // ---------------------------------------------------------------------------
  // Surveillance de la connexion au serveur local
  // ---------------------------------------------------------------------------

  let probing = false;
  async function probeConnection() {
    if (probing || state.quitting) return;
    probing = true;
    try {
      const response = await fetch('/api/health', { cache: 'no-store' });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      if (state.offline) window.location.reload();
    } catch (_) {
      if (!state.offline) {
        state.offline = true;
        preview.stop();
        closeAllModals();
        els.offline.hidden = false;
      }
    } finally {
      probing = false;
    }
  }

  async function watchConnection() {
    for (;;) {
      await sleep(state.offline ? 2000 : HEALTH_INTERVAL_MS);
      if (!state.busy && !state.quitting) await probeConnection();
    }
  }

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  function preventBrowserGestures() {
    document.addEventListener('contextmenu', (event) => event.preventDefault());
    document.addEventListener('dragstart', (event) => event.preventDefault());
    document.addEventListener('gesturestart', (event) => event.preventDefault());
    document.addEventListener('touchmove', (event) => {
      if (event.touches.length > 1) event.preventDefault();
    }, { passive: false });
    document.addEventListener('wheel', (event) => {
      if (event.ctrlKey) event.preventDefault();
    }, { passive: false });
    document.addEventListener('pointerup', () => {
      if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
    });

    let cursorTimer = null;
    const hideCursorLater = () => {
      document.body.classList.remove('cursor-hidden');
      clearTimeout(cursorTimer);
      cursorTimer = setTimeout(() => document.body.classList.add('cursor-hidden'), 3000);
    };
    document.addEventListener('mousemove', hideCursorLater);
    hideCursorLater();
  }

  function bindEvents() {
    els.homeStart.addEventListener('click', openFrames);
    els.framesBack.addEventListener('click', goHome);
    els.framesContinue.addEventListener('click', openPreview);
    els.btnShoot.addEventListener('click', shoot);
    els.btnPreviewBack.addEventListener('click', () => {
      if (state.busy) return;
      preview.stop();
      if (state.frames.length > 1) {
        renderFrames();
        showScreen('frames');
      } else {
        goHome();
      }
    });
    els.btnPrint.addEventListener('click', requestPrint);
    els.btnAgain.addEventListener('click', () => {
      state.photo = null;
      openPreview();
    });
    els.btnFinish.addEventListener('click', goHome);
    els.loadingRetry.addEventListener('click', boot);

    els.errorRetry.addEventListener('click', () => {
      const action = errorRetryAction;
      errorRetryAction = null;
      closeModal(els.modalError);
      if (action) action();
    });
    els.errorHome.addEventListener('click', () => {
      closeModal(els.modalError);
      goHome();
    });

    els.copiesMinus.addEventListener('click', () => {
      state.copies = Math.max(1, state.copies - 1);
      renderCopies();
    });
    els.copiesPlus.addEventListener('click', () => {
      state.copies = Math.min(state.copiesMax, state.copies + 1);
      renderCopies();
    });
    els.copiesCancel.addEventListener('click', () => closeModal(els.modalCopies));
    els.copiesConfirm.addEventListener('click', () => {
      closeModal(els.modalCopies);
      printPhoto(state.copies);
    });

    els.keypad.addEventListener('click', (event) => {
      const button = event.target.closest('button[data-key]');
      if (button) pin.press(button.dataset.key);
    });
    els.pinCancel.addEventListener('click', () => pin.close());
    els.menuAdmin.addEventListener('click', () => {
      window.location.href = '/admin';
    });
    els.menuQuit.addEventListener('click', () => {
      closeModal(els.modalMenu);
      quitKiosk();
    });
    els.menuClose.addEventListener('click', () => {
      closeModal(els.modalMenu);
      api('POST', '/admin/logout', {}).catch(() => {});
    });

    els.secretCorner.addEventListener('pointerdown', onSecretTap);
    document.addEventListener('keydown', onKeyDown);
    document.addEventListener('pointerdown', () => idle.reset(), { passive: true });
    window.addEventListener('resize', () => preview.resize());
    setInterval(() => idle.tick(), 250);
  }

  preventBrowserGestures();
  bindEvents();
  boot();
  watchConnection();
})();
