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
  const fullscreen = get('video-fullscreen');
  const pip = get('video-pip');
  const restore = get('video-restore');
  const mode = get('video-mode');
  const error = get('video-error');
  const watchToggle = get('video-watch-toggle');
  const watchShelf = get('continue-video');
  const watchItems = get('continue-video-items');
  const alternate = get('video-compatibility');
  const versionField = get('video-version-field');
  const versionPicker = get('video-version');
  const versionPlay = get('video-version-play');
  const upNext = get('video-up-next');
  const nextTitle = get('video-up-next-title');
  const nextHeading = get('video-up-next-heading');
  const nextCancel = get('video-next-cancel');
  const nextPlay = get('video-next-play');
  const tabs = new Map([['movie', get('movies')], ['show', get('television')]]);
  const titles = {movie:'Movies', show:'TV Shows'};
  const sectionToggles = new Map([['movie', get('show-movies-section')], ['show', get('show-tv-section')]]);
  const sectionPreference = 'musicroom-visible-video-sections';
  let visibleSections = [...tabs.keys()];
  try {
    const saved = JSON.parse(localStorage.getItem(sectionPreference));
    if (Array.isArray(saved)) visibleSections = visibleSections.filter(section => saved.includes(section));
  } catch {}
  const validSource = /^https:\/\/media\.musicroom\.invalid\/video\/[a-f0-9]{32}$/;
  let state, kind = '', library = '', libraryReady = false, pending = 0, parent = [], next = null, busy = false, timer;
  let source, hls, candidates = [], usingFallback = false, resumeAt = 0, listOffset = 0, failed = false;
  const rendered = new Set();
  let watchRecords = new Map(), watchSequence = 0, activeItem, activeScope, lastReport = 0;
  let lastSaved = 0, awaitingSeek = false, nativeActive = false;
  let selectedVersion = -1, activeVersion = null, nextEpisode = null, nextTimer = null;
  let pageSize = '60';
  const matchDialog = get('video-match');
  const matchStatus = get('video-match-status');
  const matchChoices = get('video-match-choices');
  const matchForm = get('video-match-form');
  const matchApply = get('video-match-apply');
  let matchEdit, matchSequence = 0;

  window.plexVideoPageSize = value => {
    if (pageSize === value) return;
    pageSize = value;
    if (kind && libraryReady) browse();
  };
  function openMatch(item) {
    if (matchDialog.open) return;
    matchEdit = {...watchContext(), item:item.key};
    get('video-match-name').value = item.title;
    get('video-match-year').value = /^\d{4}$/.test(item.subtitle) ? item.subtitle : '';
    matchDialog.showModal();
    searchMatches();
  }
  function matchBusy(busy) {
    matchForm.querySelector('button').disabled = busy;
    matchChoices.disabled = busy;
    matchApply.disabled = busy || !matchChoices.value;
    get('video-match-close').disabled = Boolean(matchEdit?.saving);
  }
  function searchMatches() {
    if (!matchEdit || matchEdit.saving) return;
    const title = get('video-match-name').value.trim();
    if (!title) return;
    const year = get('video-match-year').value.trim();
    matchChoices.replaceChildren();
    matchBusy(true);
    matchStatus.textContent = 'Searching Plex…';
    matchEdit.id = ++matchSequence;
    host({action:'videoSearchMatches', ...matchEdit, title, year});
  }
  matchForm.onsubmit = event => { event.preventDefault(); searchMatches(); };
  matchChoices.onchange = () => { matchApply.disabled = !matchChoices.value; };
  matchApply.onclick = () => {
    if (!matchEdit || matchEdit.saving || !matchChoices.value) return;
    matchEdit.id = ++matchSequence;
    matchEdit.saving = true;
    matchBusy(true);
    matchStatus.textContent = 'Saving match…';
    host({action:'videoApplyMatch', ...matchEdit, choice:matchChoices.value});
  };
  get('video-match-close').onclick = () => matchDialog.close();
  matchDialog.addEventListener('cancel', event => { if (matchEdit?.saving) event.preventDefault(); });
  matchDialog.addEventListener('close', () => { if (!matchDialog.open) matchEdit = null; });
  window.plexVideoMatchResult = reply => {
    if (!matchDialog.open || reply.id !== matchEdit?.id) return;
    matchEdit.saving = false;
    if (reply.saved) {
      matchDialog.close();
      browse();
      return;
    }
    if (reply.choices?.length) {
      matchChoices.replaceChildren(new Option('Choose a match', ''), ...reply.choices.map(row =>
        new Option(row.year ? row.title + ' (' + row.year + ')' : row.title, row.key)));
    }
    matchBusy(false);
    matchStatus.textContent = reply.error || (reply.choices?.length ? '' : 'No matches found. Try another title or clear the year.');
  };

  let ended = false;

  function watchContext() { return {kind, library, server:state?.serverId}; }

  function refreshWatch() {
    if (!library || !kind) return;
    host({action:'videoWatchState', id:++watchSequence, ...watchContext()});
  }

  function watchTime(seconds) {
    const total = Math.floor(seconds);
    const hours = Math.floor(total / 3600);
    return (hours ? hours + ':' : '') + String(Math.floor(total / 60) % 60).padStart(hours ? 2 : 1, '0') +
      ':' + String(total % 60).padStart(2, '0');
  }

  function renderWatch() {
    watchShelf.hidden = Boolean(parent.length || search.value.trim());
    for (const tile of tiles.children) {
      const watched = Boolean(watchRecords.get(tile.dataset.item)?.watched);
      tile.classList.toggle('watched-video', watched);
      const badge = tile.querySelector('.watched-badge');
      if (badge) badge.hidden = !watched;
    }
    watchToggle.textContent = watchRecords.get(activeItem?.key)?.watched ? 'Mark Unwatched' : 'Mark Watched';
    const recent = [...watchRecords.values()].filter(row => !row.watched && row.seconds >= 5).slice(0,24);
    watchShelf.hidden ||= recent.length === 0;
    watchItems.replaceChildren(...recent.map(row => {
      const tile = document.createElement('button');
      tile.type = 'button';
      tile.className = 'video-resume';
      if (/^\/art\/[a-f0-9]{32}$/.test(row.artwork)) {
        const thumbnail = document.createElement('img');
        thumbnail.alt = '';
        thumbnail.src = row.artwork;
        tile.append(thumbnail);
      }
      const title = document.createElement('strong');
      title.textContent = row.title;
      const resume = document.createElement('small');
      resume.textContent = 'Resume at ' + watchTime(row.seconds);
      tile.append(title, resume);
      tile.onclick = () => open(row);
      return tile;
    }));
  }

  window.plexVideoWatchState = reply => {
    if (!kind || reply.id !== watchSequence) return;
    watchRecords = new Map((reply.records || []).map(row => [row.key, row]));
    renderWatch();
  };

  function saveWatch(seconds, watched = false, refresh = false) {
    if (!activeItem || !activeScope || (!watched && (!Number.isFinite(seconds) || seconds < 5))) return;
    if (watchRecords.get(activeItem.key)?.watched && !watched) return;
    const row = {...activeItem, watched, seconds:watched ? 0 : seconds};
    watchRecords.set(row.key, row);
    lastSaved = row.seconds;
    host({action:'videoWatchUpdate', id:refresh ? ++watchSequence : 0, ...activeScope,
      item:row.key, type:row.type, title:row.title, subtitle:row.subtitle,
      artwork:row.thumb, seconds:row.seconds, watched});
    if (refresh) renderWatch();
  }

  watchToggle.onclick = () => {
    if (!activeItem || !activeScope) return;
    if (watchRecords.get(activeItem.key)?.watched) {
      watchRecords.delete(activeItem.key);
      host({action:'videoWatchClear', id:++watchSequence, ...activeScope, item:activeItem.key, type:activeItem.type});
      renderWatch();
    } else saveWatch(0, true, true);
  };

  function videoServer(value = state) { return value?.videoServer || value?.serverId || ''; }
  function preference(type) { return 'musicroom-video-library.' + videoServer() + '.' + type; }
  window.plexVideoCacheSelection = () => ({
    movie: state?.serverId ? localStorage.getItem(preference('movie')) || '' : '',
    show: state?.serverId ? localStorage.getItem(preference('show')) || '' : ''
  });

  function syncTabs() {
    get('music').setAttribute('aria-pressed', String(!kind));
    get('music-sections').hidden = Boolean(kind);
    for (const [type, tab] of tabs) {
      tab.hidden = !visibleSections.includes(type);
      tab.disabled = !videoServer();
      sectionToggles.get(type).checked = !tab.hidden;
      tab.setAttribute('aria-pressed', String(type === kind));
    }
  }

  function configure() {
    const available = state.waitingForVideo ? [] : (state.videoLibraries || []).filter(row => row.type === kind);
    const preview = state.videoPreviews?.[kind];
    const preferred = localStorage.getItem(preference(kind));
    const restored = available.find(row => row.id === preferred)?.id || available[0]?.id ||
      ((state.waitingForVideo || state.videoConnectionError) ? preview?.library : '') || '';
    if (library !== restored) {
      parent = [];
      watchRecords.clear();
    }
    library = restored;
    libraryReady = available.some(row => row.id === library);
    const choices = libraryReady ? available : (restored ? [{name:preview.name, id:restored}] : []);
    picker.replaceChildren(...choices.map(row => new Option(row.name, row.id)));
    picker.value = library;
    picker.setAttribute('aria-label', 'Switch ' + titles[kind] + ' Library');
    picker.hidden = choices.length === 0;
    picker.disabled = !libraryReady;
    browse();
    if (libraryReady) refreshWatch();
    else ++watchSequence;
  }

  window.plexVideoState = value => {
    const previous = state;
    state = value;
    if (kind && !videoServer()) window.plexVideoExit();
    syncTabs();
    if (!kind) return;
    const changedServer = videoServer(previous || {}) !== videoServer();
    if (changedServer || previous?.waitingForVideo !== state.waitingForVideo ||
        previous?.videoConnectionError !== state.videoConnectionError ||
        JSON.stringify(previous?.videoLibraries) !== JSON.stringify(state.videoLibraries)) {
      if (changedServer) {
        if (dialog.open) dialog.close();
        if (matchDialog.open) matchDialog.close();
        watchRecords.clear();
        ++watchSequence;
        parent = [];
        search.value = '';
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
    if (matchDialog.open) matchDialog.close();
    watchRecords.clear();
    ++watchSequence;
    ++pending;
    clearTimeout(timer);
    if (dialog.open) dialog.close();
    else host({action:'videoClose'});
    present();
  };

  get('music').onclick = () => window.plexVideoExit();

  for (const input of sectionToggles.values()) input.onchange = () => {
    visibleSections = [...sectionToggles].filter(([, toggle]) => toggle.checked).map(([type]) => type);
    try { localStorage.setItem(sectionPreference, JSON.stringify(visibleSections)); } catch {}
    if (kind && !visibleSections.includes(kind)) window.plexVideoExit();
    else syncTabs();
  };
  syncTabs();

  for (const [type, tab] of tabs) tab.onclick = () => {
    if (!visibleSections.includes(type) || !videoServer() || kind === type) return;
    kind = type;
    watchRecords.clear();
    parent = [];
    search.value = '';
    present();
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
    search.placeholder = 'Search ' + titles[kind].toLowerCase();
    search.setAttribute('aria-label', search.placeholder);
    search.hidden = Boolean(current) || !library;
    search.disabled = !libraryReady;
    get('video-back').hidden = !current;
    const summary = get('video-summary');
    summary.textContent = current?.summary || '';
    summary.hidden = !summary.textContent;
    tiles.classList.toggle('video-episodes', current?.type === 'season');
    loadMore.hidden = true;
    renderWatch();
    const id = ++pending;
    const preview = state.videoPreviews?.[kind];
    if (offset === 0 && !current && !search.value.trim() && preview?.library === library) {
      renderItems(preview.items, libraryReady);
    }
    if (!libraryReady) {
      status.textContent = state.waitingForVideo ? 'Reconnecting to Plex…' :
        state.videoConnectionError ? state.message : 'No ' + titles[kind] + ' libraries are available on this Plex server.';
      retry.hidden = !state.videoConnectionError;
      return;
    }
    busy = true;
    status.textContent = 'Loading…';
    host({action:'videoBrowse', id, library, kind, offset, item:current?.key, query:search.value,
      type:current?.type === 'show' ? 'season' : 'episode', pageSize:pageSize === 'all' ? 120 : Number(pageSize)});
  }

  picker.onchange = () => {
    localStorage.setItem(preference(kind), picker.value);
    parent = [];
    search.value = '';
    configure();
  };
  get('video-back').onclick = () => { parent.pop(); browse(); };
  search.oninput = () => { clearTimeout(timer); ++pending; timer = setTimeout(browse, 280); };
  loadMore.onclick = () => { if (next !== null && !busy) browse(next); };
  retry.onclick = () => {
    if (!libraryReady && state.videoConnectionError) host({action:'servers'});
    else browse(listOffset);
  };
  window.plexVideoListing = reply => {
    if (!kind || reply.id !== pending) return;
    busy = false;
    next = reply.next ?? null;
    if (listOffset === 0) {
      tiles.replaceChildren();
      rendered.clear();
    }
    const previousCount = rendered.size;
    renderItems(reply.items, true);
    if (rendered.size === previousCount || next <= listOffset) next = null;
    if (pageSize === 'all' && next !== null) { browse(next); return; }
    status.textContent = rendered.size ? '' : 'No matches.';
    loadMore.hidden = next === null;
  };

  function renderItems(rows, interactive) {
    for (const row of rows || []) {
      if (rendered.has(row.key)) continue;
      rendered.add(row.key);
      const tile = document.createElement('button');
      tile.type = 'button';
      tile.className = 'video-tile';
      tile.dataset.item = row.key;
      tile.disabled = !interactive;
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
      const badge = document.createElement('small');
      badge.className = 'watched-badge';
      badge.textContent = 'Watched';
      badge.hidden = !watchRecords.get(row.key)?.watched;
      labels.append(badge);
      tile.append(poster, labels);
      tile.onclick = () => {
        if (row.type === 'movie' || row.type === 'episode') open(row);
        else { parent.push(row); browse(); }
      };
      if (interactive && row.type === kind) {
        const card = document.createElement('div');
        card.className = 'video-match-card';
        card.dataset.item = row.key;
        const fix = document.createElement('button');
        fix.type = 'button';
        fix.className = 'video-fix-match';
        fix.textContent = '⋯';
        fix.title = 'Fix Match';
        fix.setAttribute('aria-label', 'Fix Match for ' + row.title);
        fix.onclick = () => openMatch(row);
        card.append(tile, fix);
        tiles.append(card);
      } else tiles.append(tile);
    }
  }

  function clearNext() {
    clearInterval(nextTimer);
    nextTimer = null;
    nextEpisode = null;
    upNext.hidden = true;
    nextCancel.hidden = true;
    nextPlay.hidden = true;
    nextTitle.textContent = '';
  }

  function open(item) {
    activeItem = item;
    activeScope = watchContext();
    selectedVersion = -1;
    versionField.hidden = true;
    lastSaved = watchRecords.get(item.key)?.seconds || 0;
    renderWatch();
    get('video-playing-title').textContent = item.title;
    get('video-playing-summary').textContent = item.summary || '';
    if (!dialog.open) dialog.showModal();
    requestPlayback();
  }

  function setDisplayControls(available) {
    fullscreen.disabled = pip.disabled = !available;
  }

  function requestDisplay(mode) {
    host({action:'videoDisplay', mode});
  }

  window.plexVideoDisplay = display => {
    if (!dialog.open) return;
    if (display === 'inline') delete dialog.dataset.display;
    else dialog.dataset.display = display;
    video.controls = display !== 'floating';
    restore.hidden = display !== 'fullscreen';
    if (display === 'fullscreen') restore.focus();
    else if (display === 'floating') video.focus();
    else if (!fullscreen.disabled) fullscreen.focus();
  };

  fullscreen.onclick = () => requestDisplay('fullscreen');
  pip.onclick = () => requestDisplay('floating');
  restore.onclick = () => requestDisplay('inline');
  dialog.addEventListener('cancel', event => {
    if (!dialog.dataset.display) return;
    event.preventDefault();
    requestDisplay('inline');
  });
  dialog.addEventListener('keydown', event => {
    if (dialog.dataset.display !== 'floating' || event.code !== 'Space') return;
    event.preventDefault();
    if (!event.repeat) {
      if (video.paused) video.play().catch(() => {});
      else video.pause();
    }
  });

  function requestPlayback() {
    clearNext();
    source = null;
    candidates = [];
    failed = false;
    usingFallback = false;
    nativeActive = false;
    activeVersion = null;
    ended = false;
    resumeAt = lastSaved;
    lastReport = Date.now();
    awaitingSeek = resumeAt >= 5;
    mode.textContent = 'Preparing video…';
    error.hidden = true;
    alternate.hidden = true;
    versionPlay.hidden = true;
    versionPicker.disabled = true;
    video.hidden = true;
    setDisplayControls(false);
    video.pause();
    if (hls) { hls.destroy(); hls = null; }
    video.removeAttribute('src');
    video.load();
    host({action:'videoPlay', ...activeScope, id:++pending, item:activeItem.key,
      type:activeItem.type, version:selectedVersion});
  }

  function onEnded() {
    if (ended || !activeItem) return;
    ended = true;
    saveWatch(0, true, true);
    if (!source?.canAdvance) return;
    upNext.hidden = false;
    nextHeading.textContent = 'Finding the next unwatched episode…';
    host({action:'videoNext', ...activeScope, id:pending, item:activeItem.key});
  }

  window.plexVideoNext = reply => {
    if (!dialog.open || !ended || reply.id !== pending) return;
    nextEpisode = reply.item || null;
    if (!nextEpisode) {
      nextHeading.textContent = reply.error ? 'Couldn’t look up the next episode.' : 'You’re caught up with this show.';
      return;
    }
    nextTitle.textContent = [nextEpisode.title, nextEpisode.subtitle].filter(Boolean).join(' · ');
    nextPlay.hidden = false;
    nextCancel.hidden = false;
    const deadline = Date.now() + 5000;
    nextHeading.textContent = 'Up Next in 5s';
    nextTimer = setInterval(() => {
      const seconds = Math.ceil((deadline - Date.now()) / 1000);
      if (seconds <= 0) {
        clearInterval(nextTimer);
        nextTimer = null;
        if (dialog.open && nextEpisode) open(nextEpisode);
      } else nextHeading.textContent = 'Up Next in ' + seconds + 's';
    }, 200);
  };

  nextCancel.onclick = () => {
    clearInterval(nextTimer);
    nextTimer = null;
    nextHeading.textContent = 'Up Next';
    nextCancel.hidden = true;
  };

  nextPlay.onclick = () => { if (nextEpisode) open(nextEpisode); };

  versionPicker.onchange = () => {
    if (!activeItem) return;
    if (!nativeActive && !awaitingSeek && !failed) saveWatch(video.currentTime);
    selectedVersion = Number(versionPicker.value);
    requestPlayback();
  };

  versionPlay.onclick = () => { if (activeItem) requestPlayback(); };

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
    activeVersion = candidate.index;
    if (candidate.native) {
      nativeActive = true;
      video.removeAttribute('src');
      video.load();
      video.hidden = true;
      setDisplayControls(false);
      mode.textContent = 'Direct Play · VLC';
      alternate.hidden = true;
      window.windowsPlayback.action({action:'pause'});
      host({action:'videoNative', id:pending, url:candidate.url, title:get('video-playing-title').textContent, resume:lastSaved,
        advance:Boolean(source.canAdvance), versions:(source.versions || []).length > 1});
      return;
    }
    nativeActive = false;
    mode.textContent = 'Direct Play';
    alternate.hidden = false;
    video.src = candidate.url;
    video.hidden = false;
    setDisplayControls(true);
    video.play().catch(() => {});
  }

  function compatibility(position) {
    const fallback = source?.fallbacks?.[activeVersion] || source?.hls;
    if (usingFallback || !validSource.test(fallback)) { showError('Plex couldn’t start this video. Check transcoding on your Plex server.'); return; }
    usingFallback = true;
    nativeActive = false;
    resumeAt = Number.isFinite(position) && position >= 5 ? position :
      Number.isFinite(video.currentTime) && video.currentTime >= 5 ? video.currentTime : lastSaved;
    awaitingSeek = resumeAt >= 5;
    mode.textContent = 'Plex Transcode';
    alternate.hidden = true;
    video.removeAttribute('src');
    video.load();
    video.hidden = false;
    setDisplayControls(true);
    if (window.Hls?.isSupported()) {
      hls = new window.Hls({enableWorker:false});
      hls.on(window.Hls.Events.ERROR, (_, data) => {
        if (data.fatal) showError('Plex couldn’t transcode this video. Check that transcoding is enabled and available on your server.');
      });
      hls.on(window.Hls.Events.MANIFEST_PARSED, () => video.play().catch(() => {}));
      hls.loadSource(fallback);
      hls.attachMedia(video);
    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = fallback;
      video.play().catch(() => {});
    } else {
      showError('This WebView2 runtime cannot play Plex compatibility streams.');
    }
  }
  alternate.onclick = () => compatibility();
  window.plexNativeVideo = reply => {
    if (!dialog.open || reply.id !== pending) return;
    if (reply.result === 'progress') { saveWatch(reply.seconds); return; }
    if (reply.result === 'ended') { nativeActive = false; onEnded(); return; }
    if (reply.result === 'versions') {
      nativeActive = false;
      saveWatch(reply.seconds);
      mode.textContent = 'Choose a version';
      versionPlay.hidden = false;
      versionPicker.focus();
      return;
    }
    if (reply.result === 'closed') {
      saveWatch(reply.seconds);
      dialog.close();
    } else if (reply.result === 'fallback') {
      saveWatch(reply.seconds);
      compatibility(reply.seconds);
    } else {
      nativeActive = false;
      direct();
    }
  };
  video.addEventListener('loadedmetadata', () => {
    if (awaitingSeek && resumeAt < video.duration) video.currentTime = resumeAt;
    else awaitingSeek = false;
  });
  video.addEventListener('seeked', () => { awaitingSeek = false; });
  video.addEventListener('timeupdate', () => {
    if (!nativeActive && !awaitingSeek && Date.now() - lastReport >= 5000) {
      lastReport = Date.now();
      saveWatch(video.currentTime);
    }
  });
  video.addEventListener('ended', () => {
    if (dialog.open && !nativeActive && !failed) onEnded();
  });
  video.addEventListener('play', () => window.windowsPlayback.action({action:'pause'}));
  video.addEventListener('error', () => {
    if (!dialog.open || !source || failed || (!video.getAttribute('src') && !hls)) return;
    if (usingFallback) showError('Plex couldn’t play the compatibility stream.');
    else direct();
  });
  get('video-done').onclick = () => dialog.close();
  dialog.addEventListener('close', () => {
    if (!nativeActive && !awaitingSeek && !failed) saveWatch(video.currentTime);
    clearNext();
    delete dialog.dataset.display;
    video.controls = true;
    restore.hidden = true;
    setDisplayControls(false);
    activeItem = activeScope = null;
    ++pending;
    video.pause();
    if (hls) { hls.destroy(); hls = null; }
    source = null;
    video.removeAttribute('src');
    video.load();
    host({action:'videoClose'});
    refreshWatch();
  });

  function showError(message) {
    failed = true;
    setDisplayControls(false);
    if (dialog.dataset.display) requestDisplay('inline');
    if (hls) { hls.destroy(); hls = null; }
    video.pause();
    video.removeAttribute('src');
    video.load();
    video.hidden = true;
    alternate.hidden = true;
    error.textContent = message;
    error.hidden = false;
    versionPicker.disabled = false;
    mode.textContent = '';
  }

  window.plexVideoSource = payload => {
    if (!dialog.open || payload.id !== pending || !validSource.test(payload.hls)) return;
    source = payload;
    const versions = payload.versions || [];
    versionPicker.replaceChildren(new Option('Automatic', '-1'),
      ...versions.map(row => new Option(row.label, String(row.index))));
    versionPicker.value = String(selectedVersion);
    versionField.hidden = versions.length < 2;
    versionPicker.disabled = false;
    candidates = (payload.direct || []).filter(row => validSource.test(row.url))
      .map(row => ({...row, score:row.native ? 3 : directScore(row)}))
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
