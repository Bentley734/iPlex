(() => {
  'use strict';
  const get = id => document.getElementById(id);
  const host = body => window.chrome.webview.postMessage(body);
  const browser = get('video-browser');
  const tiles = get('video-items');
  const picker = get('video-library');
  const search = get('video-search');
  const status = get('video-status');
  const loadMore = get('video-more');
  const retry = get('video-retry');
  const dialog = get('video-dialog');
  const video = get('video-player');
  const mode = get('video-mode');
  const error = get('video-error');
  const alternate = get('video-compatibility');
  const tabs = new Map([['movie', get('movies')], ['show', get('television')]]);
  const titles = {movie:'Movies', show:'TV'};
  const validSource = /^https:\/\/media\.musicroom\.invalid\/video\/[a-f0-9]{32}$/;
  let state, kind = '', library = '', pending = 0, parent = [], next = null, busy = false, timer;
  let source, hls, candidates = [], usingFallback = false, resumeAt = 0, listOffset = 0, failed = false;
  const rendered = new Set();

  function preference() { return 'musicroom-video-library.' + state.serverId + '.' + kind; }

  function syncTabs() {
    for (const [type, tab] of tabs) {
      tab.disabled = !state?.serverId;
      tab.setAttribute('aria-pressed', String(type === kind));
    }
  }

  function configure() {
    const available = (state.videoLibraries || []).filter(row => row.type === kind);
    const preferred = localStorage.getItem(preference());
    const restored = available.find(row => row.id === preferred)?.id || available[0]?.id || '';
    if (library !== restored) parent = [];
    library = restored;
    picker.replaceChildren(...available.map(row => new Option(row.name, row.id)));
    picker.value = library;
    picker.hidden = available.length === 0;
    browse();
  }

  window.plexVideoState = value => {
    const previous = state;
    state = value;
    if (kind && !state.serverId) window.plexVideoExit();
    syncTabs();
    if (!kind) return;
    if (previous?.serverId !== state.serverId || previous?.loadingLibraries !== state.loadingLibraries ||
        JSON.stringify(previous?.videoLibraries) !== JSON.stringify(state.videoLibraries)) {
      if (previous?.serverId !== state.serverId) {
        if (dialog.open) dialog.close();
        parent = [];
      }
      configure();
    }
  };

  function present() {
    document.documentElement.toggleAttribute('data-video-open', Boolean(kind));
    browser.hidden = !kind;
    syncTabs();
  }

  window.plexVideoExit = () => {
    if (!kind) return;
    kind = '';
    ++pending;
    clearTimeout(timer);
    if (dialog.open) dialog.close();
    else host({action:'videoClose'});
    present();
  };

  for (const [type, tab] of tabs) tab.onclick = () => {
    if (!state?.serverId || kind === type) return;
    kind = type;
    parent = [];
    search.value = '';
    present();
    for (const active of document.querySelectorAll('nav button[aria-pressed="true"]')) {
      if (active !== tab) active.setAttribute('aria-pressed', 'false');
    }
    configure();
  };

  function browse(offset = 0) {
    clearTimeout(timer);
    next = null;
    busy = false;
    listOffset = offset;
    retry.hidden = true;
    if (offset === 0) {
      tiles.replaceChildren();
      rendered.clear();
    }
    const current = parent.at(-1);
    get('video-title').textContent = current?.title || titles[kind];
    search.hidden = Boolean(current) || !library;
    get('video-back').hidden = !current;
    const summary = get('video-summary');
    summary.textContent = current?.summary || '';
    summary.hidden = !summary.textContent;
    tiles.classList.toggle('video-episodes', current?.type === 'season');
    loadMore.hidden = true;
    const id = ++pending;
    if (!library) {
      status.textContent = state.loadingLibraries ? 'Finding Plex libraries…' :
        'No ' + titles[kind] + ' libraries are available on this Plex server.';
      return;
    }
    busy = true;
    status.textContent = 'Loading…';
    host({action:'videoBrowse', id, library, kind, offset, item:current?.key, query:search.value,
      type:current?.type === 'show' ? 'season' : 'episode'});
  }

  picker.onchange = () => {
    localStorage.setItem(preference(), picker.value);
    parent = [];
    search.value = '';
    configure();
  };
  get('video-back').onclick = () => { parent.pop(); browse(); };
  search.oninput = () => { clearTimeout(timer); ++pending; timer = setTimeout(browse, 280); };
  loadMore.onclick = () => { if (next !== null && !busy) browse(next); };
  retry.onclick = () => browse(listOffset);
  window.plexVideoListing = reply => {
    if (!kind || reply.id !== pending) return;
    busy = false;
    next = reply.next ?? null;
    for (const row of reply.items || []) {
      if (rendered.has(row.key)) continue;
      rendered.add(row.key);
      const tile = document.createElement('button');
      tile.type = 'button';
      tile.className = 'video-tile';
      const poster = document.createElement('span');
      poster.className = 'video-poster';
      const typeIcon = document.createElement('span');
      typeIcon.textContent = row.type === 'episode' ? '▶' : '▣';
      typeIcon.setAttribute('aria-hidden', 'true');
      poster.append(typeIcon);
      if (/^\/art\/[a-f0-9]{32}$/.test(row.artwork)) {
        const image = document.createElement('img');
        image.alt = '';
        image.loading = 'lazy';
        image.onerror = () => image.remove();
        image.src = row.artwork;
        poster.append(image);
      }
      const labels = document.createElement('span');
      const title = document.createElement('strong');
      title.textContent = row.title;
      labels.append(title);
      if (row.subtitle) {
        const subtitle = document.createElement('small');
        subtitle.textContent = row.subtitle;
        labels.append(subtitle);
      }
      tile.append(poster, labels);
      tile.onclick = () => {
        if (row.type === 'movie' || row.type === 'episode') open(row);
        else { parent.push(row); browse(); }
      };
      tiles.append(tile);
    }
    status.textContent = rendered.size ? '' : 'No matches.';
    loadMore.hidden = next === null;
  };

  function open(item) {
    source = null;
    failed = false;
    usingFallback = false;
    resumeAt = 0;
    get('video-playing-title').textContent = item.title;
    get('video-playing-summary').textContent = item.summary;
    mode.textContent = 'Preparing video…';
    error.hidden = true;
    alternate.hidden = true;
    video.hidden = true;
    dialog.showModal();
    host({action:'videoPlay', kind, library, id:++pending, item:item.key, type:item.type});
  }

  // Let the runtime decide which codecs it can decode. A file extension alone can't establish that.
  function directScore(candidate) {
    const {mime, audio, video:codec} = candidate;
    const codecs = {vp8:'vp8', vp9:'vp9', av1:'av01.0.08M.08', h264:'avc1.640028',
      hevc:'hvc1.1.6.L120.B0', mpeg4:'mp4v.20.9', aac:'mp4a.40.2', ac3:'ac-3', eac3:'ec-3',
      mp3:'mp3', opus:'opus', vorbis:'vorbis', flac:'flac', alac:'alac'};
    const hints = [codecs[codec], codecs[audio]].filter(Boolean);
    return video.canPlayType(mime + (hints.length ? '; codecs="' + hints.join(', ') + '"' : '')) === 'probably'
      ? 2 : video.canPlayType(mime) ? 1 : 0;
  }

  function direct() {
    const candidate = candidates.shift();
    if (!candidate) { compatibility(); return; }
    mode.textContent = 'Direct Play';
    alternate.hidden = false;
    video.src = candidate.url;
    video.hidden = false;
    video.play().catch(() => {});
  }

  function compatibility() {
    if (usingFallback || !source?.hls) { showError('Plex couldn’t start this video. Check transcoding on your Plex server.'); return; }
    usingFallback = true;
    resumeAt = Number.isFinite(video.currentTime) ? video.currentTime : 0;
    mode.textContent = 'Plex Transcode';
    alternate.hidden = true;
    video.removeAttribute('src');
    video.load();
    video.hidden = false;
    if (window.Hls?.isSupported()) {
      hls = new window.Hls({enableWorker:false});
      hls.on(window.Hls.Events.ERROR, (_, data) => {
        if (data.fatal) showError('Plex couldn’t transcode this video. Check that transcoding is enabled and available on your server.');
      });
      hls.on(window.Hls.Events.MANIFEST_PARSED, () => video.play().catch(() => {}));
      hls.loadSource(source.hls);
      hls.attachMedia(video);
    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = source.hls;
      video.play().catch(() => {});
    } else {
      showError('This WebView2 runtime cannot play Plex compatibility streams.');
    }
  }
  alternate.onclick = compatibility;
  video.addEventListener('loadedmetadata', () => {
    if (usingFallback && resumeAt > 0 && resumeAt < video.duration) video.currentTime = resumeAt;
  });
  video.addEventListener('play', () => window.windowsPlayback.action({action:'pause'}));
  video.addEventListener('error', () => {
    if (!dialog.open || !source || failed || (!video.getAttribute('src') && !hls)) return;
    if (usingFallback) showError('Plex couldn’t play the compatibility stream.');
    else direct();
  });
  get('video-done').onclick = () => dialog.close();
  dialog.addEventListener('close', () => {
    ++pending;
    video.pause();
    if (hls) { hls.destroy(); hls = null; }
    source = null;
    video.removeAttribute('src');
    video.load();
    host({action:'videoClose'});
  });

  function showError(message) {
    failed = true;
    if (hls) { hls.destroy(); hls = null; }
    video.pause();
    video.removeAttribute('src');
    video.load();
    video.hidden = true;
    alternate.hidden = true;
    error.textContent = message;
    error.hidden = false;
    mode.textContent = '';
  }

  window.plexVideoSource = payload => {
    if (!dialog.open || payload.id !== pending || !validSource.test(payload.hls)) return;
    source = payload;
    candidates = (payload.direct || []).filter(row => validSource.test(row.url))
      .map(row => ({...row, score:directScore(row)}))
      .sort((a, b) => b.score - a.score);
    direct();
  };
  window.plexVideoError = reply => {
    if (reply.id !== pending) return;
    if (dialog.open) showError(reply.message);
    else {
      busy = false;
      status.textContent = reply.message;
      retry.hidden = false;
    }
  };
})();
