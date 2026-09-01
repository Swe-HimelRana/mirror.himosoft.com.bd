#!/usr/bin/env bash
# Sign dists/stable/Release → Release.gpg and export public key to site/himosoft.gpg
set -euo pipefail

SITE="${1:?Usage: sign-apt-release.sh <site-dir>}"

RELEASE="${SITE}/dists/stable/Release"
KEYRING="${SITE}/himosoft.gpg"

if [[ ! -f "${RELEASE}" ]]; then
  echo "Release file not found: ${RELEASE}" >&2
  exit 1
fi

if [[ -z "${APT_REPO_GPG_PRIVATE_KEY:-}" ]]; then
  echo "ERROR: APT_REPO_GPG_PRIVATE_KEY is not set." >&2
  echo "Generate a key with scripts/generate-gpg-key.sh and add the private key to GitHub Actions secrets." >&2
  echo "See docs/gpg-signing.md" >&2
  exit 1
fi

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "${GNUPGHOME}"

cleanup() { rm -rf "${GNUPGHOME}"; }
trap cleanup EXIT

gpg --batch --import <<< "${APT_REPO_GPG_PRIVATE_KEY}"

KEY_ID="$(gpg --batch --list-secret-keys --with-colons | awk -F: '$1=="sec" { print $5; exit }')"
if [[ -z "${KEY_ID}" ]]; then
  echo "No secret key found after import." >&2
  exit 1
fi

if [[ -n "${APT_REPO_GPG_PASSPHRASE:-}" ]]; then
  gpg --batch --yes --pinentry-mode loopback --passphrase "${APT_REPO_GPG_PASSPHRASE}" \
    --local-user "${KEY_ID}" -abs -o "${SITE}/dists/stable/Release.gpg" "${RELEASE}"
else
  gpg --batch --yes --local-user "${KEY_ID}" -abs -o "${SITE}/dists/stable/Release.gpg" "${RELEASE}"
fi

gpg --batch --export "${KEY_ID}" | gpg --dearmor > "${KEYRING}"

echo "Signed: ${SITE}/dists/stable/Release.gpg"
echo "Public keyring: ${KEYRING}"
