#!/usr/bin/env bash
set -euo pipefail

MIRROR_URL="${HIMOSOFT_MIRROR_URL:-https://mirror.himosoft.com.bd}"
LIST_FILE="/etc/apt/sources.list.d/himosoft.list"
KEYRING="/usr/share/keyrings/himosoft.gpg"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: curl -fsSL … | sudo bash"
  exit 1
fi

echo "==> Adding Himosoft mirror: ${MIRROR_URL}"

install -d -m 0755 /usr/share/keyrings
curl -fsSL "${MIRROR_URL}/himosoft.gpg" -o "${KEYRING}.tmp"
mv "${KEYRING}.tmp" "${KEYRING}"
chmod 644 "${KEYRING}"

cat > "${LIST_FILE}" <<EOF
# Himosoft package mirror (GPG-signed Release)
deb [signed-by=${KEYRING}] ${MIRROR_URL} stable main
EOF

apt-get update -qq

echo ""
echo "Mirror added with GPG verification."
echo "  Keyring: ${KEYRING}"
echo "  Packages: ${MIRROR_URL}"
echo ""
echo "Example:"
echo "  apt install himosoft-k3s-server"
