(() => {
  'use strict';
  const get = id => document.getElementById(id);
  const host = body => window.chrome.webview.postMessage(body);
  const player = window.windowsPlayback;
  const sectionNames = ['albums', 'artists', 'genres', 'tracks', 'playlists'];
  const sectionLabel = name => name[0].toUpperCase() + name.slice(1);
  const sectionPreference = 'musicroom-visible-sections';
  const lastSectionPreference = 'musicroom-last-music-section';
  let visibleSections = sectionNames;
  let server = '', library = '', kind = 'albums', group = null, album = null, playing = null;
  let tracks = [], entries = [], request = 0, playRequest = 0, offset = 0, busy = false, timer;
  let hasMore = false;
  let paging = false;
  let pageFailed = false;
  let pageSize = '60';
  let libraryLayout = 'grid';
  let albumPreviewSequence = 0;
  const albumPreviews = new Map();
  let listingQuery = '';
  let refreshAfterAlbum = false;
  const listingIDs = new Set();
  let caching = false;
  let artworkColors = false;
  let paletteSource = '';
  let palette = null;
  let paletteRequest = 0;
  const artworkPattern = /^\/art\/[a-f0-9]{32}$/;
  let playbackState = {};
  let nowQueue = [];
  let pins = [];
  let launchPreview = null;
  let queuedOpen = null;
  let replacingPreview = false;
  let pinnedKey = "";
  let pendingEnqueue = null;
  let enqueueSequence = 0;
  let dragIndex = null;
  let renderedQueue = null;
  let nowCover = null;
  let nowIndex = null;
  // Pixel coordinates shared with the Apple asset sheet.
  const wordmarkRegions = new Map([
    ['music', [722, 251, 684, 210]], ['musicBold', [645, 609, 810, 193]],
    ['plex', [0, 1255, 1024, 332, 1745]], ['plex2022', [1030, 1255, 1000, 461, 1745]],
    ['napster', [0, 1085, 707, 156]], ['iTunes', [720, 1085, 565, 144]],
    ['realJukebox', [0, 2206, 1000, 248, 2508]], ['realJukeboxPlus', [1020, 2206, 1000, 300, 2508]],
    ['realPlayer', [0, 2808, 471, 146, 2988]], ['realPlayerBasic', [520, 2808, 482, 175, 2988]],
    ['realPlayerPlus', [1040, 2808, 471, 176, 2988]]
  ]);
  const wordmarkSheet = new Image();
  const spotifySheet = new Image();
  const spotifyLogoRegion = [48, 13, 915, 915];
  const spotifyWordmarkRegion = [1149, 212, 2235, 596];
  let spotifyLogoURL = '';
  function loadSpotifySheet() {
    if (!spotifySheet.getAttribute('src')) spotifySheet.src = 'HeaderMarks/spotify-brand.png';
  }
  const pageEnd = get('page-end');
  const pageObserver = new IntersectionObserver(rows => {
    if (!album && hasMore && !busy && !pageFailed && rows.some(row => row.isIntersecting)) browse(true);
  }, {root:get('scroll')});
  const bands = ['bass', 'mid', 'treble'];
  const eqPresets = {flat:[0, 0, 0], bassBoost:[8, 0, 2], vocal:[-3, 6, 1], bright:[-1, 1, 7]};
  const node = (tag, text = '', cls = '') => {
    const el = document.createElement(tag);
    el.textContent = text;
    el.className = cls;
    return el;
  };
  const button = (label, action, cls = '') => {
    const el = node('button', label, cls);
    el.type = 'button';
    el.onclick = action;
    return el;
  };
  function time(input) {
    const value = Number(input);
    const secs = Number.isFinite(value) ? Math.max(0, Math.floor(value)) : 0;
    return Math.floor(secs / 60) + ':' + String(secs % 60).padStart(2, '0');
  }
  const layout = document.documentElement;
  const separator = get('sidebar-resize');
  const sidebarWidth = () => Math.round(separator.getBoundingClientRect().left - document.body.getBoundingClientRect().left);
  let sidebarDrag = null;
  let savedSidebarWidth = 0;

  function sidebarMaximum() {
    return Math.max(164, Math.min(420, window.innerWidth - 408));
  }
  function updateSidebar(width = savedSidebarWidth) {
    if (width) layout.style.setProperty('--sidebar-width', Math.max(164, Math.min(420, Math.round(width))) + 'px');
    else layout.style.removeProperty('--sidebar-width');
    separator.setAttribute('aria-valuemin', '164');
    separator.setAttribute('aria-valuemax', String(sidebarMaximum()));
    separator.setAttribute('aria-valuenow', String(sidebarWidth()));
  }
  function saveSidebar(width) {
    savedSidebarWidth = width ? Math.max(164, Math.min(sidebarMaximum(), Math.round(width))) : 0;
    updateSidebar();
    try { localStorage.setItem('musicroom-sidebar-width', String(savedSidebarWidth)); } catch {}
  }
  separator.addEventListener('pointerdown', event => {
    if (event.button !== 0 || sidebarDrag) return;
    separator.setPointerCapture(event.pointerId);
    sidebarDrag = {id:event.pointerId, x:event.clientX, width:sidebarWidth()};
    layout.dataset.sidebarDragging = '';
  });
  separator.addEventListener('pointermove', event => {
    if (sidebarDrag?.id !== event.pointerId) return;
    updateSidebar(Math.max(164, sidebarDrag.width + event.clientX - sidebarDrag.x));
  });
  separator.addEventListener('pointerup', event => {
    if (sidebarDrag?.id !== event.pointerId) return;
    if (event.clientX !== sidebarDrag.x) saveSidebar(Math.max(164, sidebarDrag.width + event.clientX - sidebarDrag.x));
    finishSidebarDrag();
  });
  function finishSidebarDrag() {
    sidebarDrag = null;
    delete layout.dataset.sidebarDragging;
    updateSidebar();
  }
  separator.addEventListener('lostpointercapture', finishSidebarDrag);
  separator.addEventListener('dblclick', () => saveSidebar(0));
  separator.addEventListener('keydown', event => {
    const keys = {ArrowLeft:sidebarWidth() - 16, ArrowRight:sidebarWidth() + 16, Home:164, End:sidebarMaximum()};
    if (!Object.hasOwn(keys, event.key)) return;
    event.preventDefault();
    saveSidebar(keys[event.key]);
  });
  window.addEventListener('resize', () => updateSidebar());

  const artworkSizeControls = {'library-artwork-size':'libraryArtwork', 'video-poster-size':'videoPosterSize'};

  function selectArtworkSize(control, value) {
    const size = ['small','large','extraLarge'].includes(value) ? value : 'medium';
    layout.dataset[artworkSizeControls[control]] = size;
    get(control).value = size;
    try { localStorage.setItem('musicroom-' + control, size); } catch {}
  }

  function cover(item) {
    const frame = node('div', '', 'cover');
    frame.setAttribute('aria-hidden', 'true');
    frame.append(node('span', '', 'fallback'));
    if (artworkPattern.test(item.artwork || '')) {
      const img = new Image();
      img.alt = '';
      img.loading = 'lazy';
      img.addEventListener('error', () => img.remove(), {once:true});
      img.src = item.artwork;
      frame.append(img);
    }
    return frame;
  }
  function status(text) {
    get('message').textContent = text;
    get('message').hidden = !text;
  }
  function browse(append = false, keepPreview = false) {
    if (launchPreview || !library || (append && busy)) return;
    paging = append;
    pageFailed = false;
    album = null;
    refreshAfterAlbum = false;
    if (!append) {
      offset = 0;
      replacingPreview = keepPreview;
      if (!keepPreview) entries = [];
      listingIDs.clear();
      listingQuery = group ? '' : get('search').value;
      hasMore = false;
      if (!keepPreview) get('grid').replaceChildren();
    }
    busy = true;
    render();
    if (!keepPreview) status('Loading library…');
    requestPage();
  }
  function requestPage() {
    host({action:'browse', id:++request, kind, query:listingQuery, group:group?.id, offset,
          pageSize:pageSize === 'all' ? 120 : Number(pageSize)});
  }
  function open(item) {
    if (launchPreview) {
      queuedOpen = {item, server:launchPreview.server, library:launchPreview.library};
      status('Opening ' + item.title + ' when Plex reconnects…');
      if (!launchPreview.waiting) host({action:'servers'});
      return;
    }
    replacingPreview = false;
    clearTimeout(timer);
    if (item.kind === 'artist' || item.kind === 'genre') {
      group = item;
      browse();
      return;
    }
    album = item;
    paging = false;
    tracks = [];
    busy = true;
    render();
    status('Loading tracks…');
    host({action:'album', id:++request, album:item.id});
  }
  function actions(label, entries) {
    const menu = node('details', '', 'queue-actions');
    const summary = node('summary', '⋯');
    summary.setAttribute('aria-label', label);
    const commands = node('div', '', 'queue-action-list');
    for (const [title, action] of entries) {
      commands.append(button(title, () => { menu.open = false; action(); }));
    }
    menu.append(summary, commands);
    return menu;
  }
  function libraryQueueActions(item, track, trackTitle, trackID, playlistCommands = []) {
    const commands = [];
    if (track !== undefined || item.kind !== 'artist') {
      commands.push(['Play Next', () => enqueueItem(item, true, track)],
        ['Add to Queue', () => enqueueItem(item, false, track)]);
    }
    const key = trackID || (item.kind === 'track' ? item.id : undefined);
    if (key || ['album', 'playlist'].includes(item.kind)) {
      commands.push(['Download', () => host({action:'offlineDownloadMusic', item:key || item.id,
        kind:key ? 'track' : item.kind, title:trackTitle || item.title, detail:item.artist || ''})]);
    }
    if (key) commands.push(['Add to Playlist', () => editPlaylist(key, trackTitle || item.title)]);
    if (track === undefined && ['album', 'artist', 'playlist'].includes(item.kind)) {
      commands.push([pins.some(pin => pin.id === item.id) ? 'Unpin' : 'Pin',
        () => host({action:'togglePin', item:item.id})]);
    }
    return actions('Actions for ' + (track === undefined ? item.title : trackTitle || tracks[track]?.title || 'track'),
      commands.concat(playlistCommands));
  }
  const playlistDialog = get('playlist-editor');
  const playlistChoices = get('playlist-editor-choices');
  const playlistForm = get('playlist-editor-form');
  const playlistName = get('playlist-editor-name');
  const playlistStatus = get('playlist-editor-status');
  const playlistClose = get('playlist-editor-close');
  let playlistSequence = 0;
  let playlistEdit = null;

  function editPlaylist(track, title) {
    if (!server || !library || launchPreview || playlistDialog.open) return;
    playlistEdit = {id:++playlistSequence, server, library, track, saving:false};
    get('playlist-editor-title').textContent = track ? 'Add to Playlist' : 'New Playlist';
    get('playlist-editor-track').textContent = title || '';
    get('playlist-editor-track').hidden = !track;
    playlistChoices.replaceChildren();
    playlistChoices.hidden = !track;
    playlistName.value = '';
    playlistForm.hidden = false;
    playlistClose.textContent = 'Cancel';
    setPlaylistSaving(false);
    playlistStatus.textContent = '';
    playlistDialog.showModal();
    if (track) loadPlaylistChoices();
    else playlistName.focus();
  }

  function loadPlaylistChoices() {
    playlistChoices.textContent = 'Finding playlists…';
    host({action:'editableMusicPlaylists', ...playlistEdit});
  }

  window.musicEditablePlaylists = reply => {
    if (!playlistDialog.open || reply.id !== playlistEdit?.id) return;
    if (reply.error) {
      playlistChoices.replaceChildren(node('p', reply.error), button('Retry Playlists', loadPlaylistChoices));
    } else if (reply.choices.length) {
      playlistChoices.replaceChildren(...reply.choices.map(row => button(row.title, () => savePlaylist(row.key))));
    } else {
      playlistChoices.textContent = 'No editable music playlists on this server.';
    }
    setPlaylistSaving(playlistEdit.saving);
  };

  function setPlaylistSaving(saving) {
    playlistEdit.saving = saving;
    playlistClose.disabled = playlistName.disabled = get('playlist-editor-create').disabled = saving;
    for (const choice of playlistChoices.querySelectorAll('button')) choice.disabled = saving;
  }

  function savePlaylist(playlist) {
    if (!playlistEdit || playlistEdit.saving) return;
    const title = playlistName.value.trim();
    if (!playlist && !title) return;
    setPlaylistSaving(true);
    playlistEdit.target = playlist;
    playlistStatus.textContent = 'Saving to Plex…';
    host({action:'saveMusicPlaylist', ...playlistEdit, playlist, title});
  }

  get('new-playlist').onclick = () => editPlaylist();
  playlistClose.onclick = () => playlistDialog.close();
  playlistForm.onsubmit = event => { event.preventDefault(); savePlaylist(); };
  playlistDialog.addEventListener('close', () => { playlistEdit = null; });
  playlistDialog.addEventListener('cancel', event => { if (playlistEdit?.saving) event.preventDefault(); });
  window.musicPlaylistSaved = reply => {
    if (!playlistDialog.open || reply.id !== playlistEdit?.id) return;
    setPlaylistSaving(false);
    playlistStatus.textContent = reply.error || reply.message;
    if (reply.error) return;
    playlistChoices.hidden = playlistForm.hidden = true;
    playlistClose.textContent = 'Done';
    playlistClose.focus();
    if (album?.kind === 'playlist' && album.id === playlistEdit.target) open(album);
    else if (kind === 'playlists' && !album) browse();
  };

  let playlistTrackSequence = 0;
  let pendingPlaylistTrack = null;
  let draggedPlaylistTrack = null;

  function changePlaylistTrack(occurrence, target) {
    if (pendingPlaylistTrack || busy || !album || album.kind !== 'playlist' || !occurrence) return;
    const source = tracks.findIndex(track => track.playlistItemID === occurrence);
    if (source < 0) return;
    let after;
    if (target !== undefined) {
      const destination = tracks.findIndex(track => track.playlistItemID === target);
      if (destination < 0 || destination === source) return;
      const predecessor = source < destination ? destination : destination - 1;
      after = tracks[predecessor]?.playlistItemID;
      if (predecessor >= 0 && !after) return;
    }
    pendingPlaylistTrack = {id:++playlistTrackSequence, server, library, playlist:album.id};
    status('Saving playlist…');
    host({action:target === undefined ? 'removePlaylistTrack' : 'movePlaylistTrack',
      ...pendingPlaylistTrack, occurrence, after});
  }

  window.musicPlaylistTrackSaved = reply => {
    if (reply.id !== pendingPlaylistTrack?.id) return;
    const saved = pendingPlaylistTrack;
    pendingPlaylistTrack = null;
    if (saved.server !== server || saved.library !== library || saved.playlist !== album?.id) return;
    if (reply.error) status(reply.error);
    else {
      busy = true;
      status('Refreshing playlist…');
      host({action:'album', id:++request, album:album.id});
    }
  };

  function playlistTrackHandle(row, occurrence) {
    const handle = node('span', '☰', 'now-drag-handle');
    handle.draggable = true;
    handle.title = 'Drag to reorder';
    handle.setAttribute('aria-hidden', 'true');
    handle.addEventListener('dragstart', event => {
      if (pendingPlaylistTrack || busy) { event.preventDefault(); return; }
      draggedPlaylistTrack = occurrence;
      event.dataTransfer.effectAllowed = 'move';
      event.dataTransfer.setData('text/plain', occurrence);
    });
    handle.addEventListener('dragend', () => { draggedPlaylistTrack = null; });
    row.addEventListener('dragover', event => {
      if (!draggedPlaylistTrack || draggedPlaylistTrack === occurrence) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = 'move';
      row.classList.add('playlist-drop-target');
    });
    row.addEventListener('dragleave', event => {
      if (!row.contains(event.relatedTarget)) row.classList.remove('playlist-drop-target');
    });
    row.addEventListener('drop', event => {
      if (!draggedPlaylistTrack) return;
      event.preventDefault();
      row.classList.remove('playlist-drop-target');
      changePlaylistTrack(draggedPlaylistTrack, occurrence);
      draggedPlaylistTrack = null;
    });
    return handle;
  }

  function renderPins() {
    get('pinned-shelf').hidden = !pins.length || Boolean(album || group || get('search').value.trim());
    const key = JSON.stringify([Boolean(launchPreview),pins]);
    if (key === pinnedKey) return;
    pinnedKey = key;
    get('pinned-items').replaceChildren(...pins.map(item => libraryTile(item)));
  }
  function genreRow(item) {
    const row = button('', () => open(item), 'genre-row');
    const chevron = node('span', '›');
    chevron.setAttribute('aria-hidden', 'true');
    row.append(node('strong', item.title), chevron);
    return row;
  }
  function libraryTile(item) {
    const tile = button('', () => open(item), 'tile');
    const text = node('div', '', 'tile-text');
    text.append(node('strong', item.title));
    if (item.artist) text.append(node('small', item.artist));
    tile.append(cover(item), text);
    const cell = node('div', '', 'library-tile');
    cell.append(tile);
    if (!launchPreview && item.kind !== 'genre') cell.append(libraryQueueActions(item));
    return cell;
  }
  window.musicPins = reply => {
    pins = reply.pins || [];
    get('grid').replaceChildren();
    render();
  };
  function enqueueItem(item, playNext, track) {
    if (launchPreview || pendingEnqueue || pendingAlbum) return;
    const id = --enqueueSequence;
    pendingEnqueue = {id, item, playNext};
    status('Adding to the queue…');
    host({action:'enqueue', id, album:item.id, track});
  }
  window.musicEnqueued = reply => {
    if (reply.id !== pendingEnqueue?.id) {
      reply.tracks.forEach(player.releaseTrack);
      return;
    }
    const {item, playNext, startIndex} = pendingEnqueue;
    pendingEnqueue = null;
    if (startIndex !== undefined || !nowQueue.length || playbackState.status === 'finished') {
      nowQueue.forEach(player.releaseTrack);
      playing = item;
      const revision = player.reset(reply.context, 'plex');
      player.queue({...reply, origin:'plex'}, startIndex ?? 0, revision, null, startIndex !== undefined || playNext);
    } else player.enqueue(reply.tracks, playNext);
    status(startIndex !== undefined ? '' : playNext ? 'Added to Play Next.' : 'Added to the queue.');
  };
  window.musicEnqueueError = reply => {
    if (reply.id !== pendingEnqueue?.id) return;
    pendingEnqueue = null;
    status(reply.message);
  };
  const albumPreviewObserver = new IntersectionObserver(records => {
    for (const record of records) {
      if (!record.isIntersecting) continue;
      const target = record.target;
      albumPreviewObserver.unobserve(target);
      if (target.isConnected && !launchPreview && !replacingPreview) loadInlineAlbum(target);
    }
  }, {root:get('scroll')});

  function playLibraryRow(item, startIndex = 0) {
    if (launchPreview || replacingPreview || pendingEnqueue || pendingAlbum) return;
    player.prepareAudio();
    const id = --enqueueSequence;
    pendingEnqueue = {id, item, startIndex};
    host({action:'enqueue', id, album:item.id});
  }
  window.openGlobalMusicResult = item => {
    window.plexVideoExit();
    selectSection(item.kind === 'track' ? 'tracks' : 'albums');
    if (item.kind === 'track') playLibraryRow(item);
    else open(item);
  };
  function loadInlineAlbum(target) {
    const id = ++albumPreviewSequence;
    albumPreviews.set(id, target);
    target.replaceChildren(node('p','Loading tracks…'));
    host({action:'albumPreview', id, album:target.album.id});
  }
  window.musicAlbumPreview = reply => {
    const target = albumPreviews.get(reply.id);
    albumPreviews.delete(reply.id);
    if (!target?.isConnected) return;
    if (reply.error || !reply.tracks?.length) {
      target.replaceChildren(button('Retry Tracks', () => loadInlineAlbum(target)));
      return;
    }
    const item = target.album;
    target.replaceChildren(...reply.tracks.map((track,index) => {
      const row = trackColumns(track, () => playLibraryRow(item,index), true, item.artist);
      const cell = node('div','','compact-track');
      cell.append(row, libraryQueueActions(item,index,track.title,track.plexID));
      return cell;
    }));
  };
  function trackColumns(track, action, grouped = false, artist = track.artist || '') {
    const row = button('', action, 'track-columns' + (grouped ? ' grouped-track' : ''));
    const number = track.number > 0 ? (track.disc > 1 ? track.disc + '.' : '') + track.number : '–';
    const title = node('strong', track.title);
    if (track.popular) {
      const badge = node('span',' 🔥','popular-track');
      badge.setAttribute('aria-label','Popular track');
      title.append(badge);
    }
    row.append(node('span',number,'track-index'), title, node('span',artist,'track-artist'));
    if (!grouped) row.append(node('span',track.album || '','track-album'));
    row.append(node('span',track.durationSeconds > 0 ? time(track.durationSeconds) : '–','track-time'));
    return row;
  }
  function alternateTile(item, mode) {
    if (mode === 'albumTracks') {
      const card = node('article','','album-with-tracks');
      const list = node('div','','inline-album-tracks');
      list.album = item;
      list.append(node('p', launchPreview ? 'Reconnecting to Plex…' : 'Loading tracks…'));
      card.append(libraryTile(item), list);
      if (!launchPreview && !replacingPreview) albumPreviewObserver.observe(list);
      return card;
    }
    const cell = node('div','','compact-track');
    const row = item.kind === 'track'
      ? trackColumns(item, () => playLibraryRow(item))
      : button(item.title, () => open(item), 'compact-library-entry');
    cell.append(row);
    if (!launchPreview && item.kind !== 'genre') cell.append(libraryQueueActions(item));
    return cell;
  }
  function useLibraryLayout(value) {
    libraryLayout = ['albumTracks','trackList'].includes(value) ? value : 'grid';
    get('library-layout').value = libraryLayout;
    try { localStorage.setItem('musicroom-library-layout',libraryLayout); } catch {}
    get('grid').replaceChildren();
    render();
  }
  function renderMusicPage() {
    if (layout.hasAttribute('data-video-open') || layout.hasAttribute('data-tool-drive-open') ||
        layout.hasAttribute('data-downloads-open')) return;
    const panel = get('browser');
    if (panel.hidden) window.interfaceMotion.show(get('welcome'), ['welcome']);
    else window.interfaceMotion.show(panel, ['music', launchPreview?.library || library, kind, group?.id, album?.id]);
  }
  window.renderMusicPage = renderMusicPage;
  window.syncMusicSectionSelection = () => {
    const archiveOpen = layout.hasAttribute('data-tool-drive-open');
    for (const tab of sectionNames) get(tab).setAttribute('aria-pressed', String(!archiveOpen && kind === tab));
  };
  function render() {
    renderMusicPage();
    get('title').textContent = album?.title || group?.title || sectionLabel(kind);
    get('new-playlist').hidden = kind !== 'playlists' || Boolean(album || group);
    get('new-playlist').disabled = Boolean(launchPreview) || !library;
    get('search').hidden = Boolean(group || album);
    get('search').placeholder = 'Search ' + kind;
    get('search').setAttribute('aria-label', 'Search ' + kind);
    get('back').hidden = !group && !album;
    get('grid').hidden = Boolean(album);
    get('details').hidden = !album;
    const readyToPage = !album && hasMore && !busy;
    get('retry-page').hidden = !readyToPage || !pageFailed;
    pageEnd.hidden = !readyToPage || pageFailed;
    pageObserver.unobserve(pageEnd);
    if (!pageEnd.hidden) pageObserver.observe(pageEnd);
    window.syncMusicSectionSelection();
    renderPins();
    if (!album) {
      const grid = get('grid');
      const mode = kind === 'genres' && !group ? 'genreList' : libraryLayout === 'trackList' || (libraryLayout === 'albumTracks' && (kind === 'albums' || group))
        ? libraryLayout : 'grid';
      grid.classList.toggle('track-list', mode === 'grid' && kind === 'tracks' && !group);
      grid.dataset.layout = mode;
      get('library-track-headings').hidden = mode !== 'trackList' || kind !== 'tracks' || Boolean(group);
      const added = document.createDocumentFragment();
      for (const item of entries.slice(grid.childElementCount)) {
        if (mode === 'genreList') added.append(genreRow(item));
        else added.append(mode === 'grid' ? libraryTile(item) : alternateTile(item,mode));
      }
      grid.append(added);
      return;
    }
    get('library-track-headings').hidden = true;
    const heading = node('div', '', 'album-heading');
    const metadata = node('div');
    metadata.append(node('h2', album.artist || sectionLabel(album.kind)),
      node('p', [album.year > 0 ? album.year : '', album.genre].filter(Boolean).join(' · ')));
    const play = button('Play ' + sectionLabel(album.kind), () => playAlbum(0), 'primary');
    play.disabled = tracks.length === 0;
    metadata.append(play);
    if (tracks.length || ['album', 'playlist'].includes(album.kind)) metadata.append(libraryQueueActions(album));
    heading.append(cover(album), metadata);
    const list = node('div', '', 'tracks');
    tracks.forEach((track, index) => {
      const row = button('', () => playAlbum(index), 'track');
      const title = node('span', track.title);
      if (track.popular) {
        const badge = node('span', ' 🔥', 'popular-track');
        badge.title = 'Popular track';
        badge.setAttribute('aria-label', 'Popular track');
        title.append(badge);
      }
      row.append(node('span', String(track.number), 'number'), title, node('small', time(track.durationSeconds)));
      const entry = node('div', '', 'library-track');
      const commands = [];
      const occurrence = album.kind === 'playlist' && track.playlistItemID;
      if (occurrence) {
        entry.classList.add('playlist-track-editable');
        entry.append(playlistTrackHandle(entry, occurrence));
        const before = tracks[index - 1]?.playlistItemID;
        const after = tracks[index + 1]?.playlistItemID;
        if (before) commands.push(['Move Up', () => changePlaylistTrack(occurrence, before)]);
        if (after) commands.push(['Move Down', () => changePlaylistTrack(occurrence, after)]);
        commands.push(['Remove from Playlist', () => changePlaylistTrack(occurrence)]);
      }
      entry.append(row, libraryQueueActions(album, index, track.title, track.plexID, commands));
      list.append(entry);
    });
    get('details').replaceChildren(heading, list);
  }
  function playAlbum(index) {
    if (!album || !tracks[index] || pendingEnqueue || pendingAlbum) return;
    player.prepareAudio();
    playRequest = ++request;
    pendingAlbum = album;
    host({action:'play', id:playRequest, album:album.id, index});
  }
  let pendingAlbum = null;
  window.musicQueue = reply => {
    if (reply.id !== playRequest || !pendingAlbum) return;
    playing = pendingAlbum;
    pendingAlbum = null;
    nowQueue = reply.tracks;
    const revision = player.reset(reply.context, 'plex');
    footerKey = '';
    player.queue(reply, reply.startIndex, revision, null);
  };
  window.offlineQueue = reply => {
    pendingAlbum = pendingEnqueue = null;
    playing = {title:reply.title, artist:reply.artist, kind:'offline'};
    nowQueue = reply.tracks;
    footerKey = '';
    const revision = player.reset(reply.context, 'offline');
    player.queue(reply, 0, revision, null);
  };
  window.musicEntries = reply => {
    if (reply.id !== request || album) return;
    if (replacingPreview) {
      replacingPreview = false;
      entries = [];
      get('grid').replaceChildren();
    }
    const oldCount = entries.length;
    for (const row of reply.entries) if (!listingIDs.has(row.id)) { entries.push(row); listingIDs.add(row.id); }
    hasMore = reply.more && reply.next > offset && entries.length > oldCount;
    offset = reply.next;
    if (pageSize === 'all' && hasMore) {
      paging = true;
      requestPage();
      return;
    }
    paging = false;
    busy = false;
    status(entries.length ? '' : 'No matches in this library.');
    render();
  };
  window.musicAlbum = reply => {
    if (reply.id !== request || !album) return;
    tracks = reply.tracks;
    busy = false;
    status(tracks.length ? '' : album.kind === 'playlist' ? 'This playlist has no playable tracks.' :
      'This item has no directly playable tracks.');
    render();
  };
  window.musicError = reply => {
    if (reply.id !== request) return;
    busy = false;
    pageFailed = paging;
    paging = false;
    pendingAlbum = null;
    status(reply.message);
    render();
  };
  const options = (control, rows, value, empty) => {
    control.replaceChildren(new Option(empty, ''), ...rows.map(row => new Option(row.name, row.id)));
    control.value = value;
  };
  window.macPlexState = state => {
    window.plexVideoState(state);
    get('cache-covers').disabled = !state.serverId;
    get('cover-library').textContent = state.serverId ? artworkCacheDescription : 'Choose a Plex server to cache artwork.';
    const connected = state.status === 'connected';
    const connecting = state.status === 'connecting';
    get('connect').hidden = connected || connecting;
    get('refresh-plex').hidden = !state.refreshAvailable;
    get('cancel').hidden = !connecting;
    get('settings-connect').hidden = connected || connecting;
    get('settings-cancel-plex').hidden = !connecting;
    get('server-label').hidden = !connected;
    get('disconnect').hidden = !connected;
    get('open-plex-settings').hidden = !connected || Boolean(state.libraryId);
    get('plex-settings-status').textContent = state.message;
    get('plex-settings-status').hidden = Boolean(state.libraryId) || !state.message;
    get('tool-drive-library-label').hidden = get('library-label').hidden = !connected || !state.libraries.length;
    get('welcome-title').textContent = connected ? 'Choose your music library' : 'Connect to Plex';
    get('connection-status').textContent = state.message;
    options(get('server'), state.servers, state.serverId, 'Choose server');
    options(get('library'), state.libraries, state.libraryId, 'Choose library');
    options(get('tool-drive-library'), state.libraries, state.toolDriveLibraryId || '', 'Choose library');
    const quick = get('quick-library');
    const previewLibrary = state.preview;
    const musicChoices = state.libraryId ? state.libraries :
      previewLibrary ? [{name:previewLibrary.name || 'Music', id:previewLibrary.library}] : [];
    quick.replaceChildren(...musicChoices.map(row => new Option(row.name, row.id)));
    quick.value = state.libraryId || previewLibrary?.library || '';
    quick.hidden = !musicChoices.length;
    quick.disabled = !state.libraryId || state.loadingLibraries;
    pins = state.pins || [];
    renderPins();
    const before = launchPreview;
    launchPreview = state.preview || null;
    get('browser').hidden = !state.libraryId && !launchPreview;
    get('welcome').hidden = !get('browser').hidden;
    if (get('browser').hidden) renderMusicPage();
    for (const tab of sectionNames) get(tab).disabled = get('browser').hidden;
    get('search').disabled = Boolean(launchPreview);
    get('retry-library').hidden = !launchPreview || launchPreview.waiting;
    if (launchPreview) {
      renderLaunchPreview();
      status(launchPreview.waiting && queuedOpen ? 'Opening ' + queuedOpen.item.title + ' when Plex reconnects…' :
        launchPreview.waiting ? [launchPreview.name, 'Reconnecting to Plex…'].filter(Boolean).join(' · ') : state.message);
      return;
    }
    if (server !== state.serverId || library !== state.libraryId) {
      server = state.serverId;
      library = state.libraryId;
      window.musicCoverCache({running:false, message:''});
      if (playlistDialog.open) playlistDialog.close();
      pendingPlaylistTrack = draggedPlaylistTrack = null;
      ++request;
      playing = album = group = pendingAlbum = null;
      nowQueue = [];
      pendingEnqueue = null;
      albumPreviews.clear();
      closePlaybackSheets();
      if (get('now-playing').open) get('now-playing').close();
      player.reset();
      const selection = queuedOpen;
      queuedOpen = null;
      if (library && selection?.server === server && selection.library === library) open(selection.item);
      else if (library) browse(false, Boolean(before?.library === library && before.server === server && entries.length));
      else { entries = []; get('grid').replaceChildren(); }
    } else if (before && library) {
      const selection = queuedOpen;
      queuedOpen = null;
      if (selection?.server === server && selection.library === library) open(selection.item);
      else browse(false, Boolean(before.server === server && before.library === library && entries.length));
    }
  };
  function renderLaunchPreview() {
    entries = launchPreview.listings?.[kind] || [];
    get('grid').replaceChildren();
    render();
  }
  get('retry-library').onclick = () => host({action:'servers'});
  function playingCover(state) {
    if (!playing) return '';
    const track = nowQueue[state.trackIndex];
    return (playing.kind !== 'playlist' && (!track?.collection || track.collection === playing.id)
      ? playing.artwork || state.artwork : state.artwork) || '';
  }
  function applyPalette() {
    const root = document.documentElement;
    root.toggleAttribute('data-artwork-colors', artworkColors && Boolean(palette));
    if (!palette) return;
    const blend = (gray, amount) => `rgb(${palette.map(value => Math.round(value * (1 - amount) + gray * amount)).join(' ')})`;
    root.style.setProperty('--artwork-accent', blend(255, 0.55));
    root.style.setProperty('--artwork-wash', blend(20, 0.67));
  }
  function pickPalette(image) {
    const canvas = document.createElement('canvas');
    canvas.width = canvas.height = 32;
    const context = canvas.getContext('2d');
    if (!context) return null;
    context.drawImage(image, 0, 0, 32, 32);
    const pixels = context.getImageData(0, 0, 32, 32).data;
    const bins = Array.from({length:64}, () => ({weight:0, totals:[0, 0, 0]}));
    for (let i = 0; i < pixels.length; i += 4) {
      if (pixels[i + 3] < 128) continue;
      const rgb = [pixels[i], pixels[i + 1], pixels[i + 2]];
      const high = Math.max(...rgb) / 255;
      const low = Math.min(...rgb) / 255;
      const weight = (0.08 + (high - low) * 3) * (0.3 + high);
      const key = (rgb[0] >> 6) * 16 + (rgb[1] >> 6) * 4 + (rgb[2] >> 6);
      bins[key].weight += weight;
      rgb.forEach((value, channel) => bins[key].totals[channel] += value * weight);
    }
    const best = bins.reduce((best, bin) => bin.weight > best.weight ? bin : best);
    return best.weight > 0 ? best.totals.map(value => value / best.weight) : null;
  }
  function updateArtworkColors(state) {
    const path = artworkColors ? playingCover(state) : '';
    const source = artworkPattern.test(path) ? path : '';
    if (source === paletteSource) return;
    paletteSource = source;
    const request = ++paletteRequest;
    palette = null;
    applyPalette();
    if (!source) return;
    const image = new Image();
    image.onload = () => {
      if (request !== paletteRequest) return;
      try { palette = pickPalette(image); } catch { palette = null; }
      applyPalette();
    };
    image.src = source;
  }
  function chooseArtworkColors(enabled) {
    artworkColors = enabled;
    get('artwork-colors').checked = enabled;
    get('animate-artwork-colors').disabled = !enabled;
    try { localStorage.setItem('musicroom-artwork-colors', enabled ? '1' : '0'); } catch {}
    updateArtworkColors(playbackState);
    applyPalette();
  }
  function chooseArtworkMotion(enabled) {
    layout.toggleAttribute('data-artwork-motion', enabled);
    get('animate-artwork-colors').checked = enabled;
    try { localStorage.setItem('musicroom-animate-artwork-colors', enabled ? '1' : '0'); } catch {}
  }
  let footerKey = '';
  let archiveTransportActive = false;
  let archiveTransportState = {};
  function archiveTransportCommand(command) { host({action:'toolDriveTransport', command}); }
  function footerCommand(command) {
    if (archiveTransportActive) archiveTransportCommand(command);
    else player.action(command);
  }
  function renderArchiveTransport() {
    const state = archiveTransportState;
    const key = JSON.stringify(['archive', state.visible, state.title, state.context, state.message]);
    if (key !== footerKey) {
      footerKey = key;
      const label = get('playing');
      if (state.visible) {
        const info = node('div');
        info.append(node('strong', state.title || 'Loading recording…'), node('small', state.context || ''));
        if (state.message) info.append(node('small', state.message));
        label.replaceChildren(info);
      } else label.textContent = 'Nothing playing';
    }
    get('playing').disabled = !state.visible;
    renderFooterControls(state, state.canToggle);
  }
  window.toolDriveTransport = state => {
    archiveTransportState = state || {};
    if (archiveTransportActive) {
      renderArchiveTransport();
      if (nowPlaying.open) {
        if (archiveTransportState.visible) renderArchiveNowPlaying();
        else nowPlaying.close();
      }
    }
  };
  window.showToolDriveTransport = active => {
    archiveTransportActive = active;
    if (active) renderArchiveTransport();
    else window.macPlayerState(playbackState);
  };
  window.macPlayerState = state => {
    nowQueue = player.queueItems;
    if (state.status === 'closed') playing = null;
    playbackState = state;
    const currentCover = playingCover(state);
    updateArtworkColors(state);
    if (archiveTransportActive) return;
    const track = nowQueue[state.trackIndex];
    const title = track?.title || state.title || playing?.title;
    const artist = track?.artist || playing?.artist;
    const albumTitle = track?.album || (playing?.kind === 'album' ? playing.title : '');
    const nextKey = JSON.stringify([playing?.id, title, artist, albumTitle, state.message, currentCover]);
    if (footerKey !== nextKey) {
      footerKey = nextKey;
      const label = get('playing');
      if (!playing) label.textContent = 'Nothing playing';
      else {
        const info = node('div');
        info.append(node('strong', title), node('small', [artist, albumTitle].filter(Boolean).join(' · ')));
        if (state.message) info.append(node('small', state.message));
        const indicator = node('span', '⌃', 'playing-indicator');
        indicator.setAttribute('aria-hidden', 'true');
        label.replaceChildren(cover({...playing, artwork:currentCover || playing.artwork}), info, indicator);
        if ('mediaSession' in navigator && typeof MediaMetadata !== 'undefined') {
          navigator.mediaSession.metadata = new MediaMetadata({
            title, artist: artist || '', album: albumTitle,
            artwork: artworkPattern.test(currentCover) ? [{src: new URL(currentCover, location.href).href}] : []
          });
        }
      }
    }
    get('playing').disabled = !playing;
    if (get('lyrics-sheet').open) updateLyrics(track);
    if (get('signal-path-sheet').open) renderSignalPath(track);
    if (get('now-playing').open) {
      if (playing) renderNowPlaying(state);
      else { closePlaybackSheets(); get('now-playing').close(); }
    }
    window.clickWheel.update(playing, state, cover);
    renderFooterControls(state, Boolean(playing));
  };
  function renderFooterControls(state, canToggle) {
    const active = state.status === 'playing';
    get('toggle').textContent = active ? '⏸' : '▶';
    get('toggle').setAttribute('aria-label', active ? 'Pause' : 'Play');
    get('toggle').disabled = !canToggle;
    get('previous').disabled = !canToggle || !state.canPrevious;
    get('next').disabled = !canToggle || !state.canNext;
    get('seek').disabled = !state.duration;
    get('seek').max = Math.max(1, state.duration || 0);
    if (document.activeElement !== get('seek')) get('seek').value = state.elapsed || 0;
    get('elapsed').textContent = time(state.elapsed);
  }
  const archiveEQInputs = [...document.querySelectorAll('[data-archive-eq]')];
  let archiveQueueKey = '';
  let archiveRevision;
  function setArchiveTools(active) {
    for (const id of ['archive-eq-toggle', 'archive-visualizer-toggle', 'archive-stop']) get(id).hidden = !active;
    for (const id of ['signal-path-button', 'lyrics-button']) get(id).hidden = active;
    get('jump-now-queue').textContent = active ? 'Tracklist' : 'Queue';
    get('now-queue-heading').textContent = active ? 'Tracklist' : 'Up Next';
    if (!active) {
      get('archive-eq').hidden = true;
      get('archive-eq-toggle').setAttribute('aria-expanded', 'false');
    }
  }
  function renderArchiveNowPlaying() {
    const state = archiveTransportState;
    get('now-title').textContent = state.title || 'Loading recording…';
    get('now-artist').textContent = state.context || '';
    get('now-album').textContent = '';
    renderNowTransport(state);
    get('now-play').disabled = !state.canToggle;
    if (state.revision !== archiveRevision) {
      archiveRevision = state.revision;
      get('archive-eq-preset').value = 'flat';
      for (const input of archiveEQInputs) {
        if (input.type === 'checkbox') input.checked = false;
        else input.value = 0;
      }
    }
    const tracks = state.tracks || [];
    const key = JSON.stringify(tracks);
    const queue = get('now-queue-list');
    if (key !== archiveQueueKey) {
      archiveQueueKey = key;
      queue.replaceChildren(...tracks.map((track, index) => {
        const row = node('li', '', 'now-queue-row');
        const entry = button(track.title, () => archiveTransportCommand({action:'playTrack', index}), 'now-queue-play');
        row.append(entry);
        return row;
      }));
    }
    for (const [index, row] of [...queue.children].entries()) {
      const entry = row.firstElementChild;
      if (index === state.trackIndex) entry.setAttribute('aria-current', 'true');
      else entry.removeAttribute('aria-current');
    }
  }
  function renderNowTransport(state) {
    const message = get('now-status');
    message.textContent = state.message || '';
    message.hidden = !state.message;
    const seek = get('now-seek');
    seek.max = Math.max(1, state.duration || 0);
    seek.disabled = !state.duration;
    if (document.activeElement !== seek) seek.value = state.elapsed || 0;
    get('now-elapsed').textContent = time(state.elapsed);
    get('now-duration').textContent = time(state.duration);
    get('now-duration').setAttribute('aria-label', 'Track duration');
    const active = state.status === 'playing';
    get('now-play').textContent = active ? '⏸' : '▶';
    get('now-play').setAttribute('aria-label', active ? 'Pause' : 'Play');
    get('now-prev').disabled = !state.canPrevious;
    get('now-next').disabled = !state.canNext;
    if (Number.isFinite(state.volume) && document.activeElement !== get('now-volume')) get('now-volume').value = state.volume;
  }
  function renderNowPlaying(state) {
    const track = nowQueue[state.trackIndex] || {};
    const path = playingCover(state);
    if (path !== nowCover) {
      nowCover = path;
      get('now-art').replaceChildren(cover({...playing, artwork:path}));
      const hasArtwork = artworkPattern.test(path);
      get('now-art').disabled = !hasArtwork;
      if (hasArtwork) get('now-playing').style.setProperty('--glass-artwork', 'url("' + path + '")');
      else get('now-playing').style.removeProperty('--glass-artwork');
      if (expandedArtwork.open) refreshExpandedArtwork();
    }
    get('signal-path-button').textContent = signalBadge(track.format);
    get('now-title').textContent = track.title || state.title || playing.title;
    get('now-artist').textContent = track.artist || playing.artist || '';
    get('now-album').textContent = track.album || (playing.kind === 'album' ? playing.title : '');
    get('now-play').disabled = false;
    renderNowTransport(state);
    const queue = get('now-queue-list');
    if (renderedQueue !== nowQueue) {
      const rows = document.createDocumentFragment();
      nowQueue.forEach((item, index) => {
        const row = node('li', '', 'now-queue-row');
        const drag = node('span', '☰', 'now-drag-handle');
        drag.draggable = true;
        drag.title = 'Drag to reorder';
        drag.setAttribute('aria-hidden', 'true');
        drag.addEventListener('dragstart', event => {
          dragIndex = index;
          event.dataTransfer.effectAllowed = 'move';
          event.dataTransfer.setData('text/plain', String(index));
        });
        drag.addEventListener('dragend', () => { dragIndex = null; });
        row.addEventListener('dragover', event => {
          if (dragIndex === null || dragIndex === index) return;
          event.preventDefault();
          event.dataTransfer.dropEffect = 'move';
          row.classList.add('drop-target');
        });
        row.addEventListener('dragleave', event => {
          if (!row.contains(event.relatedTarget)) row.classList.remove('drop-target');
        });
        row.addEventListener('drop', event => {
          event.preventDefault();
          row.classList.remove('drop-target');
          if (dragIndex !== null) player.action({action:'moveTrack', from:dragIndex, to:index});
          dragIndex = null;
        });
        const play = button('', () => player.action({action:'playTrack', index}), 'now-queue-play');
        const info = node('span', '', 'now-queue-track');
        info.append(node('strong', item.title));
        if (item.artist) info.append(node('small', item.artist));
        play.append(info, node('span', item.durationSeconds > 0 ? time(item.durationSeconds) : '', 'now-queue-length'));
        const commands = [];
        if (index > 0) commands.push(['Move Up', () => player.action({action:'moveTrack', from:index, to:index - 1})]);
        if (index + 1 < nowQueue.length) commands.push(['Move Down', () => player.action({action:'moveTrack', from:index, to:index + 1})]);
        commands.push(['Remove from Queue', () => player.action({action:'removeTrack', index})]);
        row.append(drag, play, actions('Queue actions for ' + item.title, commands));
        rows.append(row);
      });
      queue.replaceChildren(rows);
      renderedQueue = nowQueue;
      nowIndex = null;
    }
    if (nowIndex !== state.trackIndex) {
      queue.children[nowIndex]?.querySelector('.now-queue-play')?.removeAttribute('aria-current');
      queue.children[state.trackIndex]?.querySelector('.now-queue-play')?.setAttribute('aria-current', 'true');
      nowIndex = state.trackIndex;
    }
  }
  const nowPlaying = get('now-playing');
  function showNowQueue(show) {
    const queue = get('now-queue');
    const toggle = get('jump-now-queue');
    if (!show && queue.contains(document.activeElement)) toggle.focus();
    toggle.setAttribute('aria-expanded', String(show));
    queue.inert = !show;
    queue.setAttribute('aria-hidden', String(!show));
    nowPlaying.classList.toggle('queue-open', show);
    if (show) {
      const active = queue.querySelector('[aria-current="true"]');
      if (active) {
        const scroll = queue.querySelector('.now-queue-content');
        scroll.scrollTop += active.getBoundingClientRect().top - scroll.getBoundingClientRect().top - scroll.clientHeight / 2;
      }
      get('now-queue-heading').focus({preventScroll:true});
    }
  }
  const expandedArtwork = get('expanded-artwork');
  const expandedImage = get('expanded-artwork-image');
  function refreshExpandedArtwork() {
    if (artworkPattern.test(nowCover)) expandedImage.src = nowCover;
    else expandedArtwork.close();
  }
  get('now-art').onclick = () => {
    if (!nowPlaying.open || closingNowPlaying || !artworkPattern.test(nowCover)) return;
    expandedArtwork.showModal();
    refreshExpandedArtwork();
  };
  get('expanded-artwork-cover').onclick = get('close-expanded-artwork').onclick = () => expandedArtwork.close();
  expandedImage.addEventListener('error', () => { if (expandedArtwork.open) expandedArtwork.close(); });
  const lyricsSheet = get('lyrics-sheet');
  const signalSheet = get('signal-path-sheet');
  let lyricsRequest = 0;
  let lyricsFor = null;
  let lyricCues = [];
  let activeCue = -1;

  function closePlaybackSheets() {
    if (expandedArtwork.open) expandedArtwork.close();
    if (lyricsSheet.open) lyricsSheet.close();
    if (signalSheet.open) signalSheet.close();
  }
  function parseLyrics(text) {
    const offset = Number(text.match(/^\[offset:\s*([+-]?\d+)\]/im)?.[1] || 0) / 1000;
    const timed = [];
    const plain = [];
    for (const line of text.replace(/^\uFEFF/, '').split(/\r?\n/)) {
      const stamps = Array.from(line.matchAll(/\[(\d{1,4}):(\d{2})(?:[.:](\d{1,3}))?\]/g));
      if (stamps.length) {
        const last = stamps[stamps.length - 1];
        const text = line.slice(last.index + last[0].length).trim();
        for (const stamp of stamps) {
          const seconds = Number(stamp[1]) * 60 + Number(stamp[2]) + Number('0.' + (stamp[3] || '0'));
          timed.push({time:Math.max(0, seconds + offset), text});
        }
      } else if (line.trim() && !/^\[[a-z]+:.*\]$/i.test(line.trim())) {
        plain.push({text:line.trim()});
      }
    }
    return timed.length ? timed.sort((a,b) => a.time - b.time) : plain;
  }
  function updateLyrics(track) {
    if (track !== lyricsFor) {
      lyricsFor = track;
      lyricCues = [];
      activeCue = -1;
      get('lyrics-lines').replaceChildren();
      get('lyrics-track').textContent = [track?.title, track?.artist].filter(Boolean).join(' · ');
      const handle = /^https:\/\/media\.musicroom\.invalid\/([a-f0-9]{32})$/.exec(track?.url)?.[1];
      const id = ++lyricsRequest;
      get('lyrics-status').textContent = handle ? 'Loading lyrics…' : 'No Plex lyrics for this track.';
      if (handle) host({action:'lyrics', id, handle});
    }
    let low = 0, high = lyricCues.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (lyricCues[middle].time <= (playbackState.elapsed || 0)) low = middle + 1;
      else high = middle;
    }
    const index = low - 1;
    if (index !== activeCue) {
      const rows = get('lyrics-lines').children;
      rows[activeCue]?.removeAttribute('aria-current');
      activeCue = index;
      const row = rows[index];
      if (row) {
        row.setAttribute('aria-current', 'true');
        row.scrollIntoView({block:'center', behavior:matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth'});
      }
    }
  }
  window.musicLyrics = reply => {
    if (reply.id !== lyricsRequest || !lyricsSheet.open) return;
    lyricCues = parseLyrics(reply.text || '');
    get('lyrics-status').textContent = reply.error ? 'Couldn’t load lyrics.' : lyricCues.length ? '' : 'No Plex lyrics for this track.';
    get('lyrics-lines').replaceChildren(...lyricCues.map(cue => cue.time === undefined ? node('p', cue.text) :
      button(cue.text || '♪', () => player.action({action:'seek', seconds:cue.time}))));
    updateLyrics(lyricsFor);
  };
  function signalBadge(format) {
    const codec = format?.codec?.toLowerCase();
    if (!codec) return 'Signal Path';
    if (!['alac', 'flac', 'wav', 'aiff', 'wavpack', 'ape'].includes(codec) && !codec.startsWith('pcm')) return codec.toUpperCase();
    return format.sampleRate > 48000 && format.bitDepth > 16 ? 'Hi-Res' : 'Lossless';
  }
  function renderSignalPath(track) {
    const {codec, container, sampleRate, bitDepth, bitrate, channels} = track?.format || {};
    const fields = [codec?.toUpperCase(), container && container.toLowerCase() !== codec?.toLowerCase() ? container.toUpperCase() : '',
      sampleRate > 0 ? sampleRate / 1000 + ' kHz' : '', bitDepth > 0 ? bitDepth + '-bit' : '',
      bitrate > 0 ? bitrate + ' kbps' : '', channels > 0 ? channels + (channels === 1 ? ' channel' : ' channels') : ''];
    get('signal-path-source').textContent = fields.filter(Boolean).join(' · ') || 'Format details unavailable';
    const rate = player.sampleRate;
    get('signal-path-processing').textContent = rate ? 'Web Audio at ' + rate / 1000 + ' kHz' : 'WebView2 media playback';
  }
  get('lyrics-button').onclick = () => {
    lyricsFor = null;
    lyricsSheet.showModal();
    updateLyrics(nowQueue[playbackState.trackIndex] || {});
  };
  get('close-lyrics').onclick = () => lyricsSheet.close();
  get('signal-path-button').onclick = () => {
    renderSignalPath(nowQueue[playbackState.trackIndex]);
    signalSheet.showModal();
  };
  get('close-signal-path').onclick = () => signalSheet.close();

  let nowPlayingAnimation = null;
  let closingNowPlaying = false;
  let nowPlayingCloseTimer;
  function animateNowPlaying(closing) {
    const animation = window.interfaceMotion.play(nowPlaying, {closing, expanded:true});
    nowPlayingAnimation?.cancel();
    nowPlayingAnimation = animation;
    return nowPlayingAnimation;
  }
  function dismissNowPlaying() {
    if (closingNowPlaying || !nowPlaying.open) return;
    closingNowPlaying = true;
    const animation = animateNowPlaying(true);
    if (!animation) {
      nowPlaying.close();
      return;
    }
    const finish = () => {
      if (nowPlayingAnimation !== animation) return;
      clearTimeout(nowPlayingCloseTimer);
      if (nowPlaying.open) nowPlaying.close();
    };
    nowPlayingCloseTimer = setTimeout(finish, Number(animation.effect.getTiming().duration) + 60);
    animation.finished.then(finish, () => {});
  }
  nowPlaying.addEventListener('cancel', event => {
    event.preventDefault();
    if (expandedArtwork.open) expandedArtwork.close();
    else dismissNowPlaying();
  });
  nowPlaying.addEventListener('close', () => {
    if (get('archive-visualizer-toggle').getAttribute('aria-pressed') === 'true') setArchiveVisualizer(false);
    if (archiveTransportActive) setArchiveTools(false);
    if (nowPlaying.open) return;
    clearTimeout(nowPlayingCloseTimer);
    nowPlayingAnimation?.cancel();
    nowPlayingAnimation = null;
    closingNowPlaying = false;
  });
  function setArchiveVisualizer(active) {
    get('archive-visualizer-toggle').setAttribute('aria-pressed', String(active));
    archiveTransportCommand({action:'visualizer', enabled:active});
    get('now-art').replaceChildren(active ? node('span', '', 'archive-spectrum') : node('span', '♫'));
    if (active) {
      const spectrum = get('now-art').firstElementChild;
      spectrum.setAttribute('aria-label', 'Audio Visualizer');
      for (let index = 0; index < 3; index++) spectrum.append(node('i'));
    }
  }
  window.toolDriveVisualizer = levels => {
    get('now-art').querySelectorAll('.archive-spectrum i').forEach((bar, index) => {
      bar.style.height = Math.max(4, Math.min(100, (levels[index] || 0) * 100)) + '%';
    });
  };
  get('archive-visualizer-toggle').onclick = () => setArchiveVisualizer(get('archive-visualizer-toggle').getAttribute('aria-pressed') !== 'true');
  get('archive-eq-toggle').onclick = () => {
    const panel = get('archive-eq');
    panel.hidden = !panel.hidden;
    get('archive-eq-toggle').setAttribute('aria-expanded', String(!panel.hidden));
  };
  get('archive-stop').onclick = () => archiveTransportCommand({action:'close'});
  function updateArchiveEQ() {
    const values = Object.fromEntries(archiveEQInputs.map(control => [
      control.dataset.archiveEq, control.type === 'checkbox' ? control.checked : Number(control.value)
    ]));
    get('archive-eq-preset').value = Object.keys(eqPresets).find(preset =>
      eqPresets[preset].every((gain, index) => values[bands[index]] === gain)) || 'custom';
    archiveTransportCommand({action:'eq', values});
  }
  for (const input of archiveEQInputs) input.oninput = updateArchiveEQ;
  get('archive-eq-preset').onchange = event => {
    const preset = eqPresets[event.target.value];
    if (!preset) return;
    preset.forEach((gain, index) => { archiveEQInputs[index].value = gain; });
    if (event.target.value === 'flat') archiveEQInputs[3].checked = false;
    updateArchiveEQ();
  };
  get('playing').onclick = () => {
    if (nowPlaying.open || (archiveTransportActive ? !archiveTransportState.visible : !playing)) return;
    setArchiveTools(archiveTransportActive);
    if (archiveTransportActive) {
      nowCover = null;
      renderedQueue = null;
      archiveQueueKey = '';
      nowPlaying.style.removeProperty('--glass-artwork');
      get('now-art').disabled = true;
      get('now-art').replaceChildren(node('span', '♫'));
      renderArchiveNowPlaying();
    } else renderNowPlaying(playbackState);
    showNowQueue(false);
    closingNowPlaying = false;
    nowPlaying.showModal();
    animateNowPlaying(false);
    nowPlaying.querySelector('.now-playing-scroll').scrollTop = 0;
  };
  get('close-now-playing').onclick = dismissNowPlaying;
  get('jump-now-queue').onclick = () => showNowQueue(!nowPlaying.classList.contains('queue-open'));
  get('now-prev').onclick = () => footerCommand({action:'previous'});
  get('now-play').onclick = () => footerCommand({action:'toggle'});
  get('now-next').onclick = () => footerCommand({action:'next'});
  get('now-seek').oninput = event => footerCommand({action:'seek', seconds:event.target.value});
  get('now-volume').oninput = event => footerCommand({action:'volume', value:event.target.value});
  get('settings-connect').onclick = get('connect').onclick = () => host({action:'connect'});
  get('settings-cancel-plex').onclick = () => get('cancel').click();
  get('refresh-plex').onclick = () => host({action:'servers'});
  const openSettings = () => {
    const dialog = get('settings-page');
    if (!dialog.open) dialog.showModal();
    dialog.scrollTop = 0;
  };
  window.openToolDrivePlexSettings = openSettings;
  get('settings').onclick = openSettings;
  get('open-plex-settings').onclick = openSettings;
  get('close-settings').onclick = () => get('settings-page').close();
  get('settings-page').addEventListener('close', () => {
    if (layout.hasAttribute('data-tool-drive-open')) host({action:'refreshToolDrivePlex'});
  });
  get('app-update').onclick = () => host({action:'updateApp'});
  window.musicAppUpdate = state => {
    get('app-update-status').textContent = state.status;
    get('app-update').textContent = state.action;
    get('app-update').disabled = Boolean(state.disabled);
  };
  const glassDefaults = {text:'#f2f7ff', accent:'#abe3ff'};
  function chooseGlassColor(type, value) {
    const custom = /^#[a-f0-9]{6}$/i.test(value ?? '') ? value.toLowerCase() : '';
    const hex = custom || glassDefaults[type];
    get('glass-' + type + '-color').value = hex;
    get('glass-' + type + '-value').textContent = hex.toUpperCase();
    get('glass-' + type + '-reset').disabled = !custom;
    layout.toggleAttribute('data-custom-' + type, Boolean(custom));
    if (custom) layout.style.setProperty('--' + type, custom);
    else layout.style.removeProperty('--' + type);
    if (type === 'accent' && custom) {
      const [r,g,b] = hex.slice(1).match(/../g).map(channel => {
        const srgb = parseInt(channel, 16) / 255;
        return srgb <= .04045 ? srgb / 12.92 : ((srgb + .055) / 1.055) ** 2.4;
      });
      layout.style.setProperty('--accent-ink', .2126*r + .7152*g + .0722*b > .179 ? '#000' : '#fff');
    } else if (type === 'accent') layout.style.removeProperty('--accent-ink');
    try {
      const key = 'musicroom-glass-' + type + '-color';
      if (custom) localStorage.setItem(key, custom);
      else localStorage.removeItem(key);
    } catch {}
  }
  function chooseGlassTransparency(saved) {
    const value = saved === null ? NaN : Number(saved);
    const percent = Number.isFinite(value) ? Math.min(100, Math.max(0, Math.round(value / 5) * 5)) : 40;
    get('glass-transparency').value = percent;
    get('glass-transparency-value').textContent = percent + '%';
    get('glass-transparency').setAttribute('aria-valuetext', percent + '% transparent');
    layout.style.setProperty('--glass-density', String(1 - percent / 100));
    try { localStorage.setItem('musicroom-glass-transparency', String(percent)); } catch {}
  }
  function chooseMiniPlayer(value) {
    const select = get('mini-player-style');
    select.value = value;
    if (select.selectedIndex < 0) select.value = 'automatic';
    window.clickWheel.setStyle(select.value);
    try { localStorage.setItem('musicroom-mini-player', select.value); } catch {}
  }
  const headerSection = get('header-brand-section');
  const sidebarBrand = document.querySelector('#library-sidebar .header-brand');
  const headerPreview = document.querySelector('.header-preview');
  const headerLogo = get('header-logo');
  const headerWordmark = get('header-wordmark');
  const logoOptions = [...headerLogo.options];
  const wordmarkOptions = [...headerWordmark.options];
  const brandWordmarks = new Map([
    ['netflix', 'netflix-wordmark'], ['hulu', 'hulu'],
    ['disney-plus', 'disney-plus'], ['disney-plus-mono', 'disney-plus-mono'],
    ['apple-tv', 'apple-tv'], ['apple-tv-classic', 'apple-tv-classic'], ['apple-tv-glass', 'apple-tv-glass'],
    ['tool-drive-project', 'tool-drive-project-wordmark'],
    ...wordmarkOptions.filter(option => option.hasAttribute('data-video-brand') || option.hasAttribute('data-tool-drive'))
      .map(option => [option.value, option.value])
  ]);
  const headerChoices = new Map();
  let activeHeaderSection = 'music';

  function brandKey(section, part) {
    return 'musicroom-header-' + part + (section === 'music' ? '' : '-' + section);
  }
  function brandPart(part) {
    return part === 'logo' ? headerLogo : headerWordmark;
  }
  function brandOptions(section, part) {
    const options = part === 'logo' ? logoOptions : wordmarkOptions;
    return options.filter(option => {
      if (option.hasAttribute('data-video-brand')) return section === 'movie' || section === 'show';
      if (option.hasAttribute('data-tool-drive')) return section === 'toolDrive';
      return part !== 'logo' || section !== 'toolDrive' || option.value !== 'tool-drive-project';
    });
  }
  function loadHeaderSection() {
    const choices = headerChoices.get(headerSection.value);
    headerLogo.replaceChildren(...brandOptions(headerSection.value, 'logo').map(option => option.cloneNode(true)));
    headerLogo.value = choices.logo;
    headerWordmark.replaceChildren(...brandOptions(headerSection.value, 'wordmark').map(option => option.cloneNode(true)));
    headerWordmark.value = choices.wordmark;
    renderHeaderBrands();
  }
  function chooseHeaderPart(section, part, value) {
    headerChoices.get(section)[part] = value;
    if (section === headerSection.value) brandPart(part).value = value;
    try { localStorage.setItem(brandKey(section, part), value); } catch {}
    renderHeaderBrands();
  }
  function cycleHeaderChoice(part) {
    const options = brandOptions(activeHeaderSection, part).filter(option => option.value !== 'none');
    const current = options.findIndex(option => option.value === headerChoices.get(activeHeaderSection)[part]);
    chooseHeaderPart(activeHeaderSection, part, options[(current + 1) % options.length].value);
  }
  const cycleMark = get('cycle-header-logo');
  const cycleWordmark = get('cycle-header-wordmark');
  cycleMark.onclick = () => cycleHeaderChoice('logo');
  cycleWordmark.onclick = () => cycleHeaderChoice('wordmark');
  window.renderHeaderForSection = section => {
    activeHeaderSection = section;
    renderHeaderBrands();
  };

  function renderHeaderBrands() {
    const active = headerChoices.get(activeHeaderSection);
    renderHeaderBrand(sidebarBrand, active);
    renderHeaderBrand(headerPreview, headerChoices.get(headerSection.value));
    cycleMark.hidden = active.logo === 'none';
    cycleWordmark.hidden = active.wordmark === 'none';
    for (const [control, part] of [[cycleMark, 'logo'], [cycleWordmark, 'wordmark']]) {
      const option = brandOptions(activeHeaderSection, part).find(option => option.value === active[part]);
      control.setAttribute('aria-label', 'Change header ' + part + ', ' + option.textContent);
    }
  }
  function renderHeaderBrand(brand, {logo, wordmark}) {
    const mark = brand.querySelector('.header-mark');
    const logoAsset = logo === 'black' || logo === 'white' ? 'monochrome' : logo;
    if (logo === 'spotify' || wordmark === 'spotify') loadSpotifySheet();
    mark.hidden = logo === 'none' || (logo === 'spotify' && !spotifyLogoURL);
    mark.dataset.mark = logo;
    mark.toggleAttribute('data-video-brand', logoOptions.some(option => option.value === logo && option.hasAttribute('data-video-brand')));
    if (mark.hidden) mark.removeAttribute('src');
    else mark.src = logo === 'spotify' ? spotifyLogoURL : 'HeaderMarks/' + logoAsset + '.png';

    const spotify = wordmark === 'spotify';
    const region = spotify ? spotifyWordmarkRegion : wordmarkRegions.get(wordmark);
    const sheet = spotify ? spotifySheet : wordmarkSheet;
    if (region && !spotify && !wordmarkSheet.getAttribute('src')) wordmarkSheet.src = 'music-wordmarks.png';
    const canvas = brand.querySelector('.music-wordmark');
    const showCanvas = Boolean(region && sheet.naturalWidth);
    if (showCanvas) {
      const [x, y, width, height, darkY] = region;
      canvas.dataset.color = spotify || darkY !== undefined ? 'original' : 'template';
      canvas.width = width;
      canvas.height = height;
      canvas.getContext('2d').drawImage(sheet, x, darkY ?? y, width, height, 0, 0, width, height);
    }
    canvas.hidden = !showCanvas;
    const image = brand.querySelector('img.wordmark');
    const asset = brandWordmarks.get(wordmark);
    image.hidden = wordmark !== 'iplex' && !asset && (showCanvas || spotify || wordmark === 'none');
    image.dataset.wordmark = wordmark;
    image.toggleAttribute('data-video-brand', wordmarkOptions.some(option => option.value === wordmark && option.hasAttribute('data-video-brand')));
    image.src = asset ? 'HeaderMarks/' + asset + '.png' : 'wordmark.png';
  }
  spotifySheet.addEventListener('load', () => {
    renderHeaderBrands();
    const [x, y, width, height] = spotifyLogoRegion;
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    canvas.getContext('2d').drawImage(spotifySheet, x, y, width, height, 0, 0, width, height);
    canvas.toBlob(blob => {
      if (!blob) return;
      spotifyLogoURL = URL.createObjectURL(blob);
      renderHeaderBrands();
    });
  });
  const toolDriveLogoKey = brandKey('toolDrive', 'logo');
  try {
    const legacyLogo = localStorage.getItem(toolDriveLogoKey);
    if (legacyLogo === 'tool-drive-project' ||
        wordmarkOptions.some(option => option.value === legacyLogo && option.hasAttribute('data-tool-drive'))) {
      localStorage.setItem(brandKey('toolDrive', 'wordmark'), legacyLogo);
      localStorage.setItem(toolDriveLogoKey, 'none');
    }
  } catch {}
  for (const {value: section} of headerSection.options) {
    const choices = {logo:'none', wordmark:section === 'toolDrive' ? 'tool-archive-classic' : 'iplex'};
    for (const part of Object.keys(choices)) {
      try {
        const saved = localStorage.getItem(brandKey(section, part));
        if (brandOptions(section, part).some(option => option.value === saved)) choices[part] = saved;
      } catch {}
    }
    headerChoices.set(section, choices);
  }
  loadHeaderSection();
  function chooseHeaderLogoSize(value) {
    const choice = get('header-logo-size');
    choice.value = value;
    if (choice.selectedIndex === -1) choice.value = 'medium';
    for (const brand of document.querySelectorAll('.header-brand')) brand.dataset.markSize = choice.value;
    try { localStorage.setItem('musicroom-header-logo-size', choice.value); } catch {}
  }
  function updateEQ() {
    const settings = {magik:get('eq-magik').checked};
    for (const band of bands) {
      const value = Number(get(band).value);
      settings[band] = value;
      get(band + '-value').textContent = (value >= 0 ? '+' : '') + value + ' dB';
    }
    get('eq-preset').value = Object.keys(eqPresets).find(name =>
      eqPresets[name].every((gain, index) => settings[bands[index]] === gain)) || 'custom';
    player.eq(settings);
    try { localStorage.setItem('musicroom-eq', JSON.stringify(settings)); } catch {}
  }
  function chooseEQPreset(preset) {
    if (!Object.hasOwn(eqPresets, preset)) return;
    eqPresets[preset].forEach((gain, index) => { get(bands[index]).value = gain; });
    if (preset === 'flat') get('eq-magik').checked = false;
    updateEQ();
  }
  for (const type of Object.keys(glassDefaults)) {
    get('glass-' + type + '-color').oninput = event => chooseGlassColor(type, event.target.value);
    get('glass-' + type + '-reset').onclick = () => chooseGlassColor(type, '');
  }
  get('glass-transparency').oninput = event => chooseGlassTransparency(event.target.value);
  get('artwork-colors').onchange = event => chooseArtworkColors(event.target.checked);
  get('animate-artwork-colors').onchange = event => chooseArtworkMotion(event.target.checked);
  for (const control of Object.keys(artworkSizeControls))
    get(control).onchange = event => selectArtworkSize(control, event.target.value);
  get('library-layout').onchange = event => useLibraryLayout(event.target.value);
  get('library-page-size').onchange = event => {
    selectPageSize(event.target.value);
    clearTimeout(timer);
    if (album) refreshAfterAlbum = true;
    else browse();
  };
  get('mini-player-style').onchange = event => chooseMiniPlayer(event.target.value);
  headerSection.onchange = loadHeaderSection;
  headerLogo.onchange = event => chooseHeaderPart(headerSection.value, 'logo', event.target.value);
  headerWordmark.onchange = event => chooseHeaderPart(headerSection.value, 'wordmark', event.target.value);
  wordmarkSheet.addEventListener('load', renderHeaderBrands);
  get('header-logo-size').onchange = event => chooseHeaderLogoSize(event.target.value);
  for (const band of bands) get(band).oninput = updateEQ;
  get('eq-preset').onchange = event => chooseEQPreset(event.target.value);
  get('eq-magik').onchange = updateEQ;
  get('reset-eq').onclick = () => chooseEQPreset('flat');
  window.macEqualizerState = ({available}) => {
    get('eq-status').hidden = available !== false;
    get('eq-status').textContent = available === false ? 'Equalizer is unavailable for this track.' : '';
  };
  const artworkCacheDescription = 'Save album covers, artist pictures, and movie and TV show posters from the selected libraries to this device.';
  window.musicCoverCache = state => {
    caching = state.running;
    get('cache-covers').textContent = caching ? 'Cancel Caching' : 'Cache Library Artwork';
    get('cover-cache-status').textContent = state.message;
  };
  get('cache-covers').onclick = () => host({action:caching ? 'stopCoverCache' : 'cacheCovers', ...window.plexVideoCacheSelection()});
  get('disconnect').onclick = () => {
    window.plexVideoExit();
    host({action:'disconnect'});
  };
  get('cancel').onclick = () => host({action:'cancel'});
  get('server').onchange = event => { if (event.target.value) host({action:'selectServer', server:event.target.value}); };
  get('tool-drive-library').onchange = event => {
    if (event.target.value) host({action:'selectToolDriveLibrary', library:event.target.value});
  };
  get('quick-library').onchange = get('library').onchange = event => { if (event.target.value) host({action:'selectLibrary', library:event.target.value}); };
  const iconChoices = Array.from(get('icon-choices').querySelectorAll('button'));
  function chooseIcon(value) {
    const choice = iconChoices.find(option => option.value === value) || iconChoices[0];
    for (const option of iconChoices) option.setAttribute('aria-pressed', String(option === choice));
    try { localStorage.setItem('musicroom-icon', choice.value); } catch {}
    host({action:'icon', choice:choice.value});
  }
  for (const choice of iconChoices) choice.onclick = () => chooseIcon(choice.value);
  const sectionToggles = new Map();
  for (const tab of sectionNames) {
    const label = node('label', sectionLabel(tab));
    const input = document.createElement('input');
    input.type = 'checkbox';
    label.prepend(input);
    get('library-sections').append(label);
    sectionToggles.set(tab, input);
    input.onchange = () => {
      const enabled = sectionNames.filter(name => sectionToggles.get(name).checked);
      setVisibleSections(enabled);
      try { localStorage.setItem(sectionPreference, JSON.stringify(visibleSections)); } catch {}
    };
    get(tab).onclick = () => {
      window.plexVideoExit();
      selectSection(tab);
    };
  }
  setVisibleSections(sectionNames);
  try {
    const last = localStorage.getItem(lastSectionPreference);
    if (sectionNames.includes(last)) kind = last;
    const saved = JSON.parse(localStorage.getItem(sectionPreference));
    if (Array.isArray(saved)) setVisibleSections(saved);
  } catch {}
  try {
    selectPageSize(localStorage.getItem('musicroom-library-page-size'));
    for (const control of Object.keys(artworkSizeControls))
      selectArtworkSize(control, localStorage.getItem('musicroom-' + control));
    useLibraryLayout(localStorage.getItem('musicroom-library-layout'));
    savedSidebarWidth = Number(localStorage.getItem('musicroom-sidebar-width')) || 0;
    for (const type of Object.keys(glassDefaults))
      chooseGlassColor(type, localStorage.getItem('musicroom-glass-' + type + '-color'));
    chooseGlassTransparency(localStorage.getItem('musicroom-glass-transparency'));
    chooseArtworkColors(localStorage.getItem('musicroom-artwork-colors') === '1');
    chooseArtworkMotion(localStorage.getItem('musicroom-animate-artwork-colors') !== '0');
    chooseMiniPlayer(localStorage.getItem('musicroom-mini-player'));
    chooseHeaderLogoSize(localStorage.getItem('musicroom-header-logo-size'));
    const eq = JSON.parse(localStorage.getItem('musicroom-eq')) || {};
    get('eq-magik').checked = eq.magik === true;
    for (const band of bands) get(band).value = Math.max(-10, Math.min(10, Number(eq[band]) || 0));
    chooseIcon(localStorage.getItem('musicroom-icon'));
  } catch {}
  updateEQ();
  get('search').oninput = () => {
    clearTimeout(timer);
    timer = setTimeout(() => browse(), 300);
  };
  get('back').onclick = () => {
    if (album) {
      ++request; album = null; tracks = []; busy = false; status('');
      if (refreshAfterAlbum) { refreshAfterAlbum = false; browse(); }
      else render();
    }
    else { group = null; browse(); }
  };
  get('retry-page').onclick = () => browse(true);
  for (const control of ['previous', 'toggle', 'next']) get(control).onclick = () => footerCommand({action:control});
  get('seek').oninput = event => footerCommand({action:'seek', seconds:event.target.value});
  host({action:'status'});
  function selectSection(section) {
    clearTimeout(timer);
    queuedOpen = null;
    kind = section;
    try { localStorage.setItem(lastSectionPreference, section); } catch {}
    group = null;
    if (launchPreview) {
      renderLaunchPreview();
      if (launchPreview.waiting) status([launchPreview.name, 'Reconnecting to Plex…'].filter(Boolean).join(' · '));
    }
    else if (library) browse();
    else render();
  }
  function setVisibleSections(sections) {
    const enabled = sectionNames.filter(tab => sections.includes(tab));
    if (enabled.length) visibleSections = enabled;
    for (const [tab, input] of sectionToggles) {
      input.checked = visibleSections.includes(tab);
      input.disabled = input.checked && visibleSections.length === 1;
      get(tab).hidden = !input.checked;
    }
    if (!visibleSections.includes(kind)) selectSection(visibleSections[0]);
  }
  function selectPageSize(value) {
    pageSize = ['30', '60', '120', 'all'].includes(value) ? value : '60';
    get('library-page-size').value = pageSize;
    window.plexVideoPageSize(pageSize);
    try { localStorage.setItem('musicroom-library-page-size', pageSize); } catch {}
  }
})();
