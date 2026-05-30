#!/usr/bin/env bash
# =============================================================================
# 03-demo-flow.sh
# The actual live demo sequence — run this during the talk.
# Each section is paused so you can explain before proceeding.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
cmd()     { echo -e "${BLUE}[CMD]${RESET}   $*"; }
pause()   {
  echo ""
  echo -e "${YELLOW}${BOLD}  ▶ Press ENTER to continue...${RESET}"
  read -r
}
header()  {
  echo ""
  echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────────────────────────┐${RESET}"
  echo -e "${BOLD}${CYAN}│  DEMO STEP: $*${RESET}"
  echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────────────────┘${RESET}"
  echo ""
}

BASE_URL="${BASE_URL:-http://localhost:30080}"

# ─────────────────────────────────────────────────────────────────────────────
header "0 / Pre-flight — Verify cluster is healthy"

info "Cluster nodes:"
kubectl get nodes
echo ""
info "Pods in ai-agents:"
kubectl get pods -n ai-agents
echo ""
info "Agent API health:"
curl -sf "${BASE_URL}/healthz" | python3 -m json.tool
pause

# ─────────────────────────────────────────────────────────────────────────────
header "1 / Submit Your First Agent Task"

echo -e "${CYAN}SPEAKER NOTE: This is a simple research task. Watch the response — it shows queue position.${RESET}"
echo ""

cmd "curl -X POST ${BASE_URL}/agent/run -d '{task, token_budget, priority}'"
echo ""

TASK1=$(curl -sf -X POST "${BASE_URL}/agent/run" \
  -H "Content-Type: application/json" \
  -d '{
    "task": "Compare AWS EKS vs GKE vs AKS for running AI agent workloads. Focus on cost, autoscaling, and GPU support.",
    "token_budget": 2000,
    "priority": "normal",
    "task_type": "research"
  }')

echo "$TASK1" | python3 -m json.tool
TASK1_ID=$(echo "$TASK1" | python3 -c "import sys,json; print(json.load(sys.stdin)['task_id'])")
success "Task submitted: $TASK1_ID"
pause

# ─────────────────────────────────────────────────────────────────────────────
header "2 / Check Task Result"

echo -e "${CYAN}SPEAKER NOTE: Workers poll the queue. Let's check if our task completed.${RESET}"
echo ""

cmd "curl ${BASE_URL}/agent/result/${TASK1_ID}"
echo ""

for i in 1 2 3 4 5; do
  RESULT=$(curl -sf "${BASE_URL}/agent/result/${TASK1_ID}")
  STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))")
  if [[ "$STATUS" == "completed" ]]; then
    echo "$RESULT" | python3 -m json.tool
    success "Task completed!"
    break
  fi
  info "Status: $STATUS — waiting 3s..."
  sleep 3
done
pause

# ─────────────────────────────────────────────────────────────────────────────
header "3 / Flood the Queue — Watch KEDA Scale"

echo -e "${CYAN}SPEAKER NOTE: Submit 10 tasks rapidly. Watch KEDA react to queue depth.${RESET}"
echo ""
echo -e "${YELLOW}Open another terminal and run:${RESET}"
echo -e "  watch kubectl get pods -n ai-agents"
echo -e "  watch kubectl get scaledobjects -n ai-agents"
echo ""
pause

info "Submitting 10 tasks in parallel..."
TASK_IDS=()
for i in $(seq 1 10); do
  TASKS=(
    "Research Kubernetes KEDA scaling patterns for AI workloads"
    "Explain OpenTelemetry tracing for distributed systems"
    "Compare Redis vs Kafka for event-driven AI pipelines"
    "Design a token budget management system for LLM APIs"
    "Explain OPA Gatekeeper policy enforcement in Kubernetes"
    "Research GPU scheduling strategies in Kubernetes"
    "Summarize CNCF observability tools landscape 2024"
    "Design a multi-agent orchestration system using LangGraph"
    "Explain circuit breaker patterns for LLM API calls"
    "Research cost optimization strategies for AI inference"
  )
  TASK="${TASKS[$((i-1))]}"
  RESP=$(curl -sf -X POST "${BASE_URL}/agent/run" \
    -H "Content-Type: application/json" \
    -d "{\"task\": \"$TASK\", \"token_budget\": 1500, \"priority\": \"normal\", \"task_type\": \"research\"}" 2>/dev/null || echo '{"task_id":"failed","queue_position":0}')
  TID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task_id','?'))" 2>/dev/null)
  POS=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('queue_position','?'))" 2>/dev/null)
  echo "  Task $i: $TID (queue pos: $POS)"
  TASK_IDS+=("$TID")
done

echo ""
info "Queue stats:"
curl -sf "${BASE_URL}/agent/queue/stats" | python3 -m json.tool

echo ""
info "Watching KEDA scale up (30 seconds)..."
for i in $(seq 1 6); do
  REPLICAS=$(kubectl get deployment ai-worker -n ai-agents -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  QUEUE_D=$(kubectl exec -n ai-agents deploy/redis -- redis-cli llen task-queue 2>/dev/null || echo "?")
  echo "  [${i}0s] Workers: ${REPLICAS} | Queue depth: ${QUEUE_D}"
  sleep 5
done
pause

# ─────────────────────────────────────────────────────────────────────────────
header "4 / Token Budget Protection — Watch the Rejection"

echo -e "${CYAN}SPEAKER NOTE: The token budget is set at 50,000/hour. Let's try to exceed it.${RESET}"
echo -e "${CYAN}Real scenario: runaway agent trying to process your entire S3 bucket.${RESET}"
echo ""

cmd "# First, check current budget status"
curl -sf "${BASE_URL}/agent/queue/stats" | python3 -m json.tool
echo ""

cmd "# Now try submitting with max token budget repeatedly..."
REJECTED=0
ACCEPTED=0
for i in $(seq 1 20); do
  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/agent/run" \
    -H "Content-Type: application/json" \
    -d '{"task":"Exhaustive analysis of all 10,000 documents in our corpus","token_budget":4000,"priority":"high","task_type":"research"}' 2>/dev/null || echo "000")

  if [[ "$HTTP_CODE" == "429" ]]; then
    REJECTED=$((REJECTED + 1))
    echo -e "  Submission $i: ${RED}REJECTED (429 - TOKEN BUDGET)${RESET}"
  elif [[ "$HTTP_CODE" == "200" ]]; then
    ACCEPTED=$((ACCEPTED + 1))
    echo -e "  Submission $i: ${GREEN}ACCEPTED${RESET}"
  else
    echo "  Submission $i: HTTP $HTTP_CODE"
  fi
done

echo ""
success "Token budget enforcement: Accepted=$ACCEPTED, Rejected=$REJECTED"
echo -e "${YELLOW}This is what saved you from the \$12,000 bill.${RESET}"
pause

# ─────────────────────────────────────────────────────────────────────────────
header "5 / Policy Enforcement — Kyverno in Action"

echo -e "${CYAN}SPEAKER NOTE: Let's try to deploy a privileged pod into ai-agents namespace.${RESET}"
echo -e "${CYAN}Kyverno should block it before it schedules.${RESET}"
echo ""

cmd "# Attempting to deploy privileged agent pod..."
cat << 'EOF'
kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: rogue-agent
  namespace: ai-agents
  labels:
    app: rogue-agent
    component: test
spec:
  containers:
  - name: rogue
    image: alpine:3.19
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true              # <── Kyverno will block this
      allowPrivilegeEscalation: true
YAML
EOF

echo ""
info "Applying rogue privileged pod..."
KYVERNO_RESULT=$(kubectl apply -f - 2>&1 <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: rogue-agent
  namespace: ai-agents
  labels:
    app: rogue-agent
    component: test
spec:
  containers:
  - name: rogue
    image: alpine:3.19
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true
      allowPrivilegeEscalation: true
YAML
) || true

if echo "$KYVERNO_RESULT" | grep -qi "denied\|violation\|error\|forbidden"; then
  success "Kyverno BLOCKED the privileged pod! ✓"
  echo -e "${YELLOW}Policy violation message:${RESET}"
  echo "$KYVERNO_RESULT"
else
  warn "Pod was not blocked — Kyverno policy may be in Audit mode."
  echo "$KYVERNO_RESULT"
  kubectl delete pod rogue-agent -n ai-agents --ignore-not-found=true
fi

echo ""
info "Kyverno policy reports:"
kubectl get policyreport -n ai-agents 2>/dev/null || echo "  (No violations recorded yet)"
pause

# ─────────────────────────────────────────────────────────────────────────────
header "6 / Observability — Metrics & Budget Status"

echo -e "${CYAN}SPEAKER NOTE: Let's look at what Prometheus is collecting.${RESET}"
echo ""

info "Raw metrics from Agent Orchestrator:"
curl -sf "${BASE_URL}/metrics" | grep -E "^(agent_|worker_)" | head -30
echo ""

info "Budget status summary:"
curl -sf "${BASE_URL}/agent/queue/stats" | python3 -m json.tool

echo ""
echo -e "${YELLOW}Open Grafana at http://localhost:3000 (admin/admin)${RESET}"
echo -e "${YELLOW}Navigate to: Dashboards → AI Agent Platform${RESET}"
echo ""
echo -e "  Key panels to show the audience:"
echo -e "  • Token usage over time"
echo -e "  • Worker replica count (KEDA effect)"
echo -e "  • Task success/failure rate"
echo -e "  • Queue depth"
echo -e "  • Estimated LLM cost"
pause

# ─────────────────────────────────────────────────────────────────────────────
header "7 / Scale-Down — Idle Workers = \$0"

echo -e "${CYAN}SPEAKER NOTE: Queue is draining. KEDA will scale workers back down.${RESET}"
echo -e "${CYAN}This is the key FinOps win — idle capacity costs nothing.${RESET}"
echo ""

info "Current state:"
kubectl get pods -n ai-agents
echo ""

info "Watching scale-down (60 seconds)..."
for i in $(seq 1 12); do
  REPLICAS=$(kubectl get deployment ai-worker -n ai-agents -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  QUEUE_D=$(kubectl exec -n ai-agents deploy/redis -- redis-cli llen task-queue 2>/dev/null || echo "?")
  echo "  [${i}0s] Workers: ${REPLICAS} | Queue depth: ${QUEUE_D}"
  sleep 5
done

echo ""
FINAL_REPLICAS=$(kubectl get deployment ai-worker -n ai-agents -o jsonpath='{.spec.replicas}' 2>/dev/null)
success "Workers scaled back to ${FINAL_REPLICAS} (minimum). Idle worker cost: \$0."
pause

# ─────────────────────────────────────────────────────────────────────────────
header "DEMO COMPLETE"

echo ""
echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  What we just demonstrated:                            ║${RESET}"
echo -e "${GREEN}${BOLD}║                                                         ║${RESET}"
echo -e "${GREEN}${BOLD}║  ✓ Agent task submission + tracking                    ║${RESET}"
echo -e "${GREEN}${BOLD}║  ✓ KEDA auto-scaling on queue depth                    ║${RESET}"
echo -e "${GREEN}${BOLD}║  ✓ Token budget enforcement (429 rejection)             ║${RESET}"
echo -e "${GREEN}${BOLD}║  ✓ Kyverno blocking privileged pods                    ║${RESET}"
echo -e "${GREEN}${BOLD}║  ✓ Prometheus metrics + Grafana observability           ║${RESET}"
echo -e "${GREEN}${BOLD}║  ✓ KEDA scale-to-minimum on idle                       ║${RESET}"
echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${YELLOW}Chaos demo:${RESET}  ./scripts/04-chaos-test.sh"
echo -e "  ${YELLOW}Cleanup:${RESET}     ./scripts/99-cleanup.sh"
echo ""
