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
AUTH_FQDN="${AUTH_FQDN:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Must run as root."
  exit 1
fi

if [[ -z "${PUBLIC_IP}" || -z "${DOMAIN}" ]]; then
  echo "PUBLIC_IP and DOMAIN must be set. Run: sudo himosoft-k3s-server install"
  exit 1
fi

_install_k3s() {
  local san install_args="server --disable traefik --write-kubeconfig-mode 644"
  mkdir -p /etc/rancher/k3s

  log "Writing /etc/rancher/k3s/config.yaml"
  {
    echo 'write-kubeconfig-mode: "644"'
    echo "node-external-ip: \"${PUBLIC_IP}\""
    echo "disable:"
    echo "  - traefik"
    echo "tls-san:"
    for san in "${DOMAIN}" "${PUBLIC_IP}" "${AUTH_FQDN}" "${ARGOCD_FQDN}" "${DASH_FQDN}" "${TRAEFIK_FQDN}"; do
      [[ -n "${san}" ]] && echo "  - \"${san}\""
    done
  } > /etc/rancher/k3s/config.yaml

  if [[ -n "${K3S_VERSION}" ]]; then
    export INSTALL_K3S_VERSION="${K3S_VERSION}"
  fi

  log "Installing K3s (${K3S_VERSION:-latest})"
  install_progress_sub 20 "Downloading K3s"
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="${install_args}" sh -

  install_progress_sub 70 "Starting K3s"
  wait_for_k3s
  install_progress_sub 100 "K3s node ready"
  log "K3s node ready"
  k get nodes
}

if [[ "${SKIP_K3S:-no}" == "yes" ]] || { command -v k3s >/dev/null 2>&1 && systemctl is-active k3s &>/dev/null; }; then
  log "K3s is already running — skipping K3s install"
  if ! install_progress_is_noop_install; then
    wait_for_k3s
  fi
  exec "${SHARE}/platform-bootstrap.sh"
fi

install_progress_init_from_env
install_progress_run_step "Installing K3s" "${INSTALL_PROGRESS_W_K3S:-12}" _install_k3s
exec "${SHARE}/platform-bootstrap.sh"
