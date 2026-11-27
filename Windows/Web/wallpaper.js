(() => {
  'use strict';

  const root = document.documentElement;
  const choice = document.getElementById('glass-wallpaper-choice');
  const tint = document.getElementById('glass-tint');
  const picker = document.getElementById('glass-wallpaper-file');
  const preview = document.getElementById('glass-wallpaper-preview');
  const remove = document.getElementById('remove-glass-wallpaper');
  const status = document.getElementById('glass-wallpaper-status');
  const maximumBytes = 25 * 1024 * 1024;
  const presets = new Set(['prism-tide', 'ember-fold', 'violet-orbit']);
  const choiceKey = 'musicroom-glass-background';
  const gradientKey = 'musicroom-glass-gradient';
  const get = id => document.getElementById('glass-gradient-' + id);
  const gradientColors = ['first','second','third'].map(get);
  const gradientMotion = get('motion');
  const gradientSpeed = get('speed');
  const gradientDurations = {slow:48, normal:30, fast:16};
  const dimming = get('dimming');
  const palette = get('palette');
  const paletteName = get('name');
  const paletteKey = 'musicroom-glass-gradient-palettes';
  const builtIn = [
    ['Ocean', ['#253e7d', '#167f87', '#732e72']],
    ['Sunset', ['#55264f', '#a74447', '#e18043']],
    ['Evergreen', ['#173743', '#287657', '#7c8f49']],
    ['Midnight', ['#101739', '#364488', '#5e3f7a']]
  ];
  let savedPalettes = [];
  try {
    const entries = JSON.parse(localStorage.getItem(paletteKey));
    if (Array.isArray(entries)) savedPalettes = entries.filter(entry =>
      Array.isArray(entry) && typeof entry[0] === 'string' && Array.isArray(entry[1]) &&
      entry[1].length === 3 && entry[1].every(color => /^#[a-f0-9]{6}$/i.test(color)));
  } catch {}

  function renderPalettes(value = '') {
    palette.replaceChildren(new Option('Custom Colors', ''));
    builtIn.forEach(([name], index) => palette.add(new Option(name, 'preset-' + index)));
    savedPalettes.forEach(([name], index) => palette.add(new Option(name, 'saved-' + index)));
    palette.value = value;
    get('remove').hidden = !value.startsWith('saved-');
  }

  function storePalettes(value) {
    try { localStorage.setItem(paletteKey, JSON.stringify(savedPalettes)); } catch {}
    renderPalettes(value);
  }

  palette.addEventListener('change', () => {
    const [category, index] = palette.value.split('-');
    const entry = (category === 'saved' ? savedPalettes : builtIn)[index];
    if (entry) {
      entry[1].forEach((color, index) => { gradientColors[index].value = color; });
      saveGradient();
    }
    get('remove').hidden = category !== 'saved';
  });
  get('save').addEventListener('click', () => {
    const name = paletteName.value.trim();
    if (!name) return;
    savedPalettes = savedPalettes.filter(([existing]) => existing.toLowerCase() !== name.toLowerCase());
    savedPalettes.push([name, gradientColors.map(input => input.value)]);
    storePalettes('saved-' + (savedPalettes.length - 1));
    paletteName.value = '';
  });
  get('remove').addEventListener('click', () => {
    if (!palette.value.startsWith('saved-')) return;
    savedPalettes.splice(Number(palette.value.slice(6)), 1);
    storePalettes('');
  });
  renderPalettes();
  try {
    const saved = JSON.parse(localStorage.getItem(gradientKey));
    gradientColors.forEach((input, index) => {
      if (/^#[a-f0-9]{6}$/i.test(saved?.colors?.[index])) input.value = saved.colors[index];
    });
    if (Number.isFinite(saved?.dimming)) dimming.value = saved.dimming;
    if ([...gradientMotion.options].some(option => option.value === saved?.motion)) gradientMotion.value = saved.motion;
    if ([...gradientSpeed.options].some(option => option.value === saved?.speed)) gradientSpeed.value = saved.speed;
  } catch {}

  function renderGradient() {
    const active = selected === 'gradient';
    get('settings').hidden = !active;
    get('speed-label').hidden = gradientMotion.value === 'still';
    root.toggleAttribute('data-animated-gradient', active);
    root.dataset.gradientMotion = gradientMotion.value;
    gradientColors.forEach((input, index) => root.style.setProperty('--gradient-color-' + (index+1), input.value));
    root.style.setProperty('--gradient-dimming', String(Number(dimming.value)));
    get('dimming-value').value = Math.round(Number(dimming.value) * 100) + '%';
    root.style.setProperty('--gradient-duration', gradientDurations[gradientSpeed.value] + 's');
  }

  function saveGradient() {
    try {
      localStorage.setItem(gradientKey, JSON.stringify({
        colors:gradientColors.map(input => input.value), motion:gradientMotion.value, speed:gradientSpeed.value, dimming:Number(dimming.value)
      }));
    } catch {}
    renderGradient();
  }

  gradientColors.forEach(input => input.addEventListener('input', () => {
    renderPalettes();
    saveGradient();
  }));
  dimming.addEventListener('input', saveGradient);
  gradientMotion.addEventListener('change', saveGradient);
  gradientSpeed.addEventListener('change', saveGradient);

  let selected = 'custom';
  try { selected = localStorage.getItem(choiceKey) || 'custom'; } catch {}
  let objectURL = '';

  function chooseTint(value) {
    tint.value = value;
    if (tint.selectedIndex === -1) tint.value = 'themeDefault';
    root.dataset.glassTint = tint.value;
    try { localStorage.setItem('musicroom-liquid-glass-tint', tint.value); } catch {}
  }

  tint.addEventListener('change', () => chooseTint(tint.value));
  let savedTint = 'themeDefault';
  try { savedTint = localStorage.getItem('musicroom-liquid-glass-tint') || savedTint; } catch {}
  chooseTint(savedTint);

  function setWorking(working) {
    choice.disabled = working;
    picker.disabled = working;
    remove.disabled = working;
  }

  function display(blob) {
    if (objectURL) URL.revokeObjectURL(objectURL);
    objectURL = blob ? URL.createObjectURL(blob) : '';
    render();
  }

  function render() {
    const preset = presets.has(selected);
    const source = preset ? 'GlassBackgrounds/' + selected + '.jpg' : selected === 'custom' ? objectURL : '';
    choice.querySelector('[value="custom"]').hidden = !objectURL;
    choice.value = source || selected === 'gradient' ? selected : 'themeDefault';
    renderGradient();
    root.toggleAttribute('data-custom-wallpaper', Boolean(source));
    root.toggleAttribute('data-preset-wallpaper', preset);
    preview.hidden = !source;
    remove.hidden = !objectURL;
    if (source) {
      preview.src = source;
      root.style.setProperty('--glass-wallpaper', 'url("' + source + '")');
    } else {
      preview.removeAttribute('src');
      root.style.removeProperty('--glass-wallpaper');
    }
  }

  function choose(value) {
    selected = value;
    try { localStorage.setItem(choiceKey, value); } catch {}
    render();
  }

  choice.addEventListener('change', () => {
    status.textContent = '';
    choose(choice.value);
  });

  async function database() {
    return new Promise((resolve, reject) => {
      const open = indexedDB.open('iplex-appearance', 1);
      open.onupgradeneeded = () => open.result.createObjectStore('images');
      open.onsuccess = () => resolve(open.result);
      open.onerror = () => reject(open.error);
    });
  }

  async function withWallpaper(mode, operation) {
    const db = await database();
    try {
      return await new Promise((resolve, reject) => {
        const transaction = db.transaction('images', mode);
        const request = operation(transaction.objectStore('images'));
        transaction.oncomplete = () => resolve(request.result);
        transaction.onabort = () => reject(transaction.error);
        transaction.onerror = () => reject(transaction.error);
      });
    } finally {
      db.close();
    }
  }

  async function normalize(file) {
    const decoded = await createImageBitmap(file);
    try {
      const scale = Math.min(1, 2560 / Math.max(decoded.width, decoded.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(decoded.width * scale));
      canvas.height = Math.max(1, Math.round(decoded.height * scale));
      const context = canvas.getContext('2d', {alpha:false});
      context.drawImage(decoded, 0, 0, canvas.width, canvas.height);
      const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/jpeg', 0.86));
      if (!blob) throw new Error('Image conversion failed');
      return blob;
    } finally {
      decoded.close();
    }
  }

  picker.addEventListener('change', async () => {
    const file = picker.files?.[0];
    picker.value = '';
    if (!file) return;
    if (file.size > maximumBytes) {
      status.textContent = 'Choose an image smaller than 25 MB.';
      return;
    }
    setWorking(true);
    status.textContent = 'Saving background…';
    try {
      const blob = await normalize(file);
      await withWallpaper('readwrite', store => store.put(blob, 'wallpaper'));
      choose('custom');
      display(blob);
      status.textContent = 'Background updated.';
    } catch {
      status.textContent = 'Couldn’t load or save that background image.';
    } finally {
      setWorking(false);
    }
  });

  remove.addEventListener('click', async () => {
    setWorking(true);
    try {
      await withWallpaper('readwrite', store => store.delete('wallpaper'));
      if (selected === 'custom') choose('themeDefault');
      display(null);
      status.textContent = 'Background removed.';
    } catch {
      status.textContent = 'Couldn’t remove the background.';
    } finally {
      setWorking(false);
    }
  });

  render();
  setWorking(true);
  withWallpaper('readonly', store => store.get('wallpaper'))
    .then(blob => { if (blob instanceof Blob) display(blob); })
    .catch(() => {})
    .finally(() => setWorking(false));
})();
