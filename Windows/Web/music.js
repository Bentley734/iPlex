(() => {
  'use strict';
  const get = id => document.getElementById(id);
  const host = body => window.chrome.webview.postMessage(body);
  const player = window.windowsPlayback;
  let server = '', library = '', kind = 'albums', artist = null, album = null, playing = null;
  let tracks = [], entries = [], request = 0, playRequest = 0, offset = 0, busy = false, timer;
  let hasMore = false;
  let caching = false;
  let selectedTheme = 'copper';
  let deckOpen = window.matchMedia('(min-width: 1040px)').matches;
  let featureKey = '';
  let deckKey = '';
  let playbackState = {};
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
    if (/^\/art\/[a-f0-9]{32}$/.test(item.artwork || '')) {
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
    album = null;
    if (!append) {
      offset = 0;
      entries = [];
      hasMore = false;
      get('grid').replaceChildren();
    }
    busy = true;
    render();
    status('Loading library…');
    host({action:'browse', id:++request, kind, query:get('search').value, artist:artist?.id, offset});
  }
  function open(item) {
    clearTimeout(timer);
    if (item.kind === 'artist') {
      artist = item;
      browse();
      return;
    }
    album = item;
    tracks = [];
    busy = true;
    render();
    status('Loading tracks…');
    host({action:'album', id:++request, album:item.id});
  }
  function render() {
    get('title').textContent = album?.title || artist?.title || (kind === 'albums' ? 'Albums' : 'Artists');
    get('search').hidden = Boolean(artist || album);
    get('back').hidden = !artist && !album;
    get('grid').hidden = Boolean(album);
    get('details').hidden = !album;
    get('more').hidden = Boolean(album) || !hasMore || busy;
    get('albums').setAttribute('aria-pressed', String(kind === 'albums'));
    get('artists').setAttribute('aria-pressed', String(kind === 'artists'));
    renderFeature();
    if (!album) {
      const grid = get('grid');
      grid.append(...entries.slice(grid.childElementCount).map(item => {
        const tile = button('', () => open(item), 'tile');
        tile.append(cover(item), node('strong', item.title));
        if (item.artist) tile.append(node('small', item.artist));
        return tile;
      }));
      return;
    }
    const heading = node('div', '', 'album-heading');
    const metadata = node('div');
    metadata.append(node('h2', album.artist || 'Album'),
      node('p', [album.year > 0 ? album.year : '', album.genre].filter(Boolean).join(' · ')));
    const play = button('Play Album', () => playAlbum(0), 'primary');
    play.disabled = tracks.length === 0;
    metadata.append(play);
    heading.append(cover(album), metadata);
    const list = node('div', '', 'tracks');
    tracks.forEach((track, index) => {
      const row = button('', () => playAlbum(index), 'track');
      row.append(node('span', String(track.number), 'number'), node('span', track.title), node('small', time(track.durationSeconds)));
      list.append(row);
    });
    get('details').replaceChildren(heading, list);
  }
  function renderFeature() {
    const feature = get('plexify-feature');
    const item = selectedTheme === 'plexify' && !album && !artist && !get('search').value.trim() ? entries[0] : null;
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
    if (!album || !tracks[index]) return;
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
    const revision = player.reset(reply.context, 'plex');
    footerKey = '';
    player.queue(reply, reply.startIndex, revision, null);
  };
  window.musicEntries = reply => {
    if (reply.id !== request || album) return;
    const seen = new Set(entries.map(item => item.id));
    for (const row of reply.entries) if (!seen.has(row.id)) { entries.push(row); seen.add(row.id); }
    offset = reply.next;
    hasMore = reply.more;
    busy = false;
    status(entries.length ? '' : 'No matches in this library.');
    render();
  };
  window.musicAlbum = reply => {
    if (reply.id !== request || !album) return;
    tracks = reply.tracks;
    busy = false;
    status(tracks.length ? '' : 'This album has no directly playable tracks.');
    render();
  };
  window.musicError = reply => {
    if (reply.id !== request) return;
    busy = false;
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
    get('disconnect').hidden = !connected;
    get('connect').hidden = connected || connecting;
    get('cancel').hidden = !connecting;
    get('connection').hidden = !connected;
    get('library-label').hidden = !state.libraries.length;
    get('welcome-title').textContent = connected ? 'Choose your music library' : 'Connect to Plex';
    get('connection-status').textContent = state.message;
    options(get('server'), state.servers, state.serverId, 'Choose server');
    options(get('library'), state.libraries, state.libraryId, 'Choose library');
    get('albums').disabled = !state.libraryId;
    get('artists').disabled = !state.libraryId;
    get('browser').hidden = !state.libraryId;
    get('welcome').hidden = Boolean(state.libraryId);
    if (server !== state.serverId || library !== state.libraryId) {
      server = state.serverId;
      library = state.libraryId;
      window.musicCoverCache({running:false, message:''});
      ++request;
      playing = album = artist = pendingAlbum = null;
      player.reset();
      if (library) browse();
    }
  };
  let footerKey = '';
  window.macPlayerState = state => {
    playbackState = state;
    const nextKey = JSON.stringify([playing?.id, state.title, state.message]);
    if (footerKey !== nextKey) {
      footerKey = nextKey;
      const label = get('playing');
      if (!playing) label.textContent = 'Nothing playing';
      else {
        const info = node('div');
        info.append(node('strong', state.title || playing.title), node('small', [playing.artist, playing.title].filter(Boolean).join(' · ')));
        if (state.message) info.append(node('small', state.message));
        label.replaceChildren(cover(playing), info);
        if ('mediaSession' in navigator && typeof MediaMetadata !== 'undefined') {
          navigator.mediaSession.metadata = new MediaMetadata({
            title: state.title || playing.title, artist: playing.artist || '', album: playing.title,
            artwork: /^\/art\/[a-f0-9]{32}$/.test(playing.artwork || '') ? [{src: new URL(playing.artwork, location.href).href}] : []
          });
        }
      }
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
  get('settings').onclick = () => get('settings-page').showModal();
  get('close-settings').onclick = () => get('settings-page').close();
  function chooseTheme(value) {
    const theme = ['classic', 'video', 'plexify'].includes(value) ? value : 'copper';
    selectedTheme = theme;
    document.documentElement.dataset.theme = theme;
    window.clickWheel.updateTheme(theme);
    get('theme').value = theme;
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
  get('mini-player-style').onchange = event => chooseMiniPlayer(event.target.value);
  get('plexify-deck-toggle').onclick = () => { deckOpen = !deckOpen; updateDeckVisibility(); };
  get('header-logo').onchange = event => chooseHeaderLogo(event.target.value);
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
  get('icon').onchange = event => {
    try { localStorage.setItem('musicroom-icon', event.target.value); } catch {}
    host({action:'icon', choice:event.target.value});
  };
  try {
    chooseTheme(localStorage.getItem('musicroom-theme'));
    chooseMiniPlayer(localStorage.getItem('musicroom-mini-player'));
    chooseHeaderLogo(localStorage.getItem('musicroom-header-logo'));
    chooseHeaderLogoSize(localStorage.getItem('musicroom-header-logo-size'));
    const eq = JSON.parse(localStorage.getItem('musicroom-eq')) || {};
    for (const band of bands) get(band).value = Math.max(-10, Math.min(10, Number(eq[band]) || 0));
    const icon = localStorage.getItem('musicroom-icon');
    if (['groove', 'prism', 'signal', 'clickwheel'].includes(icon)) {
      get('icon').value = icon;
      host({action:'icon', choice:icon});
    }
  } catch {}
  updateEQ();
  for (const tab of ['albums', 'artists']) get(tab).onclick = () => {
    clearTimeout(timer);
    kind = tab;
    artist = null;
    browse();
  };
  get('search').oninput = () => {
    clearTimeout(timer);
    timer = setTimeout(() => browse(), 300);
  };
  get('back').onclick = () => {
    if (album) { ++request; album = null; tracks = []; busy = false; status(''); render(); }
    else { artist = null; browse(); }
  };
  get('more').onclick = () => browse(true);
  for (const control of ['previous', 'toggle', 'next']) get(control).onclick = () => player.action({action:control});
  get('seek').oninput = event => player.action({action:'seek', seconds:event.target.value});
  host({action:'status'});
})();
