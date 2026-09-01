#!/usr/bin/env bash
# Assemble static site + APT repository tree for GitHub Pages.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="${ROOT}/site"
DIST="${SITE}/dists/stable/main"
POOL="${SITE}/pool"

rm -rf "${SITE}"
mkdir -p "${DIST}/binary-all" "${DIST}/binary-amd64" "${POOL}"

echo "==> Copying site assets"
cp "${ROOT}/index.html" "${SITE}/"
cp "${ROOT}/CNAME" "${SITE}/"
cp "${ROOT}/install-mirror.sh" "${SITE}/"
chmod 755 "${SITE}/install-mirror.sh"
cp -r "${ROOT}/assets" "${SITE}/"

echo "==> Collecting .deb files into APT pool"
found=0
while IFS= read -r deb; do
  base="$(basename "${deb}")"
  pkg="${base%%_*}"
  letter="${pkg:0:1}"
  dest="${POOL}/main/${letter}/${pkg}"
  mkdir -p "${dest}"
  cp "${deb}" "${dest}/"
  found=$((found + 1))
  echo "  ${dest}/${base}"
done < <(find "${ROOT}/packages" -name '*.deb' | sort)

if [[ "${found}" -eq 0 ]]; then
  echo "No .deb files found — run scripts/build-all.sh first"
  exit 1
fi

echo "==> Generating Packages indexes"
cd "${SITE}"

# Himosoft packages are Architecture: all — apt reads binary-all on amd64 hosts.
dpkg-scanpackages --arch all pool/ > "${DIST}/binary-all/Packages"
gzip -9 -c "${DIST}/binary-all/Packages" > "${DIST}/binary-all/Packages.gz"

# Keep amd64 index for future native packages; includes all-arch entries too.
dpkg-scanpackages --arch amd64 pool/ > "${DIST}/binary-amd64/Packages"
gzip -9 -c "${DIST}/binary-amd64/Packages" > "${DIST}/binary-amd64/Packages.gz"

echo "==> Generating Release (with checksums)"
apt-ftparchive release dists/stable > dists/stable/Release

echo "==> Generating packages.json"
python3 "${ROOT}/scripts/generate-packages-json.py" "${SITE}"

echo ""
echo "Site ready: ${SITE}/"
echo "  packages.json"
echo "  dists/stable/main/binary-all/Packages.gz"
echo "  dists/stable/main/binary-amd64/Packages.gz"
echo "  dists/stable/Release"
find "${POOL}" -name '*.deb' | head -20
