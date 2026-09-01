# Adding a package to the mirror

## 1. Edit the manifest (display + metadata)

Add an entry to [`packages/manifest.json`](../packages/manifest.json):

```json
{
  "name": "himosoft-my-tool",
  "title": "Short title for the landing page",
  "description": "What it does.",
  "status": "available",
  "architecture": "all",
  "installCommand": "sudo apt install himosoft-my-tool",
  "usageCommand": "sudo himosoft-my-tool",
  "tags": ["k3s", "stable"]
}
```

Use `"status": "planned"` for packages not built yet — they still appear on the site.

## 2. Create the Debian package

```bash
cp -r packages/himosoft-k3s-server packages/himosoft-my-tool
# edit debian/control, build.sh version, src/...
```

Register in [`scripts/build-all.sh`](../scripts/build-all.sh).

## 3. Push to main

GitHub Actions will:

1. Build all `packages/*/build/*.deb`
2. Run [`scripts/generate-packages-json.py`](../scripts/generate-packages-json.py)
3. Publish `packages.json` + landing page to GitHub Pages

## packages.json schema

Generated at `https://mirror.himosoft.com.bd/packages.json`:

| Field | Description |
|-------|-------------|
| `generatedAt` | ISO timestamp of last CI build |
| `mirrorUrl` | Base URL |
| `featuredInstall` | Hero section install commands |
| `packages[]` | Merged manifest + built `.deb` info |
| `packages[].deb.url` | Direct download link when built |
| `packages[].version` | From `.deb` control file |

The landing page loads this file dynamically — no HTML edits needed for new packages.
