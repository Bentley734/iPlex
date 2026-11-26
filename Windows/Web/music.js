(() => {
  'use strict';
  const get = id => document.getElementById(id);
  const host = body => window.chrome.webview.postMessage(body);
  const player = window.windowsPlayback;
  const sectionNames = ['albums', 'artists', 'genres', 'tracks', 'playlists'];
  const sectionLabel = name => name[0].toUpperCase() + name.slice(1);
  const sectionPreference = 'musicroom-visible-sections';
  let visibleSections = sectionNames;
  let server = '', library = '', kind = 'albums', group = null, album = null, playing = null;
  let tracks = [], entries = [], request = 0, playRequest = 0, offset = 0, busy = false, timer;
  let hasMore = false;
  let paging = false;
  let pageFailed = false;
  let pageSize = '60';
  let listingQuery = '';
  let refreshAfterAlbum = false;
  const listingIDs = new Set();
  let caching = false;
  let selectedTheme = 'copper';
  let artworkColors = false;
  let paletteSource = '';
  let palette = null;
  let paletteRequest = 0;
  const artworkPattern = /^\/art\/[a-f0-9]{32}$/;
  let deckOpen = window.matchMedia('(min-width: 1040px)').matches;
  let featureKey = '';
  let deckKey = '';
  let playbackState = {};
  let nowQueue = [];
  let pendingEnqueue = null;
  let enqueueSequence = 0;
  let dragIndex = null;
  let renderedQueue = null;
  let nowCover = null;
  let nowIndex = null;
  // Regions in the supplied transparent wordmark sheet, including a small inset.
  const wordmarkRegions = new Map([['music', [722, 251, 684, 210]], ['musicBold', [645, 609, 810, 193]]]);
  const wordmarkSheet = new Image();
  const pageEnd = get('page-end');
  const pageObserver = new IntersectionObserver(rows => {
    if (!album && hasMore && !busy && !pageFailed && rows.some(row => row.isIntersecting)) browse(true);
  }, {root:get('scroll')});
  const bands = ['bass', 'mid', 'treble'];
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
  function browse(append = false) {
    if (!library || (append && busy)) return;
    paging = append;
    pageFailed = false;
    album = null;
    refreshAfterAlbum = false;
    if (!append) {
      offset = 0;
      entries = [];
      listingIDs.clear();
      listingQuery = group ? '' : get('search').value;
      hasMore = false;
      get('grid').replaceChildren();
    }
    busy = true;
    render();
    status('Loading library…');
    requestPage();
  }
  function requestPage() {
    host({action:'browse', id:++request, kind, query:listingQuery, group:group?.id, offset,
          pageSize:pageSize === 'all' ? 120 : Number(pageSize)});
  }
  function open(item) {
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
  function libraryQueueActions(item, track) {
    return actions('Queue actions for ' + (track === undefined ? item.title : tracks[track]?.title || 'track'), [
      ['Play Next', () => enqueueItem(item, true, track)],
      ['Add to Queue', () => enqueueItem(item, false, track)]
    ]);
  }
  function enqueueItem(item, playNext, track) {
    if (pendingEnqueue || pendingAlbum) return;
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
    const {item, playNext} = pendingEnqueue;
    pendingEnqueue = null;
    if (!nowQueue.length || playbackState.status === 'finished') {
      nowQueue.forEach(player.releaseTrack);
      playing = item;
      const revision = player.reset(reply.context, 'plex');
      player.queue({...reply, origin:'plex'}, 0, revision, null, playNext);
    } else player.enqueue(reply.tracks, playNext);
    status(playNext ? 'Added to Play Next.' : 'Added to the queue.');
  };
  window.musicEnqueueError = reply => {
    if (reply.id !== pendingEnqueue?.id) return;
    pendingEnqueue = null;
    status(reply.message);
  };
  function render() {
    get('title').textContent = album?.title || group?.title || sectionLabel(kind);
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
    for (const tab of sectionNames) get(tab).setAttribute('aria-pressed', String(kind === tab));
    renderFeature();
    if (!album) {
      const grid = get('grid');
      grid.classList.toggle('track-list', kind === 'tracks' && !group);
      const added = document.createDocumentFragment();
      for (const item of entries.slice(grid.childElementCount)) {
        const tile = button('', () => open(item), 'tile');
        const text = node('div', '', 'tile-text');
        text.append(node('strong', item.title));
        if (item.artist) text.append(node('small', item.artist));
        tile.append(cover(item), text);
        const cell = node('div', '', 'library-tile');
        cell.append(tile);
        if (item.kind !== 'artist' && item.kind !== 'genre') cell.append(libraryQueueActions(item));
        added.append(cell);
      }
      grid.append(added);
      return;
    }
    const heading = node('div', '', 'album-heading');
    const metadata = node('div');
    metadata.append(node('h2', album.artist || sectionLabel(album.kind)),
      node('p', [album.year > 0 ? album.year : '', album.genre].filter(Boolean).join(' · ')));
    const play = button('Play ' + sectionLabel(album.kind), () => playAlbum(0), 'primary');
    play.disabled = tracks.length === 0;
    metadata.append(play);
    if (tracks.length) metadata.append(libraryQueueActions(album));
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
      entry.append(row, libraryQueueActions(album, index));
      list.append(entry);
    });
    get('details').replaceChildren(heading, list);
  }
  function renderFeature() {
    const feature = get('plexify-feature');
    const item = selectedTheme === 'plexify' && !album && !group && ['albums', 'artists'].includes(kind) && !get('search').value.trim() ? entries[0] : null;
    feature.hidden = !item;
    const key = JSON.stringify([item?.id, item?.title, item?.kind, item?.artwork]);
    if (key === featureKey) return;
    featureKey = key;
    if (!item) { feature.replaceChildren(); return; }
    const openFeature = button('', () => open(item));
    const info = node('span', '', 'feature-info');
    info.append(node('small', 'From your library'), node('strong', item.title));
    if (item.artist) info.append(node('span', item.artist));
    const arrow = node('span', '↗', 'feature-arrow');
    arrow.setAttribute('aria-hidden', 'true');
    openFeature.append(cover(item), info, arrow);
    feature.replaceChildren(openFeature);
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
  window.musicEntries = reply => {
    if (reply.id !== request || album) return;
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
    status(tracks.length ? '' : 'This item has no directly playable tracks.');
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
    const connected = state.status === 'connected';
    const connecting = state.status === 'connecting';
    get('connect').hidden = connected || connecting;
    get('refresh-plex').hidden = !state.refreshAvailable;
    get('cancel').hidden = !connecting;
    get('connection').hidden = !connected;
    get('open-plex-settings').hidden = !connected || Boolean(state.libraryId);
    get('plex-settings-status').textContent = state.message;
    get('plex-settings-status').hidden = Boolean(state.libraryId) || !state.message;
    get('library-label').hidden = !state.libraries.length;
    get('welcome-title').textContent = connected ? 'Choose your music library' : 'Connect to Plex';
    get('connection-status').textContent = state.message;
    options(get('server'), state.servers, state.serverId, 'Choose server');
    options(get('library'), state.libraries, state.libraryId, 'Choose library');
    for (const tab of sectionNames) get(tab).disabled = !state.libraryId;
    get('browser').hidden = !state.libraryId;
    get('welcome').hidden = Boolean(state.libraryId);
    if (server !== state.serverId || library !== state.libraryId) {
      server = state.serverId;
      library = state.libraryId;
      window.musicCoverCache({running:false, message:''});
      ++request;
      playing = album = group = pendingAlbum = null;
      nowQueue = [];
      pendingEnqueue = null;
      if (get('now-playing').open) get('now-playing').close();
      player.reset();
      if (library) browse();
    }
  };
  function playingCover(state) {
    if (!playing) return '';
    const track = nowQueue[state.trackIndex];
    return (playing.kind !== 'playlist' && (!track?.collection || track.collection === playing.id)
      ? playing.artwork || state.artwork : state.artwork) || '';
  }
  function applyPalette() {
    const root = document.documentElement;
    root.toggleAttribute('data-artwork-colors', Boolean(palette));
    if (!palette) return;
    const light = selectedTheme === 'classic';
    const blend = (gray, amount) => `rgb(${palette.map(value => Math.round(value * (1 - amount) + gray * amount)).join(' ')})`;
    root.style.setProperty('--artwork-accent', blend(light ? 0 : 255, 0.55));
    root.style.setProperty('--artwork-wash', blend(light ? 255 : 20, light ? 0.72 : 0.67));
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
    try { localStorage.setItem('musicroom-artwork-colors', enabled ? '1' : '0'); } catch {}
    updateArtworkColors(playbackState);
  }
  let footerKey = '';
  window.macPlayerState = state => {
    nowQueue = player.queueItems;
    if (state.status === 'closed') playing = null;
    playbackState = state;
    const currentCover = playingCover(state);
    updateArtworkColors(state);
    const nextKey = JSON.stringify([playing?.id, state.title, state.message, currentCover]);
    if (footerKey !== nextKey) {
      footerKey = nextKey;
      const label = get('playing');
      if (!playing) label.textContent = 'Nothing playing';
      else {
        const info = node('div');
        info.append(node('strong', state.title || playing.title), node('small', [playing.artist, playing.title].filter(Boolean).join(' · ')));
        if (state.message) info.append(node('small', state.message));
        label.replaceChildren(cover({...playing, artwork:currentCover || playing.artwork}), info);
        if ('mediaSession' in navigator && typeof MediaMetadata !== 'undefined') {
          navigator.mediaSession.metadata = new MediaMetadata({
            title: state.title || playing.title, artist: playing.artist || '', album: playing.title,
            artwork: artworkPattern.test(currentCover) ? [{src: new URL(currentCover, location.href).href}] : []
          });
        }
      }
    }
    get('show-now-playing').disabled = !playing;
    if (get('now-playing').open) {
      if (playing) renderNowPlaying(state);
      else get('now-playing').close();
    }
    if (selectedTheme === 'plexify') renderDeck(state);
    window.clickWheel.update(playing, state, cover);
    const active = state.status === 'playing';
    get('toggle').textContent = active ? '⏸' : '▶';
    get('toggle').setAttribute('aria-label', active ? 'Pause' : 'Play');
    get('toggle').disabled = !playing;
    get('previous').disabled = !state.canPrevious;
    get('next').disabled = !state.canNext;
    get('seek').disabled = !state.duration;
    get('seek').max = Math.max(1, state.duration || 0);
    if (document.activeElement !== get('seek')) get('seek').value = state.elapsed || 0;
    get('elapsed').textContent = time(state.elapsed);
  };
  function renderNowPlaying(state) {
    const track = nowQueue[state.trackIndex] || {};
    const path = playingCover(state);
    if (path !== nowCover) {
      nowCover = path;
      get('now-art').replaceChildren(cover({...playing, artwork:path}));
    }
    get('now-title').textContent = track.title || state.title || playing.title;
    get('now-artist').textContent = track.artist || playing.artist || '';
    get('now-album').textContent = track.album || (playing.kind === 'album' ? playing.title : '');
    const message = get('now-status');
    message.textContent = state.message || '';
    message.hidden = !state.message;
    const seek = get('now-seek');
    seek.max = Math.max(1, state.duration || 0);
    seek.disabled = !state.duration;
    if (document.activeElement !== seek) seek.value = state.elapsed || 0;
    get('now-elapsed').textContent = time(state.elapsed);
    get('now-duration').textContent = time(state.duration);
    const active = state.status === 'playing';
    get('now-play').textContent = active ? '⏸' : '▶';
    get('now-play').setAttribute('aria-label', active ? 'Pause' : 'Play');
    get('now-prev').disabled = !state.canPrevious;
    get('now-next').disabled = !state.canNext;
    if (Number.isFinite(state.volume)) get('now-volume').value = state.volume;
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
  get('show-now-playing').onclick = () => {
    if (!playing || nowPlaying.open) return;
    renderNowPlaying(playbackState);
    showNowQueue(false);
    nowPlaying.showModal();
    nowPlaying.querySelector('.now-playing-scroll').scrollTop = 0;
  };
  get('close-now-playing').onclick = () => nowPlaying.close();
  get('jump-now-queue').onclick = () => showNowQueue(!nowPlaying.classList.contains('queue-open'));
  get('now-prev').onclick = () => player.action({action:'previous'});
  get('now-play').onclick = () => player.action({action:'toggle'});
  get('now-next').onclick = () => player.action({action:'next'});
  get('now-seek').oninput = event => player.action({action:'seek', seconds:event.target.value});
  get('now-volume').oninput = event => player.action({action:'volume', value:event.target.value});
  function renderDeck(state) {
    const next = state.tracks?.[state.trackIndex + 1];
    const key = JSON.stringify([playing?.id, playing?.artwork, state.title, next?.title]);
    if (deckKey === key) return;
    deckKey = key;
    const panel = get('plexify-track');
    if (!playing) { panel.textContent = 'Nothing playing'; return; }
    const title = node('strong', state.title || playing.title);
    const artist = node('small', [playing.artist, playing.title].filter(Boolean).join(' · '));
    panel.replaceChildren(cover(playing), title, artist);
    if (next?.title) {
      const upNext = node('div', '', 'plexify-up-next');
      upNext.append(node('small', 'Up Next'), node('span', next.title));
      panel.append(upNext);
    }
  }
  get('connect').onclick = () => host({action:'connect'});
  get('refresh-plex').onclick = () => host({action:'servers'});
  const openSettings = () => {
    const dialog = get('settings-page');
    dialog.showModal();
    dialog.scrollTop = 0;
  };
  get('settings').onclick = openSettings;
  get('open-plex-settings').onclick = openSettings;
  get('close-settings').onclick = () => get('settings-page').close();
  get('app-update').onclick = () => host({action:'updateApp'});
  window.musicAppUpdate = state => {
    get('app-update-status').textContent = state.status;
    get('app-update').textContent = state.action;
    get('app-update').disabled = Boolean(state.disabled);
  };
  function chooseTheme(value) {
    const theme = ['classic', 'video', 'plexify', 'liquidGlass'].includes(value) ? value : 'copper';
    selectedTheme = theme;
    document.documentElement.dataset.theme = theme;
    window.clickWheel.updateTheme(theme);
    get('theme').value = theme;
    applyPalette();
    updateDeckVisibility();
    renderFeature();
    if (theme === 'plexify') renderDeck(playbackState);
    try { localStorage.setItem('musicroom-theme', theme); } catch {}
  }
  function chooseMiniPlayer(value) {
    const select = get('mini-player-style');
    select.value = value;
    if (select.selectedIndex < 0) select.value = 'automatic';
    window.clickWheel.setStyle(select.value);
    try { localStorage.setItem('musicroom-mini-player', select.value); } catch {}
  }
  function updateDeckVisibility() {
    const plexify = selectedTheme === 'plexify';
    const visible = plexify && deckOpen;
    get('plexify-deck').hidden = !visible;
    const toggle = get('plexify-deck-toggle');
    toggle.hidden = !plexify;
    toggle.setAttribute('aria-expanded', String(visible));
    document.documentElement.dataset.plexifyDeck = visible ? 'open' : 'closed';
  }
  function renderHeaderWordmark() {
    const region = wordmarkRegions.get(get('header-wordmark').value);
    const showMusic = Boolean(region && wordmarkSheet.naturalWidth);
    for (const brand of document.querySelectorAll('.header-brand')) {
      const canvas = brand.querySelector('.music-wordmark');
      if (showMusic) {
        const [x, y, width, height] = region;
        canvas.width = width;
        canvas.height = height;
        canvas.getContext('2d').drawImage(wordmarkSheet, x, y, width, height, 0, 0, width, height);
      }
      canvas.hidden = !showMusic;
      brand.querySelector('img.wordmark').hidden = showMusic;
    }
  }
  function chooseHeaderWordmark(value) {
    const choice = get('header-wordmark');
    choice.value = wordmarkRegions.has(value) ? value : 'iplex';
    if (choice.value !== 'iplex' && !wordmarkSheet.getAttribute('src')) wordmarkSheet.src = 'music-wordmarks.png';
    renderHeaderWordmark();
    try { localStorage.setItem('musicroom-header-wordmark', choice.value); } catch {}
  }
  function chooseHeaderLogo(value) {
    const choice = get('header-logo');
    choice.value = value;
    if (choice.selectedIndex === -1) choice.value = 'none';
    const logo = choice.value;
    const asset = logo === 'black' || logo === 'white' ? 'monochrome' : logo;
    for (const image of document.querySelectorAll('.header-mark')) {
      image.hidden = logo === 'none';
      image.dataset.mark = logo;
      if (image.hidden) image.removeAttribute('src');
      else image.src = 'HeaderMarks/' + asset + '.png';
    }
    try { localStorage.setItem('musicroom-header-logo', logo); } catch {}
  }
  function chooseHeaderLogoSize(value) {
    const choice = get('header-logo-size');
    choice.value = value;
    if (choice.selectedIndex === -1) choice.value = 'medium';
    for (const brand of document.querySelectorAll('.header-brand')) brand.dataset.markSize = choice.value;
    try { localStorage.setItem('musicroom-header-logo-size', choice.value); } catch {}
  }
  function updateEQ() {
    const settings = {};
    for (const band of bands) {
      const value = Number(get(band).value);
      settings[band] = value;
      get(band + '-value').textContent = (value >= 0 ? '+' : '') + value + ' dB';
    }
    player.eq(settings);
    try { localStorage.setItem('musicroom-eq', JSON.stringify(settings)); } catch {}
  }
  get('theme').onchange = event => chooseTheme(event.target.value);
  get('artwork-colors').onchange = event => chooseArtworkColors(event.target.checked);
  get('library-page-size').onchange = event => {
    selectPageSize(event.target.value);
    clearTimeout(timer);
    if (album) refreshAfterAlbum = true;
    else browse();
  };
  get('mini-player-style').onchange = event => chooseMiniPlayer(event.target.value);
  get('plexify-deck-toggle').onclick = () => { deckOpen = !deckOpen; updateDeckVisibility(); };
  get('header-logo').onchange = event => chooseHeaderLogo(event.target.value);
  get('header-wordmark').onchange = event => chooseHeaderWordmark(event.target.value);
  wordmarkSheet.addEventListener('load', renderHeaderWordmark);
  get('header-logo-size').onchange = event => chooseHeaderLogoSize(event.target.value);
  for (const band of bands) get(band).oninput = updateEQ;
  get('reset-eq').onclick = () => {
    for (const band of bands) get(band).value = 0;
    updateEQ();
  };
  window.macEqualizerState = ({available}) => {
    get('eq-status').hidden = available !== false;
    get('eq-status').textContent = available === false ? 'Equalizer is unavailable for this track.' : '';
  };
  window.musicCoverCache = state => {
    caching = state.running;
    get('cover-library').textContent = library ? 'Save album covers and artist pictures from the selected library to this device.' :
      'Choose a Plex music library to cache artwork.';
    get('cache-covers').disabled = !library;
    get('cache-covers').textContent = caching ? 'Cancel Caching' : 'Cache Library Artwork';
    get('cover-cache-status').textContent = state.message;
  };
  get('cache-covers').onclick = () => host({action:caching ? 'stopCoverCache' : 'cacheCovers'});
  get('disconnect').onclick = () => host({action:'disconnect'});
  get('cancel').onclick = () => host({action:'cancel'});
  get('server').onchange = event => { if (event.target.value) host({action:'selectServer', server:event.target.value}); };
  get('library').onchange = event => { if (event.target.value) host({action:'selectLibrary', library:event.target.value}); };
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
    get(tab).onclick = () => selectSection(tab);
  }
  setVisibleSections(sectionNames);
  try {
    const saved = JSON.parse(localStorage.getItem(sectionPreference));
    if (Array.isArray(saved)) setVisibleSections(saved);
  } catch {}
  try {
    selectPageSize(localStorage.getItem('musicroom-library-page-size'));
    chooseTheme(localStorage.getItem('musicroom-theme'));
    chooseArtworkColors(localStorage.getItem('musicroom-artwork-colors') === '1');
    chooseMiniPlayer(localStorage.getItem('musicroom-mini-player'));
    chooseHeaderLogo(localStorage.getItem('musicroom-header-logo'));
    chooseHeaderWordmark(localStorage.getItem('musicroom-header-wordmark'));
    chooseHeaderLogoSize(localStorage.getItem('musicroom-header-logo-size'));
    const eq = JSON.parse(localStorage.getItem('musicroom-eq')) || {};
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
  for (const control of ['previous', 'toggle', 'next']) get(control).onclick = () => player.action({action:control});
  get('seek').oninput = event => player.action({action:'seek', seconds:event.target.value});
  host({action:'status'});
  function selectSection(section) {
    clearTimeout(timer);
    kind = section;
    group = null;
    if (library) browse();
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
    try { localStorage.setItem('musicroom-library-page-size', pageSize); } catch {}
  }
})();
