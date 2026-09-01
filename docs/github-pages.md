# GitHub Pages

Site and APT mirror are deployed by [.github/workflows/deploy-mirror.yml](../.github/workflows/deploy-mirror.yml) on push to `main`.

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
2. Register in `packages/manifest.json`
3. Push to `main` — GitHub Actions builds all `.deb` files and publishes to Pages
