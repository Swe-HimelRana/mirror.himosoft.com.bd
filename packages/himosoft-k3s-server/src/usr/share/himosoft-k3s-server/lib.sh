#!/usr/bin/env bash
# Shared helpers for himosoft-k3s-server bootstrap scripts.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

k() {
  k3s kubectl "$@"
}

log() {
  install_progress_before_output
  echo "==> $*"
  install_progress_after_output
}

# Apt-style overall install progress — fixed bar on the last terminal line (stderr).
install_progress_is_tty() {
  [[ -t 2 ]] && [[ -n "${TERM:-}" ]] && command -v tput >/dev/null 2>&1
}

install_progress_is_noop_install() {
  [[ "${SKIP_K3S:-no}" == "yes" \
    && "${SKIP_TRAEFIK:-no}" == "yes" \
    && "${SKIP_AUTHELIA:-no}" == "yes" \
    && "${SKIP_ARGOCD:-no}" == "yes" \
    && "${SKIP_DASHBOARD:-no}" == "yes" \
    && "${SKIP_INGRESS:-no}" == "yes" ]]
}

install_progress_reset() {
  INSTALL_PROGRESS_ACTIVE=no
  INSTALL_PROGRESS_PCT=0
  INSTALL_PROGRESS_LABEL="Starting"
  INSTALL_PROGRESS_DONE_WEIGHT=0
  INSTALL_PROGRESS_CURRENT_WEIGHT=0
  INSTALL_PROGRESS_TOTAL_WEIGHT=100
  INSTALL_PROGRESS_SUB_PCT=0
}

install_progress_recalc() {
  local partial=0 cur="${INSTALL_PROGRESS_CURRENT_WEIGHT:-0}" done="${INSTALL_PROGRESS_DONE_WEIGHT:-0}"
  local sub="${INSTALL_PROGRESS_SUB_PCT:-0}" total="${INSTALL_PROGRESS_TOTAL_WEIGHT:-100}"
  partial=$(( cur * sub / 100 ))
  if (( total > 0 )); then
    INSTALL_PROGRESS_PCT=$(( (done + partial) * 100 / total ))
  else
    INSTALL_PROGRESS_PCT=100
  fi
  if (( INSTALL_PROGRESS_PCT > 100 )); then
    INSTALL_PROGRESS_PCT=100
  fi
}

install_progress_redraw() {
  [[ "${INSTALL_PROGRESS_ACTIVE:-}" == "yes" ]] || return 0
  if ! install_progress_is_tty; then
    return 0
  fi
  local pct="${INSTALL_PROGRESS_PCT:-0}" label="${INSTALL_PROGRESS_LABEL:-Installing}"
  local width=40 filled empty bar="" rows cols line pad i
  if (( pct > 100 )); then
    pct=100
  fi
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  for ((i = 0; i < filled; i++)); do bar+='#'; done
  for ((i = 0; i < empty; i++)); do bar+='-'; done
  line="$(printf 'Progress: [%3d%%] [%s] %s' "${pct}" "${bar}" "${label}")"
  rows=$(tput lines)
  cols=$(tput cols 2>/dev/null || echo 80)
  pad=$(( cols - ${#line} ))
  if (( pad < 0 )); then
    pad=0
  fi
  {
    tput sc
    tput cup $(( rows - 1 )) 0
    tput el
    printf '%s' "${line}"
    printf '%*s' "${pad}" ''
    tput rc
  } >&2 2>/dev/null || printf '\r%-*s' "${cols}" "${line}" >&2
}

install_progress_clear_line() {
  if ! install_progress_is_tty; then
    return 0
  fi
  local rows cols
  rows=$(tput lines)
  cols=$(tput cols 2>/dev/null || echo 80)
  {
    tput cup $(( rows - 1 )) 0
    tput el
  } >&2 2>/dev/null || printf '\r%-*s\r' "${cols}" '' >&2
}

install_progress_before_output() {
  [[ "${INSTALL_PROGRESS_ACTIVE:-}" == "yes" ]] || return 0
  install_progress_clear_line
}

install_progress_after_output() {
  install_progress_redraw
}

install_progress_start() {
  install_progress_reset
  INSTALL_PROGRESS_ACTIVE=yes
  export INSTALL_PROGRESS_ACTIVE
  trap 'install_progress_finish' EXIT INT TERM
  install_progress_redraw
}

install_progress_finish() {
  local exit_code=$?
  [[ "${INSTALL_PROGRESS_ACTIVE:-}" == "yes" ]] || return 0
  trap - EXIT INT TERM
  if (( exit_code != 0 )); then
    install_progress_clear_line
    INSTALL_PROGRESS_ACTIVE=no
    export INSTALL_PROGRESS_ACTIVE
    return "${exit_code}"
  fi
  if install_progress_is_tty; then
    local bar="" i rows
    for ((i = 0; i < 40; i++)); do bar+='#'; done
    rows=$(tput lines)
    {
      tput cup $(( rows - 1 )) 0
      tput el
      printf 'Progress: [100%%] [%s] Complete\n' "${bar}"
    } >&2 2>/dev/null || printf '\nProgress: [100%%] Complete\n' >&2
  fi
  INSTALL_PROGRESS_ACTIVE=no
  export INSTALL_PROGRESS_ACTIVE
}

install_progress_step_begin() {
  local weight="${2:-0}"
  if (( weight == 0 )); then
    return 0
  fi
  INSTALL_PROGRESS_LABEL="${1:-Installing}"
  INSTALL_PROGRESS_CURRENT_WEIGHT="${weight}"
  INSTALL_PROGRESS_SUB_PCT=0
  install_progress_recalc
  install_progress_redraw
}

install_progress_step_end() {
  local weight="${INSTALL_PROGRESS_CURRENT_WEIGHT:-0}"
  if (( weight == 0 )); then
    return 0
  fi
  INSTALL_PROGRESS_DONE_WEIGHT=$(( ${INSTALL_PROGRESS_DONE_WEIGHT:-0} + weight ))
  INSTALL_PROGRESS_SUB_PCT=100
  install_progress_recalc
  export INSTALL_PROGRESS_DONE_WEIGHT
  install_progress_redraw
}

install_progress_sub() {
  [[ "${INSTALL_PROGRESS_ACTIVE:-}" == "yes" ]] || return 0
  local cur="${INSTALL_PROGRESS_CURRENT_WEIGHT:-0}"
  if (( cur == 0 )); then
    return 0
  fi
  local sub_pct="${1:-0}" sub_label="${2:-}"
  if (( sub_pct > 100 )); then
    sub_pct=100
  fi
  [[ -n "${sub_label}" ]] && INSTALL_PROGRESS_LABEL="${sub_label}"
  INSTALL_PROGRESS_SUB_PCT="${sub_pct}"
  install_progress_recalc
  install_progress_redraw
}

install_progress_run_step() {
  local label="$1" weight="$2"
  shift 2
  if [[ "${INSTALL_PROGRESS_ACTIVE:-}" != "yes" ]]; then
    "$@"
    return 0
  fi
  install_progress_step_begin "${label}" "${weight}"
  "$@"
  install_progress_step_end
}

# Build step weights from install plan (respects SKIP_* / feature flags).
install_progress_init_from_env() {
  if install_progress_is_noop_install; then
    install_progress_reset
    INSTALL_PROGRESS_ACTIVE=no
    export INSTALL_PROGRESS_ACTIVE
    return 0
  fi

  local done="${INSTALL_PROGRESS_DONE_WEIGHT:-0}" total=0
  local w_k3s=0 w_coredns=2 w_traefik=0 w_certmgr=0 w_tls=0 w_authelia=0 w_argocd=0 w_dashboard=0 w_ingress=0 w_finish=3

  [[ "${SKIP_K3S:-no}" != "yes" ]] && w_k3s=12
  [[ "${SKIP_TRAEFIK:-no}" != "yes" ]] && w_traefik=10
  if [[ "${ENABLE_LETSENCRYPT:-no}" == "yes" ]]; then
    w_certmgr=8
    w_tls=14
  fi
  if [[ "${SKIP_AUTHELIA:-no}" != "yes" && "${INSTALL_AUTHELIA:-yes}" == "yes" ]]; then
    w_authelia=14
  fi
  if [[ "${SKIP_ARGOCD:-no}" != "yes" && "${INSTALL_ARGOCD:-yes}" == "yes" ]]; then
    w_argocd=22
  fi
  [[ "${SKIP_DASHBOARD:-no}" != "yes" ]] && w_dashboard=10
  [[ "${SKIP_INGRESS:-no}" != "yes" ]] && w_ingress=5

  total=$(( w_k3s + w_coredns + w_traefik + w_certmgr + w_tls + w_authelia + w_argocd + w_dashboard + w_ingress + w_finish ))
  if (( total < 1 )); then
    total=100
  fi

  INSTALL_PROGRESS_TOTAL_WEIGHT=${total}
  INSTALL_PROGRESS_DONE_WEIGHT=${done}
  INSTALL_PROGRESS_W_K3S=${w_k3s}
  INSTALL_PROGRESS_W_COREDNS=${w_coredns}
  INSTALL_PROGRESS_W_TRAEFIK=${w_traefik}
  INSTALL_PROGRESS_W_CERTMGR=${w_certmgr}
  INSTALL_PROGRESS_W_TLS=${w_tls}
  INSTALL_PROGRESS_W_AUTHELIA=${w_authelia}
  INSTALL_PROGRESS_W_ARGOCD=${w_argocd}
  INSTALL_PROGRESS_W_DASHBOARD=${w_dashboard}
  INSTALL_PROGRESS_W_INGRESS=${w_ingress}
  INSTALL_PROGRESS_W_FINISH=${w_finish}
  export INSTALL_PROGRESS_TOTAL_WEIGHT INSTALL_PROGRESS_DONE_WEIGHT

  if [[ "${INSTALL_PROGRESS_ACTIVE:-}" != "yes" ]]; then
    install_progress_start
    INSTALL_PROGRESS_DONE_WEIGHT=${done}
    install_progress_recalc
    install_progress_redraw
  else
    install_progress_recalc
    install_progress_redraw
  fi
}

print_wait_progress() {
  local elapsed=$1 max=$2 label=$3
  if (( max < 1 )); then
    max=1
  fi
  install_progress_sub $(( elapsed * 100 / max )) "${label}"
}

clear_wait_progress() {
  :
}

warn() {
  install_progress_before_output
  echo "==> WARNING: $*" >&2
  install_progress_after_output
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
    install_progress_sub $(( i * 100 / 60 )) "Waiting for K3s API"
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
      log "CoreDNS is ready"
      sleep 3
      return 0
    fi
    install_progress_sub $(( elapsed * 100 / max_wait )) "CoreDNS"
    sleep 5
    elapsed=$((elapsed + 5))
  done
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

render_traefik_ingress_class_block() {
  if [[ "${ENABLE_LETSENCRYPT:-no}" == "yes" ]]; then
    cat <<'EOF'
  enabled: true
  isDefaultClass: true
  name: traefik
EOF
  else
    echo "  enabled: false"
  fi
}

render_traefik_kubernetes_ingress_block() {
  if [[ "${ENABLE_LETSENCRYPT:-no}" == "yes" ]]; then
    cat <<'EOF'
    enabled: true
    ingressClass: traefik
EOF
  else
    echo "    enabled: false"
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
  sed -n 's/.*Digest: //p' | head -1 | tr -d '\r'
}

generate_authelia_password_hash() {
  local password="$1" hash="" tmp_job="" job_id secret_name logs=""

  if k get deployment authelia -n authelia >/dev/null 2>&1; then
    logs="$(k exec -n authelia deploy/authelia -- \
      authelia crypto hash generate argon2 --password "${password}" --no-confirm 2>&1 || true)"
    hash="$(printf '%s\n' "${logs}" | extract_authelia_hash)"
    if [[ -n "${hash}" ]]; then
      printf '%s' "${hash}"
      return 0
    fi
    [[ -n "${logs}" ]] && warn "Authelia pod hash attempt failed: ${logs}"
  fi

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    logs="$(docker run --rm docker.io/authelia/authelia:4.38.5 \
      authelia crypto hash generate argon2 --password "${password}" --no-confirm 2>&1 || true)"
    hash="$(printf '%s\n' "${logs}" | extract_authelia_hash)"
    if [[ -n "${hash}" ]]; then
      printf '%s' "${hash}"
      return 0
    fi
    [[ -n "${logs}" ]] && warn "Docker hash attempt failed: ${logs}"
  fi

  job_id="authelia-hash-$$"
  secret_name="${job_id}-pw"
  tmp_job="/tmp/${job_id}.yaml"

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
          command: ["/bin/sh", "-ec"]
          args:
            - |
              authelia crypto hash generate argon2 \
                --password "$(cat /secrets/password)" --no-confirm
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

  printf '%s' "${hash}"
}

sync_authelia_users_secret() {
  : "${AUTHELIA_ADMIN_USER:?AUTHELIA_ADMIN_USER not set}"
  : "${AUTHELIA_ADMIN_PASSWORD:?AUTHELIA_ADMIN_PASSWORD not set}"
  : "${AUTHELIA_ADMIN_EMAIL:?AUTHELIA_ADMIN_EMAIL not set}"

  local hash db tmp_out
  log "Updating Authelia admin user..."
  hash="$(generate_authelia_password_hash "${AUTHELIA_ADMIN_PASSWORD}")" || {
    echo "Failed to hash Authelia password — see warnings above for job output." >&2
    return 1
  }

  db="$(authelia_users_work_file)"
  tmp_out="$(authelia_users_work_file)"
  if k get secret "$(authelia_users_secret_name)" -n authelia >/dev/null 2>&1; then
    authelia_fetch_users_db "${db}"
  else
    echo "users:" > "${db}"
  fi

  authelia_upsert_user_in_file "${db}" "${AUTHELIA_ADMIN_USER}" \
    "${AUTHELIA_ADMIN_DISPLAY_NAME:-Admin}" "${hash}" "${AUTHELIA_ADMIN_EMAIL}" "${tmp_out}"

  k create secret generic authelia-users -n authelia \
    --from-file=users_database.yml="${tmp_out}" \
    --dry-run=client -o yaml | k apply -f -
  rm -f "${db}" "${tmp_out}"
}

# --- Authelia file-backend user management (users_database.yml in secret authelia-users) ---

authelia_users_secret_name() {
  echo "authelia-users"
}

authelia_users_require_ready() {
  if ! authelia_enabled; then
    echo "Authelia is not configured." >&2
    return 1
  fi
  if ! k get deployment authelia -n authelia >/dev/null 2>&1; then
    echo "Authelia is not installed. Run: sudo himosoft-k3s-server install" >&2
    return 1
  fi
  if ! k get secret "$(authelia_users_secret_name)" -n authelia >/dev/null 2>&1; then
    echo "Authelia users secret not found." >&2
    return 1
  fi
  return 0
}

authelia_valid_username() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9_-]+$ ]]
}

authelia_fetch_users_db() {
  local dest="$1"
  k get secret "$(authelia_users_secret_name)" -n authelia \
    -o "jsonpath={.data.users_database\.yml}" | base64 -d > "${dest}"
}

authelia_apply_users_db() {
  local src="$1"
  k create secret generic "$(authelia_users_secret_name)" -n authelia \
    --from-file=users_database.yml="${src}" \
    --dry-run=client -o yaml | k apply -f -
  if k get deployment authelia -n authelia >/dev/null 2>&1; then
    k rollout restart deployment/authelia -n authelia >/dev/null 2>&1 || true
    wait_for_deployment authelia authelia 600
  fi
}

authelia_user_exists_in_file() {
  local file="$1" user="$2"
  grep -qE "^  ${user}:$" "${file}"
}

authelia_list_usernames_in_file() {
  local file="$1"
  awk '/^users:/{next} /^  [a-zA-Z0-9_-]+:$/ { gsub(/:$/, "", $1); print $1 }' "${file}"
}

authelia_user_email_from_file() {
  local file="$1" user="$2"
  awk -v u="${user}" '
    $0 ~ "^  " u ":$" { found=1; next }
    found && /^  [a-zA-Z0-9_-]+:$/ { exit }
    found && /^    email:/ {
      line=$0
      sub(/^    email: */, "", line)
      gsub(/^"/, "", line)
      gsub(/"$/, "", line)
      print line
      exit
    }
  ' "${file}"
}

authelia_user_disabled_in_file() {
  local file="$1" user="$2"
  awk -v u="${user}" '
    $0 ~ "^  " u ":$" { found=1; next }
    found && /^  [a-zA-Z0-9_-]+:$/ { exit }
    found && /^    disabled:/ { print ($2 == "true"); exit }
  ' "${file}"
}

authelia_count_active_users_in_file() {
  local file="$1"
  awk '
    /^  [a-zA-Z0-9_-]+:$/ { user=$1; gsub(/:$/, "", user); disabled[user]=0 }
    /^    disabled: true/ { if (user != "") disabled[user]=1 }
    END { n=0; for (u in disabled) if (!disabled[u]) n++; print n+0 }
  ' "${file}"
}

authelia_write_user_block() {
  local username="$1" displayname="$2" hash="$3" email="$4"
  cat <<EOF
  ${username}:
    disabled: false
    displayname: "${displayname}"
    password: "$(printf '%s' "${hash}")"
    email: "${email}"
    groups:
      - admins
EOF
}

authelia_remove_user_from_file() {
  local infile="$1" user="$2" outfile="$3"
  awk -v u="${user}" '
    $0 ~ "^  " u ":$" { skip=1; next }
    skip && /^  [a-zA-Z0-9_-]+:$/ { skip=0 }
    !skip { print }
  ' "${infile}" > "${outfile}"
}

authelia_set_user_disabled_in_file() {
  local infile="$1" user="$2" disabled="$3" outfile="$4"
  awk -v u="${user}" -v dis="${disabled}" '
    $0 ~ "^  " u ":$" { inuser=1; print; next }
    inuser && /^  [a-zA-Z0-9_-]+:$/ { inuser=0 }
    inuser && /^    disabled:/ {
      print "    disabled: " dis
      next
    }
    { print }
  ' "${infile}" > "${outfile}"
}

authelia_upsert_user_in_file() {
  local infile="$1" username="$2" displayname="$3" hash="$4" email="$5" outfile="$6"
  local tmp_strip="/tmp/authelia-strip-$$.yml"
  if authelia_user_exists_in_file "${infile}" "${username}"; then
    authelia_remove_user_from_file "${infile}" "${username}" "${tmp_strip}"
    infile="${tmp_strip}"
  fi
  if grep -q '^users:' "${infile}"; then
    cp "${infile}" "${outfile}"
  else
    echo "users:" > "${outfile}"
  fi
  authelia_write_user_block "${username}" "${displayname}" "${hash}" "${email}" >> "${outfile}"
  rm -f "${tmp_strip}"
}

authelia_users_work_file() {
  mktemp /tmp/authelia-users-XXXXXX.yml
}

authelia_user_add() {
  local username="$1" email="$2" password="$3" displayname="${4:-}"
  local hash db tmp_out

  authelia_users_require_ready || return 1
  authelia_valid_username "${username}" || {
    echo "Invalid username — use letters, numbers, underscore, hyphen only." >&2
    return 1
  }
  [[ -n "${email}" ]] || { echo "Email is required." >&2; return 1; }
  [[ -n "${password}" ]] || { echo "Password is required." >&2; return 1; }

  displayname="${displayname:-${username}}"
  hash="$(generate_authelia_password_hash "${password}")" || return 1

  db="$(authelia_users_work_file)"
  tmp_out="$(authelia_users_work_file)"
  authelia_fetch_users_db "${db}"
  if authelia_user_exists_in_file "${db}" "${username}"; then
    echo "User '${username}' already exists." >&2
    rm -f "${db}" "${tmp_out}"
    return 1
  fi

  authelia_upsert_user_in_file "${db}" "${username}" "${displayname}" "${hash}" "${email}" "${tmp_out}"
  authelia_apply_users_db "${tmp_out}"
  rm -f "${db}" "${tmp_out}"
  log "Authelia user '${username}' created"
}

authelia_user_show_email() {
  local username="$1" db email disabled

  authelia_users_require_ready || return 1
  [[ -n "${username}" ]] || { echo "Username is required." >&2; return 1; }

  db="$(authelia_users_work_file)"
  authelia_fetch_users_db "${db}"
  if ! authelia_user_exists_in_file "${db}" "${username}"; then
    echo "User '${username}' not found." >&2
    rm -f "${db}"
    return 1
  fi

  email="$(authelia_user_email_from_file "${db}" "${username}")"
  disabled="$(authelia_user_disabled_in_file "${db}" "${username}")"
  rm -f "${db}"

  echo "${email}"
  [[ "${disabled}" == "1" ]] && echo "(account suspended)" >&2
}

authelia_user_suspend() {
  local username="$1" db tmp_out active

  authelia_users_require_ready || return 1
  [[ -n "${username}" ]] || { echo "Username is required." >&2; return 1; }

  db="$(authelia_users_work_file)"
  tmp_out="$(authelia_users_work_file)"
  authelia_fetch_users_db "${db}"
  if ! authelia_user_exists_in_file "${db}" "${username}"; then
    echo "User '${username}' not found." >&2
    rm -f "${db}" "${tmp_out}"
    return 1
  fi
  if [[ "$(authelia_user_disabled_in_file "${db}" "${username}")" == "1" ]]; then
    echo "User '${username}' is already suspended." >&2
    rm -f "${db}" "${tmp_out}"
    return 1
  fi

  active="$(authelia_count_active_users_in_file "${db}")"
  if (( active <= 1 )); then
    echo "Cannot suspend '${username}' — at least one active user must remain." >&2
    rm -f "${db}" "${tmp_out}"
    return 1
  fi

  authelia_set_user_disabled_in_file "${db}" "${username}" "true" "${tmp_out}"
  authelia_apply_users_db "${tmp_out}"
  rm -f "${db}" "${tmp_out}"
  log "Authelia user '${username}' suspended"
}

authelia_user_delete() {
  local username="$1" db tmp_out active

  authelia_users_require_ready || return 1
  [[ -n "${username}" ]] || { echo "Username is required." >&2; return 1; }

  db="$(authelia_users_work_file)"
  tmp_out="$(authelia_users_work_file)"
  authelia_fetch_users_db "${db}"
  if ! authelia_user_exists_in_file "${db}" "${username}"; then
    echo "User '${username}' not found." >&2
    rm -f "${db}" "${tmp_out}"
    return 1
  fi

  if [[ "$(authelia_user_disabled_in_file "${db}" "${username}")" != "1" ]]; then
    active="$(authelia_count_active_users_in_file "${db}")"
    if (( active <= 1 )); then
      echo "Cannot delete '${username}' — at least one active user must remain." >&2
      rm -f "${db}" "${tmp_out}"
      return 1
    fi
  fi

  authelia_remove_user_from_file "${db}" "${username}" "${tmp_out}"
  authelia_apply_users_db "${tmp_out}"
  rm -f "${db}" "${tmp_out}"
  log "Authelia user '${username}' deleted"
}

authelia_user_list() {
  local db user email status

  authelia_users_require_ready || return 1
  db="$(authelia_users_work_file)"
  authelia_fetch_users_db "${db}"

  echo "Authelia users (from users_database.yml):"
  while IFS= read -r user; do
    [[ -n "${user}" ]] || continue
    email="$(authelia_user_email_from_file "${db}" "${user}")"
    if [[ "$(authelia_user_disabled_in_file "${db}" "${user}")" == "1" ]]; then
      status="suspended"
    else
      status="active"
    fi
    printf "  %-20s %-30s %s\n" "${user}" "${email}" "${status}"
  done < <(authelia_list_usernames_in_file "${db}")
  rm -f "${db}"
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
    elif [[ "${line}" == *"@INGRESS_CLASS_BLOCK@"* ]]; then
      render_traefik_ingress_class_block
    elif [[ "${line}" == *"@KUBERNETES_INGRESS_BLOCK@"* ]]; then
      render_traefik_kubernetes_ingress_block
    else
      echo "${line}"
    fi
  done < <(apply_template "${share}/traefik-values.yaml.template") > "${out}"
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

  sync_authelia_users_secret
  k rollout restart deployment/authelia -n authelia 2>/dev/null || true
  wait_for_deployment authelia authelia 600

  apply_template "${share}/manifests/authelia/middleware-forwardauth.yaml.template" | k apply -f -
  apply_template_ingress "${share}/manifests/authelia/ingressroute.yaml.template" "${AUTH_FQDN}" | k apply -f -
  upgrade_traefik_dashboard_auth
  log "Authelia ready — login portal: https://${AUTH_FQDN}"
}
