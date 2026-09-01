#!/usr/bin/env bash
# One-time: generate the APT repo signing key (run locally, never in CI).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY_EMAIL="${APT_REPO_GPG_EMAIL:-mirror@himosoft.com.bd}"
OUT="${ROOT}/keys/himosoft-repo.key"

mkdir -p "${ROOT}/keys"

if ! command -v gpg >/dev/null 2>&1; then
  echo "ERROR: gpg not found." >&2
  echo "" >&2
  echo "Install GnuPG, then run this script again:" >&2
  echo "  macOS:   brew install gnupg" >&2
  echo "  Ubuntu:  sudo apt install gnupg" >&2
  echo "" >&2
  echo "Or generate the key on your Ubuntu server (gpg is preinstalled):" >&2
  echo "  scp scripts/generate-gpg-key.sh root@YOUR_SERVER:/tmp/" >&2
  echo "  ssh root@YOUR_SERVER 'bash /tmp/generate-gpg-key.sh'" >&2
  exit 1
fi

if [[ -f "${OUT}" ]]; then
  echo "Key export already exists: ${OUT}"
  echo "Delete it first if you want a new key."
  exit 1
fi

cat <<EOF
Create a GPG key for signing the APT repository.

Suggested answers:
  Kind:        1 (RSA and RSA)
  Key size:    4096
  Expiration:  0 (no expiry)
  Real name:   Himosoft APT Mirror
  Email:       mirror@himosoft.com.bd
  Comment:     (press Enter — leave empty)
  Confirm:     O (okay / yes)

Passphrase is asked **last** (after name and email). Save it as GitHub secret APT_REPO_GPG_PASSPHRASE.

EOF

gpg --full-generate-key

FPR="$(gpg --list-secret-keys --with-colons "${KEY_EMAIL}" | awk -F: '$1=="fpr" { print $10; exit }')"

if [[ -z "${FPR}" ]]; then
  echo "No key found for ${KEY_EMAIL}." >&2
  exit 1
fi

gpg --armor --export-secret-keys "${FPR}" > "${OUT}"
gpg --armor --export "${FPR}" > "${ROOT}/keys/himosoft-repo.pub"

chmod 600 "${OUT}"

cat <<EOF

Done.

  Private key (GitHub secret):  ${OUT}
  Public key (reference):       ${ROOT}/keys/himosoft-repo.pub
  Fingerprint:                  ${FPR}

Next steps:
  1. GitHub → Settings → Secrets → APT_REPO_GPG_PRIVATE_KEY = contents of ${OUT}
  2. GitHub → Secrets → APT_REPO_GPG_PASSPHRASE = your passphrase
  3. Push mirror repo to main — CI publishes Release.gpg and himosoft.gpg
  4. Never commit ${OUT} to git.

EOF
