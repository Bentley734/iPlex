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
    choice.value = source ? selected : 'themeDefault';
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
