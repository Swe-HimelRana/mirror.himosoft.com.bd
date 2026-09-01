#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
chmod +x "${ROOT}/scripts/build-deb.sh"

echo "==> Building himosoft-common (shared library)"
"${ROOT}/scripts/build-deb.sh" himosoft-common

for pkg_dir in "${ROOT}"/packages/himosoft-*/; do
  pkg="$(basename "${pkg_dir}")"
  [[ "${pkg}" == "himosoft-common" ]] && continue
  echo "==> Building ${pkg}"
  "${ROOT}/scripts/build-deb.sh" "${pkg}"
done

echo ""
echo "==> All packages built"
