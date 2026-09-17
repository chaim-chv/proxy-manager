(() => {
  'use strict';

  /* ------------------------------------------------------------------ *
   * Color theme: system → light → dark, persisted in localStorage.
   * Sets data-theme on <html>; CSS falls back to prefers-color-scheme.
   * ------------------------------------------------------------------ */
  const THEME_KEY = 'pm-theme';
  const root = document.documentElement;
  const toggles = [...document.querySelectorAll('[data-theme-toggle]')];
  const mql = window.matchMedia('(prefers-color-scheme: dark)');
  const shotImgs = [...document.querySelectorAll('img[data-dark]')];
  let shotsManaged = false;

  const currentPref = () => {
    const v = localStorage.getItem(THEME_KEY);
    return v === 'light' || v === 'dark' ? v : 'system';
  };
  const effectiveDark = () => {
    const p = currentPref();
    return p === 'dark' || (p === 'system' && mql.matches);
  };

  // Once JS runs we own the screenshot source, so drop the <picture> <source>
  // elements — otherwise the OS media query would override a manual choice.
  const manageShots = (dark) => {
    if (!shotsManaged) {
      document.querySelectorAll('picture source').forEach((s) => s.remove());
      shotsManaged = true;
    }
    for (const img of shotImgs) {
      const want = dark ? img.dataset.dark : img.dataset.light;
      if (want && img.getAttribute('src') !== want) img.src = want;
    }
  };

  const applyTheme = () => {
    const pref = currentPref();
    if (pref === 'system') root.removeAttribute('data-theme');
    else root.setAttribute('data-theme', pref);

    for (const btn of toggles) {
      btn.dataset.mode = pref;
      const label = `Color theme: ${pref}`;
      btn.setAttribute('aria-label', label);
      btn.title = label;
    }
    manageShots(effectiveDark());
  };

  const cycleTheme = () => {
    const order = ['system', 'light', 'dark'];
    const next = order[(order.indexOf(currentPref()) + 1) % order.length];
    if (next === 'system') localStorage.removeItem(THEME_KEY);
    else localStorage.setItem(THEME_KEY, next);
    applyTheme();
  };

  toggles.forEach((btn) => btn.addEventListener('click', cycleTheme));
  mql.addEventListener('change', () => { if (currentPref() === 'system') applyTheme(); });
  applyTheme();

  /* ------------------------------------------------------------------ *
   * Download: resolve the latest release so the button shows the version
   * and downloads the .zip directly. Falls back to /releases/latest.
   * ------------------------------------------------------------------ */
  const API = 'https://api.github.com/repos/chaim-chv/proxy-manager/releases/latest';
  const REPO = 'https://github.com/chaim-chv/proxy-manager';
  const CACHE_KEY = 'pm-release';
  const CACHE_TTL = 60 * 60 * 1000;

  async function latestRelease() {
    try {
      const cached = JSON.parse(sessionStorage.getItem(CACHE_KEY) || 'null');
      if (cached && Date.now() - cached.at < CACHE_TTL) return cached.data;
    } catch (_) { /* ignore */ }
    const res = await fetch(API, { headers: { Accept: 'application/vnd.github+json' } });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const data = await res.json();
    try { sessionStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), data })); } catch (_) { /* ignore */ }
    return data;
  }

  function zipUrl(rel) {
    const asset = (rel.assets || []).find((a) => /^ProxyManager-.*\.zip$/i.test(a.name));
    if (asset && asset.browser_download_url) return asset.browser_download_url;
    const tag = rel.tag_name;
    return tag
      ? `${REPO}/releases/download/${tag}/ProxyManager-${tag.replace(/^v/, '')}.zip`
      : null;
  }

  latestRelease()
    .then((rel) => {
      const url = zipUrl(rel);
      if (url) document.querySelectorAll('[data-dl-main]').forEach((a) => { a.href = url; });
      if (rel.tag_name) {
        document.querySelectorAll('[data-dl-version]').forEach((el) => {
          el.textContent = rel.tag_name;
          el.hidden = false;
        });
      }
      if (rel.html_url) {
        document.querySelectorAll('[data-dl-notes]').forEach((a) => { a.href = rel.html_url; });
      }
    })
    .catch(() => { /* keep the /releases/latest fallback */ });

  /* Download dropdown menu */
  const downloads = [...document.querySelectorAll('[data-download]')];
  const closeMenus = (except) => {
    for (const d of downloads) {
      if (d === except) continue;
      const menu = d.querySelector('[data-dl-menu]');
      const toggle = d.querySelector('[data-dl-toggle]');
      if (menu) menu.hidden = true;
      if (toggle) toggle.setAttribute('aria-expanded', 'false');
    }
  };
  for (const d of downloads) {
    const toggle = d.querySelector('[data-dl-toggle]');
    const menu = d.querySelector('[data-dl-menu]');
    if (!toggle || !menu) continue;
    toggle.addEventListener('click', (e) => {
      e.stopPropagation();
      const willOpen = menu.hidden;
      closeMenus(d);
      menu.hidden = !willOpen;
      toggle.setAttribute('aria-expanded', String(willOpen));
    });
  }
  document.addEventListener('click', () => closeMenus());
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeMenus(); });

  /* ------------------------------------------------------------------ *
   * Very subtle cursor tilt on screenshots (max 1°). Opt out on
   * reduced-motion.
   * ------------------------------------------------------------------ */
  if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    const MAX_DEG = 1.0;
    document.querySelectorAll('[data-tilt]').forEach((el) => {
      el.addEventListener('mousemove', (e) => {
        const r = el.getBoundingClientRect();
        const px = (e.clientX - r.left) / r.width - 0.5;
        const py = (e.clientY - r.top) / r.height - 0.5;
        el.style.transform =
          `perspective(1200px) rotateX(${(-py * MAX_DEG).toFixed(2)}deg) ` +
          `rotateY(${(px * MAX_DEG).toFixed(2)}deg) translateY(-2px)`;
      });
      el.addEventListener('mouseleave', () => { el.style.transform = ''; });
    });
  }
})();
