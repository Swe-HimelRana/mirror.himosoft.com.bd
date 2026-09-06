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

  function renderPackageCard(pkg) {
    const status = pkg.status || 'planned';
    const hasDocs = !!(pkg.docsUrl || pkg.docs);
    const docsHref = packageDocsHref(pkg);

    const tags = (pkg.tags || [])
      .filter(function (t) {
        return t !== 'stable' && t !== 'planned';
      })
      .slice(0, 5)
      .map(function (t) {
        return `<span class="pkg-row__tag">${esc(t)}</span>`;
      })
      .join('');

    let version = '';
    if (pkg.deb) {
      version = `<span class="pkg-row__version">v${esc(pkg.version)}</span>`;
    } else if (status === 'planned') {
      version = '<span class="pkg-row__version pkg-row__version--muted">Soon</span>';
    }

    const inner = `
      <div class="pkg-row__main">
        <div class="pkg-row__head">
          <h3 class="pkg-row__title">${esc(pkg.title)}</h3>
          <span class="pkg-row__status pkg-row__status--${esc(status)}">${esc(STATUS_LABEL[status] || status)}</span>
        </div>
        <div class="pkg-row__name">${esc(pkg.name)}</div>
        <p class="pkg-row__desc">${esc(pkg.description)}</p>
        ${tags ? `<div class="pkg-row__tags">${tags}</div>` : ''}
      </div>
      <div class="pkg-row__aside">
        ${version}
        ${hasDocs ? '<span class="pkg-row__arrow" aria-hidden="true">→</span>' : ''}
      </div>`;

    if (hasDocs) {
      return `<a class="pkg-row pkg-row--link status-${esc(status)}" href="${esc(docsHref)}">${inner}</a>`;
    }
    return `<article class="pkg-row status-${esc(status)}">${inner}</article>`;
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
