#!/usr/bin/env bash
# Assemble static site + APT repository tree for GitHub Pages.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="${ROOT}/site"
DIST="${SITE}/dists/stable/main/binary-amd64"
POOL="${SITE}/pool"

rm -rf "${SITE}"
mkdir -p "${DIST}" "${POOL}"

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

echo "==> Generating Packages index"
cd "${SITE}"
dpkg-scanpackages --arch amd64 pool/ > "${DIST}/Packages"
gzip -9 -c "${DIST}/Packages" > "${DIST}/Packages.gz"

cat > "${SITE}/dists/stable/Release" <<EOF
Origin: Himosoft
Label: Himosoft Mirror
Suite: stable
Codename: stable
Architectures: amd64 all
Components: main
Description: Himosoft server packages
Date: $(date -Ru)
EOF

echo "==> Generating packages.json"
python3 "${ROOT}/scripts/generate-packages-json.py" "${SITE}"

echo ""
echo "Site ready: ${SITE}/"
echo "  packages.json"
echo "  dists/stable/main/binary-amd64/Packages.gz"
find "${POOL}" -name '*.deb' | head -20
