#!/usr/bin/env bash
# K3s install — called by himosoft-k3s-server after configuration.
set -euo pipefail

SHARE="/usr/share/himosoft-k3s-server"
# shellcheck source=/dev/null
source "${SHARE}/lib.sh"

DOMAIN="${DOMAIN:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
K3S_VERSION="${K3S_VERSION:-}"
ARGOCD_FQDN="${ARGOCD_FQDN:-}"
DASH_FQDN="${DASH_FQDN:-}"
TRAEFIK_FQDN="${TRAEFIK_FQDN:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Must run as root."
  exit 1
fi

if [[ -z "${PUBLIC_IP}" || -z "${DOMAIN}" ]]; then
  echo "PUBLIC_IP and DOMAIN must be set. Run: sudo himosoft-k3s-server install"
  exit 1
fi

if command -v k3s >/dev/null 2>&1 && systemctl is-active k3s &>/dev/null; then
  log "K3s is already running — skipping K3s install"
  wait_for_k3s
  exec "${SHARE}/platform-bootstrap.sh"
fi

TLS_SANS=(
  "${DOMAIN}"
  "${PUBLIC_IP}"
  "${ARGOCD_FQDN}"
  "${DASH_FQDN}"
  "${TRAEFIK_FQDN}"
)

mkdir -p /etc/rancher/k3s

log "Writing /etc/rancher/k3s/config.yaml"
{
  echo 'write-kubeconfig-mode: "644"'
  echo "node-external-ip: \"${PUBLIC_IP}\""
  echo "disable:"
  echo "  - traefik"
  echo "tls-san:"
  for san in "${TLS_SANS[@]}"; do
    [[ -n "${san}" ]] && echo "  - \"${san}\""
  done
} > /etc/rancher/k3s/config.yaml

INSTALL_ARGS="server --disable traefik --write-kubeconfig-mode 644"
if [[ -n "${K3S_VERSION}" ]]; then
  export INSTALL_K3S_VERSION="${K3S_VERSION}"
fi

log "Installing K3s (${K3S_VERSION:-latest})"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="${INSTALL_ARGS}" sh -

wait_for_k3s
log "K3s node ready"
k get nodes

exec "${SHARE}/platform-bootstrap.sh"
