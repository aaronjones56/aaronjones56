/* Photobooth : panneau d'administration (connexion par PIN, tableau de bord, événements, photos, upload…). */
(() => {
  'use strict';

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  const ICONS = {
    camera: '<path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"/><circle cx="12" cy="13" r="4"/>',
    printer: '<path d="M6 9V2h12v7"/><path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"/><rect x="6" y="14" width="12" height="8"/>',
    storage: '<ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/>',
    internet: '<circle cx="12" cy="12" r="10"/><path d="M2 12h20M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/>',
  };
  const STATE_LABELS = { ok: 'OK', warning: 'ATTENTION', error: 'ERREUR', disabled: 'DÉSACTIVÉE' };

  // ---------------------------------------------------------------------------
  // Outils
  // ---------------------------------------------------------------------------

  class ApiError extends Error {
    constructor(message, status) {
      super(message);
      this.status = status;
    }
  }

  async function api(method, url, body = null, { timeout = 60000 } = {}) {
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
        throw new ApiError(error.name === 'AbortError' ? 'Le serveur ne répond pas.' : 'Serveur injoignable.', 0);
      }
      let data = null;
      try {
        data = await response.json();
      } catch (_) {
        data = null;
      }
      if (response.status === 401 && !url.startsWith('/admin/login')) {
        window.location.reload();
      }
      if (!response.ok || (data && data.ok === false)) {
        throw new ApiError((data && data.error) || `Erreur ${response.status}`, response.status);
      }
      return data || {};
    } finally {
      clearTimeout(timer);
    }
  }

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>"']/g, (char) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    })[char]);
  }

  function formatDate(iso) {
    if (!iso) return '—';
    const date = new Date(iso);
    if (Number.isNaN(date.getTime())) return iso;
    return date.toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' });
  }

  function formatNumber(value) {
    return Number(value || 0).toLocaleString('fr-FR');
  }

  function toast(message, kind = 'info', duration = 4500) {
    const item = document.createElement('div');
    item.className = `toast is-${kind}`;
    item.textContent = message;
    $('#toasts').append(item);
    setTimeout(() => item.remove(), duration);
  }

  function slugify(text) {
    return String(text || '')
      .replace(/['`’]/g, '')
      .normalize('NFKD')
      .replace(/[̀-ͯ]/g, '')
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 60)
      .replace(/-+$/g, '');
  }

  async function withBusy(button, action) {
    button.classList.add('is-busy');
    button.disabled = true;
    try {
      return await action();
    } finally {
      button.classList.remove('is-busy');
      button.disabled = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Connexion
  // ---------------------------------------------------------------------------

  function initLogin() {
    const form = $('#login-form');
    const input = $('#login-pin');
    const error = $('#login-error');
    $('#login-keypad').addEventListener('click', (event) => {
      const button = event.target.closest('button[data-key]');
      if (!button) return;
      const key = button.dataset.key;
      input.value = key === 'back' ? input.value.slice(0, -1) : (input.value + key).slice(0, 12);
      error.textContent = '';
    });
    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      if (!input.value) return;
      try {
        await api('POST', '/admin/login', { pin: input.value });
        window.location.reload();
      } catch (err) {
        error.textContent = err.message;
        input.value = '';
        input.focus();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Fenêtres
  // ---------------------------------------------------------------------------

  function openModal(id) {
    $(id).hidden = false;
  }

  function closeModal(id) {
    $(id).hidden = true;
  }

  function confirmDialog(message, { title = 'Confirmer', confirmLabel = 'Confirmer', danger = false } = {}) {
    return new Promise((resolve) => {
      $('#confirm-title').textContent = title;
      $('#confirm-message').textContent = message;
      const ok = $('#confirm-ok');
      ok.textContent = confirmLabel;
      ok.className = `btn ${danger ? 'btn-danger' : 'btn-primary'}`;
      const finish = (result) => {
        closeModal('#confirm-modal');
        ok.removeEventListener('click', onOk);
        $('#confirm-cancel').removeEventListener('click', onCancel);
        resolve(result);
      };
      const onOk = () => finish(true);
      const onCancel = () => finish(false);
      ok.addEventListener('click', onOk);
      $('#confirm-cancel').addEventListener('click', onCancel);
      openModal('#confirm-modal');
    });
  }

  function showOverlay(title, text, spinner = true) {
    $('#overlay-title').textContent = title;
    $('#overlay-text').textContent = text;
    $('#overlay-spinner').hidden = !spinner;
    $('#overlay').hidden = false;
  }

  // ---------------------------------------------------------------------------
  // Onglets
  // ---------------------------------------------------------------------------

  let currentTab = 'dashboard';
  const loaders = {};

  function showTab(name) {
    if (!loaders[name]) name = 'dashboard';
    currentTab = name;
    $$('.nav-item[data-tab]').forEach((item) => item.classList.toggle('is-active', item.dataset.tab === name));
    $$('.panel').forEach((panel) => panel.classList.toggle('is-active', panel.dataset.panel === name));
    if (window.location.hash !== `#${name}`) history.replaceState(null, '', `#${name}`);
    window.scrollTo({ top: 0 });
    loaders[name]().catch((error) => toast(error.message, 'error'));
  }

  // ---------------------------------------------------------------------------
  // Tableau de bord
  // ---------------------------------------------------------------------------

  function statusCard(title, icon, state, value, detail) {
    return `
      <div class="status-card is-${state}">
        <span class="status-icon"><svg viewBox="0 0 24 24">${ICONS[icon]}</svg></span>
        <div>
          <p class="status-title">${escapeHtml(title)}</p>
          <p class="status-value">${escapeHtml(value)}</p>
          <p class="status-detail">${escapeHtml(detail)}</p>
        </div>
      </div>`;
  }

  function kpi(label, value, sub = '', highlight = false) {
    return `
      <div class="kpi${highlight ? ' is-highlight' : ''}">
        <p class="kpi-label">${escapeHtml(label)}</p>
        <p class="kpi-value">${escapeHtml(value)}</p>
        <p class="kpi-sub">${escapeHtml(sub)}</p>
      </div>`;
  }

  function internetCard(connectivity) {
    if (connectivity.internet === null || connectivity.internet === undefined) {
      return statusCard('Internet', 'internet', 'neutral', 'VÉRIFICATION…', 'Test de la connexion en cours');
    }
    let detail = 'Aucune connexion : normal pendant un événement';
    if (connectivity.internet) {
      detail = 'Connexion disponible';
      if (connectivity.server_configured) {
        detail += connectivity.server ? ' · serveur photos joignable' : ' · serveur photos injoignable';
      }
    }
    return statusCard('Internet', 'internet', connectivity.internet ? 'ok' : 'neutral',
      connectivity.internet ? 'EN LIGNE' : 'HORS LIGNE', detail);
  }

  async function loadDashboard() {
    const data = await api('GET', '/api/admin/stats');
    const { devices, stats, disk, event, connectivity } = data;
    $('#dash-event').textContent = `Événement actif : ${event.name} · ${event.display_date} · dossier ${event.folder}`;
    $('#status-grid').innerHTML = [
      statusCard('Caméra', 'camera', devices.camera.state, STATE_LABELS[devices.camera.state] || '?', devices.camera.message),
      statusCard('Imprimante', 'printer', devices.printer.state, STATE_LABELS[devices.printer.state] || '?', devices.printer.message),
      statusCard('Stockage', 'storage', devices.storage.state, STATE_LABELS[devices.storage.state] || '?', devices.storage.message),
      internetCard(connectivity),
    ].join('');
    const otherPending = data.pending_total - stats.pending;
    $('#kpi-grid').innerHTML = [
      kpi('Sessions', formatNumber(stats.sessions), `${formatNumber(stats.sessions_completed)} terminée(s)`),
      kpi('Photos', formatNumber(stats.photos), `${formatNumber(stats.shots)} prise(s) de vue`, true),
      kpi('Imprimées', formatNumber(stats.printed), `${formatNumber(stats.prints)} tirage(s) au total`),
      kpi('Uploadées', formatNumber(stats.uploaded), stats.photos ? `${Math.round((stats.uploaded * 100) / stats.photos)} % de l'événement` : ''),
      kpi('À uploader', formatNumber(stats.pending), otherPending > 0 ? `+ ${formatNumber(otherPending)} dans d'autres événements` : 'Événement actif'),
      kpi('Espace disque libre', disk.free_human, `Événement : ${stats.disk_human} · disque utilisé à ${formatNumber(disk.percent_used)} %`),
    ].join('');
  }
  loaders.dashboard = loadDashboard;

  async function testCamera(button) {
    await withBusy(button, async () => {
      try {
        const data = await api('POST', '/api/admin/test-camera', {}, { timeout: 120000 });
        $('#image-modal-title').textContent = data.message;
        $('#image-modal-img').src = data.url;
        openModal('#image-modal');
      } catch (error) {
        toast(`Caméra : ${error.message}`, 'error', 7000);
      }
    });
  }

  async function testPrinter(button) {
    await withBusy(button, async () => {
      try {
        const data = await api('POST', '/api/admin/test-printer', {}, { timeout: 120000 });
        toast(data.message, 'success');
      } catch (error) {
        toast(`Imprimante : ${error.message}`, 'error', 7000);
      }
    });
  }

  async function waitForRestart() {
    await sleep(2500);
    const deadline = Date.now() + 60000;
    while (Date.now() < deadline) {
      try {
        const response = await fetch('/api/health', { cache: 'no-store' });
        if (response.ok) {
          window.location.reload();
          return;
        }
      } catch (_) {
        // Serveur pas encore relancé.
      }
      await sleep(1000);
    }
    showOverlay('Le photobooth ne répond pas', 'Relancez-le avec scripts\\start_kiosk.bat ou python app.py.', false);
  }

  async function restartApp() {
    const ok = await confirmDialog("L'application va redémarrer. Les photos déjà prises sont conservées.", {
      title: "Redémarrer l'application",
      confirmLabel: 'Redémarrer',
    });
    if (!ok) return;
    try {
      await api('POST', '/api/admin/restart', {});
    } catch (error) {
      toast(error.message, 'error');
      return;
    }
    showOverlay('Redémarrage…', 'Le photobooth redémarre, la page se rechargera automatiquement.');
    waitForRestart();
  }

  async function quitKiosk() {
    const ok = await confirmDialog('Le navigateur kiosk et le serveur vont être arrêtés : vous retrouverez le bureau Windows.', {
      title: 'Quitter le kiosk',
      confirmLabel: 'Quitter',
      danger: true,
    });
    if (!ok) return;
    try {
      await api('POST', '/api/admin/quit', {});
    } catch (error) {
      toast(error.message, 'error');
      return;
    }
    showOverlay('Photobooth fermé', 'Vous pouvez fermer cette fenêtre.', false);
  }

  // ---------------------------------------------------------------------------
  // Événements
  // ---------------------------------------------------------------------------

  let slugEdited = false;

  async function loadEvents() {
    const data = await api('GET', '/api/admin/events');
    $('#events-body').innerHTML = data.events.map((event) => `
      <tr>
        <td><div class="cell-title">${escapeHtml(event.name)}</div><div class="cell-sub">${escapeHtml(event.slug)}</div></td>
        <td>${escapeHtml(event.display_date)}</td>
        <td class="num">${formatNumber(event.stats.photos)}</td>
        <td class="num">${formatNumber(event.stats.printed)}</td>
        <td class="num">${event.stats.pending ? `<span class="badge badge-warning">${formatNumber(event.stats.pending)}</span>` : '0'}</td>
        <td class="num">${escapeHtml(event.stats.disk_human)}</td>
        <td>${event.active
          ? '<span class="badge badge-accent">Actif</span>'
          : `<button class="btn btn-light" type="button" data-activate="${event.id}">Activer</button>`}</td>
      </tr>`).join('');
    const dateInput = $('#event-form [name="event_date"]');
    if (!dateInput.value) dateInput.value = new Date().toISOString().slice(0, 10);
  }
  loaders.events = loadEvents;

  async function createEvent(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const payload = {
      name: form.name.value.trim(),
      event_date: form.event_date.value,
      slug: form.slug.value.trim(),
      activate: form.activate.checked,
    };
    try {
      const data = await api('POST', '/api/admin/events', payload);
      toast(`Événement « ${data.event.name} » créé`, 'success');
      form.reset();
      slugEdited = false;
      await loadEvents();
    } catch (error) {
      toast(error.message, 'error');
    }
  }

  async function activateEvent(eventId) {
    try {
      const data = await api('POST', `/api/admin/events/${eventId}/activate`, {});
      toast(`Événement actif : ${data.event.name}`, 'success');
      await loadEvents();
    } catch (error) {
      toast(error.message, 'error');
    }
  }

  // ---------------------------------------------------------------------------
  // Photos
  // ---------------------------------------------------------------------------

  const gallery = { eventId: null, page: 1, pages: 1, photos: [] };

  function photoBadges(photo) {
    const badges = [];
    if (photo.print_count) badges.push(`<span class="badge badge-accent">Imprimée × ${photo.print_count}</span>`);
    badges.push(photo.uploaded
      ? '<span class="badge badge-success">En ligne</span>'
      : `<span class="badge ${photo.last_upload_error ? 'badge-danger' : 'badge-warning'}">${photo.last_upload_error ? 'Échec upload' : 'À envoyer'}</span>`);
    if (photo.shot_count > 1) badges.push(`<span class="badge">${photo.shot_count} photos</span>`);
    return badges.join('');
  }

  async function loadPhotos() {
    const events = (await api('GET', '/api/admin/events')).events;
    const select = $('#photos-event');
    if (gallery.eventId === null) gallery.eventId = (events.find((event) => event.active) || events[0] || {}).id;
    select.innerHTML = events.map((event) => `<option value="${event.id}">${escapeHtml(event.name)} (${escapeHtml(event.display_date)})</option>`).join('');
    select.value = String(gallery.eventId);

    const data = await api('GET', `/api/admin/photos?event_id=${gallery.eventId}&page=${gallery.page}&per_page=24`);
    gallery.page = data.page;
    gallery.pages = data.pages;
    gallery.photos = data.photos;
    $('#photos-count').textContent = `${formatNumber(data.total)} photo(s) dans cet événement`;
    $('#photos-page').textContent = `Page ${data.page} / ${data.pages}`;
    $('#photos-prev').disabled = data.page <= 1;
    $('#photos-next').disabled = data.page >= data.pages;
    const grid = $('#photo-grid');
    if (!data.photos.length) {
      grid.innerHTML = '<div class="empty">Aucune photo pour le moment.</div>';
      return;
    }
    grid.innerHTML = data.photos.map((photo, index) => `
      <button class="photo-card" type="button" data-index="${index}">
        <img src="${escapeHtml(photo.thumb_url)}" alt="" loading="lazy">
        <span class="photo-code">${escapeHtml(photo.display_code)}</span>
        <span class="cell-sub">${escapeHtml(formatDate(photo.created_at))} · ${escapeHtml(photo.frame_name)}</span>
        <span class="photo-meta">${photoBadges(photo)}</span>
      </button>`).join('');
  }
  loaders.photos = loadPhotos;

  let detailPhoto = null;

  function openPhoto(photo) {
    detailPhoto = photo;
    $('#photo-detail-image').src = photo.final_url;
    $('#photo-detail-qr').src = photo.qr_url;
    $('#photo-detail-code').textContent = photo.display_code;
    $('#photo-download').href = `/admin/photos/${encodeURIComponent(photo.code)}/download`;
    $('#photo-original').href = `/admin/photos/${encodeURIComponent(photo.code)}/original`;
    const rows = [
      ['Prise le', formatDate(photo.created_at)],
      ['Cadre', photo.frame_name],
      ['Impressions', photo.print_count ? `${photo.print_count} tirage(s)` : 'Aucune'],
      ['En ligne', photo.uploaded ? `Oui (${formatDate(photo.uploaded_at)})` : 'Non'],
      ['Lien public', photo.public_url],
    ];
    if (photo.last_upload_error) rows.push(['Dernière erreur', photo.last_upload_error]);
    $('#photo-detail-list').innerHTML = rows
      .map(([label, value]) => `<dt>${escapeHtml(label)}</dt><dd>${escapeHtml(value)}</dd>`)
      .join('');
    openModal('#photo-modal');
  }

  async function printDetailPhoto(button) {
    if (!detailPhoto) return;
    await withBusy(button, async () => {
      try {
        const data = await api('POST', `/api/admin/photos/${encodeURIComponent(detailPhoto.code)}/print`, { copies: 1 }, { timeout: 120000 });
        toast('Impression envoyée', 'success');
        openPhoto(data.photo);
        loadPhotos();
      } catch (error) {
        toast(error.message, 'error', 7000);
      }
    });
  }

  async function deleteDetailPhoto() {
    if (!detailPhoto) return;
    const ok = await confirmDialog(`La photo ${detailPhoto.display_code} et ses fichiers seront supprimés définitivement de la borne.`, {
      title: 'Supprimer la photo',
      confirmLabel: 'Supprimer',
      danger: true,
    });
    if (!ok) return;
    try {
      await api('DELETE', `/api/admin/photos/${encodeURIComponent(detailPhoto.code)}`, {});
      toast('Photo supprimée', 'success');
      closeModal('#photo-modal');
      loadPhotos();
    } catch (error) {
      toast(error.message, 'error');
    }
  }

  // ---------------------------------------------------------------------------
  // Upload
  // ---------------------------------------------------------------------------

  let uploadPolling = false;

  function renderProgress(progress) {
    $('#upload-bar').style.width = `${progress.percent}%`;
    let text = progress.message || 'Aucun upload en cours.';
    if (progress.running) {
      text = `${progress.done} / ${progress.total} · ${progress.succeeded} envoyée(s), ${progress.failed} en échec`;
      if (progress.current) text += ` · en cours : ${progress.current}`;
    }
    $('#upload-text').textContent = text;
    $('#upload-errors').innerHTML = (progress.errors || [])
      .map((item) => `<li><strong>${escapeHtml(item.code)}</strong> : ${escapeHtml(item.error)}</li>`)
      .join('');
    $('#upload-start').disabled = Boolean(progress.running);
    $('#upload-start').classList.toggle('is-busy', Boolean(progress.running));
  }

  async function loadUpload() {
    const data = await api('GET', '/api/admin/upload/status');
    const server = data.connectivity.server_configured
      ? (data.connectivity.server === null ? 'vérification…' : (data.connectivity.server ? 'joignable' : 'injoignable'))
      : 'non vérifié (upload désactivé)';
    const rows = [
      ['Upload', data.enabled ? 'activé' : 'désactivé (UPLOAD_ENABLED=false)'],
      ['Adresse du serveur', data.url || 'non configurée'],
      ['Token', data.token_configured ? 'configuré' : 'absent (UPLOAD_API_TOKEN)'],
      ['Serveur photos', server],
    ];
    $('#upload-config').innerHTML = rows.map(([label, value]) => `<dt>${escapeHtml(label)}</dt><dd>${escapeHtml(value)}</dd>`).join('');
    $('#upload-problem').hidden = !data.problem;
    $('#upload-problem').textContent = data.problem || '';
    $('#pending-active').textContent = formatNumber(data.pending_active);
    $('#pending-all').textContent = formatNumber(data.pending_all);
    renderProgress(data.progress);
    if (data.progress.running) pollUpload();
  }
  loaders.upload = loadUpload;

  async function pollUpload() {
    if (uploadPolling) return;
    uploadPolling = true;
    try {
      for (;;) {
        await sleep(700);
        const data = await api('GET', '/api/admin/upload/status');
        renderProgress(data.progress);
        $('#pending-active').textContent = formatNumber(data.pending_active);
        $('#pending-all').textContent = formatNumber(data.pending_all);
        if (!data.progress.running) {
          toast(data.progress.message, data.progress.failed ? 'error' : 'success', 7000);
          break;
        }
      }
    } catch (error) {
      toast(error.message, 'error');
    } finally {
      uploadPolling = false;
    }
  }

  async function startUpload() {
    const scope = ($('input[name="upload-scope"]:checked') || {}).value || 'active';
    try {
      const data = await api('POST', '/api/admin/upload', { scope });
      renderProgress(data.progress);
      pollUpload();
    } catch (error) {
      toast(error.message, 'error', 7000);
    }
  }

  // ---------------------------------------------------------------------------
  // Imprimante
  // ---------------------------------------------------------------------------

  async function loadPrinters() {
    const data = await api('GET', '/api/admin/printers');
    const status = data.status;
    $('#printer-mode').textContent = `${data.label} (PRINTER_MODE=${data.mode}) · mise à l'échelle : ${data.fit_mode === 'fit' ? 'image entière' : 'bord à bord'}`;
    $('#printer-status').innerHTML = `<span class="dot dot-${escapeHtml(status.state)}"></span>${escapeHtml(status.message)}`;
    const notice = $('#printer-notice');
    notice.hidden = data.mode !== 'null';
    notice.textContent = "Mode simulation : rien n'est réellement imprimé. Mettez PRINTER_MODE=windows dans le fichier .env puis redémarrez pour utiliser une vraie imprimante.";

    const choices = [];
    if (data.mode === 'windows') {
      choices.push({ name: '', label: 'Imprimante par défaut de Windows' });
    }
    data.printers.forEach((printer) => choices.push({ name: printer.name, label: printer.name + (printer.is_default ? ' (par défaut)' : '') }));
    if (!data.printers.length && data.mode === 'windows') {
      $('#printer-list').innerHTML = '<div class="empty">Aucune imprimante détectée : vérifiez son installation dans Windows.</div>';
      return;
    }
    $('#printer-list').innerHTML = choices.map((choice) => `
      <label class="choice">
        <input type="radio" name="printer" value="${escapeHtml(choice.name)}" ${choice.name === data.selected ? 'checked' : ''}>
        <span>${escapeHtml(choice.label)}</span>
      </label>`).join('');
  }
  loaders.printer = loadPrinters;

  async function savePrinter(button) {
    const selected = $('input[name="printer"]:checked');
    if (!selected) {
      toast('Choisissez une imprimante.', 'error');
      return;
    }
    await withBusy(button, async () => {
      try {
        await api('POST', '/api/admin/printer', { name: selected.value });
        toast('Imprimante enregistrée', 'success');
        await loadPrinters();
      } catch (error) {
        toast(error.message, 'error');
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Cadres
  // ---------------------------------------------------------------------------

  async function loadFrames() {
    const data = await api('GET', '/api/admin/frames');
    $('#frames-dir').textContent = `${data.frames.length} cadre(s) actif(s) · dossier : ${data.frames_dir}`;
    $('#frames-errors').innerHTML = data.errors.map((error) => `<li>${escapeHtml(error)}</li>`).join('');
    $('#frame-admin-grid').innerHTML = data.frames.map((frame) => `
      <div class="frame-admin" style="--ratio: ${frame.width} / ${frame.height}">
        <img src="${escapeHtml(frame.preview_url)}" alt="" loading="lazy">
        <h3>${escapeHtml(frame.name)}</h3>
        <div class="photo-meta">
          <span class="badge">${escapeHtml(frame.folder || frame.id)}</span>
          <span class="badge">${frame.width} × ${frame.height}</span>
          ${frame.shots > 1 ? `<span class="badge badge-accent">${frame.shots} photos</span>` : ''}
          <span class="badge ${frame.has_overlay ? 'badge-success' : ''}">${frame.has_overlay ? 'frame.png' : 'sans calque'}</span>
          <span class="badge">${frame.has_preview ? 'preview.jpg' : 'vignette auto'}</span>
        </div>
      </div>`).join('');
  }
  loaders.frames = loadFrames;

  // ---------------------------------------------------------------------------
  // Réglages
  // ---------------------------------------------------------------------------

  function settingRow(setting) {
    const hint = `Valeur du .env : ${setting.type === 'bool' ? (setting.default ? 'oui' : 'non') : setting.default}${setting.overridden ? ' · modifié ici' : ''}`;
    const control = setting.type === 'bool'
      ? `<label class="switch"><input type="checkbox" name="${setting.name}" ${setting.value ? 'checked' : ''}><span></span></label>`
      : `<input type="number" name="${setting.name}" value="${setting.value}" min="${setting.min}" max="${setting.max}" step="1">`;
    return `
      <div class="setting">
        <div>
          <div class="setting-label">${escapeHtml(setting.label)}</div>
          <div class="setting-hint">${escapeHtml(hint)}</div>
        </div>
        ${control}
      </div>`;
  }

  async function loadSettings() {
    const data = await api('GET', '/api/admin/settings');
    $('#settings-form').innerHTML = data.settings.map(settingRow).join('');
    $('#config-list').innerHTML = Object.entries(data.config)
      .map(([label, value]) => `<dt>${escapeHtml(label)}</dt><dd>${escapeHtml(value)}</dd>`)
      .join('');
  }
  loaders.settings = loadSettings;

  async function saveSettings(button) {
    const values = {};
    $$('#settings-form input').forEach((input) => {
      values[input.name] = input.type === 'checkbox' ? input.checked : Number(input.value);
    });
    await withBusy(button, async () => {
      try {
        await api('POST', '/api/admin/settings', { values });
        toast('Réglages enregistrés', 'success');
        await loadSettings();
      } catch (error) {
        toast(error.message, 'error');
      }
    });
  }

  async function resetSettings() {
    const ok = await confirmDialog('Les réglages modifiés ici seront remplacés par les valeurs du fichier .env.', {
      title: 'Revenir aux valeurs du .env',
      confirmLabel: 'Réinitialiser',
    });
    if (!ok) return;
    try {
      await api('POST', '/api/admin/settings', { reset: true });
      toast('Réglages réinitialisés', 'success');
      await loadSettings();
    } catch (error) {
      toast(error.message, 'error');
    }
  }

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  async function logout(destination) {
    try {
      await api('POST', '/admin/logout', {});
    } finally {
      window.location.href = destination;
    }
  }

  function initDashboard() {
    $$('.nav-item[data-tab]').forEach((item) => item.addEventListener('click', () => showTab(item.dataset.tab)));
    $$('[data-goto]').forEach((item) => item.addEventListener('click', () => showTab(item.dataset.goto)));
    $$('[data-close]').forEach((item) => item.addEventListener('click', () => {
      item.closest('.modal').hidden = true;
    }));
    $$('.modal').forEach((modal) => modal.addEventListener('click', (event) => {
      if (event.target === modal && modal.id !== 'confirm-modal') modal.hidden = true;
    }));
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') $$('.modal').forEach((modal) => { modal.hidden = true; });
    });

    $('#btn-back-kiosk').addEventListener('click', () => logout('/'));
    $('#btn-logout').addEventListener('click', () => logout('/admin'));
    $('#dash-refresh').addEventListener('click', () => loadDashboard().catch((error) => toast(error.message, 'error')));
    $('#act-test-camera').addEventListener('click', (event) => testCamera(event.currentTarget));
    $('#act-test-printer').addEventListener('click', (event) => testPrinter(event.currentTarget));
    $('#act-upload').addEventListener('click', async () => {
      showTab('upload');
      await startUpload();
    });
    $('#act-restart').addEventListener('click', restartApp);
    $('#act-quit').addEventListener('click', quitKiosk);

    const form = $('#event-form');
    form.addEventListener('submit', createEvent);
    form.name.addEventListener('input', () => {
      if (!slugEdited) form.slug.value = slugify(form.name.value);
    });
    form.slug.addEventListener('input', () => {
      slugEdited = form.slug.value.length > 0;
    });
    $('#events-body').addEventListener('click', (event) => {
      const button = event.target.closest('[data-activate]');
      if (button) activateEvent(button.dataset.activate);
    });

    $('#photos-event').addEventListener('change', (event) => {
      gallery.eventId = Number(event.target.value);
      gallery.page = 1;
      loadPhotos().catch((error) => toast(error.message, 'error'));
    });
    $('#photos-prev').addEventListener('click', () => {
      gallery.page = Math.max(1, gallery.page - 1);
      loadPhotos().catch((error) => toast(error.message, 'error'));
    });
    $('#photos-next').addEventListener('click', () => {
      gallery.page = Math.min(gallery.pages, gallery.page + 1);
      loadPhotos().catch((error) => toast(error.message, 'error'));
    });
    $('#photo-grid').addEventListener('click', (event) => {
      const card = event.target.closest('.photo-card');
      if (card) openPhoto(gallery.photos[Number(card.dataset.index)]);
    });
    $('#photo-print').addEventListener('click', (event) => printDetailPhoto(event.currentTarget));
    $('#photo-delete').addEventListener('click', deleteDetailPhoto);

    $('#upload-start').addEventListener('click', startUpload);
    $('#printer-refresh').addEventListener('click', () => loadPrinters().catch((error) => toast(error.message, 'error')));
    $('#printer-save').addEventListener('click', (event) => savePrinter(event.currentTarget));
    $('#printer-test').addEventListener('click', (event) => testPrinter(event.currentTarget));
    $('#frames-reload').addEventListener('click', () => loadFrames()
      .then(() => toast('Cadres rechargés', 'success'))
      .catch((error) => toast(error.message, 'error')));
    $('#settings-save').addEventListener('click', (event) => saveSettings(event.currentTarget));
    $('#settings-reset').addEventListener('click', resetSettings);

    setInterval(() => {
      if (currentTab === 'dashboard' && !document.hidden && $('#overlay').hidden) {
        loadDashboard().catch(() => {});
      }
    }, 10000);
    showTab(window.location.hash.slice(1) || 'dashboard');
  }

  if ($('#login-form')) initLogin();
  else initDashboard();
})();
