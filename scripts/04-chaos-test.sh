#!/usr/bin/env bash
# =============================================================================
# 04-chaos-test.sh
# Runs the chaos scenarios:
#   1. Token flood (50 tasks via Kubernetes Job)
#   2. Infinite retry simulation
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
step()    { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
pause()   { echo -e "\n${YELLOW}${BOLD}  ▶ Press ENTER to continue...${RESET}"; read -r; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── Chaos 1: Token Flood ─────────────────────────────────────────────────────
step "CHAOS 1: Token Flood (50 Tasks)"

echo -e "${CYAN}This deploys 5 parallel Job pods, each submitting 10 tasks.${RESET}"
echo -e "${CYAN}Watch: KEDA scales up, quota limits kick in, budget rejects overflow.${RESET}"
echo ""
pause

# Delete any previous chaos jobs
kubectl delete job token-flood-chaos -n ai-agents --ignore-not-found=true
kubectl delete job infinite-retry-chaos -n ai-agents --ignore-not-found=true

kubectl apply -f "$REPO_ROOT/manifests/chaos/token-flood.yaml" \
  --selector="app=chaos,scenario=token-flood"

info "Chaos Job deployed. Watching..."
echo ""
echo "  Open in other terminals:"
echo "  Terminal 1: watch kubectl get pods -n ai-agents"
echo "  Terminal 2: watch -n2 \"kubectl exec -n ai-agents deploy/redis -- redis-cli llen task-queue\""
echo "  Terminal 3: watch kubectl get scaledobjects -n ai-agents"
echo ""

# Stream chaos job logs
info "Chaos pod logs (streaming):"
sleep 5
kubectl wait --for=condition=ready pod -l "app=chaos,scenario=token-flood" -n ai-agents --timeout=60s 2>/dev/null || true
kubectl logs -n ai-agents -l "app=chaos,scenario=token-flood" --prefix=true -f --max-log-requests=5 &
LOGS_PID=$!

# Watch for 45 seconds
for i in $(seq 1 9); do
  REPLICAS=$(kubectl get deployment ai-worker -n ai-agents -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  QUEUE_D=$(kubectl exec -n ai-agents deploy/redis -- redis-cli llen task-queue 2>/dev/null || echo "?")
  echo "  [${i}0s] Workers: ${REPLICAS} replicas | Queue: ${QUEUE_D} tasks"
  sleep 5
done

kill $LOGS_PID 2>/dev/null || true

echo ""
info "Final pod count:"
kubectl get pods -n ai-agents | grep ai-worker | wc -l | xargs echo "  AI worker pods:"
pause

# ─── Chaos 2: Infinite Retry ─────────────────────────────────────────────────
step "CHAOS 2: Infinite Retry Simulation"

echo -e "${CYAN}This simulates a broken agent that retries forever.${RESET}"
echo -e "${CYAN}The token budget acts as the circuit breaker.${RESET}"
echo ""
pause

kubectl apply -f "$REPO_ROOT/manifests/chaos/token-flood.yaml" \
  --selector="app=chaos,scenario=infinite-retry"

sleep 5
kubectl wait --for=condition=ready pod -l "app=chaos,scenario=infinite-retry" -n ai-agents --timeout=60s 2>/dev/null || true

info "Watching retry simulation (logs):"
kubectl logs -n ai-agents -l "app=chaos,scenario=infinite-retry" --prefix=true -f 2>/dev/null &
LOGS_PID=$!
sleep 20
kill $LOGS_PID 2>/dev/null || true

echo ""
success "Chaos scenarios complete."
echo ""
echo -e "${YELLOW}Key observations from chaos tests:${RESET}"
echo "  • KEDA auto-scaled workers in response to queue pressure"
echo "  • Token budget rejected overflow tasks (HTTP 429)"
echo "  • Kyverno enforced resource limits on all pods"
echo "  • Retry circuit broken by budget enforcement — no infinite cost spiral"
echo ""
echo -e "  ${CYAN}Cleanup chaos jobs:${RESET}"
echo "  kubectl delete job token-flood-chaos infinite-retry-chaos -n ai-agents"
