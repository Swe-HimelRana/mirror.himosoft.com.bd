/**
 * Load packages.json and render mirror landing page sections.
 */
(function () {
  const PACKAGES_URL = 'packages.json';
  let catalog = null;
  let searchQuery = '';

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

  function packageMatches(pkg, query) {
    if (!query) return true;
    const haystack = [
      pkg.name,
      pkg.title,
      pkg.description,
      pkg.status,
      (pkg.tags || []).join(' '),
      pkg.installCommand,
      pkg.usageCommand,
    ]
      .filter(Boolean)
      .join(' ')
      .toLowerCase();
    return haystack.includes(query);
  }

  function filteredPackages() {
    if (!catalog) return [];
    const query = searchQuery.trim().toLowerCase();
    return catalog.packages.filter(function (pkg) {
      return packageMatches(pkg, query);
    });
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

  function renderPackageCard(pkg) {
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
  }

  function updateMeta(data, visibleCount) {
    const meta = document.querySelector('[data-packages-meta]');
    if (!meta || !data) return;

    const total = data.packages.length;
    const query = searchQuery.trim();
    let countLine = '';

    if (query) {
      countLine = `<span>${visibleCount} of ${total} shown</span> · `;
    } else {
      countLine =
        `<span>${data.packageCount.available} available</span> · ` +
        `<span>${data.packageCount.planned} planned</span> · `;
    }

    if (data.generatedAt) {
      const t = new Date(data.generatedAt);
      countLine += `Updated <time datetime="${esc(data.generatedAt)}">${t.toLocaleString()}</time>`;
    }

    meta.innerHTML = countLine;
  }

  function renderPackages() {
    const grid = document.querySelector('[data-packages-grid]');
    const empty = document.querySelector('[data-search-empty]');
    if (!grid || !catalog) return;

    const packages = filteredPackages();
    updateMeta(catalog, packages.length);

    if (packages.length === 0) {
      grid.innerHTML = '';
      grid.classList.remove('loading');
      if (empty) empty.hidden = !searchQuery.trim();
      return;
    }

    if (empty) empty.hidden = true;
    grid.innerHTML = packages.map(renderPackageCard).join('');
    grid.classList.remove('loading');
  }

  function setupSearch() {
    const wrap = document.querySelector('[data-package-search]');
    const input = document.getElementById('package-search-input');
    const clearBtn = document.querySelector('[data-search-clear]');
    if (!wrap || !input) return;

    wrap.hidden = false;

    function syncClear() {
      if (clearBtn) clearBtn.hidden = !input.value;
    }

    input.addEventListener('input', function () {
      searchQuery = input.value;
      syncClear();
      renderPackages();
    });

    if (clearBtn) {
      clearBtn.addEventListener('click', function () {
        input.value = '';
        searchQuery = '';
        syncClear();
        renderPackages();
        input.focus();
      });
    }

    input.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') {
        input.value = '';
        searchQuery = '';
        syncClear();
        renderPackages();
        input.blur();
      }
    });
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
      catalog = data;
      renderHero(data.featuredInstall);
      setupSearch();
      renderPackages();
    })
    .catch(function (err) {
      showError(err.message || 'Failed to load packages');
      console.error(err);
    });
})();
