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
  root.removeAttribute('data-iplex-archive-loading');
})();
