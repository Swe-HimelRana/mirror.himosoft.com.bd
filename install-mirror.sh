#!/usr/bin/env bash
set -euo pipefail

MIRROR_URL="${HIMOSOFT_MIRROR_URL:-https://mirror.himosoft.com.bd}"
LIST_FILE="/etc/apt/sources.list.d/himosoft.list"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: curl -fsSL … | sudo bash"
  exit 1
fi

echo "==> Adding Himosoft mirror: ${MIRROR_URL}"
cat > "${LIST_FILE}" <<EOF
# Himosoft package mirror
deb [trusted=yes] ${MIRROR_URL} stable main
EOF

apt-get update -qq

echo ""
echo "Mirror added. Browse packages at https://mirror.himosoft.com.bd"
echo "  apt install <package-name>"
echo ""
echo "Example:"
echo "  apt install himosoft-k3s-server"
