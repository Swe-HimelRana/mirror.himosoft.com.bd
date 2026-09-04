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
    "${template}"
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
