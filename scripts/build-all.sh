#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
chmod +x "${ROOT}/scripts/build-deb.sh"

for pkg_dir in "${ROOT}"/packages/himosoft-*/; do
  pkg="$(basename "${pkg_dir}")"
  echo "==> Building ${pkg}"
  "${ROOT}/scripts/build-deb.sh" "${pkg}"
done

echo ""
echo "==> All packages built"
