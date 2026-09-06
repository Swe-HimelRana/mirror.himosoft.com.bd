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

diagnose_workload() {
  local ns="$1" name="$2"
  warn "Diagnostics for ${name} in namespace ${ns}:"
  k get pods -n "${ns}" 2>/dev/null | grep -E "NAME|${name}" || k get pods -n "${ns}" 2>/dev/null || true
  local pod
  pod="$(k get pods -n "${ns}" -o name 2>/dev/null | grep "${name}" | head -1 || true)"
  if [[ -n "${pod}" ]]; then
    k describe "${pod}" -n "${ns}" 2>/dev/null | sed -n '/Events:/,$p' | tail -20
    k logs "${pod}" -n "${ns}" --tail=25 2>/dev/null || true
  fi
}

workload_has_fatal_pod() {
  local ns="$1" name="$2"
  k get pods -n "${ns}" --no-headers 2>/dev/null | grep "${name}" \
    | grep -qE 'CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError'
}

# Poll until ready; uses wall clock (rollout --timeout does not count toward max_wait incorrectly).
wait_for_deployment() {
  local ns="$1" name="$2" max_wait="${3:-600}"
  local start now elapsed last_diag=0 remaining
  start="$(date +%s)"
  log "Waiting for deployment/${name} in ${ns} (up to ${max_wait}s, images may take several minutes)..."
  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    if (( elapsed >= max_wait )); then
      warn "Timed out after ${max_wait}s waiting for deployment/${name} in ${ns}"
      diagnose_workload "${ns}" "${name}"
      return 1
    fi
    if k get deployment "${name}" -n "${ns}" >/dev/null 2>&1; then
      if workload_has_fatal_pod "${ns}" "${name}"; then
        warn "Pod for ${name} is in a failed state"
        diagnose_workload "${ns}" "${name}"
      fi
      remaining=$((max_wait - elapsed))
      (( remaining < 30 )) && remaining=30
      if k rollout status "deployment/${name}" -n "${ns}" --timeout="${remaining}s" 2>/dev/null; then
        log "deployment/${name} is ready"
        return 0
      fi
      if (( elapsed - last_diag >= 90 )); then
        log "Still waiting for ${name}... (${elapsed}s elapsed)"
        k get pods -n "${ns}" 2>/dev/null | grep -E "NAME|${name}" || true
        last_diag=$elapsed
      fi
    fi
    sleep 10
  done
}

wait_for_statefulset() {
  local ns="$1" name="$2" max_wait="${3:-600}"
  local start now elapsed last_diag=0 remaining
  start="$(date +%s)"
  log "Waiting for statefulset/${name} in ${ns} (up to ${max_wait}s)..."
  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    if (( elapsed >= max_wait )); then
      warn "Timed out after ${max_wait}s waiting for statefulset/${name} in ${ns}"
      diagnose_workload "${ns}" "${name}"
      return 1
    fi
    if k get statefulset "${name}" -n "${ns}" >/dev/null 2>&1; then
      remaining=$((max_wait - elapsed))
      (( remaining < 30 )) && remaining=30
      if k rollout status "statefulset/${name}" -n "${ns}" --timeout="${remaining}s" 2>/dev/null; then
        log "statefulset/${name} is ready"
        return 0
      fi
      if (( elapsed - last_diag >= 90 )); then
        log "Still waiting for ${name}... (${elapsed}s elapsed)"
        k get pods -n "${ns}" 2>/dev/null | grep -E "NAME|${name}" || true
        last_diag=$elapsed
      fi
    fi
    sleep 10
  done
}

deployment_ready() {
  local ns="$1" name="$2"
  local ready desired
  ready="$(k get deployment "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  desired="$(k get deployment "${name}" -n "${ns}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
  [[ -n "${ready}" && -n "${desired}" && "${ready}" -ge 1 && "${ready}" == "${desired}" ]]
}

k3s_running() {
  command -v k3s >/dev/null 2>&1 && systemctl is-active k3s &>/dev/null
}

k8s_namespace_exists() {
  k get namespace "$1" >/dev/null 2>&1
}

# Sets STATE_K3S STATE_TRAEFIK STATE_AUTHELIA STATE_ARGOCD STATE_DASHBOARD
# Values: missing | installed | ready
detect_platform_state() {
  STATE_K3S=missing
  STATE_TRAEFIK=missing
  STATE_AUTHELIA=missing
  STATE_ARGOCD=missing
  STATE_DASHBOARD=missing

  if command -v k3s >/dev/null 2>&1; then
    if k3s_running; then
      STATE_K3S=ready
    else
      STATE_K3S=installed
    fi
  fi

  if ! k3s_running; then
    return 0
  fi

  if k8s_namespace_exists traefik; then
    if deployment_ready traefik traefik; then
      STATE_TRAEFIK=ready
    else
      STATE_TRAEFIK=installed
    fi
  fi

  if k8s_namespace_exists authelia && k get deployment authelia -n authelia >/dev/null 2>&1; then
    if deployment_ready authelia authelia; then
      STATE_AUTHELIA=ready
    else
      STATE_AUTHELIA=installed
    fi
  fi

  if k8s_namespace_exists argocd; then
    if deployment_ready argocd argocd-server; then
      STATE_ARGOCD=ready
    else
      STATE_ARGOCD=installed
    fi
  fi

  if k8s_namespace_exists kubernetes-dashboard; then
    if deployment_ready kubernetes-dashboard kubernetes-dashboard; then
      STATE_DASHBOARD=ready
    else
      STATE_DASHBOARD=installed
    fi
  fi
}

platform_state_label() {
  case "${1:-missing}" in
    ready) echo "installed (ready)" ;;
    installed) echo "installed (starting or unhealthy)" ;;
    missing) echo "not installed" ;;
    disabled) echo "disabled in config" ;;
    *) echo "${1}" ;;
  esac
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
    -e "s|@AUTH_FQDN@|${AUTH_FQDN:-}|g" \
    -e "s|@DOMAIN@|${DOMAIN}|g" \
    -e "s|@ACME_EMAIL@|${ACME_EMAIL:-admin@${DOMAIN}}|g" \
    "${template}"
}

authelia_enabled() {
  [[ "${INSTALL_AUTHELIA:-yes}" == "yes" && -n "${AUTH_FQDN:-}" ]]
}

render_authelia_middleware_argocd() {
  if authelia_enabled; then
    cat <<'EOF'
        - name: authelia-forwardauth
          namespace: authelia
EOF
  fi
}

render_authelia_middleware_dashboard_block() {
  if authelia_enabled; then
    cat <<'EOF'
      middlewares:
        - name: authelia-forwardauth
          namespace: authelia
EOF
  fi
}

render_traefik_dashboard_middlewares() {
  if authelia_enabled; then
    cat <<'EOF'
    middlewares:
      - name: authelia-forwardauth
        namespace: authelia
EOF
  fi
}

build_protected_domains_yaml() {
  local -a domains=()
  if [[ "${INSTALL_ARGOCD:-yes}" == "yes" && -n "${ARGOCD_FQDN:-}" ]]; then
    domains+=("${ARGOCD_FQDN}")
  fi
  domains+=("${DASH_FQDN}" "${TRAEFIK_FQDN}")
  local d
  for d in "${domains[@]}"; do
    echo "        - '${d}'"
  done
}

generate_authelia_password_hash() {
  local password="$1" job="authelia-hash-$$" secret="${job}-pw" hash="" tmp_job="/tmp/${job}.yaml"

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    hash="$(docker run --rm docker.io/authelia/authelia:4.38.5 \
      authelia crypto hash generate argon2 --password "${password}" --no-confirm 2>/dev/null \
      | awk '/^\$argon2/{print; exit}')"
    if [[ -n "${hash}" ]]; then
      echo "${hash}"
      return 0
    fi
  fi

  k delete job "${job}" -n authelia --ignore-not-found --wait=false 2>/dev/null || true
  k delete secret "${secret}" -n authelia --ignore-not-found 2>/dev/null || true
  k create secret generic "${secret}" -n authelia --from-literal=password="${password}"

  cat > "${tmp_job}" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: authelia
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: hash
          image: docker.io/authelia/authelia:4.38.5
          env:
            - name: AUTHELIA_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${secret}
                  key: password
          command:
            - /bin/sh
            - -ec
            - 'authelia crypto hash generate argon2 --password "$AUTHELIA_PASSWORD" --no-confirm'
EOF

  k apply -f "${tmp_job}"
  if ! k wait --for=condition=complete "job/${job}" -n authelia --timeout=180s 2>/dev/null; then
    warn "Authelia hash job failed — pod logs:"
    k logs "job/${job}" -n authelia 2>/dev/null || true
    k delete job "${job}" -n authelia --ignore-not-found --wait=false
    k delete secret "${secret}" -n authelia --ignore-not-found
    rm -f "${tmp_job}"
    return 1
  fi

  hash="$(k logs "job/${job}" -n authelia 2>/dev/null | awk '/^\$argon2/{print; exit}')"
  k delete job "${job}" -n authelia --ignore-not-found --wait=false
  k delete secret "${secret}" -n authelia --ignore-not-found
  rm -f "${tmp_job}"
  [[ -n "${hash}" ]] || return 1
  echo "${hash}"
}

sync_authelia_users_secret() {
  : "${AUTHELIA_ADMIN_USER:?AUTHELIA_ADMIN_USER not set}"
  : "${AUTHELIA_ADMIN_PASSWORD:?AUTHELIA_ADMIN_PASSWORD not set}"
  : "${AUTHELIA_ADMIN_EMAIL:?AUTHELIA_ADMIN_EMAIL not set}"

  local hash tmp_users="/tmp/authelia-users-$$.yml"
  log "Updating Authelia admin user..."
  hash="$(generate_authelia_password_hash "${AUTHELIA_ADMIN_PASSWORD}")" || {
    echo "Failed to hash Authelia password." >&2
    return 1
  }

  cat > "${tmp_users}" <<EOF
users:
  ${AUTHELIA_ADMIN_USER}:
    disabled: false
    displayname: "${AUTHELIA_ADMIN_DISPLAY_NAME:-Admin}"
    password: "${hash}"
    email: ${AUTHELIA_ADMIN_EMAIL}
    groups:
      - admins
EOF

  k create secret generic authelia-users -n authelia \
    --from-file=users_database.yml="${tmp_users}" \
    --dry-run=client -o yaml | k apply -f -
  rm -f "${tmp_users}"
}

apply_template_ingress() {
  local template="$1" fqdn="$2"
  local tls_block line
  tls_block="$(render_tls_block "${fqdn}")"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == *"@TLS_BLOCK@"* ]]; then
      echo "${tls_block}"
    elif [[ "${line}" == *"@AUTHELIA_MIDDLEWARES@"* ]]; then
      render_authelia_middleware_argocd
    elif [[ "${line}" == *"@AUTHELIA_MIDDLEWARES_BLOCK@"* ]]; then
      render_authelia_middleware_dashboard_block
    else
      echo "${line}"
    fi
  done < <(apply_template "${template}")
}

apply_template_with_tls() {
  local template="$1" fqdn="$2"
  apply_template_ingress "${template}" "${fqdn}"
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

check_dns_for_ssl() {
  local fqdn all_ok=1
  local -a fqdns=("${TRAEFIK_FQDN}" "${DASH_FQDN}")
  if [[ "${INSTALL_ARGOCD:-yes}" == "yes" && -n "${ARGOCD_FQDN:-}" ]]; then
    fqdns+=("${ARGOCD_FQDN}")
  fi
  if authelia_enabled; then
    fqdns+=("${AUTH_FQDN}")
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
  local tls_block="" line
  if [[ "${ENABLE_LETSENCRYPT:-no}" == "yes" ]]; then
    tls_block=$'    tls:\n      certResolver: letsencrypt'
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == *"@TRAEFIK_DASHBOARD_TLS@"* ]]; then
      if [[ -n "${tls_block}" ]]; then
        printf '%b\n' "${tls_block}"
      fi
    elif [[ "${line}" == *"@TRAEFIK_DASHBOARD_MIDDLEWARES@"* ]]; then
      render_traefik_dashboard_middlewares
    else
      echo "${line}"
    fi
  done < <(apply_template "${share}/traefik-values.yaml.template") > "${out}"
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
  apply_template_ingress "${share}/manifests/ingressroutes-dashboard.yaml.template" "${DASH_FQDN}" | k apply -f -
}

upgrade_traefik_dashboard_auth() {
  if ! authelia_enabled; then
    return 0
  fi
  if ! helm status traefik -n traefik >/dev/null 2>&1; then
    return 0
  fi
  log "Applying Authelia middleware to Traefik dashboard route"
  ensure_helm
  write_traefik_values
  helm upgrade traefik traefik/traefik -n traefik \
    -f /etc/himosoft/traefik-values.yaml --wait --timeout 5m
}

install_authelia() {
  if [[ "${SKIP_AUTHELIA:-no}" == "yes" ]]; then
    log "Authelia already installed — skipping"
    return 0
  fi

  if ! authelia_enabled; then
    log "Skipping Authelia (not selected)"
    return 0
  fi

  local share="${SHARE:-/usr/share/himosoft-k3s-server}"
  : "${AUTH_FQDN:?AUTH_FQDN not set}"
  : "${AUTHELIA_ADMIN_USER:?AUTHELIA_ADMIN_USER not set}"
  : "${AUTHELIA_ADMIN_PASSWORD:?AUTHELIA_ADMIN_PASSWORD not set}"
  : "${AUTHELIA_ADMIN_EMAIL:?AUTHELIA_ADMIN_EMAIL not set}"

  if k get deployment authelia -n authelia >/dev/null 2>&1; then
    log "Authelia already installed — syncing admin account and refreshing routes"
    sync_authelia_users_secret
    k rollout restart deployment/authelia -n authelia 2>/dev/null || true
    wait_for_deployment authelia authelia 600
    apply_template "${share}/manifests/authelia/middleware-forwardauth.yaml.template" | k apply -f -
    apply_template_ingress "${share}/manifests/authelia/ingressroute.yaml.template" "${AUTH_FQDN}" | k apply -f -
    upgrade_traefik_dashboard_auth
    return 0
  fi

  log "Installing Authelia SSO (protects Argo CD, Dashboard, Traefik UI)"
  k apply -f "${share}/manifests/authelia/namespace.yaml"
  k apply -f "${share}/manifests/authelia/redis.yaml"
  wait_for_deployment authelia authelia-redis 300

  if ! k get secret authelia-secrets -n authelia >/dev/null 2>&1; then
    k create secret generic authelia-secrets -n authelia \
      --from-literal=jwt_secret="$(openssl rand -hex 32)" \
      --from-literal=session_secret="$(openssl rand -hex 32)" \
      --from-literal=storage_encryption_key="$(openssl rand -hex 32)"
  fi

  local protected tmp_cfg="/tmp/authelia-configuration-$$.yml"
  log "Generating Authelia password hash..."
  sync_authelia_users_secret

  protected="$(build_protected_domains_yaml)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == *"@PROTECTED_DOMAINS_YAML@"* ]]; then
      echo "${protected}"
    else
      echo "${line}"
    fi
  done < <(apply_template "${share}/manifests/authelia/configuration.yml.template") > "${tmp_cfg}"

  k create configmap authelia-config -n authelia \
    --from-file=configuration.yml="${tmp_cfg}" \
    --dry-run=client -o yaml | k apply -f -
  rm -f "${tmp_cfg}"

  k apply -f "${share}/manifests/authelia/deployment.yaml"
  wait_for_deployment authelia authelia 600

  apply_template "${share}/manifests/authelia/middleware-forwardauth.yaml.template" | k apply -f -
  apply_template_ingress "${share}/manifests/authelia/ingressroute.yaml.template" "${AUTH_FQDN}" | k apply -f -
  upgrade_traefik_dashboard_auth
  log "Authelia ready — login portal: https://${AUTH_FQDN}"
}
