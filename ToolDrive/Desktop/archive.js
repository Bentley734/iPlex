(() => {
  const root = document.documentElement;
  const oldHeader = document.querySelector('.topbar');
  const tools = oldHeader.querySelector('.topbar-tools');
  const search = document.querySelector('.search-wrap');
  search.querySelector('input').placeholder = 'Search shows';
  const header = document.createElement('header');
  header.className = 'iplex-archive-header';
  const title = document.createElement('h1');
  title.textContent = 'Tool Drive';
  header.append(title, search, tools);
  oldHeader.after(header);
  const listHead = document.getElementById('list-head');
  const showList = document.getElementById('show-list');
  const table = document.createElement('div');
  table.className = 'iplex-archive-table';
  listHead.before(table);
  table.append(listHead, showList);
  document.querySelector('#show-library').textContent = 'Recording Library';

  window.applyIPlexArchiveAppearance = settings => {
    title.textContent = settings.title || 'Tool Drive';
    root.style.setProperty('--iplex-text', settings.text);
    root.style.setProperty('--iplex-accent', settings.accent);
    root.style.setProperty('--iplex-density', settings.density);
    root.style.setProperty('--iplex-tint', settings.tint || 'transparent');
    root.style.setProperty('--iplex-background', settings.background || 'transparent');
    if (settings.background && settings.tint) {
      root.style.setProperty('--iplex-wash', 'color-mix(in srgb, var(--iplex-tint) calc(7% + 12% * var(--iplex-density)), transparent)');
    } else {
      root.style.removeProperty('--iplex-wash');
    }
    root.toggleAttribute('data-iplex-hover', settings.hover);
  };
  if (window.initialIPlexArchiveAppearance) window.applyIPlexArchiveAppearance(window.initialIPlexArchiveAppearance);
  if (window.toolWindows) {
    const updateArchivePlayer = window.macPlayerState;
    window.macPlayerState = state => {
      updateArchivePlayer?.(state);
      if (!state) return;
      const {visible, status, title, context, message, elapsed, duration, canPrevious, canNext} = state;
      window.toolWindows.send('iplexTransport', {
        visible, status, title, context, message, elapsed, duration, canPrevious, canNext,
        canToggle: Array.isArray(state.tracks) && state.tracks.length > 0 &&
          !['loading', 'resolving', 'error'].includes(status)
      });
    };
    window.iplexArchiveTransport = request => {
      switch (request.action) {
        case 'toggle': case 'previous': case 'next': case 'seek': case 'close':
          window.windowsPlayback?.action(request);
          break;
        case 'eq': case 'visualizer': case 'tracklist':
          document.getElementById('mac-player-' + request.action)?.click();
          break;
      }
    };
  }
  root.removeAttribute('data-iplex-archive-loading');
})();
