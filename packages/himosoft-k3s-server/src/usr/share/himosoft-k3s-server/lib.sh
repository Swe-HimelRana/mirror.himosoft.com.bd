#!/usr/bin/env bash
# Shared helpers for himosoft-k3s-server bootstrap scripts.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

k() {
  k3s kubectl "$@"
}

log() {
  echo "==> $*"
}

warn() {
  echo "==> WARNING: $*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

ensure_helm() {
  if need_cmd helm; then
    return 0
  fi
  log "Helm not found — installing Helm 3"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

wait_for_k3s() {
  local i
  for i in $(seq 1 60); do
    if k get nodes >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  echo "Timed out waiting for K3s API." >&2
  return 1
}

# Poll until a workload exists, then wait for rollout (handles SSA apply race).
wait_for_deployment() {
  local ns="$1" name="$2" max_wait="${3:-600}"
  local elapsed=0
  log "Waiting for deployment/${name} in ${ns}..."
  while (( elapsed < max_wait )); do
    if k get deployment "${name}" -n "${ns}" >/dev/null 2>&1; then
      if k rollout status "deployment/${name}" -n "${ns}" --timeout=120s; then
        return 0
      fi
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  warn "deployment/${name} not ready in namespace ${ns}"
  k get deploy,pods -n "${ns}" 2>/dev/null || true
  return 1
}

wait_for_statefulset() {
  local ns="$1" name="$2" max_wait="${3:-600}"
  local elapsed=0
  log "Waiting for statefulset/${name} in ${ns}..."
  while (( elapsed < max_wait )); do
    if k get statefulset "${name}" -n "${ns}" >/dev/null 2>&1; then
      if k rollout status "statefulset/${name}" -n "${ns}" --timeout=120s; then
        return 0
      fi
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  warn "statefulset/${name} not ready in namespace ${ns}"
  k get sts,pods -n "${ns}" 2>/dev/null || true
  return 1
}

deployment_ready() {
  local ns="$1" name="$2"
  local ready desired
  ready="$(k get deployment "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  desired="$(k get deployment "${name}" -n "${ns}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
  [[ -n "${ready}" && -n "${desired}" && "${ready}" -ge 1 && "${ready}" == "${desired}" ]]
}

wait_pods_ready() {
  local ns="$1" label="$2"
  k wait --for=condition=ready pod -l "${label}" -n "${ns}" --timeout=600s
}

apply_template() {
  local template="$1"
  sed \
    -e "s|@ARGOCD_FQDN@|${ARGOCD_FQDN}|g" \
    -e "s|@DASH_FQDN@|${DASH_FQDN}|g" \
    -e "s|@TRAEFIK_FQDN@|${TRAEFIK_FQDN}|g" \
    -e "s|@ACME_EMAIL@|${ACME_EMAIL:-admin@${DOMAIN}}|g" \
    "${template}"
}

detect_public_ip() {
  curl -fsSL -4 --max-time 5 ifconfig.me 2>/dev/null \
    || curl -fsSL -4 --max-time 5 icanhazip.com 2>/dev/null \
    || curl -fsSL -4 --max-time 5 api.ipify.org 2>/dev/null \
    || true
}

dns_points_to_ip() {
  local fqdn="$1" expected="$2"
  local resolved=""
  resolved="$(getent ahostsv4 "${fqdn}" 2>/dev/null | awk '{print $1; exit}')"
  if [[ -z "${resolved}" ]]; then
    resolved="$(dig +short "${fqdn}" A 2>/dev/null | tail -1)"
  fi
  [[ -n "${resolved}" && "${resolved}" == "${expected}" ]]
}

render_tls_block() {
  local fqdn="$1"
  if [[ "${ENABLE_LETSENCRYPT:-no}" == "yes" ]]; then
    cat <<EOF
  tls:
    certResolver: letsencrypt
    domains:
      - main: "${fqdn}"
EOF
  else
    echo "  tls: {}"
  fi
}

apply_template_with_tls() {
  local template="$1" fqdn="$2"
  local tls_block line
  tls_block="$(render_tls_block "${fqdn}")"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == *"@TLS_BLOCK@"* ]]; then
      echo "${tls_block}"
    else
      echo "${line}"
    fi
  done < <(apply_template "${template}")
}

check_dns_for_ssl() {
  local fqdn all_ok=1
  local -a fqdns=("${TRAEFIK_FQDN}" "${DASH_FQDN}")
  if [[ "${INSTALL_ARGOCD:-yes}" == "yes" && -n "${ARGOCD_FQDN:-}" ]]; then
    fqdns+=("${ARGOCD_FQDN}")
  fi

  log "Checking DNS before Let's Encrypt..."
  for fqdn in "${fqdns[@]}"; do
    if dns_points_to_ip "${fqdn}" "${PUBLIC_IP}"; then
      log "  OK  ${fqdn} -> ${PUBLIC_IP}"
    else
      warn "  FAIL ${fqdn} does not resolve to ${PUBLIC_IP}"
      all_ok=0
    fi
  done

  if [[ "${all_ok}" -eq 1 ]]; then
    ENABLE_LETSENCRYPT=yes
    log "DNS verified — Let's Encrypt SSL will be enabled"
  else
    ENABLE_LETSENCRYPT=no
    warn "DNS not ready — skipping Let's Encrypt (Traefik default cert for now)"
    warn "After fixing DNS, run: sudo himosoft-k3s-server fix-ssl"
  fi
  export ENABLE_LETSENCRYPT
}

write_traefik_values() {
  local share="${SHARE:-/usr/share/himosoft-k3s-server}"
  local out="/etc/himosoft/traefik-values.yaml"
  mkdir -p /etc/himosoft
  local dashboard_tls=""
  if [[ "${ENABLE_LETSENCRYPT:-no}" == "yes" ]]; then
    dashboard_tls=$'    tls:\n      certResolver: letsencrypt'
  fi
  apply_template "${share}/traefik-values.yaml.template" \
    | sed "s|@TRAEFIK_DASHBOARD_TLS@|${dashboard_tls}|g" > "${out}"
  if [[ "${ENABLE_LETSENCRYPT:-no}" == "yes" ]]; then
    apply_template "${share}/traefik-values-acme.yaml.template" >> "${out}"
  fi
  chmod 600 "${out}"
}

# Argo CD install.yaml requires -n argocd; without it workloads land in default.
cleanup_argocd_from_default() {
  if ! k get deployment argocd-server -n default >/dev/null 2>&1; then
    return 0
  fi
  warn "Argo CD is in namespace 'default' (must be 'argocd') — removing misplaced install"
  local kind res
  for kind in deployment statefulset service secret configmap role rolebinding networkpolicy serviceaccount; do
    k get "${kind}" -n default -o name 2>/dev/null | grep argocd | while read -r res; do
      k delete "${res}" -n default --ignore-not-found --wait=false 2>/dev/null || true
    done
  done
  log "Waiting for default-namespace Argo CD pods to terminate..."
  local i
  for i in $(seq 1 30); do
    if ! k get pods -n default 2>/dev/null | grep -q argocd; then
      return 0
    fi
    sleep 2
  done
}

argocd_admin_password() {
  if k get secret argocd-initial-admin-secret -n argocd >/dev/null 2>&1; then
    k get secret argocd-initial-admin-secret -n argocd \
      -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || true
    return 0
  fi
  if k get secret argocd-initial-admin-secret -n default >/dev/null 2>&1; then
    k get secret argocd-initial-admin-secret -n default \
      -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || true
  fi
}

configure_argocd_ingress() {
  local share="${SHARE:-/usr/share/himosoft-k3s-server}"
  : "${ARGOCD_FQDN:?ARGOCD_FQDN not set}"

  if ! k get deployment argocd-server -n argocd >/dev/null 2>&1; then
    warn "Argo CD not in namespace argocd — skipping ingress"
    return 0
  fi

  log "Configuring Argo CD for Traefik ingress (TLS terminated at edge)"

  k patch configmap argocd-cm -n argocd --type merge -p "$(cat <<EOF
{
  "data": {
    "url": "https://${ARGOCD_FQDN}",
    "server.insecure": "true",
    "server.redirect.to.https": "false",
    "application.resourceTrackingMethod": "annotation"
  }
}
EOF
)"

  if k get configmap argocd-cmd-params-cm -n argocd >/dev/null 2>&1; then
    k patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'
  fi

  k apply -f "${share}/manifests/argocd-middleware.yaml"
  apply_template_with_tls "${share}/manifests/ingressroutes-argocd.yaml.template" "${ARGOCD_FQDN}" | k apply -f -

  k rollout restart deployment/argocd-server -n argocd
  wait_for_deployment argocd argocd-server 300
}

apply_dashboard_ingress() {
  local share="${SHARE:-/usr/share/himosoft-k3s-server}"
  apply_template_with_tls "${share}/manifests/ingressroutes-dashboard.yaml.template" "${DASH_FQDN}" | k apply -f -
}
