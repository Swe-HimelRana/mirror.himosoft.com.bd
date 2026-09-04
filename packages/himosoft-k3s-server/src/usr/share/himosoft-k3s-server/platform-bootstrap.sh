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
: "${ARGOCD_FQDN:?ARGOCD_FQDN not set}"
: "${DASH_FQDN:?DASH_FQDN not set}"
: "${TRAEFIK_FQDN:?TRAEFIK_FQDN not set}"

ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
DASHBOARD_MANIFEST="https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml"
TRAEFIK_CHART_VERSION="${TRAEFIK_CHART_VERSION:-}"

configure_argocd_ingress() {
  log "Configuring Argo CD for Traefik ingress"
  k patch configmap argocd-cm -n argocd --type merge -p "$(cat <<EOF
{
  "data": {
    "url": "https://${ARGOCD_FQDN}",
    "server.insecure": "true",
    "application.resourceTrackingMethod": "annotation"
  }
}
EOF
)" 2>/dev/null || true
  if k get deployment argocd-server -n argocd >/dev/null 2>&1; then
    k rollout restart deployment/argocd-server -n argocd 2>/dev/null || true
    wait_for_deployment argocd argocd-server 300 || true
  fi
}

install_traefik() {
  if helm status traefik -n traefik >/dev/null 2>&1; then
    if k get pods -n traefik -l app.kubernetes.io/name=traefik --field-selector=status.phase=Running 2>/dev/null | grep -q traefik; then
      log "Traefik already running — refreshing values"
    else
      log "Traefik release exists but pods not ready — upgrading"
    fi
  else
    log "Installing Traefik ingress controller"
  fi

  ensure_helm
  helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
  helm repo update traefik

  local values_file="/etc/himosoft/traefik-values.yaml"
  mkdir -p /etc/himosoft
  apply_template "${SHARE}/traefik-values.yaml.template" > "${values_file}"
  chmod 600 "${values_file}"

  local helm_args=(
    upgrade --install traefik traefik/traefik
    -n traefik --create-namespace
    -f "${values_file}"
    --wait --timeout 10m
  )
  if [[ -n "${TRAEFIK_CHART_VERSION}" ]]; then
    helm_args+=(--version "${TRAEFIK_CHART_VERSION}")
  fi

  helm "${helm_args[@]}"
  wait_for_deployment traefik traefik 300
  log "Traefik ready"
}

install_argocd() {
  log "Installing Argo CD"
  k create namespace argocd --dry-run=client -o yaml | k apply -f -

  cleanup_argocd_from_default

  if deployment_ready argocd argocd-server; then
    log "Argo CD already running in namespace argocd — skipping manifest apply"
    configure_argocd_ingress
    log "Argo CD ready"
    return 0
  fi

  log "Applying Argo CD manifest to namespace argocd (server-side apply)..."
  k apply --server-side --force-conflicts -n argocd -f "${ARGOCD_MANIFEST}"

  sleep 5

  wait_for_deployment argocd argocd-server 600
  wait_for_deployment argocd argocd-repo-server 600
  wait_for_statefulset argocd argocd-application-controller 600 || true
  wait_for_deployment argocd argocd-applicationset-controller 300 || true

  configure_argocd_ingress
  log "Argo CD ready"
}

install_k8s_dashboard() {
  if deployment_ready kubernetes-dashboard kubernetes-dashboard; then
    log "Kubernetes Dashboard already running"
    k apply -f "${SHARE}/manifests/dashboard-admin.yaml"
    return 0
  fi

  log "Installing Kubernetes Dashboard"
  k apply -f "${DASHBOARD_MANIFEST}"
  sleep 3
  wait_for_deployment kubernetes-dashboard kubernetes-dashboard 600
  k apply -f "${SHARE}/manifests/dashboard-admin.yaml"
  log "Kubernetes Dashboard ready"
}

install_ingressroutes() {
  log "Applying IngressRoutes (Argo CD + Kubernetes Dashboard)"
  apply_template "${SHARE}/manifests/ingressroutes.yaml.template" | k apply -f -
  log "IngressRoutes applied"
}

print_summary() {
  local argocd_pass dashboard_token
  argocd_pass=""
  dashboard_token=""

  if k get secret argocd-initial-admin-secret -n argocd >/dev/null 2>&1; then
    argocd_pass="$(k get secret argocd-initial-admin-secret -n argocd \
      -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || true)"
  elif k get secret argocd-initial-admin-secret -n default >/dev/null 2>&1; then
    argocd_pass="$(k get secret argocd-initial-admin-secret -n default \
      -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || true)"
  fi

  if k get sa himosoft-dashboard-admin -n kubernetes-dashboard >/dev/null 2>&1; then
    dashboard_token="$(k -n kubernetes-dashboard create token himosoft-dashboard-admin --duration=8760h 2>/dev/null || true)"
  fi

  cat <<EOF

╔══════════════════════════════════════════════════════════════╗
║  Himosoft K3s platform bootstrap complete                    ║
╚══════════════════════════════════════════════════════════════╝

DNS — point these A records to ${PUBLIC_IP}:
  ${ARGOCD_FQDN}
  ${DASH_FQDN}
  ${TRAEFIK_FQDN}

URLs (HTTPS via Traefik default cert until cert-manager):
  Argo CD              https://${ARGOCD_FQDN}
  Kubernetes Dashboard https://${DASH_FQDN}
  Traefik Dashboard    https://${TRAEFIK_FQDN}/dashboard/

Argo CD login:
  Username : admin
  Password : ${argocd_pass:-<run: himosoft-k3s-server credentials>}

Kubernetes Dashboard login:
  Select "Token" and run: sudo himosoft-k3s-server credentials

Verify:
  k3s kubectl get pods -A
  sudo himosoft-k3s-server status

GitOps note:
  Traefik is pre-installed by this package. When deploying Phase 2 from
  your GitOps repo, adopt this release or skip duplicate Traefik install.

Firewall:
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow from YOUR_ADMIN_IP to any port 6443 proto tcp

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
