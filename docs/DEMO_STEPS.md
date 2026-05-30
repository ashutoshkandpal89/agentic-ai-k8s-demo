# 🎬 Demo Walkthrough — Speaker Notes

> Full step-by-step guide for the live demo section of the talk.
> Each step includes: what to say, what to show, expected output, and fallback.

---

## ⏱️ Timing Budget: 10 minutes

| Step | Time | What |
|------|------|------|
| Pre-flight | 1 min | Show cluster is running |
| Task submission | 1.5 min | Submit first task, show response |
| KEDA scaling | 2 min | Flood queue, watch workers scale |
| Token budget | 1.5 min | Hit budget limit, show 429 |
| Kyverno policy | 1.5 min | Try privileged pod, watch it get blocked |
| Grafana | 1.5 min | Show dashboard, metrics |
| Wrap-up | 0.5 min | Key takeaways |

---

## STEP 0 — Pre-flight (1 min)

**Say:**
> "Before we start — the cluster is already running. Let me show you what's deployed."

**Show:**
```bash
kubectl get nodes
kubectl get pods -n ai-agents
kubectl get scaledobjects -n ai-agents
```

**Expected output:**
```
NAME                    STATUS   ROLES    AGE
k3d-ai-demo-server-0    Ready    master   5m
k3d-ai-demo-agent-0     Ready    <none>   5m
k3d-ai-demo-agent-1     Ready    <none>   5m

NAME                        READY   STATUS    RESTARTS
agent-orchestrator-xxx      1/1     Running   0
ai-worker-xxx               1/1     Running   0
redis-xxx                   1/1     Running   0
```

---

## STEP 1 — Submit First Task (1.5 min)

**Say:**
> "This is our agent API. I'm going to submit a research task with a token budget of 2000 tokens.
> Notice the response — it doesn't just say 'ok'. It tells you queue position, estimated tokens, and task ID."

**Show:**
```bash
curl -X POST http://localhost:30080/agent/run \
  -H "Content-Type: application/json" \
  -d '{
    "task": "Compare AWS EKS vs GKE vs AKS for AI workloads",
    "token_budget": 2000,
    "priority": "normal",
    "task_type": "research"
  }' | python3 -m json.tool
```

**Expected output:**
```json
{
  "task_id": "a1b2c3d4-...",
  "status": "queued",
  "queue_position": 1,
  "estimated_tokens": 2000,
  "message": "Task queued. Position: 1. Workers will auto-scale if needed."
}
```

**Then show result:**
```bash
# Replace with actual task_id from above
curl http://localhost:30080/agent/result/a1b2c3d4-... | python3 -m json.tool
```

**Expected output (completed):**
```json
{
  "task_id": "a1b2c3d4-...",
  "status": "completed",
  "result": "[MOCK] Completed analysis of: 'Compare AWS EKS vs GKE...'",
  "tokens_used": 850,
  "cost_usd": 0.0017,
  "latency_seconds": 0.42,
  "tool_calls": [{"tool": "web_search", ...}, {"tool": "write_report", ...}]
}
```

---

## STEP 2 — Queue Flood + KEDA Scaling (2 min)

**Say:**
> "Now let's simulate real load. I'm going to submit 10 tasks at once.
> Watch what KEDA does — it reads the Redis queue depth and decides how many workers to spin up."

**Open TWO terminal tabs before running:**
```bash
# Tab 1: Watch pods
watch kubectl get pods -n ai-agents

# Tab 2: Watch queue
watch -n2 "kubectl exec -n ai-agents deploy/redis -- redis-cli llen task-queue"
```

**Then run (Tab 3):**
```bash
./scripts/03-demo-flow.sh
# Follow the prompts through Step 3
```

**What to narrate:**
> "Queue depth hits 10 → KEDA adds workers. 
> This is not CPU-based scaling. This is business-signal-based scaling.
> The cost difference over a month is significant."

**Expected KEDA behavior:**
```
Queue depth 10  → 2 workers
Queue depth 25  → 5 workers
Queue depth 50+ → 10-15 workers
Queue drains    → back to 1 worker (after 60s cooldown)
```

---

## STEP 3 — Token Budget Enforcement (1.5 min)

**Say:**
> "This is the slide that should scare you. Your agent has no stopping condition.
> It will call GPT-4 until your credit card stops it. We need something earlier in the chain."

**Show:**
```bash
# First — check budget status
curl http://localhost:30080/agent/queue/stats | python3 -m json.tool
```

```bash
# Now try to exceed it — submit many high-budget tasks
for i in {1..15}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:30080/agent/run \
    -H "Content-Type: application/json" \
    -d '{"task":"Exhaustive corpus analysis","token_budget":4000,"priority":"high","task_type":"research"}')
  echo "Attempt $i: HTTP $HTTP_CODE"
done
```

**Expected output:**
```
Attempt 1:  HTTP 200   ← accepted
Attempt 2:  HTTP 200   ← accepted
...
Attempt 9:  HTTP 429   ← REJECTED (budget exceeded)
Attempt 10: HTTP 429   ← REJECTED
...
```

**Point to the 429:**
> "That HTTP 429 is not an error. That's money saved.
> The token budget manager in Redis tracked every reservation and stopped at 90% utilization.
> Finance won't call you at 11am this time."

---

## STEP 4 — Kyverno Policy Block (1.5 min)

**Say:**
> "Let's try something fun. I'm going to deploy a privileged pod into the ai-agents namespace.
> In a normal cluster, this works fine. With Kyverno... let's see."

**Show:**
```bash
kubectl apply -f - <<EOF
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
  - name: root-runner
    image: alpine:3.19
    command: ["sleep", "infinity"]
    securityContext:
      privileged: true
      allowPrivilegeEscalation: true
EOF
```

**Expected output (Kyverno blocks it):**
```
Error from server: error when creating "STDIN": admission webhook 
"validate.kyverno.svc-fail" denied the request: 

resource Pod/ai-agents/rogue-agent was blocked due to the following policies

restrict-ai-agent-privileges:
  deny-privileged-containers: AI agent pods must not run as privileged.
```

**Say:**
> "The pod never scheduled. The admission webhook killed it before it reached the scheduler.
> This is policy-as-code. You write it once, it enforces forever."

---

## STEP 5 — Grafana Observability (1.5 min)

**Open in browser:** `http://localhost:3000` (admin/admin)

**Navigate to:** Dashboards → AI Agent Platform

**Walk through each panel:**
1. **Token Usage** — "This is the number that keeps engineering honest with finance"
2. **Worker Replicas** — "Watch this number. It went from 1 to N and back. That's KEDA."
3. **Task Success vs Failure** — "The ratio. If failures spike, budget or policy is rejecting."
4. **Latency P95/P99** — "This is your SLO baseline. Set alerts here, not on CPU."
5. **Kyverno Violations** — "Audit trail of every blocked pod. This is your compliance report."

**Say:**
> "This dashboard exists because we instrumented from day one.
> OpenTelemetry traces → OTel Collector → Prometheus → Grafana.
> You cannot govern what you cannot see."

---

## Fallback Plan (Internet Fails / Ollama Not Available)

1. **MOCK_LLM=true is the default** — entire demo runs without any internet or LLM
2. **Pre-recorded terminal session** — record with `asciinema rec demo.cast`, replay with `asciinema play demo.cast`
3. **If k3d fails** — show the YAML files and talk through them ("conference-safe architecture walkthrough")
4. **If Grafana doesn't load** — show raw Prometheus metrics at `http://localhost:30090`

```bash
# Emergency: just query Prometheus directly
curl -s 'http://localhost:30090/api/v1/query?query=agent_task_queue_depth' | python3 -m json.tool
curl -s 'http://localhost:30090/api/v1/query?query=sum(agent_token_usage_total)' | python3 -m json.tool
```

---

## Pre-Demo Checklist (Run the night before)

```bash
# 1. Full dry run
./scripts/01-setup-cluster.sh
./scripts/02-deploy-platform.sh
./scripts/03-demo-flow.sh

# 2. Verify all access URLs work
curl http://localhost:30080/healthz
curl http://localhost:30090/-/ready
curl http://localhost:3000/api/health

# 3. Take screenshots as fallback
# 4. Record asciinema session as backup
# 5. Confirm laptop doesn't sleep during demo
#    (System Preferences → Battery → Prevent sleep when display is on)
```

---

## Recovery Commands (Something Goes Wrong)

```bash
# Pod stuck in Pending
kubectl describe pod <pod-name> -n ai-agents

# Kyverno blocking legitimate pods
kubectl get clusterpolicy
kubectl patch clusterpolicy restrict-ai-agent-privileges --type=merge \
  -p '{"spec":{"validationFailureAction":"Audit"}}'   # Switch to Audit mode

# KEDA not scaling
kubectl get scaledobjects -n ai-agents
kubectl describe scaledobject ai-worker-scaler -n ai-agents
kubectl logs -n keda deploy/keda-operator | tail -20

# Redis not responding
kubectl exec -n ai-agents deploy/redis -- redis-cli ping
kubectl restart rollout deployment/redis -n ai-agents

# Nuclear option: restart everything
kubectl rollout restart deployment -n ai-agents
```
