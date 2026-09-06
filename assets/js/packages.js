/**
 * Load packages.json and render mirror landing page sections.
 */
(function () {
  const PACKAGES_URL = 'packages.json';
  let catalog = null;
  let searchQuery = '';
  let activeTag = 'all';

  const CATEGORY = {
    k3s: { label: 'Kubernetes', icon: 'K8s', tone: 'k8s' },
    kubernetes: { label: 'Kubernetes', icon: 'K8s', tone: 'k8s' },
    argocd: { label: 'GitOps', icon: 'Git', tone: 'k8s' },
    traefik: { label: 'Ingress', icon: 'Ing', tone: 'k8s' },
    docker: { label: 'Docker', icon: 'Dkr', tone: 'docker' },
    monitoring: { label: 'Monitoring', icon: 'Mon', tone: 'monitor' },
    grafana: { label: 'Grafana', icon: 'Gfn', tone: 'monitor' },
    prometheus: { label: 'Prometheus', icon: 'Prm', tone: 'monitor' },
    dashboard: { label: 'Dashboard', icon: 'Dash', tone: 'monitor' },
    htop: { label: 'Dashboard', icon: 'Dash', tone: 'monitor' },
    security: { label: 'Security', icon: 'Sec', tone: 'security' },
    database: { label: 'Database', icon: 'DB', tone: 'database' },
    replica: { label: 'Replica', icon: 'Rep', tone: 'database' },
    backup: { label: 'Backup', icon: 'Bak', tone: 'backup' },
    restic: { label: 'Backup', icon: 'Bak', tone: 'backup' },
    tools: { label: 'Tools', icon: 'Ops', tone: 'tools' },
    performance: { label: 'Performance', icon: 'Tune', tone: 'tools' },
    diagnostics: { label: 'Diagnostics', icon: 'Diag', tone: 'diagnostics' },
    library: { label: 'Library', icon: 'Lib', tone: 'library' },
    kubectl: { label: 'Kubernetes', icon: 'K8s', tone: 'k8s' },
    'server-a': { label: 'Server A', icon: 'A', tone: 'server' },
    'server-b': { label: 'Server B', icon: 'B', tone: 'server' },
    'server-c': { label: 'Server C', icon: 'C', tone: 'server' },
  };

  const STATUS_LABEL = {
    available: 'Available',
    planned: 'Coming soon',
    missing: 'Build missing',
  };

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

  function packageDocsHref(pkg) {
    if (pkg.docsUrl) {
      return pkg.docsUrl.startsWith('/') ? pkg.docsUrl : '/' + pkg.docsUrl.replace(/^\/+/, '');
    }
    return `/packages/${encodeURIComponent(pkg.name)}.html`;
  }

  function packageCategory(pkg) {
    const tags = pkg.tags || [];
    for (let i = 0; i < tags.length; i++) {
      if (CATEGORY[tags[i]]) return CATEGORY[tags[i]];
    }
    return { label: 'Package', icon: 'Pkg', tone: 'default' };
  }

  function packageMatches(pkg, query, tag) {
    if (tag && tag !== 'all') {
      const tags = pkg.tags || [];
      if (!tags.includes(tag)) return false;
    }
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
      return packageMatches(pkg, query, activeTag);
    });
  }

  function collectFilterTags(packages) {
    const counts = {};
    packages.forEach(function (pkg) {
      (pkg.tags || []).forEach(function (tag) {
        if (tag === 'stable' || tag === 'planned') return;
        counts[tag] = (counts[tag] || 0) + 1;
      });
    });
    return Object.keys(counts)
      .sort(function (a, b) {
        return counts[b] - counts[a] || a.localeCompare(b);
      })
      .map(function (tag) {
        return { tag: tag, count: counts[tag], label: (CATEGORY[tag] && CATEGORY[tag].label) || tag };
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

  function renderStatusBadge(status) {
    const label = STATUS_LABEL[status] || status;
    return `<span class="pkg-card__status pkg-card__status--${esc(status)}">${esc(label)}</span>`;
  }

  function renderTags(tags, status) {
    const visible = (tags || []).filter(function (t) {
      return t !== 'stable' && t !== 'planned';
    });
    const items = visible
      .slice(0, 4)
      .map(function (t) {
        return `<span class="pkg-tag">${esc(t)}</span>`;
      })
      .join('');
    return items || `<span class="pkg-tag pkg-tag--muted">${esc(status)}</span>`;
  }

  function renderPackageCard(pkg) {
    const status = pkg.status || 'planned';
    const hasDocs = !!(pkg.docsUrl || pkg.docs);
    const docsHref = packageDocsHref(pkg);
    const cat = packageCategory(pkg);
    const tone = cat.tone || 'default';

    let meta = '';
    if (pkg.deb) {
      meta = `<div class="pkg-card__meta">v${esc(pkg.version)} · ${esc(pkg.architecture)} · ${formatBytes(pkg.deb.sizeBytes)}</div>`;
    } else if (status === 'planned') {
      meta = '<div class="pkg-card__meta pkg-card__meta--muted">Not published yet</div>';
    } else if (status === 'missing') {
      meta = '<div class="pkg-card__meta pkg-card__meta--warn">Build artifact missing</div>';
    }

    const install =
      pkg.installCommand && status === 'available'
        ? `<div class="pkg-card__install"><code>${esc(pkg.installCommand)}</code></div>`
        : '';

    const usage =
      pkg.usageCommand && pkg.usageCommand !== pkg.installCommand && status === 'available'
        ? `<div class="pkg-card__usage">Then: <code>${esc(pkg.usageCommand)}</code></div>`
        : '';

    const footer = `
      <div class="pkg-card__footer">
        <div class="pkg-card__tags">${renderTags(pkg.tags, status)}</div>
        ${hasDocs ? '<span class="pkg-card__cta">View guide <span aria-hidden="true">→</span></span>' : ''}
      </div>`;

    const inner = `
      <div class="pkg-card__accent"></div>
      <div class="pkg-card__body">
        <div class="pkg-card__header">
          <span class="pkg-card__icon pkg-card__icon--${esc(tone)}" aria-hidden="true">${esc(cat.icon)}</span>
          ${renderStatusBadge(status)}
        </div>
        <h3 class="pkg-card__title">${esc(pkg.title)}</h3>
        <div class="pkg-card__name">${esc(pkg.name)}</div>
        <p class="pkg-card__desc">${esc(pkg.description)}</p>
        ${meta}
        ${install}
        ${usage}
        ${footer}
      </div>`;

    if (hasDocs) {
      return `<a class="pkg-card pkg-card--link pkg-card--${esc(tone)} status-${esc(status)}" href="${esc(docsHref)}">${inner}</a>`;
    }
    return `<article class="pkg-card pkg-card--${esc(tone)} status-${esc(status)}">${inner}</article>`;
  }

  function updateMeta(data, visibleCount) {
    const meta = document.querySelector('[data-packages-meta]');
    if (!meta || !data) return;

    const total = data.packages.length;
    const query = searchQuery.trim();
    let countLine = '';

    if (query || activeTag !== 'all') {
      countLine = `<span class="meta-highlight">${visibleCount}</span> of ${total} shown · `;
    } else {
      countLine =
        `<span class="meta-highlight">${data.packageCount.available}</span> available · ` +
        `${data.packageCount.planned} planned · `;
    }

    if (data.generatedAt) {
      const t = new Date(data.generatedAt);
      countLine += `Updated <time datetime="${esc(data.generatedAt)}">${t.toLocaleString()}</time>`;
    }

    meta.innerHTML = countLine;
  }

  function renderTagFilters() {
    const wrap = document.querySelector('[data-tag-filters]');
    if (!wrap || !catalog) return;

    const tags = collectFilterTags(catalog.packages);
    if (tags.length === 0) {
      wrap.hidden = true;
      return;
    }

    wrap.hidden = false;
    const buttons = [{ tag: 'all', label: 'All', count: catalog.packages.length }]
      .concat(tags)
      .map(function (item) {
        const active = activeTag === item.tag ? ' is-active' : '';
        return (
          `<button type="button" class="tag-filter${active}" data-tag="${esc(item.tag)}">` +
          `${esc(item.label)} <span class="tag-filter__count">${item.count}</span>` +
          '</button>'
        );
      })
      .join('');

    wrap.innerHTML = buttons;
    wrap.querySelectorAll('.tag-filter').forEach(function (btn) {
      btn.addEventListener('click', function () {
        activeTag = btn.getAttribute('data-tag') || 'all';
        wrap.querySelectorAll('.tag-filter').forEach(function (b) {
          b.classList.toggle('is-active', b === btn);
        });
        renderPackages();
      });
    });
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
      if (empty) empty.hidden = !(searchQuery.trim() || activeTag !== 'all');
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
      grid.innerHTML = `<div class="pkg-error">${esc(msg)}</div>`;
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
      renderTagFilters();
      renderPackages();
    })
    .catch(function (err) {
      showError(err.message || 'Failed to load packages');
      console.error(err);
    });
})();
