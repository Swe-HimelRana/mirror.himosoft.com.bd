# GPG signing for the APT mirror

The mirror publishes a signed `Release` file:

- `dists/stable/Release`
- `dists/stable/Release.gpg` (detached signature)
- `himosoft.gpg` (public key for `signed-by=` on client machines)

Clients install the mirror with `install-mirror.sh`, which uses `signed-by` instead of `[trusted=yes]`.

## One-time key generation (local)

Requires `gpg` (`brew install gnupg` on macOS, or use your Ubuntu server).

You are already in the mirror repo if your prompt shows `mirror.himosoft.com.bd` — do **not** run `cd mirror.himosoft.com.bd` again.

```bash
chmod +x scripts/generate-gpg-key.sh
./scripts/generate-gpg-key.sh
```

This creates:

| File | Purpose |
|------|---------|
| `keys/himosoft-repo.key` | **Private** — add to GitHub Secrets only |
| `keys/himosoft-repo.pub` | Public key reference (armored) |

## GitHub Actions secrets

In **Settings → Secrets and variables → Actions**, add:

| Secret | Value |
|--------|--------|
| `APT_REPO_GPG_PRIVATE_KEY` | Full armored private key from `keys/himosoft-repo.key` |
| `APT_REPO_GPG_PASSPHRASE` | Passphrase used when creating the key (omit if none) |

CI imports the key, signs `Release`, and publishes `Release.gpg` + `himosoft.gpg`.

## Client setup

```bash
curl -fsSL https://mirror.himosoft.com.bd/install-mirror.sh | sudo bash
```

This writes:

```
/etc/apt/sources.list.d/himosoft.list
/usr/share/keyrings/himosoft.gpg
```

Sources line:

```
deb [signed-by=/usr/share/keyrings/himosoft.gpg] https://mirror.himosoft.com.bd stable main
```

## Migrate from `[trusted=yes]`

On servers that already added the mirror:

```bash
curl -fsSL https://mirror.himosoft.com.bd/install-mirror.sh | sudo bash
rm -f /var/lib/apt/lists/*mirror.himosoft.com.bd*
apt clean
apt update
```

After a successful `apt update` you should see `Get: ... Release.gpg` instead of `Ign: ... Release.gpg`.

## Verify signature locally

```bash
curl -fsSLO https://mirror.himosoft.com.bd/dists/stable/Release
curl -fsSLO https://mirror.himosoft.com.bd/dists/stable/Release.gpg
curl -fsSL https://mirror.himosoft.com.bd/himosoft.gpg | gpg --dearmor > himosoft.gpg
gpg --no-default-keyring --keyring ./himosoft.gpg --verify Release.gpg Release
```

Expected: `Good signature`.
