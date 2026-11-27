(() => {
  'use strict';
  const get = id => document.getElementById(id);
  const node = (tag, text) => {
    const element = document.createElement(tag);
    if (text !== undefined) element.textContent = text;
    return element;
  };
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
  const subtitleDefault = get('subtitle-default');
  let subtitleMode = 'off';
  const initializedSubtitleTracks = new WeakSet();
  try {
    if (localStorage.getItem('musicroom-video-subtitles') === 'automatic') subtitleDefault.value = 'automatic';
  } catch {}
  subtitleDefault.onchange = () => {
    try { localStorage.setItem('musicroom-video-subtitles', subtitleDefault.value); } catch {}
  };

  function initializeSubtitle(track) {
    if (subtitleMode !== 'off' || !['subtitles', 'captions'].includes(track.kind) ||
        initializedSubtitleTracks.has(track)) return;
    initializedSubtitleTracks.add(track);
    track.mode = 'disabled';
  }

  video.textTracks.addEventListener('addtrack', event => initializeSubtitle(event.track));
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
  const defaults = {movie:'Movies', show:'TV Shows', toolDrive:'Tool Drive', music:'Music', downloads:'Downloads'};
  const toolDrivePanel = get('tool-drive-panel');
  let archiveEntry = 0;
  let archiveMotion = null;
  window.toolDrivePageReady = ready => {
    get('tool-drive-loading').hidden = ready;
  };
  const downloadsPanel = get('downloads-panel');
  const sectionButtons = new Map([...tabs, ['toolDrive', get('tool-drive')], ['music', get('music')],
    ['downloads', get('downloads')]]);
  const titles = {...defaults};
  for (const [section, button] of sectionButtons) {
    const input = get(button.id + '-name');
    const key = 'musicroom-section-name-' + section;
    try { input.value = localStorage.getItem(key) || ''; } catch {}
    function applyName() {
      titles[section] = input.value.trim().slice(0, 48) || defaults[section];
      button.textContent = titles[section];
      const option = get('header-brand-section').querySelector('option[value="' + section + '"]');
      option.textContent = titles[section];
      if (section === 'downloads') get('downloads-title').textContent = titles[section];
      if (section === kind) {
        if (!parent.length) get('video-title').textContent = titles[section];
        search.placeholder = 'Search ' + titles[section];
        search.setAttribute('aria-label', search.placeholder);
        picker.setAttribute('aria-label', 'Switch ' + titles[section] + ' Library');
      }
    }
    input.oninput = () => {
      try { localStorage.setItem(key, input.value); } catch {}
      applyName();
    };
    // Read names before the initial Plex state activates a section.
    button.textContent = titles[section] = input.value.trim().slice(0, 48) || defaults[section];
    get('header-brand-section').querySelector('option[value="' + section + '"]').textContent = titles[section];
    if (section === 'downloads') get('downloads-title').textContent = titles[section];
  }
  const sectionToggles = new Map([['movie', get('show-movies-section')], ['show', get('show-tv-section')]]);
  const sectionPreference = 'musicroom-visible-video-sections';
  const lastSectionPreference = 'musicroom-last-video-section';
  let visibleSections = [...tabs.keys()];
  let preferredKind = '';
  try {
    const saved = JSON.parse(localStorage.getItem(sectionPreference));
    if (Array.isArray(saved)) visibleSections = visibleSections.filter(section => saved.includes(section));
    const last = localStorage.getItem(lastSectionPreference);
    if (last === 'toolDrive' || last === 'downloads' || visibleSections.includes(last)) preferredKind = last;
  } catch {}
  const validSource = /^https:\/\/media\.musicroom\.invalid\/video\/[a-f0-9]{32}$/;
  let state, kind = '', library = '', libraryReady = false, pending = 0, parent = [], next = null, busy = false, timer;
  let archiveOpen = false;
  let downloadsOpen = false;
  let source, hls, candidates = [], usingFallback = false, resumeAt = 0, listOffset = 0, failed = false;
  const rendered = new Set();
  const moviePage = get('movie-details');
  const listingHeader = browser.querySelector('.library-page-header');
  const listingContent = browser.querySelector('.content');
  let selectedDetail, movieOpener, videoDetailSequence = 0, requestedMovieDownload = false;

  let showBeforeEpisode, tvListing, currentDetailMetadata;
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
      closeDetails();
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

  function watchFor(item) {
    return watchRecords.get(item?.key) || item || {};
  }

  function renderWatch() {
    watchShelf.hidden = Boolean(parent.length || search.value.trim());
    let foundNext = false;
    for (const tile of tiles.children) {
      const watch = watchFor(tile.videoItem);
      const watched = Boolean(watch.watched);
      tile.classList.toggle('watched-video', watched);
      const badge = tile.querySelector('.watched-badge');
      if (badge) badge.hidden = !watched;
      const nextBadge = tile.querySelector('.next-episode');
      if (nextBadge) {
        nextBadge.hidden = watched || foundNext;
        if (!watched) foundNext = true;
      }
      const progress = tile.querySelector('.episode-progress');
      if (progress) {
        progress.hidden = watched || !(watch.seconds >= 5) || !(tile.videoItem.duration > 0);
        progress.value = Math.min(1, (watch.seconds || 0) / (tile.videoItem.duration || 1));
      }
    }
    updateMovieActions();
    watchToggle.textContent = watchFor(activeItem).watched ? 'Mark Unwatched' : 'Mark Watched';
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
      tile.onclick = () => row.type === 'episode' ? openDetails(row, tile) : open(row);
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

  function markUnwatched(item, scope) {
    const {key, type, title, subtitle, thumb} = item;
    if (item.watched) {
      watchRecords.set(key, {...item, watched:false, seconds:0});
      host({action:'videoWatchUpdate', id:++watchSequence, ...scope, item:key, type, title,
        subtitle, artwork:thumb, explicitlyUnwatched:true, seconds:0});
    } else {
      watchRecords.delete(key);
      host({action:'videoWatchClear', id:++watchSequence, ...scope, item:key, type});
    }
    renderWatch();
  }

  watchToggle.onclick = () => {
    if (!activeItem || !activeScope) return;
    if (watchFor(activeItem).watched) markUnwatched(activeItem, activeScope);
    else saveWatch(0, true, true);
  };

  function videoServer(value = state) { return value?.videoServer || value?.serverId || ''; }
  function preference(type) { return 'musicroom-video-library.' + videoServer() + '.' + type; }
  window.plexVideoCacheSelection = () => ({
    movie: state?.serverId ? localStorage.getItem(preference('movie')) || '' : '',
    show: state?.serverId ? localStorage.getItem(preference('show')) || '' : ''
  });

  function syncTabs() {
    get('music').setAttribute('aria-pressed', String(!kind && !downloadsOpen));
    get('tool-drive').setAttribute('aria-pressed', String(archiveOpen));
    get('downloads').setAttribute('aria-pressed', String(downloadsOpen));
    get('music-sections').hidden = Boolean(kind || downloadsOpen);
    window.syncMusicSectionSelection?.();
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
    if (library !== restored) closeDetails();
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
    if (!videoServer()) {
      showMusic();
      syncTabs();
      return;
    }
    if (!kind && visibleSections.includes(preferredKind)) {
      openSection(preferredKind);
      return;
    }
    syncTabs();
    if (!kind) return;
    const changedServer = videoServer(previous || {}) !== videoServer();
    if (changedServer || previous?.waitingForVideo !== state.waitingForVideo ||
        previous?.videoConnectionError !== state.videoConnectionError ||
        JSON.stringify(previous?.videoLibraries) !== JSON.stringify(state.videoLibraries)) {
      if (changedServer) {
        closeDetails();
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
    window.renderHeaderForSection?.(archiveOpen ? 'toolDrive' : downloadsOpen ? 'downloads' : kind || 'music');
    browser.hidden = !kind;
    syncTabs();
  }

  function showMusic() {
    if (!kind) return;
    closeDetails();
    kind = '';
    if (matchDialog.open) matchDialog.close();
    watchRecords.clear();
    ++watchSequence;
    ++pending;
    clearTimeout(timer);
    if (dialog.open) dialog.close();
    else host({action:'videoClose'});
    present();
    window.renderMusicPage?.();
  }

  function rememberSection(section) {
    preferredKind = section;
    try {
      if (section) localStorage.setItem(lastSectionPreference, section);
      else localStorage.removeItem(lastSectionPreference);
    } catch {}
  }

  window.plexVideoExit = () => {
    rememberSection('');
    showMusic();
    if (archiveOpen) openArchive(false);
    if (downloadsOpen) openDownloads(false);
  };

  get('music').onclick = () => window.plexVideoExit();

  for (const input of sectionToggles.values()) input.onchange = () => {
    visibleSections = [...sectionToggles].filter(([, toggle]) => toggle.checked).map(([type]) => type);
    try { localStorage.setItem(sectionPreference, JSON.stringify(visibleSections)); } catch {}
    if (tabs.has(preferredKind) && !visibleSections.includes(preferredKind)) window.plexVideoExit();
    else syncTabs();
  };
  syncTabs();

  for (const [type, tab] of tabs) tab.onclick = () => {
    if (!visibleSections.includes(type) || !videoServer() || kind === type) return;
    rememberSection(type);
    openSection(type);
  };

  function openSection(type) {
    closeDetails();
    if (archiveOpen) openArchive(false);
    if (downloadsOpen) openDownloads(false);
    kind = type;
    watchRecords.clear();
    parent = [];
    search.value = '';
    present();
    configure();
  }

  const globalDialog = get('global-search-dialog');
  const globalInput = get('global-search-input');
  const globalResults = get('global-search-results');
  const globalStatus = get('global-search-status');
  let globalSequence = 0, searchTimer, selectedCredit;

  function launchGlobalSearch(credit) {
    selectedCredit = credit;
    get('global-search-heading').textContent = credit?.name || 'Search iPlex';
    globalInput.value = '';
    globalInput.hidden = Boolean(credit);
    if (!globalDialog.open) globalDialog.showModal();
    if (!credit) globalInput.focus();
    searchGlobally();
  }

  function searchGlobally() {
    clearTimeout(searchTimer);
    const id = ++globalSequence;
    const query = globalInput.value.trim(), credit = selectedCredit;
    globalResults.replaceChildren();
    if (!query && !credit) {
      globalStatus.textContent = 'Enter a title, artist, venue, or date.';
      host({action:'globalSearch', id, query:''});
      return;
    }
    globalStatus.textContent = 'Searching…';
    searchTimer = setTimeout(() => {
      const location = type => {
        const choices = (state?.videoLibraries || []).filter(row => row.type === type);
        const saved = localStorage.getItem(preference(type));
        return choices.find(row => row.id === saved)?.id || choices[0]?.id;
      };
      host({action:'globalSearch', id, query, person:credit?.id, credit:credit?.role,
            movies:location('movie'), shows:location('show')});
    }, credit ? 0 : 275);
  }

  function openGlobalResult(group, row) {
    globalDialog.close();
    if (group === 'album' || group === 'track') window.openGlobalMusicResult?.(row);
    else if (group === 'downloads') {
      rememberSection('downloads');
      openDownloads(true);
      playDownload(row);
    } else if (group === 'toolDrive') {
      rememberSection('toolDrive');
      openArchive(true);
      host({action:'openToolDriveRecording', recording:row.id});
    } else {
      const section = group === 'movie' ? 'movie' : 'show';
      rememberSection(section);
      openSection(section);
      openDetails(row, get('global-search'));
    }
  }

  get('global-search').onclick = () => launchGlobalSearch();
  get('global-search-close').onclick = () => globalDialog.close();
  globalInput.oninput = searchGlobally;
  globalDialog.addEventListener('close', () => {
    clearTimeout(searchTimer);
    ++globalSequence;
    host({action:'globalSearch', id:globalSequence, query:''});
  });
  document.addEventListener('keydown', event => {
    if (event.key.toLowerCase() === 'f' && event.shiftKey && (event.ctrlKey || event.metaKey) &&
        !document.querySelector('dialog[open]')) {
      event.preventDefault();
      launchGlobalSearch();
    }
  });
  window.plexGlobalSearch = reply => {
    if (!globalDialog.open || reply.id !== globalSequence) return;
    const labels = {movie:titles.movie, show:titles.show, episode:'Episodes', album:'Albums',
                    track:'Tracks', toolDrive:titles.toolDrive, downloads:titles.downloads};
    const groups = reply.groups || [];
    globalStatus.textContent = reply.failed ? 'Some results could not be loaded.' : (groups.length ? '' : 'No matches.');
    globalResults.replaceChildren(...groups.map(group => {
      const section = node('section');
      section.append(node('h3', labels[group.kind]));
      for (const row of group.rows) {
        const button = node('button');
        button.append(node('strong', row.title), node('small', row.subtitle || ''));
        button.onclick = () => openGlobalResult(group.kind, row);
        section.append(button);
      }
      return section;
    }));
  };

  function reportArchiveBounds() {
    const visible = archiveOpen && !document.querySelector('dialog[open]');
    const {left, top, width, height} = toolDrivePanel.getBoundingClientRect();
    const unit = (value, size) => Math.round(value * 10000 / Math.max(1, size));
    host({action:'toolDrivePanel', visible, pause:!archiveOpen, left:unit(left,innerWidth), top:unit(top,innerHeight),
          width:unit(width,innerWidth), height:unit(height,innerHeight),
          entry:archiveEntry, motion:archiveMotion, appearance:archiveAppearance()});
  }
  function archiveAppearance() {
    const root = document.documentElement;
    const appearance = getComputedStyle(root);
    const value = name => appearance.getPropertyValue('--' + name).trim();
    const channels = value('custom-tint-rgb');
    const tint = root.dataset.glassTint === 'none' ? '' : channels ? `rgb(${channels})` : value('accent');
    const gradient = root.hasAttribute('data-animated-gradient') ? {
      motion:root.dataset.gradientMotion, duration:value('gradient-duration'), dimming:value('gradient-dimming'),
      colors:[1,2,3].map(index => value('gradient-color-' + index))
    } : null;
    return {title:titles.toolDrive, text:value('text'), accent:value('accent'), gradient,
            density:value('glass-density'), tint,
            background:value('panel'), hover:root.hasAttribute('data-glass-hover')};
  }
  function openArchive(open) {
    const entering = open && !archiveOpen;
    if (open) {
      showMusic();
      if (downloadsOpen) openDownloads(false);
      window.windowsPlayback?.action({action:'pause'});
    }
    archiveOpen = open;
    document.documentElement.toggleAttribute('data-tool-drive-open', open);
    window.showToolDriveTransport?.(open);
    toolDrivePanel.hidden = !open;
    if (entering) {
      archiveEntry++;
      window.interfaceMotion.show(toolDrivePanel, ['toolDrive'], motion => { archiveMotion = motion; });
    }
    present();
    reportArchiveBounds();
    if (!open) window.renderMusicPage?.();
  }
  get('tool-drive').onclick = () => {
    rememberSection('toolDrive');
    openArchive(true);
  };
  new ResizeObserver(() => { if (archiveOpen) reportArchiveBounds(); }).observe(toolDrivePanel);
  new MutationObserver(() => { if (archiveOpen) reportArchiveBounds(); })
    .observe(document.body, {subtree:true, attributes:true, attributeFilter:['open']});
  new MutationObserver(() => { if (archiveOpen) reportArchiveBounds(); })
    .observe(document.documentElement, {attributes:true, attributeFilter:['style', 'data-glass-hover', 'data-glass-tint', 'data-artwork-colors', 'data-animated-gradient', 'data-gradient-motion']});
  function resumeArchive() {
    if (preferredKind === 'toolDrive') openArchive(true);
    if (preferredKind === 'downloads') openDownloads(true);
  }
  window.addEventListener('DOMContentLoaded', resumeArchive, {once:true});

  function openDownloads(open) {
    if (open) {
      showMusic();
      if (archiveOpen) openArchive(false);
    }
    downloadsOpen = open;
    document.documentElement.toggleAttribute('data-downloads-open', open);
    downloadsPanel.hidden = !open;
    present();
    if (open) host({action:'offlineList'});
    else window.renderMusicPage?.();
  }
  get('downloads').onclick = () => {
    rememberSection('downloads');
    openDownloads(true);
  };
  let downloadedItems = [];
  let removeID = '';
  const removeDialog = get('remove-download');
  get('remove-download-cancel').onclick = () => removeDialog.close();
  get('remove-download-confirm').onclick = () => {
    if (removeID) host({action:'offlineRemove', media:removeID});
    removeDialog.close();
  };
  get('downloads-cancel').onclick = () => host({action:'offlineCancel'});
  get('downloads-search').oninput = renderDownloads;
  window.offlineState = reply => {
    downloadedItems = reply.items || [];
    if (requestedMovieDownload) showMovieText(get('movie-download-status'), reply.message || '');
    get('downloads-status').textContent = reply.message || '';
    get('downloads-cancel').hidden = !reply.busy;
    const progress = get('downloads-progress');
    progress.hidden = !reply.busy;
    if (Number.isFinite(reply.progress)) progress.value = reply.progress;
    else progress.removeAttribute('value');
    const queue = get('downloads-queue');
    queue.replaceChildren();
    for (const job of [...(reply.pending || []), ...(reply.failed || [])]) {
      const line = node('div');
      line.append(node('span', job.title + ' · ' + (job.error || 'Queued')));
      if (job.error) {
        const retry = node('button', 'Retry');
        retry.onclick = () => host({action:'offlineRetry', job:job.id});
        line.append(retry);
      }
      const dismiss = node('button', job.error ? 'Dismiss' : 'Cancel');
      dismiss.onclick = () => host({action:'offlineDismiss', job:job.id});
      line.append(dismiss);
      queue.append(line);
    }
    renderDownloads();
  };
  window.offlineError = message => {
    if (requestedMovieDownload) showMovieText(get('movie-download-status'), message);
    get('downloads-status').textContent = message;
  };
  function playDownload(row) {
    const player = window.windowsPlayback;
    if (row.kind === 'music') player.prepareAudio();
    else player.action({action:'pause'});
    host({action:row.kind === 'music' ? 'offlinePlay' : 'offlineVideo', media:row.id, title:row.title});
  }
  function renderDownloads() {
    const query = get('downloads-search').value.trim().toLocaleLowerCase();
    const items = downloadedItems.filter(row => [row.title,row.detail].join(' ').toLocaleLowerCase().includes(query));
    get('downloads-empty').hidden = downloadedItems.length > 0;
    const section = get('downloads-items');
    section.replaceChildren();
    for (const [type, label] of [['music','Music'], ['movie','Movies'], ['episode','TV Shows']]) {
      const rows = items.filter(row => row.kind === type);
      if (!rows.length) continue;
      const heading = document.createElement('h2');
      heading.textContent = label;
      section.append(heading);
      for (const row of rows) {
        const item = document.createElement('article');
        const play = document.createElement('button');
        play.textContent = row.title + (row.resume >= 5 ? ' · Resume' : '') + (row.detail ? ' · ' + row.detail : '');
        play.onclick = () => playDownload(row);
        const remove = document.createElement('button');
        remove.textContent = 'Remove';
        remove.setAttribute('aria-label', 'Remove ' + row.title);
        remove.onclick = () => {
          removeID = row.id;
          get('remove-download-name').textContent = row.title;
          removeDialog.showModal();
        };
        item.append(play, remove);
        section.append(item);
      }
    }
  }
  get('video-download').onclick = () => {
    if (!activeItem || !activeScope) return;
    host({action:'offlineDownloadVideo', item:activeItem.key, library:activeScope.library,
          kind:activeItem.type, title:activeItem.title, detail:activeItem.subtitle, version:selectedVersion});
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
    if (!selectedDetail) window.interfaceMotion.show(browser, ['video', kind, library, current?.key]);
    if (selectedDetail?.type === 'show') {
      const season = current?.type === 'season';
      get('show-all-seasons').hidden = !season;
      get('show-browse-title').textContent = season ? current.title : 'Seasons';
    }
    get('video-title').textContent = current?.title || titles[kind];
    search.placeholder = 'Search ' + titles[kind];
    search.setAttribute('aria-label', search.placeholder);
    search.hidden = Boolean(current) || !library;
    search.disabled = !libraryReady;
    get('video-back').hidden = !current;
    const summary = get('video-summary');
    summary.textContent = selectedDetail?.key === current?.key ? '' : current?.summary || '';
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
    renderWatch();
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
      tile.videoItem = row;
      tile.disabled = !interactive;
      const poster = document.createElement('span');
      poster.className = 'video-poster';
      const typeIcon = document.createElement('span');
      typeIcon.textContent = '▣';
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
      const subtitle = document.createElement('small');
      subtitle.className = 'video-subtitle';
      subtitle.textContent = row.subtitle || '';
      labels.append(subtitle);
      const badge = document.createElement('small');
      badge.className = 'watched-badge';
      badge.textContent = 'Watched';
      badge.hidden = !watchRecords.get(row.key)?.watched;
      labels.append(badge);
      if (row.type === 'episode') {
        const nextEpisode = node('small', 'Next Unwatched');
        nextEpisode.className = 'next-episode';
        const progress = node('progress');
        progress.className = 'episode-progress';
        progress.max = 1;
        progress.setAttribute('aria-label', 'Episode progress');
        labels.append(nextEpisode, progress);
      }
      tile.append(poster, labels);
      tile.onclick = () => {
        if (['movie','show','episode'].includes(row.type)) openDetails(row, tile);
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

  function setMovieArt(image, source) {
    image.hidden = !source || !/^\/art\/[a-f0-9]{32}$/.test(source);
    image.onerror = () => { image.hidden = true; };
    if (image.hidden) image.removeAttribute('src');
    else image.src = source;
  }

  function showMovieText(element, text) {
    element.textContent = text;
    element.hidden = !text;
  }

  function updateMovieActions() {
    if (!selectedDetail || selectedDetail.type === 'show') return;
    const watch = watchFor(selectedDetail);
    const resume = watch && !watch.watched && watch.seconds >= 5;
    get('movie-play').textContent = resume ? 'Resume' : (selectedDetail.type === 'episode' ? 'Play Episode' : 'Play Movie');
    get('movie-watch').textContent = watch?.watched ? 'Mark Unwatched' : 'Mark Watched';
    showMovieText(get('movie-resume'), resume ? 'Continue at ' + watchTime(watch.seconds) : '');
  }

  function openDetails(item, opener) {
    if (item.type === 'episode' && selectedDetail?.type === 'show') {
      showBeforeEpisode = {item:selectedDetail, opener:movieOpener, metadata:currentDetailMetadata, scroll:moviePage.scrollTop};
    }
    if (item.type === 'show') {
      tvListing = {nodes:[...tiles.childNodes], keys:[...rendered], next, offset:listOffset,
        message:status.textContent, scroll:listingContent.scrollTop, busy};
      get('show-browse').append(listingContent);
      parent = [item];
    }
    presentDetails(item, opener);
    requestVideoDetails();
    if (item.type === 'show') browse();
  }

  function presentDetails(item, opener, metadata) {
    selectedDetail = item;
    currentDetailMetadata = metadata;
    requestedMovieDownload = false;
    showMovieText(get('movie-download-status'), '');
    showMovieText(get('movie-detail-status'), '');
    get('movie-detail-retry').hidden = true;
    movieOpener = opener;
    const show = item.type === 'show';
    listingHeader.hidden = true;
    listingContent.hidden = get('show-browse').hidden = !show;
    for (const id of ['movie-play','movie-download','movie-watch','movie-resume']) get(id).hidden = show;
    get('movie-match').hidden = item.type === 'episode';
    moviePage.hidden = false;
    moviePage.dataset.kind = item.type;
    moviePage.scrollTop = 0;
    const backTo = item.type === 'episode' ? parent.at(-1)?.title || titles.show : titles[item.type];
    get('movie-back').textContent = '‹ Back to ' + backTo;
    get('movie-detail-title').textContent = item.title;
    updateMovieActions();
    renderVideoDetails(metadata || {});
    window.interfaceMotion.show(moviePage, ['videoDetails', library, item.key]);
    get('movie-detail-title').focus({preventScroll:true});
  }

  function closeDetails() {
    if (!selectedDetail) return;
    if (tvListing) {
      browser.insertBefore(listingContent, moviePage);
      parent = [];
    }
    tvListing = showBeforeEpisode = null;
    selectedDetail = currentDetailMetadata = null;
    ++videoDetailSequence;
    moviePage.hidden = true;
    listingHeader.hidden = listingContent.hidden = false;
  }

  get('movie-back').onclick = () => {
    const opener = movieOpener;
    if (showBeforeEpisode) {
      const {item, opener:showOpener, metadata, scroll} = showBeforeEpisode;
      showBeforeEpisode = null;
      ++videoDetailSequence;
      presentDetails(item, showOpener, metadata);
      if (!metadata) requestVideoDetails();
      moviePage.scrollTop = scroll;
    } else {
      const listing = tvListing;
      closeDetails();
      if (listing?.nodes.length && !listing.busy) {
        ++pending;
        busy = false;
        tiles.replaceChildren(...listing.nodes);
        rendered.clear();
        for (const key of listing.keys) rendered.add(key);
        listOffset = listing.offset;
        next = listing.next;
        status.textContent = listing.message;
        retry.hidden = true;
        loadMore.hidden = next === null;
        get('video-title').textContent = titles[kind];
        get('video-back').hidden = true;
        get('video-summary').hidden = true;
        search.hidden = !library;
        tiles.classList.remove('video-episodes');
        listingContent.scrollTop = listing.scroll;
        renderWatch();
      } else if (listing) browse();
      window.interfaceMotion.show(browser, ['video', kind, library, parent.at(-1)?.key]);
    }
    if (opener?.isConnected) opener.focus({preventScroll:true});
    else if (!selectedDetail) search.focus({preventScroll:true});
  };
  get('show-all-seasons').onclick = () => { if (parent.at(-1)?.type === 'season') { parent.pop(); browse(); } };
  moviePage.addEventListener('keydown', event => {
    if (event.key === 'Escape') {
      event.preventDefault();
      get(selectedDetail?.type === 'show' && parent.at(-1)?.type === 'season' ? 'show-all-seasons' : 'movie-back').click();
    }
  });
  get('movie-play').onclick = () => { if (selectedDetail && selectedDetail.type !== 'show') open(selectedDetail); };
  get('movie-match').onclick = () => { if (selectedDetail) openMatch(selectedDetail); };
  get('movie-download').onclick = () => {
    if (!selectedDetail || selectedDetail.type === 'show') return;
    requestedMovieDownload = true;
    host({action:'offlineDownloadVideo', item:selectedDetail.key, library,
      kind:selectedDetail.type, title:selectedDetail.title, detail:selectedDetail.subtitle, version:-1});
  };
  get('movie-watch').onclick = () => {
    if (!selectedDetail || selectedDetail.type === 'show') return;
    const {key, type, title, subtitle, thumb} = selectedDetail;
    if (watchFor(selectedDetail).watched) {
      markUnwatched(selectedDetail, watchContext());
      return;
    } else {
      watchRecords.set(key, {...selectedDetail, watched:true, seconds:0});
      host({action:'videoWatchUpdate', id:++watchSequence, ...watchContext(), item:key,
        type, title, subtitle, artwork:thumb, watched:true, seconds:0});
    }
    renderWatch();
  };

  function requestVideoDetails() {
    if (!selectedDetail) return;
    showMovieText(get('movie-detail-status'), '');
    get('movie-detail-retry').hidden = true;
    host({action:'videoDetails', id:++videoDetailSequence, item:selectedDetail.key, type:selectedDetail.type, ...watchContext()});
  }

  function renderVideoDetails(details) {
    get('movie-facts').textContent = [selectedDetail.type === 'episode' ? selectedDetail.subtitle : details.year || selectedDetail.subtitle, details.minutes ? details.minutes + ' min' : '',
      details.classification].filter(Boolean).join('  ·  ');
    setMovieArt(get('movie-backdrop'), details.backdrop);
    setMovieArt(get('movie-poster'), details.thumbnail || selectedDetail.artwork);
    showMovieText(get('movie-genres'), (details.genres || []).join(' · '));
    const synopsis = get('movie-synopsis');
    const summary = details.summary || selectedDetail.summary || '';
    synopsis.hidden = !summary;
    synopsis.querySelector('p').textContent = summary;
    const credits = get('movie-credits'), formats = get('movie-formats');
    credits.hidden = !details.credits?.length;
    credits.querySelector('ul').replaceChildren(...(details.credits || []).map(credit => {
      const li = document.createElement('li'), image = document.createElement('img');
      image.alt = '';
      if (/^https:\/\/(?:image\.tmdb\.org\/t\/p\/w185\/[A-Za-z0-9_-]+|metadata-static\.plex\.tv\/(?:[a-f0-9]\/)?people\/[a-f0-9]+)\.(?:jpe?g|png|webp)$/.test(credit.photo)) {
        image.referrerPolicy = 'no-referrer';
        image.loading = 'lazy';
        image.src = credit.photo;
      } else setMovieArt(image, credit.photo);
      const initials = document.createElement('span');
      initials.className = 'movie-credit-symbol';
      initials.textContent = credit.name.trim().split(/\s+/).slice(0,2).map(word => word[0]).join('');
      initials.setAttribute('aria-hidden', 'true');
      if (image.hidden) li.append(initials);
      else {
        image.onerror = () => image.replaceWith(initials);
        li.append(image);
      }
      const name = document.createElement('strong'), role = document.createElement('small');
      name.textContent = credit.name;
      role.textContent = credit.role;
      if (/^[0-9]+$/.test(credit.id)) {
        const button = node('button', credit.name);
        button.onclick = () => launchGlobalSearch(credit);
        li.append(button, role);
      } else li.append(name, role);
      return li;
    }));
    formats.hidden = !details.formats?.length;
    formats.querySelector('ul').replaceChildren(...(details.formats || []).map(format => {
      const li = document.createElement('li');
      li.textContent = format;
      return li;
    }));
  }

  get('movie-detail-retry').onclick = requestVideoDetails;
  window.plexVideoDetails = reply => {
    if (!selectedDetail || reply.id !== videoDetailSequence || reply.key !== selectedDetail.key) return;
    showMovieText(get('movie-detail-status'), reply.error || '');
    get('movie-detail-retry').hidden = !reply.error;
    if (!reply.error) { currentDetailMetadata = reply; renderVideoDetails(reply); }
  };

  function open(item) {
    activeItem = item;
    activeScope = watchContext();
    selectedVersion = -1;
    versionField.hidden = true;
    const watch = watchFor(item);
    lastSaved = watch.watched ? 0 : watch.seconds || 0;
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

  let hideExitTimer;
  function revealFullscreenExit() {
    clearTimeout(hideExitTimer);
    restore.hidden = false;
    hideExitTimer = setTimeout(() => { restore.hidden = true; }, 3000);
  }

  dialog.addEventListener('pointermove', event => {
    if (dialog.dataset.display === 'fullscreen' && event.pointerType !== 'touch') revealFullscreenExit();
  });

  window.plexVideoDisplay = display => {
    if (!dialog.open) return;
    if (display === 'inline') delete dialog.dataset.display;
    else dialog.dataset.display = display;
    video.controls = display !== 'floating';
    clearTimeout(hideExitTimer);
    restore.hidden = display !== 'fullscreen';
    if (display === 'fullscreen') {
      revealFullscreenExit();
      video.focus();
    }
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
    subtitleMode = subtitleDefault.value === 'automatic' ? 'automatic' : 'off';
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
      type:activeItem.type, version:selectedVersion, subtitles:subtitleMode});
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
        advance:Boolean(source.canAdvance), versions:(source.versions || []).length > 1, subtitles:subtitleMode});
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
    for (let index = 0; index < video.textTracks.length; index++)
      initializeSubtitle(video.textTracks[index]);
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
    clearTimeout(hideExitTimer);
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
