window.interfaceMotion = (() => {
  'use strict';
  const root = document.documentElement;
  const get = id => document.getElementById(id);
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  const pagePicker = get('page-transition');
  const hoverToggle = get('glass-hover-effects');
  let route = null;
  let currentPageAnimation;

  function transition({element, closing = false, expanded = false} = {}) {
    const style = pagePicker.value;
    if (reduce.matches || style === 'none') return null;
    const start = {opacity: expanded ? 0 : .42};
    if (style === 'slide') start.transform = 'translateX(' + (expanded ? 28 : 22) + 'px)';
    if (style === 'zoom') start.transform = 'scale(' + (expanded ? .92 : .97) + ')';
    const end = closing ? {
      opacity:getComputedStyle(element).opacity,
      transform:getComputedStyle(element).transform
    } : {opacity:1, transform:'none'};
    return {frames: closing ? [end, {...start, opacity:0}] : [start, end], options: {
      duration:closing ? 200 : style === 'fade' ? 220 : expanded ? 360 : 290,
      easing:closing ? 'ease-in' : 'cubic-bezier(.16,1,.3,1)',
      fill:closing ? 'forwards' : 'none'
    }};
  }

  function play(element, options) {
    const motion = transition({element, ...options});
    return motion && element.animate ? element.animate(motion.frames, motion.options) : null;
  }

  function show(element, keys, present) {
    if (element.hidden) return;
    const next = JSON.stringify(keys);
    if (route === next) return;
    currentPageAnimation?.cancel();
    if (present) present(route === null ? null : transition());
    else if (route !== null) currentPageAnimation = play(element);
    route = next;
  }

  function applyHover() {
    root.toggleAttribute('data-glass-hover', hoverToggle.checked);
  }

  try {
    const savedPage = localStorage.getItem('musicroom-page-transition');
    if ([...pagePicker.options].some(option => option.value === savedPage)) pagePicker.value = savedPage;
    hoverToggle.checked = localStorage.getItem('musicroom-glass-hover-effects') !== '0';
  } catch {}
  applyHover();

  pagePicker.onchange = () => {
    currentPageAnimation?.cancel();
    try { localStorage.setItem('musicroom-page-transition', pagePicker.value); } catch {}
  };
  hoverToggle.onchange = () => {
    applyHover();
    try { localStorage.setItem('musicroom-glass-hover-effects', hoverToggle.checked ? '1' : '0'); } catch {}
  };
  reduce.addEventListener('change', () => {
    if (reduce.matches) currentPageAnimation?.cancel();
  });
  return {show, play};
})();
