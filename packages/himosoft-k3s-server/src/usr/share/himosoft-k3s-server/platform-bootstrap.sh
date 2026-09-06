#!/usr/bin/env bash
# Traefik, Argo CD, Kubernetes Dashboard, and IngressRoutes bootstrap.
set -euo pipefail

SHARE="/usr/share/himosoft-k3s-server"
CONF="/etc/himosoft/k3s-server.conf"

# shellcheck source=/dev/null
source "${SHARE}/lib.sh"

if [[ -f "${CONF}" ]]; then
  # shellcheck source=/dev/null
  source "${CONF}"
fi

: "${PUBLIC_IP:?PUBLIC_IP not set}"
: "${DOMAIN:?DOMAIN not set}"
: "${TRAEFIK_FQDN:?TRAEFIK_FQDN not set}"
: "${DASH_FQDN:?DASH_FQDN not set}"

INSTALL_ARGOCD="${INSTALL_ARGOCD:-yes}"
ACME_EMAIL="${ACME_EMAIL:-admin@${DOMAIN}}"

ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
DASHBOARD_MANIFEST="https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml"
TRAEFIK_CHART_VERSION="${TRAEFIK_CHART_VERSION:-}"

install_traefik() {
  check_dns_for_ssl

  if helm status traefik -n traefik >/dev/null 2>&1; then
    log "Traefik release exists — upgrading"
  else
    log "Installing Traefik ingress controller"
  fi

  ensure_helm
  helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
  helm repo update traefik

  write_traefik_values

  local helm_args=(
    upgrade --install traefik traefik/traefik
    -n traefik --create-namespace
    -f /etc/himosoft/traefik-values.yaml
    --wait --timeout 10m
  )
  if [[ -n "${TRAEFIK_CHART_VERSION}" ]]; then
    helm_args+=(--version "${TRAEFIK_CHART_VERSION}")
  fi

  helm "${helm_args[@]}"
  wait_for_deployment traefik traefik 300
  if [[ "${ENABLE_LETSENCRYPT:-no}" == "yes" ]]; then
    log "Traefik ready — obtaining Let's Encrypt certificates (may take 1–2 minutes)"
    sleep 15
  else
    log "Traefik ready — using default self-signed certificate"
  fi
}

install_argocd() {
  if [[ "${INSTALL_ARGOCD:-yes}" != "yes" ]]; then
    log "Skipping Argo CD (not selected)"
    return 0
  fi

  : "${ARGOCD_FQDN:?ARGOCD_FQDN not set}"

  log "Installing Argo CD"
  k create namespace argocd --dry-run=client -o yaml | k apply -f -
  cleanup_argocd_from_default

  if deployment_ready argocd argocd-server; then
    log "Argo CD already running in namespace argocd"
    configure_argocd_ingress
    return 0
  fi

  log "Applying Argo CD manifest to namespace argocd (server-side apply)..."
  k apply --server-side --force-conflicts -n argocd -f "${ARGOCD_MANIFEST}"
  sleep 5

  log "Waiting for Argo CD dependencies (redis, dex, repo-server)..."
  wait_for_deployment argocd argocd-redis 600
  wait_for_deployment argocd argocd-dex-server 600
  wait_for_deployment argocd argocd-repo-server 900

  log "Waiting for Argo CD server..."
  wait_for_deployment argocd argocd-server 900
  wait_for_statefulset argocd argocd-application-controller 600 || true
  wait_for_deployment argocd argocd-applicationset-controller 300 || true

  configure_argocd_ingress
  log "Argo CD ready"
}

install_k8s_dashboard() {
  if deployment_ready kubernetes-dashboard kubernetes-dashboard; then
    log "Kubernetes Dashboard already running"
    k apply -f "${SHARE}/manifests/dashboard-admin.yaml"
    apply_dashboard_ingress
    return 0
  fi

  log "Installing Kubernetes Dashboard"
  k apply -f "${DASHBOARD_MANIFEST}"
  sleep 3
  wait_for_deployment kubernetes-dashboard kubernetes-dashboard 600
  k apply -f "${SHARE}/manifests/dashboard-admin.yaml"
  apply_dashboard_ingress
  log "Kubernetes Dashboard ready"
}

install_ingressroutes() {
  apply_dashboard_ingress
  if [[ "${INSTALL_ARGOCD:-yes}" == "yes" ]]; then
    configure_argocd_ingress
  fi
  log "IngressRoutes applied"
}

print_summary() {
  local argocd_pass="" dashboard_token="" ssl_note
  if [[ "${ENABLE_LETSENCRYPT:-no}" == "yes" ]]; then
    ssl_note="Let's Encrypt (trusted HTTPS)"
  else
    ssl_note="Traefik default cert (browser warning until: sudo himosoft-k3s-server fix-ssl)"
  fi

  if [[ "${INSTALL_ARGOCD:-yes}" == "yes" ]]; then
    if k get secret argocd-initial-admin-secret -n argocd >/dev/null 2>&1; then
      argocd_pass="$(k get secret argocd-initial-admin-secret -n argocd \
        -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || true)"
    fi
  fi

  if k get sa himosoft-dashboard-admin -n kubernetes-dashboard >/dev/null 2>&1; then
    dashboard_token="$(k -n kubernetes-dashboard create token himosoft-dashboard-admin --duration=8760h 2>/dev/null || true)"
  fi

  cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║  Himosoft K3s platform bootstrap complete                    ║
╚══════════════════════════════════════════════════════════════╝

SSL: ${ssl_note}

URLs:
  Kubernetes Dashboard https://${DASH_FQDN}
  Traefik Dashboard    https://${TRAEFIK_FQDN}/dashboard/
EOF

  if [[ "${INSTALL_ARGOCD:-yes}" == "yes" ]]; then
    cat <<EOF
  Argo CD              https://${ARGOCD_FQDN}
EOF
  fi

  cat <<EOF

DNS — A records must point to ${PUBLIC_IP}:
  ${TRAEFIK_FQDN}
  ${DASH_FQDN}
EOF

  if [[ "${INSTALL_ARGOCD:-yes}" == "yes" ]]; then
    echo "  ${ARGOCD_FQDN}"
  fi

  if [[ "${INSTALL_ARGOCD:-yes}" == "yes" ]]; then
    cat <<EOF

Argo CD login:
  Username : admin
  Password : ${argocd_pass:-<run: sudo himosoft-k3s-server credentials>}
EOF
  fi

  cat <<EOF

Kubernetes Dashboard: Token login — sudo himosoft-k3s-server credentials

Verify:
  sudo himosoft-k3s-server status
  k3s kubectl get pods -A

Firewall:
  ufw allow 80/tcp && ufw allow 443/tcp

EOF

  if [[ -n "${dashboard_token}" ]]; then
    echo "Dashboard token:"
    echo "${dashboard_token}"
    echo ""
  fi
}

install_traefik
install_argocd
install_k8s_dashboard
install_ingressroutes
print_summary
