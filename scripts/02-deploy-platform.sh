#!/usr/bin/env bash
# =============================================================================
# 02-deploy-platform.sh
# Build images, import to k3d, deploy the full AI agent platform
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

CLUSTER_NAME="ai-demo"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Verify cluster is running
if ! kubectl cluster-info &>/dev/null; then
  error "No cluster found. Run ./scripts/01-setup-cluster.sh first."
fi

# ── Build Docker images ────────────────────────────────────────────────────────
step "Building Docker Images"

info "Building agent-orchestrator image..."
docker build -t agent-orchestrator:latest "$REPO_ROOT/src/agent/" -q
success "agent-orchestrator:latest built"

info "Building ai-worker image..."
# Copy shared modules into worker build context
cp "$REPO_ROOT/src/agent/orchestrator.py"   "$REPO_ROOT/src/worker/"
cp "$REPO_ROOT/src/agent/token_budget.py"   "$REPO_ROOT/src/worker/"
docker build -t ai-worker:latest "$REPO_ROOT/src/worker/" -q
success "ai-worker:latest built"

# ── Import images to k3d (no registry needed) ────────────────────────────────
step "Importing Images to k3d Cluster"

info "Importing agent-orchestrator..."
k3d image import agent-orchestrator:latest -c "$CLUSTER_NAME"
success "agent-orchestrator imported"

info "Importing ai-worker..."
k3d image import ai-worker:latest -c "$CLUSTER_NAME"
success "ai-worker imported"

# ── Apply namespace + quotas ──────────────────────────────────────────────────
step "Applying Namespace & Resource Quotas"

kubectl apply -f "$REPO_ROOT/manifests/base/namespace.yaml"
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/ai-agents --timeout=30s
success "Namespace ai-agents ready"

# ── Apply Kyverno policies ────────────────────────────────────────────────────
step "Applying Kyverno Governance Policies"

kubectl apply -f "$REPO_ROOT/manifests/policy/restrict-privileged.yaml"
sleep 3   # Give Kyverno webhook time to register
success "Kyverno policies applied"

info "Active policies:"
kubectl get clusterpolicy -o custom-columns="NAME:.metadata.name,ACTION:.spec.validationFailureAction,READY:.status.conditions[0].status"

# ── Deploy core platform ───────────────────────────────────────────────────────
step "Deploying Core Platform (Redis, Orchestrator, Workers)"

kubectl apply -f "$REPO_ROOT/manifests/base/redis.yaml"
kubectl rollout status deployment/redis -n ai-agents --timeout=60s
success "Redis ready"

kubectl apply -f "$REPO_ROOT/manifests/base/agent-orchestrator.yaml"
kubectl rollout status deployment/agent-orchestrator -n ai-agents --timeout=90s
success "Agent Orchestrator ready"

kubectl apply -f "$REPO_ROOT/manifests/base/ai-worker.yaml"
kubectl rollout status deployment/ai-worker -n ai-agents --timeout=90s
success "AI Worker ready (1 replica)"

# ── Deploy KEDA ScaledObject ──────────────────────────────────────────────────
step "Deploying KEDA ScaledObject"

kubectl apply -f "$REPO_ROOT/manifests/keda/scaled-object.yaml"
sleep 5
kubectl get scaledobjects -n ai-agents
success "KEDA ScaledObject active"

# ── Deploy Monitoring ─────────────────────────────────────────────────────────
step "Deploying OTel Collector"

kubectl apply -f "$REPO_ROOT/manifests/monitoring/otel-collector.yaml"
kubectl rollout status deployment/otel-collector -n monitoring --timeout=90s
success "OTel Collector ready"

# ── Import Grafana dashboard ──────────────────────────────────────────────────
step "Importing Grafana Dashboard"

# Wait for Grafana to be ready
kubectl rollout status deployment/kube-prometheus-grafana -n monitoring --timeout=60s

# Port-forward in background to import dashboard
kubectl port-forward -n monitoring svc/kube-prometheus-grafana 3000:80 &>/dev/null &
PF_PID=$!
sleep 4

if curl -sf http://localhost:3000/api/health &>/dev/null; then
  curl -sf -X POST \
    -H "Content-Type: application/json" \
    -u admin:admin \
    -d @"$REPO_ROOT/grafana/dashboards/ai-agents-dashboard.json" \
    "http://localhost:3000/api/dashboards/import" &>/dev/null && \
    success "Grafana dashboard imported" || \
    warn "Dashboard import failed — import manually from grafana/dashboards/"
else
  warn "Grafana not reachable via port-forward — import dashboard manually"
fi

kill $PF_PID 2>/dev/null || true

# ── Health check ──────────────────────────────────────────────────────────────
step "Platform Health Check"

echo ""
info "Pods in ai-agents namespace:"
kubectl get pods -n ai-agents -o wide

echo ""
info "Testing Agent API..."
sleep 3

# Test via NodePort
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:30080/healthz 2>/dev/null || echo "000")
if [[ "$HTTP_STATUS" == "200" ]]; then
  success "Agent API healthy (HTTP 200)"
else
  warn "Agent API not yet reachable on :30080 (status: $HTTP_STATUS). Try: kubectl port-forward -n ai-agents svc/agent-orchestrator 8080:8080"
fi

# ── Print access URLs ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║          PLATFORM DEPLOYED SUCCESSFULLY ✓                 ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${CYAN}Agent API:${RESET}       http://localhost:30080"
echo -e "  ${CYAN}API Docs:${RESET}        http://localhost:30080/docs"
echo -e "  ${CYAN}Metrics:${RESET}         http://localhost:30080/metrics"
echo -e "  ${CYAN}Prometheus:${RESET}      http://localhost:30090"
echo -e "  ${CYAN}Grafana:${RESET}         http://localhost:3000  (admin/admin)"
echo ""
echo -e "  ${YELLOW}Next:${RESET} ./scripts/03-demo-flow.sh"
echo ""
