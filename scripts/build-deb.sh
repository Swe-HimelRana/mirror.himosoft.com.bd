#!/usr/bin/env bash
# Build a single Himosoft .deb package: scripts/build-deb.sh <package-dir-name>
set -euo pipefail

PKG_NAME="${1:?Usage: build-deb.sh himosoft-foo}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="${ROOT}/packages/${PKG_NAME}"
VERSION="1.0.0"
BUILD_ROOT="${PKG_DIR}/build"
STAGING="${BUILD_ROOT}/${PKG_NAME}_${VERSION}_all"
LIB="${ROOT}/packages/_lib/interactive.sh"

[[ -d "${PKG_DIR}" ]] || { echo "Missing ${PKG_DIR}"; exit 1; }

rm -rf "${BUILD_ROOT}"
mkdir -p "${STAGING}/DEBIAN" "${STAGING}/usr/bin"

cp "${PKG_DIR}/debian/control" "${STAGING}/DEBIAN/"
[[ -f "${PKG_DIR}/debian/postinst" ]] && cp "${PKG_DIR}/debian/postinst" "${STAGING}/DEBIAN/" && chmod 755 "${STAGING}/DEBIAN/postinst"

cp "${PKG_DIR}/src/usr/bin/${PKG_NAME}" "${STAGING}/usr/bin/"
chmod 755 "${STAGING}/usr/bin/${PKG_NAME}"

if [[ -d "${PKG_DIR}/src/usr/share/${PKG_NAME}" ]]; then
  mkdir -p "${STAGING}/usr/share/${PKG_NAME}"
  cp -r "${PKG_DIR}/src/usr/share/${PKG_NAME}/." "${STAGING}/usr/share/${PKG_NAME}/"
  find "${STAGING}/usr/share/${PKG_NAME}" -type f -name '*.sh' -exec chmod 755 {} +
fi

mkdir -p "${STAGING}/usr/share/himosoft/lib"
cp "${LIB}" "${STAGING}/usr/share/himosoft/lib/interactive.sh"

dpkg-deb --build --root-owner-group "${STAGING}" "${BUILD_ROOT}/${PKG_NAME}_${VERSION}_all.deb"
echo "Built: ${BUILD_ROOT}/${PKG_NAME}_${VERSION}_all.deb"
