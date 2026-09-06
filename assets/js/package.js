/**
 * Render per-package instruction page from packages.json.
 * URL: /packages/<name>.html  or  /package.html?p=<name>
 */
(function () {
  const PACKAGES_URL = '../packages.json';

  function packageDocsHref(pkg) {
    if (pkg.docsUrl) {
      return pkg.docsUrl.startsWith('/') ? pkg.docsUrl : '/' + pkg.docsUrl.replace(/^\/+/, '');
    }
    return `/packages/${encodeURIComponent(pkg.name)}.html`;
  }

  function esc(s) {
    const d = document.createElement('div');
    d.textContent = s ?? '';
    return d.innerHTML;
  }

  function packageNameFromUrl() {
    const params = new URLSearchParams(window.location.search);
    const query = params.get('p');
    if (query) return query;

    const match = window.location.pathname.match(/\/packages\/([^/]+)\.html$/);
    if (match) return decodeURIComponent(match[1]);

    return null;
  }

  function formatBytes(n) {
    if (!n) return '';
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    return (n / (1024 * 1024)).toFixed(1) + ' MB';
  }

  function renderCodeBlock(text, multiline) {
    if (!text) return '';
    const lines = String(text).split('\n');
    const html = lines
      .map(function (line) {
        if (line.startsWith('#')) {
          return `<div class="comment">${esc(line)}</div>`;
        }
        return `<div><span class="cmd">${esc(line)}</span></div>`;
      })
      .join('');
    return `<div class="code-block${multiline ? ' code-block-wide' : ''}">${html}</div>`;
  }

  function renderSteps(steps) {
    if (!steps || !steps.length) return '';
    return (
      '<ol class="doc-steps">' +
      steps
        .map(function (step) {
          let inner = `<strong>${esc(step.title || 'Step')}</strong>`;
          if (step.body) {
            inner += `<p>${esc(step.body)}</p>`;
          }
          if (step.command) {
            inner += renderCodeBlock(step.command, true);
          }
          return `<li>${inner}</li>`;
        })
        .join('') +
      '</ol>'
    );
  }

  function renderCommands(commands) {
    if (!commands || !commands.length) return '';
    const rows = commands
      .map(function (c) {
        return (
          '<tr>' +
          `<td><code>${esc(c.command)}</code></td>` +
          `<td>${esc(c.description || '')}</td>` +
          '</tr>'
        );
      })
      .join('');
    return (
      '<div class="doc-section">' +
      '<h2>Commands</h2>' +
      '<div class="cmd-table-wrap">' +
      '<table class="cmd-table">' +
      '<thead><tr><th>Command</th><th>Description</th></tr></thead>' +
      `<tbody>${rows}</tbody>` +
      '</table></div></div>'
    );
  }

  function renderList(title, items) {
    if (!items || !items.length) return '';
    return (
      '<div class="doc-section">' +
      `<h2>${esc(title)}</h2>` +
      '<ul class="doc-list">' +
      items.map(function (item) {
        return `<li>${esc(item)}</li>`;
      }).join('') +
      '</ul></div>'
    );
  }

  function renderRelated(names, allPackages) {
    if (!names || !names.length) return '';
    const links = names
      .map(function (name) {
        const pkg = allPackages.find(function (p) {
          return p.name === name;
        });
        if (!pkg) return `<li><code>${esc(name)}</code></li>`;
        const href = packageDocsHref(pkg);
        return `<li><a href="${esc(href)}">${esc(pkg.title || name)}</a> <span class="muted">(${esc(name)})</span></li>`;
      })
      .join('');
    return (
      '<div class="doc-section">' +
      '<h2>Related packages</h2>' +
      `<ul class="doc-list related-list">${links}</ul>` +
      '</div>'
    );
  }

  function renderPackage(pkg, allPackages) {
    const docs = pkg.docs || {};
    const status = pkg.status || 'planned';
    const tags = (pkg.tags || [])
      .map(function (t) {
        return `<span class="tag-item">${esc(t)}</span>`;
      })
      .join('');

    let meta = '';
    if (pkg.deb) {
      meta =
        `<p class="pkg-meta">` +
        `Version <strong>v${esc(pkg.version)}</strong> · ` +
        `${esc(pkg.architecture)} · ${formatBytes(pkg.deb.sizeBytes)} · ` +
        `<a href="${esc(pkg.deb.url)}">${esc(pkg.deb.filename)}</a>` +
        '</p>';
    }

    const installBlock = pkg.installCommand
      ? '<div class="doc-section"><h2>Install</h2>' +
        renderCodeBlock(
          (pkg.installCommand.includes('\n') ? '' : 'sudo apt update &&\n') + pkg.installCommand,
          true
        ) +
        '</div>'
      : '';

    const usageBlock =
      pkg.usageCommand && pkg.usageCommand !== pkg.installCommand
        ? '<div class="doc-section"><h2>Quick start</h2>' +
          renderCodeBlock(pkg.usageCommand, false) +
          '</div>'
        : '';

    const stepsBlock =
      docs.steps && docs.steps.length
        ? '<div class="doc-section"><h2>Step-by-step</h2>' + renderSteps(docs.steps) + '</div>'
        : '';

    document.title = `${pkg.title || pkg.name} — HimoSoft Linux Mirror`;
    const breadcrumb = document.querySelector('[data-breadcrumb-current]');
    if (breadcrumb) breadcrumb.textContent = pkg.name;

    return (
      '<header class="package-doc-header">' +
      `<div class="pkg-name">${esc(pkg.name)}</div>` +
      `<h1>${esc(pkg.title || pkg.name)}</h1>` +
      `<p class="package-lead">${esc(docs.overview || pkg.description)}</p>` +
      meta +
      `<div class="tags">${tags}<span class="tag-item status-${esc(status)}">${esc(status)}</span></div>` +
      '</header>' +
      installBlock +
      usageBlock +
      stepsBlock +
      renderCommands(docs.commands) +
      renderList('Prerequisites', docs.prerequisites) +
      renderList('Notes', docs.notes) +
      renderRelated(docs.relatedPackages, allPackages) +
      '<div class="doc-section doc-back">' +
      '<a class="btn-secondary" href="../#packages">← Back to all packages</a>' +
      '</div>'
    );
  }

  function showError(msg) {
    const root = document.querySelector('[data-package-doc]');
    if (root) {
      root.innerHTML = `<p class="doc-error">${esc(msg)}</p><p><a href="../#packages">← Back to packages</a></p>`;
      root.classList.remove('loading');
    }
  }

  const name = packageNameFromUrl();
  if (!name) {
    showError('No package specified.');
    return;
  }

  fetch(PACKAGES_URL, { cache: 'no-cache' })
    .then(function (r) {
      if (!r.ok) throw new Error('Could not load packages.json');
      return r.json();
    })
    .then(function (data) {
      const pkg = (data.packages || []).find(function (p) {
        return p.name === name;
      });
      const root = document.querySelector('[data-package-doc]');
      if (!pkg) {
        showError(`Package not found: ${name}`);
        return;
      }
      if (!pkg.docs) {
        showError(`No instructions published yet for ${name}.`);
        return;
      }
      if (root) {
        root.innerHTML = renderPackage(pkg, data.packages || []);
        root.classList.remove('loading');
      }
    })
    .catch(function (err) {
      showError(err.message || 'Failed to load package');
      console.error(err);
    });
})();
