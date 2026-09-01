# Himosoft Package Mirror

Official APT mirror for **all** HimoSoft Linux packages — one source, many tools.

- **Site:** [mirror.himosoft.com.bd](https://mirror.himosoft.com.bd)

## Quick start

```bash
# Add mirror
curl -fsSL https://mirror.himosoft.com.bd/install-mirror.sh | sudo bash

# Install any HimoSoft package
sudo apt update
sudo apt install himosoft-k3s-server   # example — see packages.json for full catalog
```

## Packages

| Package | Description |
|---------|-------------|
| `himosoft-k3s-server` | Interactive K3s install — detects public IP, prompts for domain & options |

## Interactive setup flow

```
╔══════════════════════════════════════════╗
║     Himosoft K3s Server — Setup          ║
╚══════════════════════════════════════════╝

Detected public IP: 194.62.248.81
Use detected public IP? [Y/n]:
Domain (K3s TLS SAN) [srv1.himosoft.com.bd]:
K3s version (empty = latest):
...
Proceed with K3s installation? [Y/n]:
```

Non-interactive:

```bash
sudo himosoft-k3s-server install -y --public-ip 194.62.248.81 --domain srv1.himosoft.com.bd
```

## Development

```bash
./scripts/build-all.sh
./scripts/publish-apt-repo.sh   # generates site/ + packages.json
```

## Managing packages

Edit **`packages/manifest.json`** — CI merges it with built `.deb` files into **`packages.json`** for the landing page.

See [docs/adding-packages.md](docs/adding-packages.md).
