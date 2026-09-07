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

print_wait_progress() {
  local elapsed=$1 max=$2 label=$3
  local width=28 pct filled empty bar="" i
  (( max < 1 )) && max=1
  pct=$(( elapsed * 100 / max ))
  (( pct > 100 )) && pct=100
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  for ((i = 0; i < filled; i++)); do bar+='#'; done
  for ((i = 0; i < empty; i++)); do bar+='-'; done
  printf '\r==> [%s] %3d%% (%ds/%ds) %s' "${bar}" "${pct}" "${elapsed}" "${max}" "${label}" >&2
}

clear_wait_progress() {
  printf '\r%*s\r' 88 "" >&2
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

# Silent readiness check — avoids kubectl rollout status flooding SSH sessions.
deployment_rollout_complete() {
  local ns="$1" name="$2"
  local ready desired updated available generation observed
  ready="$(k get deployment "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  desired="$(k get deployment "${name}" -n "${ns}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  updated="$(k get deployment "${name}" -n "${ns}" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo 0)"
  available="$(k get deployment "${name}" -n "${ns}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  generation="$(k get deployment "${name}" -n "${ns}" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo 0)"
  observed="$(k get deployment "${name}" -n "${ns}" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo 0)"
  [[ "${desired:-0}" -ge 1 ]] \
    && [[ "${ready:-0}" == "${desired}" ]] \
    && [[ "${updated:-0}" == "${desired}" ]] \
    && [[ "${available:-0}" == "${desired}" ]] \
    && [[ "${generation}" == "${observed}" ]]
}

statefulset_rollout_complete() {
  local ns="$1" name="$2"
  local ready desired updated current generation observed
  ready="$(k get statefulset "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  desired="$(k get statefulset "${name}" -n "${ns}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  updated="$(k get statefulset "${name}" -n "${ns}" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo 0)"
  current="$(k get statefulset "${name}" -n "${ns}" -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo 0)"
  generation="$(k get statefulset "${name}" -n "${ns}" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo 0)"
  observed="$(k get statefulset "${name}" -n "${ns}" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo 0)"
  [[ "${desired:-0}" -ge 1 ]] \
    && [[ "${ready:-0}" == "${desired}" ]] \
    && [[ "${updated:-0}" == "${desired}" ]] \
    && [[ "${current:-0}" == "${desired}" ]] \
    && [[ "${generation}" == "${observed}" ]]
}

# Poll until ready; silent polling keeps SSH sessions alive without log spam.
wait_for_deployment() {
  local ns="$1" name="$2" max_wait="${3:-600}"
  local start now elapsed last_heartbeat=0 fatal_count=0
  start="$(date +%s)"
  log "Waiting for deployment/${name} in ${ns} (up to ${max_wait}s, images may take several minutes)..."
  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    print_wait_progress "${elapsed}" "${max_wait}" "${name} in ${ns}"
    if (( elapsed >= max_wait )); then
      clear_wait_progress
      warn "Timed out after ${max_wait}s waiting for deployment/${name} in ${ns}"
      diagnose_workload "${ns}" "${name}"
      return 1
    fi
    if k get deployment "${name}" -n "${ns}" >/dev/null 2>&1; then
      if workload_has_fatal_pod "${ns}" "${name}"; then
        (( fatal_count += 1 ))
        if (( fatal_count >= 2 )); then
          clear_wait_progress
          warn "Pod for ${name} is in a failed state — aborting wait"
          diagnose_workload "${ns}" "${name}"
          return 1
        fi
      else
        fatal_count=0
      fi
      if deployment_rollout_complete "${ns}" "${name}"; then
        clear_wait_progress
        log "deployment/${name} is ready"
        return 0
      fi
      if (( elapsed - last_heartbeat >= 60 )); then
        clear_wait_progress
        log "Still waiting for ${name}... (${elapsed}s / ${max_wait}s)"
        k get pods -n "${ns}" 2>/dev/null | grep -E "NAME|${name}" || true
        last_heartbeat=$elapsed
      fi
    fi
    sleep 5
  done
}

wait_for_statefulset() {
  local ns="$1" name="$2" max_wait="${3:-600}"
  local start now elapsed last_heartbeat=0 fatal_count=0
  start="$(date +%s)"
  log "Waiting for statefulset/${name} in ${ns} (up to ${max_wait}s)..."
  while true; do
    now="$(date +%s)"
    elapsed=$((now - start))
    print_wait_progress "${elapsed}" "${max_wait}" "${name} in ${ns}"
    if (( elapsed >= max_wait )); then
      clear_wait_progress
      warn "Timed out after ${max_wait}s waiting for statefulset/${name} in ${ns}"
      diagnose_workload "${ns}" "${name}"
      return 1
    fi
    if k get statefulset "${name}" -n "${ns}" >/dev/null 2>&1; then
      if workload_has_fatal_pod "${ns}" "${name}"; then
        (( fatal_count += 1 ))
        if (( fatal_count >= 2 )); then
          clear_wait_progress
          warn "Pod for ${name} is in a failed state — aborting wait"
          diagnose_workload "${ns}" "${name}"
          return 1
        fi
      else
        fatal_count=0
      fi
      if statefulset_rollout_complete "${ns}" "${name}"; then
        clear_wait_progress
        log "statefulset/${name} is ready"
        return 0
      fi
      if (( elapsed - last_heartbeat >= 60 )); then
        clear_wait_progress
        log "Still waiting for ${name}... (${elapsed}s / ${max_wait}s)"
        k get pods -n "${ns}" 2>/dev/null | grep -E "NAME|${name}" || true
        last_heartbeat=$elapsed
      fi
    fi
    sleep 5
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

wait_for_coredns() {
  local i elapsed=0 max_wait=180
  log "Waiting for cluster DNS (CoreDNS)..."
  while (( elapsed < max_wait )); do
    if k get deployment coredns -n kube-system >/dev/null 2>&1 && \
       deployment_ready kube-system coredns; then
      clear_wait_progress
      log "CoreDNS is ready"
      sleep 3
      return 0
    fi
    print_wait_progress "${elapsed}" "${max_wait}" "CoreDNS"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  clear_wait_progress
  warn "CoreDNS not ready after ${max_wait}s — continuing (DNS may still be starting)"
}

wait_for_redis_ready() {
  local ns="${1:-authelia}" max_wait="${2:-180}" elapsed=0
  log "Waiting for Redis (DNS + TCP) in ${ns}..."
  while (( elapsed < max_wait )); do
    if k get endpoints authelia-redis -n "${ns}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -qE '^[0-9]'; then
      if k run "redis-wait-$$" -n "${ns}" --rm -i --restart=Never \
        --image=busybox:1.36 --command -- sh -c "nc -z -w 5 authelia-redis 6379" >/dev/null 2>&1; then
        clear_wait_progress
        log "Redis is accepting connections"
        sleep 5
        return 0
      fi
    fi
    print_wait_progress "${elapsed}" "${max_wait}" "Redis in ${ns}"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  clear_wait_progress
  warn "Redis connectivity check timed out after ${max_wait}s"
  return 1
}

k8s_namespace_exists() {
  k get namespace "$1" >/dev/null 2>&1
}

# Sets STATE_K3S STATE_TRAEFIK STATE_AUTHELIA STATE_ARGOCD STATE_DASHBOARD STATE_CERT_MANAGER
# Values: missing | installed | ready
detect_platform_state() {
  STATE_K3S=missing
  STATE_TRAEFIK=missing
  STATE_AUTHELIA=missing
  STATE_ARGOCD=missing
  STATE_DASHBOARD=missing
  STATE_CERT_MANAGER=missing

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

  if k8s_namespace_exists cert-manager; then
    if deployment_ready cert-manager cert-manager; then
      STATE_CERT_MANAGER=ready
    else
      STATE_CERT_MANAGER=installed
    fi
  else
    STATE_CERT_MANAGER=missing
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
    -e "s|@FQDN@|${FQDN:-}|g" \
    -e "s|@CERT_NAME@|${CERT_NAME:-}|g" \
    -e "s|@SECRET_NAME@|${SECRET_NAME:-}|g" \
    -e "s|@NAMESPACE@|${NAMESPACE:-}|g" \
    -e "s|@ISSUER_NAME@|${ISSUER_NAME:-letsencrypt}|g" \
    "${template}"
}

tls_secret_name() {
  echo "tls-$(echo "${1}" | tr '[:upper:]' '[:lower:]' | tr '.' '-')"
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

extract_authelia_hash() {
  grep -oE '\$argon2[^[:space:]]+' | head -1
}

generate_authelia_password_hash() {
  local password="$1" hash="" tmp_job="" job_id secret_name logs=""
  job_id="authelia-hash-$$"
  secret_name="${job_id}-pw"
  tmp_job="/tmp/${job_id}.yaml"

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    logs="$(docker run --rm docker.io/authelia/authelia:4.38.5 \
      authelia crypto hash generate argon2 --password "${password}" --no-confirm 2>&1 || true)"
    hash="$(printf '%s\n' "${logs}" | extract_authelia_hash)"
    if [[ -n "${hash}" ]]; then
      echo "${hash}"
      return 0
    fi
    [[ -n "${logs}" ]] && warn "Docker hash attempt failed: ${logs}"
  fi

  k delete job "${job_id}" -n authelia --ignore-not-found --wait=false >/dev/null 2>&1 || true
  k delete secret "${secret_name}" -n authelia --ignore-not-found >/dev/null 2>&1 || true
  k create secret generic "${secret_name}" -n authelia --from-literal=password="${password}" >/dev/null

  cat > "${tmp_job}" <<'JOBTMPL'
apiVersion: batch/v1
kind: Job
metadata:
  name: @JOB_ID@
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
          args:
            - authelia
            - crypto
            - hash
            - generate
            - argon2
            - --password
            - file:/secrets/password
            - --no-confirm
          volumeMounts:
            - name: password
              mountPath: /secrets
              readOnly: true
      volumes:
        - name: password
          secret:
            secretName: @SECRET_NAME@
            items:
              - key: password
                path: password
JOBTMPL
  sed -i "s/@JOB_ID@/${job_id}/g; s/@SECRET_NAME@/${secret_name}/g" "${tmp_job}"

  if [[ ! -s "${tmp_job}" ]]; then
    warn "Failed to write Authelia hash job manifest"
    k delete secret "${secret_name}" -n authelia --ignore-not-found
    return 1
  fi

  if ! k apply -f "${tmp_job}" >/dev/null 2>&1; then
    warn "Failed to apply Authelia hash job"
    k delete secret "${secret_name}" -n authelia --ignore-not-found >/dev/null 2>&1 || true
    rm -f "${tmp_job}"
    return 1
  fi

  if ! k wait --for=condition=complete "job/${job_id}" -n authelia --timeout=180s >/dev/null 2>&1; then
    warn "Authelia hash job did not complete — details:"
    k describe job "${job_id}" -n authelia 2>/dev/null | sed -n '/Events:/,$p' || true
    k logs "job/${job_id}" -n authelia 2>&1 || true
    k delete job "${job_id}" -n authelia --ignore-not-found --wait=false >/dev/null 2>&1 || true
    k delete secret "${secret_name}" -n authelia --ignore-not-found >/dev/null 2>&1 || true
    rm -f "${tmp_job}"
    return 1
  fi

  logs="$(k logs "job/${job_id}" -n authelia 2>&1 || true)"
  hash="$(printf '%s\n' "${logs}" | extract_authelia_hash)"
  k delete job "${job_id}" -n authelia --ignore-not-found --wait=false >/dev/null 2>&1 || true
  k delete secret "${secret_name}" -n authelia --ignore-not-found >/dev/null 2>&1 || true
  rm -f "${tmp_job}"

  if [[ -z "${hash}" ]]; then
    warn "Authelia hash job finished but no argon2 digest was found. Job output:"
    printf '%s\n' "${logs}" >&2
    return 1
  fi

  echo "${hash}"
}

sync_authelia_users_secret() {
  : "${AUTHELIA_ADMIN_USER:?AUTHELIA_ADMIN_USER not set}"
  : "${AUTHELIA_ADMIN_PASSWORD:?AUTHELIA_ADMIN_PASSWORD not set}"
  : "${AUTHELIA_ADMIN_EMAIL:?AUTHELIA_ADMIN_EMAIL not set}"

  local hash tmp_users="/tmp/authelia-users-$$.yml"
  log "Updating Authelia admin user..."
  hash="$(generate_authelia_password_hash "${AUTHELIA_ADMIN_PASSWORD}")" || {
    echo "Failed to hash Authelia password — see warnings above for job output." >&2
    return 1
  }

  cat > "${tmp_users}" <<EOF
users:
  ${AUTHELIA_ADMIN_USER}:
    disabled: false
    displayname: "${AUTHELIA_ADMIN_DISPLAY_NAME:-Admin}"
    password: "${hash}"
    email: "${AUTHELIA_ADMIN_EMAIL}"
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
    local secret
    secret="$(tls_secret_name "${fqdn}")"
    cat <<EOF
  tls:
    secretName: ${secret}
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
    log "DNS verified — cert-manager will obtain Let's Encrypt certificates"
  else
    ENABLE_LETSENCRYPT=no
    warn "DNS not ready — skipping Let's Encrypt (Traefik default cert for now)"
    warn "After fixing DNS, re-run: sudo himosoft-k3s-server bootstrap"
  fi
  export ENABLE_LETSENCRYPT
}

write_traefik_values() {
  local share="${SHARE:-/usr/share/himosoft-k3s-server}"
  local out="/etc/himosoft/traefik-values.yaml"
  mkdir -p /etc/himosoft
  local tls_block="" line
  if [[ "${ENABLE_LETSENCRYPT:-no}" == "yes" ]]; then
    tls_block=$"    tls:\n      secretName: $(tls_secret_name "${TRAEFIK_FQDN}")"
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
    apply_template "${share}/traefik-values-certmanager.yaml.template" >> "${out}"
  fi
  chmod 600 "${out}"
}

certificate_rate_limited() {
  local ns="$1" name="$2"
  k describe certificate "${name}" -n "${ns}" 2>/dev/null \
    | grep -qE 'rateLimited|too many certificates'
}

certificate_retry_after_hint() {
  local ns="$1" name="$2"
  k describe certificate "${name}" -n "${ns}" 2>/dev/null \
    | grep -oE 'retry after [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]+ UTC' | head -1 || true
}

wait_for_certificate() {
  local ns="$1" name="$2" max_wait="${3:-300}"
  local start now elapsed=0 status="" reason="" message=""
  start="$(date +%s)"
  log "Waiting for certificate/${name} in ${ns} (up to ${max_wait}s)..."
  while (( elapsed < max_wait )); do
    now="$(date +%s)"
    elapsed=$((now - start))
    print_wait_progress "${elapsed}" "${max_wait}" "cert ${name}"
    if certificate_rate_limited "${ns}" "${name}"; then
      clear_wait_progress
      message="$(certificate_retry_after_hint "${ns}" "${name}")"
      warn "Let's Encrypt rate limit for ${name}${message:+ — ${message}}"
      return 2
    fi
    status="$(k get certificate "${name}" -n "${ns}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    reason="$(k get certificate "${name}" -n "${ns}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)"
    if [[ "${status}" == "True" ]]; then
      clear_wait_progress
      log "certificate/${name} is ready"
      return 0
    fi
    if [[ "${status}" == "False" && "${reason}" != "Issuing" && "${reason}" != "DoesNotExist" ]]; then
      clear_wait_progress
      if certificate_rate_limited "${ns}" "${name}"; then
        message="$(certificate_retry_after_hint "${ns}" "${name}")"
        warn "Let's Encrypt rate limit for ${name}${message:+ — ${message}}"
        return 2
      fi
      message="$(k get certificate "${name}" -n "${ns}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)"
      warn "certificate/${name} failed (${reason}): ${message}"
      k describe certificate "${name}" -n "${ns}" 2>/dev/null | sed -n '/Events:/,$p' | tail -10 || true
      return 1
    fi
    sleep 5
  done
  clear_wait_progress
  if certificate_rate_limited "${ns}" "${name}"; then
    message="$(certificate_retry_after_hint "${ns}" "${name}")"
    warn "Let's Encrypt rate limit for ${name}${message:+ — ${message}}"
    return 2
  fi
  warn "Timed out waiting for certificate/${name} in ${ns} — continuing install"
  k describe certificate "${name}" -n "${ns}" 2>/dev/null | sed -n '/Events:/,$p' | tail -10 || true
  return 1
}

ensure_tls_certificate() {
  local fqdn="$1" ns="$2" issuer="${3:-letsencrypt}"
  local share="${SHARE:-/usr/share/himosoft-k3s-server}"
  local secret_name cert_name current_issuer rc=0
  secret_name="$(tls_secret_name "${fqdn}")"
  cert_name="${secret_name}"

  k create namespace "${ns}" --dry-run=client -o yaml | k apply -f - >/dev/null 2>&1 || true

  current_issuer="$(k get certificate "${cert_name}" -n "${ns}" \
    -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null || true)"
  if [[ -n "${current_issuer}" && "${current_issuer}" != "${issuer}" ]]; then
    k delete certificate "${cert_name}" -n "${ns}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    sleep 2
  fi

  FQDN="${fqdn}" NAMESPACE="${ns}" SECRET_NAME="${secret_name}" CERT_NAME="${cert_name}"
  ISSUER_NAME="${issuer}"
  export FQDN NAMESPACE SECRET_NAME CERT_NAME ISSUER_NAME
  apply_template "${share}/manifests/cert-manager/certificate.yaml.template" | k apply -f -
  wait_for_certificate "${ns}" "${cert_name}" 300 || rc=$?
  return "${rc}"
}

sync_tls_certificate() {
  local fqdn="$1" ns="$2" issuer="${3:-letsencrypt}"
  local rc=0
  ensure_tls_certificate "${fqdn}" "${ns}" "${issuer}" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    return 0
  fi
  if [[ "${rc}" -eq 2 ]]; then
    TLS_RATE_LIMITED=yes
    export TLS_RATE_LIMITED
    if [[ "${issuer}" == "letsencrypt" && "${TLS_USING_STAGING:-no}" != "yes" ]]; then
      log "Production rate limited — switching to Let's Encrypt staging for ${fqdn}"
      TLS_USING_STAGING=yes
      export TLS_USING_STAGING
      ensure_tls_certificate "${fqdn}" "${ns}" "letsencrypt-staging" || true
      return 0
    fi
  fi
  TLS_CERTS_PENDING=$((TLS_CERTS_PENDING + 1))
  export TLS_CERTS_PENDING
  warn "Certificate for ${fqdn} not ready — install will continue"
  return 0
}

sync_all_tls_certificates() {
  if [[ "${ENABLE_LETSENCRYPT:-no}" != "yes" ]]; then
    return 0
  fi

  local issuer="letsencrypt"
  TLS_CERTS_PENDING=0
  TLS_USING_STAGING=no
  TLS_RATE_LIMITED=no
  export TLS_CERTS_PENDING TLS_USING_STAGING TLS_RATE_LIMITED

  if [[ "${ACME_STAGING:-no}" == "yes" ]]; then
    issuer="letsencrypt-staging"
    TLS_USING_STAGING=yes
    export TLS_USING_STAGING
    log "Using Let's Encrypt staging (ACME_STAGING=yes)"
  fi

  log "Issuing TLS certificates (cert-manager + Let's Encrypt)..."
  sync_tls_certificate "${TRAEFIK_FQDN}" traefik "${issuer}"
  [[ "${TLS_USING_STAGING:-no}" == "yes" ]] && issuer="letsencrypt-staging"
  sync_tls_certificate "${DASH_FQDN}" kubernetes-dashboard "${issuer}"
  [[ "${TLS_USING_STAGING:-no}" == "yes" ]] && issuer="letsencrypt-staging"

  if [[ "${INSTALL_ARGOCD:-yes}" == "yes" && -n "${ARGOCD_FQDN:-}" ]]; then
    sync_tls_certificate "${ARGOCD_FQDN}" argocd "${issuer}"
  fi
  [[ "${TLS_USING_STAGING:-no}" == "yes" ]] && issuer="letsencrypt-staging"

  if authelia_enabled; then
    sync_tls_certificate "${AUTH_FQDN}" authelia "${issuer}"
  fi

  if k get deployment traefik -n traefik >/dev/null 2>&1; then
    k rollout restart deployment/traefik -n traefik >/dev/null 2>&1 || true
    wait_for_deployment traefik traefik 180
  fi

  if [[ "${TLS_USING_STAGING:-no}" == "yes" ]]; then
    warn "Staging certificates in use — browsers will show untrusted HTTPS"
    warn "After Let's Encrypt rate limit clears, run: sudo himosoft-k3s-server bootstrap"
  elif [[ "${TLS_CERTS_PENDING:-0}" -gt 0 ]]; then
    warn "${TLS_CERTS_PENDING} certificate(s) not ready — run: sudo himosoft-k3s-server bootstrap"
  else
    log "TLS certificates ready"
  fi
  return 0
}

install_cert_manager() {
  if [[ "${ENABLE_LETSENCRYPT:-no}" != "yes" ]]; then
    return 0
  fi

  local share="${SHARE:-/usr/share/himosoft-k3s-server}"
  local chart_version="${CERT_MANAGER_CHART_VERSION:-}"

  apply_cluster_issuers() {
    apply_template "${share}/manifests/cert-manager/cluster-issuer.yaml.template" | k apply -f -
    apply_template "${share}/manifests/cert-manager/cluster-issuer-staging.yaml.template" | k apply -f -
  }

  if k get deployment cert-manager -n cert-manager >/dev/null 2>&1 \
    && deployment_ready cert-manager cert-manager; then
    log "cert-manager already running — syncing ClusterIssuers"
    apply_cluster_issuers
    return 0
  fi

  log "Installing cert-manager"
  ensure_helm
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update jetstack

  local helm_args=(
    upgrade --install cert-manager jetstack/cert-manager
    -n cert-manager --create-namespace
    --set crds.enabled=true
    --set prometheus.enabled=false
  )
  if [[ -n "${chart_version}" ]]; then
    helm_args+=(--version "${chart_version}")
  fi

  if ! helm "${helm_args[@]}" >/dev/null 2>&1; then
    warn "cert-manager Helm install failed — retrying with verbose output"
    helm "${helm_args[@]}"
  fi

  wait_for_deployment cert-manager cert-manager 300
  wait_for_deployment cert-manager cert-manager-webhook 300
  wait_for_deployment cert-manager cert-manager-cainjector 300

  apply_cluster_issuers
  log "cert-manager ready"
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

  k rollout restart deployment/argocd-server -n argocd >/dev/null 2>&1 || true
  wait_for_deployment argocd argocd-server 600
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
  if ! helm upgrade traefik traefik/traefik -n traefik \
    -f /etc/himosoft/traefik-values.yaml >/dev/null 2>&1; then
    helm upgrade traefik traefik/traefik -n traefik \
      -f /etc/himosoft/traefik-values.yaml
  fi
  wait_for_deployment traefik traefik 300
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
    k apply -f "${share}/manifests/authelia/deployment.yaml"
    k rollout restart deployment/authelia -n authelia 2>/dev/null || true
    wait_for_deployment authelia authelia 600
    apply_template "${share}/manifests/authelia/middleware-forwardauth.yaml.template" | k apply -f -
    apply_template_ingress "${share}/manifests/authelia/ingressroute.yaml.template" "${AUTH_FQDN}" | k apply -f -
    upgrade_traefik_dashboard_auth
    return 0
  fi

  log "Installing Authelia SSO (protects Argo CD, Dashboard, Traefik UI)"
  wait_for_coredns
  k apply -f "${share}/manifests/authelia/namespace.yaml"
  k apply -f "${share}/manifests/authelia/redis.yaml"
  wait_for_deployment authelia authelia-redis 300
  wait_for_redis_ready authelia 180

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
  k rollout status deployment/authelia -n authelia --timeout=600s 2>/dev/null \
    || wait_for_deployment authelia authelia 600

  apply_template "${share}/manifests/authelia/middleware-forwardauth.yaml.template" | k apply -f -
  apply_template_ingress "${share}/manifests/authelia/ingressroute.yaml.template" "${AUTH_FQDN}" | k apply -f -
  upgrade_traefik_dashboard_auth
  log "Authelia ready — login portal: https://${AUTH_FQDN}"
}
