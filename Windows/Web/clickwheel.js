'use strict';

window.clickWheel = (() => {
  const byId = id => document.getElementById(id);
  const player = window.windowsPlayback;
  const root = document.documentElement;
  const dialog = byId('wheel-player');
  const opener = byId('open-wheel');
  const ring = byId('wheel-ring');
  let state = {}, item = null, theme = 'copper';
  let volume = 1, scrubbing = false, preview = null, drag = null, suppressClick = false;
  let artworkKey;
  const clamp = (value, max) => Math.min(max, Math.max(0, value));

  function clock(value) {
    const seconds = Math.floor(Number.isFinite(value) ? Math.max(0, value) : 0);
    return Math.floor(seconds / 60) + ':' + String(seconds % 60).padStart(2, '0');
  }

  function position() { return preview ?? (state.elapsed || 0); }

  function drawProgress() {
    const duration = state.duration || 0;
    const bar = byId('wheel-progress');
    bar.max = Math.max(1, duration);
    bar.value = clamp(position(), bar.max);
    byId('wheel-elapsed').textContent = clock(position());
    byId('wheel-duration').textContent = clock(duration);
  }

  function drawMode() {
    byId('wheel-mode').textContent = scrubbing ? 'SCRUB' : `VOL ${Math.round(volume * 100)}%`;
    byId('wheel-center').setAttribute('aria-label', scrubbing ? 'Switch wheel to volume' : 'Switch wheel to scrub');
    byId('wheel-center').firstElementChild.textContent = scrubbing ? '↔' : '◉';
    byId('wheel-minus').setAttribute('aria-label', scrubbing ? 'Seek backward 10 seconds' : 'Decrease playback volume');
    byId('wheel-plus').setAttribute('aria-label', scrubbing ? 'Seek forward 10 seconds' : 'Increase playback volume');
  }

  function setVolume(value) {
    volume = clamp(value, 1);
    player.action({action:'volume', value:volume});
    drawMode();
  }

  function adjust(direction) {
    if (!scrubbing) {
      setVolume(volume + direction * 0.05);
    } else if (state.duration > 0) {
      player.action({action:'seek', seconds:clamp(position() + direction * 10, state.duration)});
    }
  }

  function update(currentAlbum, currentState, makeCover) {
    if (item?.id !== currentAlbum?.id || state.trackIndex !== currentState.trackIndex) {
      preview = null;
      if (drag) drag.ignore = true;
    }
    item = currentAlbum;
    state = currentState;
    updateTheme(theme);
    if (!item) return;
    const key = JSON.stringify([item.id, item.artwork]);
    if (artworkKey !== key) {
      artworkKey = key;
      byId('wheel-cover').replaceChildren(makeCover(item));
    }

    byId('wheel-track').textContent = Number.isInteger(state.trackIndex) ? `Track ${state.trackIndex + 1}` : '';
    byId('wheel-title').textContent = state.title || item.title;
    byId('wheel-subtitle').textContent = [item.artist, item.title].filter(Boolean).join(' · ');
    byId('wheel-message').textContent = state.message || '';
    byId('wheel-message').hidden = !state.message;
    const playing = state.status === 'playing';
    byId('wheel-play').textContent = playing ? '⏸' : '▶';
    byId('wheel-play').setAttribute('aria-label', playing ? 'Pause' : 'Play');
    byId('wheel-next').disabled = !state.canNext;
    drawProgress();
  }

  function updateTheme(choice) {
    theme = choice;
    opener.hidden = !item || theme === 'copper';
    if (opener.hidden && dialog.open) closePlayer();
  }

  function ringAngle(event) {
    const bounds = ring.getBoundingClientRect();
    const x = event.clientX - bounds.left - bounds.width / 2;
    const y = event.clientY - bounds.top - bounds.height / 2;
    const radius = Math.hypot(x, y) / (bounds.width / 2);
    return radius >= 0.48 && radius <= 1.14 ? Math.atan2(y, x) : null;
  }

  ring.addEventListener('pointerdown', event => {
    if (drag || event.button !== 0) return;
    suppressClick = false;
    const angle = ringAngle(event);
    if (angle !== null) drag = {id:event.pointerId, x:event.clientX, y:event.clientY, angle, moved:false};
  });

  function pointerMove(event) {
    if (drag?.id !== event.pointerId || drag.ignore) return;
    if (!drag.moved) {
      if (Math.hypot(event.clientX - drag.x, event.clientY - drag.y) < 9) return;
      drag.moved = true;
      ring.setPointerCapture(event.pointerId);
    }
    const angle = ringAngle(event);
    if (angle === null) return;
    const difference = angle - drag.angle;
    drag.angle = angle;
    const turn = Math.atan2(Math.sin(difference), Math.cos(difference)) / (2 * Math.PI);
    if (Math.abs(turn) > 0.25) return;
    if (!scrubbing) {
      setVolume(volume + turn);
    } else if (state.duration > 0) {
      preview = clamp(position() + turn * Math.min(120, state.duration), state.duration);
      drawProgress();
    }
  }

  function pointerEnd(event) {
    if (drag?.id !== event.pointerId) return;
    if (event.type === 'pointerup' && preview !== null) player.action({action:'seek', seconds:preview});
    suppressClick = drag.moved;
    drag = null;
    preview = null;
    drawProgress();
  }

  window.addEventListener('pointermove', pointerMove);
  window.addEventListener('pointerup', pointerEnd);
  window.addEventListener('pointercancel', pointerEnd);
  ring.addEventListener('click', event => {
    if (suppressClick && event.detail !== 0) {
      suppressClick = false;
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }, true);
  ring.addEventListener('wheel', event => {
    event.preventDefault();
    if (event.deltaY) adjust(event.deltaY > 0 ? -1 : 1);
  }, {passive:false});

  opener.onclick = () => {
    scrubbing = false;
    drawMode();
    dialog.showModal();
    root.classList.add('floating-player');
    window.chrome.webview.postMessage({action:'openFloatingPlayer'});
    byId('wheel-center').focus();
  };
  function closePlayer() {
    if (dialog.open) dialog.close();
    if (!root.classList.contains('floating-player')) return;
    drag = null;
    preview = null;
    root.classList.remove('floating-player');
    window.chrome.webview.postMessage({action:'closeFloatingPlayer'});
    if (!opener.hidden) opener.focus();
  }
  dialog.addEventListener('close', () => { if (!dialog.open) closePlayer(); });
  dialog.addEventListener('cancel', event => {
    event.preventDefault();
    closePlayer();
  });
  window.closeFloatingPlayer = closePlayer;
  dialog.querySelector('.device-screen').addEventListener('pointerdown', event => {
    if (event.button === 0 && event.pointerType === 'mouse') {
      window.chrome.webview.postMessage({action:'dragFloatingPlayer'});
    }
  });
  byId('wheel-menu').onclick = closePlayer;
  byId('wheel-prev').onclick = () => player.action(state.canPrevious && position() < 2.5 ?
    {action:'previous'} : {action:'seek', seconds:0});
  byId('wheel-next').onclick = () => player.action({action:'next'});
  byId('wheel-play').onclick = () => player.action({action:'toggle'});
  byId('wheel-center').onclick = () => {
    scrubbing = !scrubbing;
    drawMode();
  };
  byId('wheel-minus').onclick = () => adjust(-1);
  byId('wheel-plus').onclick = () => adjust(1);
  dialog.addEventListener('keydown', event => {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
    event.preventDefault();
    adjust(event.key === 'ArrowRight' ? 1 : -1);
  });
  return {update, updateTheme};
})();
