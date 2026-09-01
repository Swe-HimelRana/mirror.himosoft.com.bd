#!/usr/bin/env bash
# K3s install — called by himosoft-k3s-server after configuration.
set -euo pipefail

DOMAIN="${DOMAIN:-srv1.himosoft.com.bd}"
PUBLIC_IP="${PUBLIC_IP:-}"
K3S_VERSION="${K3S_VERSION:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Must run as root."
  exit 1
fi

if [[ -z "${PUBLIC_IP}" ]]; then
  echo "PUBLIC_IP not set. Run: sudo himosoft-k3s-server install"
  exit 1
fi

if command -v k3s >/dev/null 2>&1 && systemctl is-active k3s &>/dev/null; then
  echo "K3s is already running. Re-run only after uninstall if you need a fresh install."
  exit 1
fi

mkdir -p /etc/rancher/k3s

echo "==> Writing /etc/rancher/k3s/config.yaml"
cat > /etc/rancher/k3s/config.yaml <<EOF
write-kubeconfig-mode: "644"
tls-san:
  - "${DOMAIN}"
  - "${PUBLIC_IP}"
node-external-ip: "${PUBLIC_IP}"
disable:
  - traefik
EOF

INSTALL_ARGS="server --disable traefik --write-kubeconfig-mode 644"
if [[ -n "${K3S_VERSION}" ]]; then
  export INSTALL_K3S_VERSION="${K3S_VERSION}"
fi

echo "==> Installing K3s (${K3S_VERSION:-latest})"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="${INSTALL_ARGS}" sh -

echo ""
echo "==> K3s installed successfully"
echo ""
echo "  Public IP : ${PUBLIC_IP}"
echo "  Domain    : ${DOMAIN}"
echo "  Kubeconfig: /etc/rancher/k3s/k3s.yaml"
echo ""
echo "Verify:"
echo "  k3s kubectl get nodes"
echo ""
echo "Next steps:"
echo "  1. k3s kubectl get nodes"
echo "  2. Deploy ingress, TLS, and workloads on your cluster"
echo ""
echo "Firewall (ufw example):"
echo "  ufw allow 80/tcp"
echo "  ufw allow 443/tcp"
echo "  ufw allow from YOUR_ADMIN_IP to any port 6443 proto tcp"
