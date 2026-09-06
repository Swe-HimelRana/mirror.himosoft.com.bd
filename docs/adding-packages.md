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

## 2. Add package instructions

Create [`packages/docs/<package-name>.json`](../packages/docs/) so the catalog card links to a full instructions page:

```json
{
  "overview": "Longer description for the package page.",
  "prerequisites": ["Debian or Ubuntu", "sudo access"],
  "steps": [
    {
      "title": "Install",
      "body": "Optional explanation.",
      "command": "sudo apt install himosoft-my-tool"
    }
  ],
  "commands": [
    { "command": "sudo himosoft-my-tool status", "description": "Show status" }
  ],
  "notes": ["Config saved to /etc/himosoft/my-tool.conf"],
  "relatedPackages": ["himosoft-common"]
}
```

CI publishes `packages/<name>.html` automatically when a docs file exists.

## 3. Create the Debian package

```bash
cp -r packages/himosoft-k3s-server packages/himosoft-my-tool
# edit debian/control, build.sh version, src/...
```

Register in [`scripts/build-all.sh`](../scripts/build-all.sh).

## 4. Push to main

GitHub Actions will:

1. Build all `packages/*/build/*.deb`
2. Run [`scripts/generate-packages-json.py`](../scripts/generate-packages-json.py)
3. Publish `packages.json`, per-package instruction pages, and the landing page to GitHub Pages

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
| `packages[].docs` | Merged from `packages/docs/<name>.json` |
| `packages[].docsUrl` | Link to `/packages/<name>.html` instructions page |

The landing page loads `packages.json` dynamically. Package cards link to their instructions page when docs exist.
