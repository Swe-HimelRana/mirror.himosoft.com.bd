# GitHub Pages

Site and APT mirror are deployed by [deploy-mirror.yml](../.github/workflows/deploy-mirror.yml).

## Custom domain

1. Add `CNAME` file (already in repo root): `mirror.himosoft.com.bd`
2. Cloudflare DNS: `mirror` CNAME → `<org>.github.io` (or user pages host)
3. GitHub repo **Settings → Pages → Custom domain** → `mirror.himosoft.com.bd`

## Local preview

```bash
./scripts/build-all.sh
./scripts/publish-apt-repo.sh
cd site && python3 -m http.server 8765
# Open http://localhost:8765
```

## Adding a new package

1. Copy `packages/himosoft-k3s-server/` as a template
2. Register in `scripts/build-all.sh`
3. Update `index.html` package list
4. Push to `main` — CI rebuilds and publishes
