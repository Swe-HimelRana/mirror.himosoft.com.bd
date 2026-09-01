/**
 * Load packages.json and render mirror landing page sections.
 */
(function () {
  const PACKAGES_URL = 'packages.json';

  function esc(s) {
    const d = document.createElement('div');
    d.textContent = s ?? '';
    return d.innerHTML;
  }

  function formatBytes(n) {
    if (!n) return '';
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    return (n / (1024 * 1024)).toFixed(1) + ' MB';
  }

  function renderHero(featured) {
    const block = document.querySelector('[data-hero-commands]');
    if (!block || !featured) return;

    const example = featured.examplePackage || 'himosoft-k3s-server';
    const installLine = (featured.installTemplate || 'sudo apt install <package-name>').replace(
      '<package-name>',
      example
    );

    block.innerHTML = `
      <div class="comment"># 1. Add this mirror (once per server)</div>
      <div><span class="cmd">${esc(featured.mirrorScript)}</span></div>
      <div class="comment"># 2. Install any package from the catalog</div>
      <div><span class="cmd">${esc(featured.aptUpdate || 'sudo apt update')}</span></div>
      <div><span class="cmd">${esc(installLine)}</span></div>
    `;
    block.classList.remove('loading');
  }

  function renderPackages(data) {
    const grid = document.querySelector('[data-packages-grid]');
    const meta = document.querySelector('[data-packages-meta]');
    if (!grid) return;

    if (meta && data.generatedAt) {
      const t = new Date(data.generatedAt);
      meta.innerHTML =
        `<span>${data.packageCount.available} available</span> · ` +
        `<span>${data.packageCount.planned} planned</span> · ` +
        `Updated <time datetime="${esc(data.generatedAt)}">${t.toLocaleString()}</time>`;
    }

    if (!data.packages || data.packages.length === 0) {
      grid.innerHTML = '<p class="loading">No packages listed.</p>';
      grid.classList.remove('loading');
      return;
    }

    grid.innerHTML = data.packages
      .map(function (pkg) {
        const status = pkg.status || 'planned';
        const tags = (pkg.tags || [])
          .map(function (t) {
            const cls = t === 'stable' || t === 'planned' ? 'status-' + t : '';
            return `<span class="tag-item ${cls}">${esc(t)}</span>`;
          })
          .join('');

        let extra = '';
        if (pkg.deb) {
          extra =
            `<div class="pkg-version">v${esc(pkg.version)} · ${esc(pkg.architecture)} · ${formatBytes(pkg.deb.sizeBytes)}</div>` +
            `<a class="deb-link" href="${esc(pkg.deb.url)}">${esc(pkg.deb.filename)}</a>`;
        } else if (status === 'planned') {
          extra = '<span class="tag">coming soon</span>';
        } else if (status === 'missing') {
          extra = '<span class="tag" style="color:#f87171">build missing</span>';
        }

        const install =
          pkg.installCommand && status === 'available'
            ? `<div class="tag-item" style="margin-top:0.5rem;font-family:var(--mono)">${esc(pkg.installCommand)}</div>`
            : '';

        return `
          <article class="card status-${esc(status)}">
            <div class="pkg-name">${esc(pkg.name)}</div>
            <h3>${esc(pkg.title)}</h3>
            ${extra}
            <p>${esc(pkg.description)}</p>
            ${install}
            <div class="tags">${tags}</div>
          </article>
        `;
      })
      .join('');

    grid.classList.remove('loading');
  }

  function showError(msg) {
    const grid = document.querySelector('[data-packages-grid]');
    if (grid) {
      grid.innerHTML = `<p class="loading">${esc(msg)}</p>`;
      grid.classList.remove('loading');
    }
  }

  fetch(PACKAGES_URL, { cache: 'no-cache' })
    .then(function (r) {
      if (!r.ok) throw new Error('Could not load packages.json');
      return r.json();
    })
    .then(function (data) {
      renderHero(data.featuredInstall);
      renderPackages(data);
    })
    .catch(function (err) {
      showError(err.message || 'Failed to load packages');
      console.error(err);
    });
})();
