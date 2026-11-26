'use strict';

// The stream proxy returns same-origin, seekable URLs for every source, including
// Plex. This keeps credentials out of the player and permits real audio analysis.
window.windowsPlayback = (() => {
  const audio = new Audio();
  audio.preload = 'metadata';
  audio.crossOrigin = 'anonymous';
  let tracks = [], index = 0, collection = '', origin = '', state = 'closed', error = '';
  let context, filters, analyser, spectrum, meter = 0, attempt = 0, expectedURL = '';
  let volumeStage, outputVolume = 1;
  let wantsPlay = false, revision = 0;
  let retryTimer = 0, retries = 0, resumeAt = 0, healthySince = 0;
  let decoded = null, scheduled = null, decoding = null, decodeGeneration = 0, pausedOffset = 0;
  let opening = false;
  let tone = {};
  const magik = [[315,-0.75],[400,-2.6],[500,-4.75],[630,-7.65],[800,-4.75],[1000,-2.6],[1250,-0.75],[10000,0.15]];
  function publish() {
    const track = tracks[index] || {};
    window.macPlayerState?.({
      visible: state !== 'closed', status: state, message: error, error, volume: outputVolume,
      tracks: tracks.map(({title, durationSeconds}) => ({title, durationSeconds})),
      trackIndex: index, context: collection, title: track.title || collection, artwork: track.artwork,
      duration: decoded ? decoded.buffer.duration : Number.isFinite(audio.duration) && audio.currentSrc === expectedURL ? audio.duration : track.durationSeconds || 0,
      elapsed: decoded ? decodedTime() : audio.currentSrc === expectedURL ? audio.currentTime : 0,
      canPrevious: index > 0, canNext: index + 1 < tracks.length
    });
    if ('mediaSession' in navigator) {
      navigator.mediaSession.playbackState = state === 'playing' ? 'playing' : state === 'paused' ? 'paused' : 'none';
    }
  }
  function prepareAudio() {
    if (!context) {
      try {
        context = new AudioContext();
        filters = [['lowshelf',200,1], ['peaking',1000,1], ['highshelf',4000,1],
          ...magik.map(([hz]) => ['peaking',hz,4.3])].map(([type,hz,q]) => {
          const f = context.createBiquadFilter();
          f.type = type; f.frequency.value = hz; f.Q.value = q; return f;
        });
        analyser = context.createAnalyser(); analyser.fftSize = 2048;
        spectrum = new Uint8Array(analyser.frequencyBinCount);
        const limiter = context.createDynamicsCompressor();
        limiter.threshold.value = -1; limiter.knee.value = 0; limiter.ratio.value = 20;
        limiter.attack.value = .001; limiter.release.value = .1;
        const gain = context.createGain();
        gain.gain.value = outputVolume;
        const source = context.createMediaElementSource(audio);
        let last = source;
        for (const node of [...filters, limiter, gain, analyser, context.destination]) { last.connect(node); last = node; }
        volumeStage = gain;
        audio.volume = 1;
        eq(tone);
      } catch {
        window.macEqualizerState?.({available:false}); return;
      }
    }
    if (context.state === 'suspended') context.resume().catch(() => {});
    window.macEqualizerState?.({available:Boolean(analyser)});
  }
  function eq(values = {}) {
    tone = values;
    if (!filters) return;
    const gain = key => Math.max(-10,Math.min(10,Number(values[key]) || 0));
    const gains = [gain('bass'), gain('mid'), gain('treble'), ...magik.map(([,db]) => values.magik ? db : 0)];
    filters.forEach((filter,i) => filter.gain.setTargetAtTime(gains[i], context.currentTime,.012));
  }
  function measure() {
    if (!analyser || state !== 'playing' || document.hidden) return;
    analyser.getByteFrequencyData(spectrum);
    const ranges = [[35,240],[240,2400],[2400,12000]];
    const scale = analyser.fftSize / context.sampleRate;
    const levels = ranges.map(([lo,hi]) => {
      let total = 0; const begin = Math.max(1,Math.ceil(lo*scale)), end = Math.min(spectrum.length,Math.ceil(hi*scale));
      for (let i=begin; i<end; i++) total += (spectrum[i]/255)**2;
      return Math.sqrt(total / Math.max(1,end-begin));
    });
    window.macVisualizerLevels?.(levels);
  }
  function windowState() { window.macVisualizerWindowState?.({visible:!document.hidden,fullScreen:Boolean(document.fullscreenElement)}); }
  function visualize(p) {
    if (p.action === 'listen' && !meter) meter = setInterval(measure, 40);
    if (p.action === 'idle') { clearInterval(meter); meter = 0; }
    if (p.action === 'window') windowState();
    if (p.action === 'fullscreen') {
      const action = document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen();
      action.catch(windowState);
    }
  }
  document.addEventListener('fullscreenchange',windowState);
  document.addEventListener('visibilitychange',windowState);
  function cancelRetry() {
    clearTimeout(retryTimer);
    retryTimer = retries = resumeAt = healthySince = 0;
  }
  function decodedTime() {
    if (!decoded?.node || !context) return pausedOffset;
    return Math.max(0, Math.min(decoded.buffer.duration, decoded.offset + context.currentTime - decoded.start));
  }
  function cancelDecode() {
    decodeGeneration++;
    decoding?.abort();
    decoding = null;
  }
  function stopBuffer(slot) {
    if (!slot?.node) return;
    slot.node.onended = null;
    slot.node.stop();
    slot.node.disconnect();
    slot.node = null;
  }
  function clearDecoded() {
    cancelDecode();
    stopBuffer(decoded);
    stopBuffer(scheduled);
    decoded = scheduled = null;
    pausedOffset = 0;
    opening = false;
  }
  async function decodeTrack(track, wait) {
    // Bound the encoded transfer and decoded buffer so long recordings can
    // retain normal seekable streaming on memory-constrained machines.
    const maxBytes = 96 * 1024 * 1024, maxSeconds = 900;
    if (!context || !filters || track.durationSeconds > maxSeconds) return null;
    const controller = new AbortController();
    decoding = controller;
    const timer = setTimeout(() => controller.abort(), wait);
    try {
      const response = await fetch(track.url, {signal:controller.signal});
      if (!response.ok || !response.body || Number(response.headers.get('content-length')) > maxBytes) {
        controller.abort();
        return null;
      }
      const reader = response.body.getReader();
      const chunks = [];
      let length = 0;
      while (true) {
        const part = await reader.read();
        if (part.done) break;
        length += part.value.byteLength;
        if (length > maxBytes) { controller.abort(); return null; }
        chunks.push(part.value);
      }
      const bytes = new Uint8Array(length);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      const buffer = await context.decodeAudioData(bytes.buffer);
      return buffer.duration <= maxSeconds && buffer.numberOfChannels <= 2 ? buffer : null;
    } catch { return null; }
    finally {
      clearTimeout(timer);
      if (decoding === controller) decoding = null;
    }
  }
  function bufferSlot(buffer, offset, start) {
    const node = context.createBufferSource();
    node.buffer = buffer;
    node.connect(filters[0]);
    node.start(start, offset);
    return {node, buffer, start, offset};
  }
  function startDecoded(buffer, offset = 0) {
    pausedOffset = Math.max(0, Math.min(offset, buffer.duration - 0.01));
    decoded = bufferSlot(buffer, pausedOffset, context.currentTime + 0.02);
    wantsPlay = true; state = 'playing'; error = '';
    monitorDecoded(decoded);
    publish();
  }
  function monitorDecoded(slot) {
    const following = tracks[index + 1], serial = decodeGeneration;
    const end = slot.start + slot.buffer.duration - slot.offset;
    slot.node.onended = () => {
      if (slot !== decoded) return;
      slot.node.disconnect();
      slot.node = null;
      if (scheduled) {
        decoded = scheduled;
        scheduled = null;
        index++;
        setMediaMetadata();
        monitorDecoded(decoded);
        publish();
      } else if (following) {
        select(index + 1, true);
      } else {
        wantsPlay = false; pausedOffset = slot.buffer.duration; state = 'finished'; publish();
      }
    };
    if (following) decodeTrack(following, Math.max(1000, (end - context.currentTime) * 1000)).then(buffer => {
      if (!buffer || serial !== decodeGeneration || decoded !== slot || !slot.node || context.currentTime >= end) return;
      scheduled = bufferSlot(buffer, 0, end);
    });
  }
  function setMediaMetadata() {
    if ('mediaSession' in navigator && 'MediaMetadata' in window) {
      navigator.mediaSession.metadata = new MediaMetadata({title:tracks[index].title,artist:'TOOL',album:collection});
    }
  }
  function retryOrFail() {
    if (!wantsPlay || !tracks[index] || retryTimer) return;
    if (retries >= 2 || audio.error?.code === MediaError.MEDIA_ERR_DECODE) {
      fail('Audio unavailable or unsupported on this device.');
      return;
    }
    retries++;
    healthySince = 0;
    if (audio.currentTime > 0) resumeAt = audio.currentTime;
    state = 'loading';
    error = 'Retrying playback…';
    publish();
    retryTimer = setTimeout(() => {
      retryTimer = 0;
      if (!wantsPlay || !tracks[index]) return;
      audio.load();
      play();
    }, retries * 1000);
  }
  function reset(label, type) {
    cancelRetry();
    clearDecoded();
    revision++; wantsPlay = false; attempt++; expectedURL = ''; audio.pause();
    audio.removeAttribute('src'); audio.load();
    tracks = []; index = 0; collection = label || ''; origin = type || ''; error = '';
    state = type ? 'loading' : 'closed';
    publish();
    if ('mediaSession' in navigator) navigator.mediaSession.metadata = null;
    return revision;
  }
  function fail(message) {
    state = 'error'; error = message || 'This audio could not be played.'; wantsPlay = false; publish();
  }
  function play() {
    if (!tracks[index]) return;
    prepareAudio();
    wantsPlay = true;
    if (opening) return;
    if (decoded) {
      if (!decoded.node) startDecoded(decoded.buffer, state === 'finished' ? 0 : pausedOffset);
      return;
    }
    const serial = ++attempt;
    audio.play().catch(e => {
      if (serial !== attempt || e.name === 'AbortError') return;
      if (e.name === 'NotAllowedError') { wantsPlay = false; state = 'paused'; error = 'Press Play to start audio.'; publish(); }
      else retryOrFail();
    });
  }
  function select(i, autoplay, startAt = 0) {
    if (!Number.isInteger(i) || !tracks[i]) return;
    cancelRetry();
    clearDecoded();
    audio.pause();
    audio.removeAttribute('src');
    audio.load();
    expectedURL = '';
    index=i; attempt++; wantsPlay=autoplay; error=''; state=autoplay?'loading':'paused';
    const track = tracks[i];
    setMediaMetadata();
    publish();
    if (autoplay && context && filters) {
      const serial=decodeGeneration;
      opening = true;
      decodeTrack(track, 4000).then(buffer=>{
        if (serial !== decodeGeneration) return;
        opening = false;
        if (!buffer || context.state !== 'running') openStream(track,wantsPlay,startAt);
        else if (wantsPlay) startDecoded(buffer,startAt);
        else { decoded={node:null,buffer}; pausedOffset=startAt; publish(); }
      });
      return;
    }
    openStream(track, autoplay, startAt);
  }
  function openStream(track, autoplay, startAt) {
    expectedURL = new URL(track.url, location.href).href;
    const handle = new URL(expectedURL).pathname.slice(1);
    if (/^[a-f0-9]{32}$/.test(handle)) window.chrome?.webview?.postMessage({channel:'player',body:{action:'beginTrack',handle}});
    audio.src = expectedURL;
    if (startAt > 0) { resumeAt = startAt; audio.currentTime = startAt; }
    if (autoplay) play();
    publish();
  }
  function queue(payload, start=0, expectedRevision, position, autoplay=true) {
    if (expectedRevision !== undefined && expectedRevision !== revision) return;
    if (!Array.isArray(payload?.tracks) || !payload.tracks.length) { fail('No playable tracks were found.'); return; }
    tracks = payload.tracks; collection = payload.context || collection; origin = payload.origin || origin;
    if (position) {
      const {trackIndex,trackTitle,seconds}=position;
      if (!Number.isSafeInteger(trackIndex) || tracks[trackIndex]?.title !== trackTitle ||
          !Number.isFinite(seconds) || seconds < 0 || seconds > 86400) {
        fail('The saved track has changed. Open the recording to choose a track.');
        return;
      }
      select(trackIndex,true,seconds);
    } else select(Math.min(Math.max(0,Number(start)||0),tracks.length-1),autoplay);
  }
  function pause() {
    cancelRetry(); wantsPlay = false; attempt++; audio.pause();
    if (decoded) {
      pausedOffset=decodedTime();
      cancelDecode();
      stopBuffer(decoded); stopBuffer(scheduled); scheduled=null;
    }
    if (tracks.length) {state='paused'; publish();}
  }
  function seek(time) {
    if (decoded && Number.isFinite(time)) {
      cancelDecode(); stopBuffer(decoded); stopBuffer(scheduled); scheduled=null;
      pausedOffset=Math.max(0,Math.min(decoded.buffer.duration - 0.01,time));
      if (wantsPlay) startDecoded(decoded.buffer,pausedOffset); else publish();
      return;
    }
    if (tracks.length && Number.isFinite(time) && Number.isFinite(audio.duration)) {
      const handle = new URL(expectedURL).pathname.slice(1);
      if (/^[a-f0-9]{32}$/.test(handle)) window.chrome?.webview?.postMessage({channel:'player',body:{action:'seekTrack',handle}});
      audio.currentTime = Math.max(0, Math.min(audio.duration,time));
    }
  }
  function updateQueue(next) {
    const current = tracks[index];
    const following = tracks[index + 1];
    tracks = next;
    index = tracks.indexOf(current);
    if (decoded?.node && tracks[index + 1] !== following) {
      cancelDecode();
      stopBuffer(scheduled);
      scheduled = null;
      monitorDecoded(decoded);
    }
    publish();
  }
  function enqueue(additions, playNext) {
    if (!tracks[index] || !additions.length) return;
    const next = tracks.slice();
    next.splice(playNext ? index + 1 : next.length, 0, ...additions);
    updateQueue(next);
  }
  function moveTrack(from, to) {
    if (!Number.isInteger(from) || !Number.isInteger(to) || !tracks[from] || !tracks[to] || from === to) return;
    const next = tracks.slice();
    next.splice(to, 0, next.splice(from, 1)[0]);
    updateQueue(next);
  }
  function releaseTrack(track) {
    const match = /^https:\/\/media\.musicroom\.invalid\/([a-f0-9]{32})$/.exec(track?.url || '');
    if (match) window.chrome?.webview?.postMessage({action:'releaseTrack', handle:match[1]});
  }
  function removeTrack(position) {
    if (!Number.isInteger(position) || !tracks[position]) return;
    const next = tracks.slice();
    const removed = next.splice(position, 1)[0];
    if (!next.length) reset();
    else if (position === index) {
      tracks = next;
      select(Math.min(position, next.length - 1), position < next.length && wantsPlay);
    } else updateQueue(next);
    releaseTrack(removed);
  }
  function action(p) {
    switch(p.action) {
      case 'toggle': if (wantsPlay) pause(); else play(); break;
      case 'pause': pause(); break;
      case 'previous': select(index-1,true); break;
      case 'next': select(index+1,true); break;
      case 'seek': seek(Number(p.seconds)); break;
      case 'volume': {
        const value = Number(p.value);
        if (!Number.isFinite(value)) break;
        outputVolume = Math.max(0, Math.min(1, value));
        if (volumeStage) volumeStage.gain.setTargetAtTime(outputVolume, context.currentTime, .015);
        else audio.volume = outputVolume;
        publish();
        break;
      }
      case 'playTrack': select(Number(p.index),true); break;
      case 'moveTrack': moveTrack(p.from, p.to); break;
      case 'removeTrack': removeTrack(p.index); break;
      case 'close': reset(); break;
    }
  }
  function current() { return tracks.length && expectedURL && audio.currentSrc === expectedURL; }
  for (const event of ['timeupdate','durationchange','loadedmetadata']) audio.addEventListener(event,() => {
    if (!current()) return;
    if (event === 'loadedmetadata' && resumeAt > 0) { const position = resumeAt; resumeAt = 0; seek(position); }
    if (healthySince && performance.now() - healthySince >= 5000) { healthySince = 0; retries = 0; }
    publish();
  });
  audio.addEventListener('playing',() => { if (current()) {state='playing'; error=''; healthySince=performance.now(); publish();} });
  audio.addEventListener('pause',() => { if (current() && audio.paused && !audio.ended && !wantsPlay) {state='paused'; publish();} });
  audio.addEventListener('waiting',() => { if (current() && wantsPlay) {state='loading'; publish();} });
  audio.addEventListener('ended',() => { if (current()) { if (index+1<tracks.length) select(index+1,true); else { wantsPlay=false; state='finished'; publish(); } } });
  audio.addEventListener('error',() => { if (current() && audio.error) retryOrFail(); });
  if ('mediaSession' in navigator) {
    for (const [key,handler] of Object.entries({play,pause,previoustrack:()=>select(index-1,true),nexttrack:()=>select(index+1,true),
      seekto:p=>seek(p.seekTime),seekbackward:p=>seek((decoded?decodedTime():audio.currentTime)-(p.seekOffset||10)),seekforward:p=>seek((decoded?decodedTime():audio.currentTime)+(p.seekOffset||10)),stop:()=>reset()})) {
      try { navigator.mediaSession.setActionHandler(key,handler); } catch { /* Optional media command. */ }
    }
  }
  function release() {
    clearDecoded(); clearInterval(decodedUpdates);
    cancelRetry(); clearInterval(meter); meter=0; wantsPlay=false; attempt++; audio.pause();
    audio.removeAttribute('src'); audio.load();
    if (context && context.state !== 'closed') context.close().catch(() => {});
  }
  window.addEventListener('pagehide', release, {once:true});
  window.addEventListener('beforeunload', release, {once:true});
  const decodedUpdates=setInterval(()=>{ if (decoded?.node) publish(); },250);
  return {prepareAudio,action,visualize,eq,queue,reset,fail,enqueue,releaseTrack, get queueItems(){return tracks;}, get revision(){return revision;}, get origin(){return origin;}};
})();
