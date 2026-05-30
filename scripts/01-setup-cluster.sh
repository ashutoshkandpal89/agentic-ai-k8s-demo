#!/usr/bin/env bash
# =============================================================================
# 01-setup-cluster.sh
# Bootstrap k3d cluster + install KEDA, Kyverno, Prometheus stack
# Runtime: ~5-8 minutes (first run, pulls images)
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

# ── Config ────────────────────────────────────────────────────────────────────
CLUSTER_NAME="ai-demo"
K3D_VERSION_MIN="5.0.0"
KEDA_VERSION="2.14.0"
KYVERNO_VERSION="3.2.0"

# ── Preflight checks ─────────────────────────────────────────────────────────
step "Preflight Checks"

for cmd in docker k3d kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    error "$cmd not found. Install it first. See README.md."
  fi
  success "$cmd found: $(${cmd} version --short 2>/dev/null || ${cmd} version 2>/dev/null | head -1)"
done

# Check Docker is running
if ! docker info &>/dev/null; then
  error "Docker daemon is not running. Start Docker Desktop."
fi
success "Docker daemon running"

# ── Create k3d cluster ────────────────────────────────────────────────────────
step "Creating k3d Cluster: $CLUSTER_NAME"

# Delete existing cluster if it exists
if k3d cluster list | grep -q "$CLUSTER_NAME"; then
  warn "Cluster '$CLUSTER_NAME' already exists. Deleting..."
  k3d cluster delete "$CLUSTER_NAME"
fi

k3d cluster create "$CLUSTER_NAME" \
  --agents 2 \
  --port "30080:30080@loadbalancer" \
  --port "30090:30090@loadbalancer" \
  --port "3000:3000@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0" \
  --wait \
  --timeout 120s

success "k3d cluster '$CLUSTER_NAME' created with 2 agent nodes"

# Verify cluster
kubectl cluster-info
kubectl get nodes

# ── Install KEDA ──────────────────────────────────────────────────────────────
step "Installing KEDA v${KEDA_VERSION}"

helm repo add kedacore https://kedacore.github.io/charts --force-update
helm repo update kedacore

helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --version "$KEDA_VERSION" \
  --set watchNamespace="ai-agents" \
  --set prometheus.metricServer.enabled=true \
  --set prometheus.operator.enabled=true \
  --wait \
  --timeout 120s

kubectl rollout status deployment/keda-operator -n keda --timeout=90s
success "KEDA installed"

# ── Install Kyverno ───────────────────────────────────────────────────────────
step "Installing Kyverno v${KYVERNO_VERSION} (Policy Engine)"

helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
helm repo update kyverno

helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --version "$KYVERNO_VERSION" \
  --set admissionController.replicas=1 \
  --set backgroundController.enabled=true \
  --set cleanupController.enabled=false \
  --set reportsController.enabled=false \
  --wait \
  --timeout 120s

kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=90s
success "Kyverno installed"

# ── Install Prometheus + Grafana ──────────────────────────────────────────────
step "Installing Prometheus + Grafana (kube-prometheus-stack)"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update prometheus-community

helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.scrapeInterval="15s" \
  --set grafana.adminPassword="admin" \
  --set grafana.service.type="NodePort" \
  --set grafana.service.nodePort=3000 \
  --set grafana.sidecar.dashboards.enabled=true \
  --set prometheus.service.type="NodePort" \
  --set prometheus.service.nodePort=30090 \
  --set alertmanager.enabled=false \
  --set kubeStateMetrics.enabled=true \
  --wait \
  --timeout 180s

kubectl rollout status deployment/kube-prometheus-grafana -n monitoring --timeout=120s
success "Prometheus + Grafana installed"

# ── Print summary ─────────────────────────────────────────────────────────────
step "Cluster Ready!"

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║         CLUSTER SETUP COMPLETE ✓                     ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${CYAN}Grafana:${RESET}    http://localhost:3000  (admin / admin)"
echo -e "  ${CYAN}Prometheus:${RESET} http://localhost:30090"
echo -e "  ${CYAN}Agent API:${RESET}  http://localhost:30080 (after step 2)"
echo ""
echo -e "  ${YELLOW}Next:${RESET} ./scripts/02-deploy-platform.sh"
echo ""
