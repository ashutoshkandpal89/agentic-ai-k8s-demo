# 🤖 Agentic AI Without Chaos
### Open Source Reference Implementation for Operating AI Agents on Kubernetes

> *"Building AI agents is easy. Operating them safely and cost-efficiently in production is the hard part."*  
> — Ashutosh Kandpal, Cloud & AI Consultant

---

## 🎯 What This Demo Shows

| Step | What Happens | Tool |
|------|-------------|------|
| 1 | Bootstrap local K8s cluster | k3d |
| 2 | Deploy multi-agent AI platform | kubectl + Helm |
| 3 | Submit agent tasks via API | FastAPI |
| 4 | Watch KEDA auto-scale workers | KEDA |
| 5 | Simulate token explosion (chaos) | Custom chaos pod |
| 6 | Watch Kyverno policy block runaway pods | Kyverno |
| 7 | Observe traces + cost metrics in Grafana | OTel + Prometheus + Grafana |

---

## 🏗️ Architecture

\`\`\`
┌─────────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster (k3d)                      │
│                                                                       │
│  ┌──────────────┐    ┌───────────────────┐    ┌──────────────────┐   │
│  │  API Gateway │───▶│ Agent Orchestrator│───▶│  Task Queue      │   │
│  │  (FastAPI)   │    │  (LangGraph)      │    │  (Redis Lists)   │   │
│  └──────────────┘    └───────────────────┘    └────────┬─────────┘   │
│                                                         │             │
│                    ┌────────────────────────────────────▼──────────┐  │
│                    │            KEDA ScaledObject                   │  │
│                    │    (scales workers on queue depth)             │  │
│                    └────────────────────────────────────┬──────────┘  │
│                                                          │             │
│  ┌───────────────────────────────────────────────────────▼──────────┐ │
│  │                     AI Worker Pods (1–20)                         │ │
│  │         FastAPI + LangGraph + Ollama (llama3.2:1b)                │ │
│  └──────────────────────────────────────────────────────────────────┘ │
│                                                                       │
│  ┌──────────────┐    ┌───────────────────┐    ┌──────────────────┐   │
│  │   Kyverno    │    │   Prometheus      │    │    Grafana       │   │
│  │  (Policy)    │    │   (Metrics)       │    │  (Dashboards)    │   │
│  └──────────────┘    └───────────────────┘    └──────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
\`\`\`

---
## 📋 Prerequisites

\`\`\`bash
brew install k3d kubectl helm watch   # macOS
docker version                        # Docker Desktop must be running
\`\`\`

> **💡 Docker Desktop memory:** Settings → Resources → Memory: **6GB minimum**

> **💡 No GPU / No internet needed** — runs in \`MOCK_LLM=true\` mode by default

---

## 🚀 Quick Start

\`\`\`bash
git clone https://github.com/ashutoshkandpal89/agentic-ai-k8s-demo
cd agentic-ai-k8s-demo
chmod +x scripts/*.sh
\`\`\`

### Step 1 — Create namespace first (important — do this before anything else)
\`\`\`bash
kubectl create namespace ai-agents
kubectl label namespace ai-agents type=ai-agent
\`\`\`

### Step 2 — Install KEDA
\`\`\`bash
helm repo add kedacore https://kedacore.github.io/charts --force-update
helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --version 2.14.0 \
  --set operator.replicaCount=1 \
  --set metricsServer.replicaCount=1 \
  --set webhooks.replicaCount=1 \
  --timeout 300s \
  --wait
\`\`\`

### Step 3 — Install Kyverno
\`\`\`bash
helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set admissionController.replicas=1 \
  --wait \
  --timeout 180s
\`\`\`

### Step 4 — Install Prometheus + Grafana
\`\`\`bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword="admin" \
  --set grafana.service.type="NodePort" \
  --set grafana.service.nodePort=30300 \
  --set prometheus.service.type="NodePort" \
  --set prometheus.service.nodePort=30090 \
  --set alertmanager.enabled=false \
  --wait \
  --timeout 300s
\`\`\`

### Step 5 — Deploy the AI Platform
\`\`\`bash
./scripts/02-deploy-platform.sh
\`\`\`

### Step 6 — Verify everything is running
\`\`\`bash
kubectl get pods -n ai-agents
kubectl get pods -n keda
kubectl get pods -n kyverno
kubectl get pods -n monitoring
\`\`\`

All pods should show \`Running\`.

---

## 🎬 Key Demo Commands

### Submit an agent task
\`\`\`bash
curl -X POST http://localhost:30080/agent/run \
  -H "Content-Type: application/json" \
  -d '{"task": "Compare AWS EKS vs GKE vs AKS for AI workloads", "token_budget": 2000}' \
  | python3 -m json.tool
\`\`\`

### Check task result
\`\`\`bash
curl http://localhost:30080/agent/result/PASTE_TASK_ID_HERE | python3 -m json.tool
\`\`\`

### Watch KEDA auto-scale workers
\`\`\`bash
watch kubectl get pods -n ai-agents
watch kubectl get scaledobjects -n ai-agents
\`\`\`

### Trigger chaos: token flood
\`\`\`bash
./scripts/04-chaos-test.sh
\`\`\`

### Open Grafana dashboard
\`\`\`bash
kubectl port-forward -n monitoring svc/kube-prometheus-grafana 3000:80 &
open http://localhost:3000
\`\`\`
Username: \`admin\` / Password: \`admin\` → Dashboard: **AI Agent Platform**

### API Docs
\`\`\`bash
open http://localhost:30080/docs
\`\`\`

### Run full interactive demo
\`\`\`bash
./scripts/03-demo-flow.sh
\`\`\`

---

## 📁 Repository Structure

\`\`\`
agentic-ai-k8s-demo/
├── src/
│   ├── agent/                        # Agent Orchestrator (FastAPI + LangGraph)
│   │   ├── main.py                   # REST API + Prometheus metrics + OTel
│   │   ├── orchestrator.py           # 3-node workflow: plan → tools → synthesize
│   │   ├── token_budget.py           # Redis rolling-window token budget enforcer
│   │   └── Dockerfile
│   └── worker/                       # AI Worker (KEDA scales this)
│       ├── main.py                   # BRPOP queue poller + graceful SIGTERM
│       └── Dockerfile
├── manifests/
│   ├── base/                         # Namespace, ResourceQuota, Redis, Deployments, RBAC
│   ├── keda/                         # ScaledObject — scale on queue depth not CPU
│   ├── policy/                       # Kyverno ClusterPolicies — no root, no privilege escalation
│   ├── monitoring/                   # Prometheus alert rules + OTel Collector
│   └── chaos/                        # Token flood + infinite retry chaos Jobs
├── grafana/
│   └── dashboards/                   # Pre-built AI Agent Platform dashboard (10 panels)
├── scripts/
│   ├── 01-setup-cluster.sh           # k3d + KEDA + Kyverno + Prometheus
│   ├── 02-deploy-platform.sh         # Build images, import to k3d, deploy
│   ├── 03-demo-flow.sh               # Interactive live demo with pause points
│   ├── 04-chaos-test.sh              # Token flood + infinite retry chaos
│   └── 99-cleanup.sh                 # Delete cluster entirely
└── docs/
    ├── DEMO_STEPS.md                 # Exact commands + expected output + fallbacks
    └── TROUBLESHOOTING.md            # Every failure mode + fix
\`\`\`

---

## 🔑 Key Concepts Demonstrated

| Concept | Implementation |
|---------|---------------|
| **Token budget enforcement** | Redis rolling-window counter → HTTP 429 on breach |
| **Event-driven autoscaling** | KEDA ScaledObject triggers on Redis list length |
| **Policy as code** | Kyverno ClusterPolicy — blocks privileged pods at admission |
| **Cost observability** | \`agent_llm_cost_usd_total\` Prometheus counter + Grafana panel |
| **Graceful shutdown** | SIGTERM handler — in-flight tasks complete before pod dies |
| **Distributed tracing** | OpenTelemetry spans: submit → plan → tool → synthesize |
| **Retry circuit breaking** | Token budget acts as circuit breaker for infinite retry loops |

---

## ⚠️ Known Issues & Quick Fixes

### 1. KEDA install fails — "namespace ai-agents not found"
Always create the namespace **before** installing KEDA:
\`\`\`bash
kubectl create namespace ai-agents
kubectl label namespace ai-agents type=ai-agent
\`\`\`

### 2. Prometheus error — "port not in valid range"
NodePorts must be 30000-32767. The scripts use \`30300\` for Grafana, not \`3000\`:
- Grafana → http://localhost:30300
- Prometheus → http://localhost:30090

### 3. Redis pods not starting after deploy script
Apply Redis manually:
\`\`\`bash
kubectl apply -f manifests/base/redis.yaml
kubectl rollout status deployment/redis -n ai-agents --timeout=120s
\`\`\`

### 4. \`watch\` command not found on Mac
\`\`\`bash
brew install watch
\`\`\`

### 5. KEDA timeout on slow internet
\`\`\`bash
helm uninstall keda -n keda 2>/dev/null || true
kubectl delete namespace keda 2>/dev/null || true
sleep 10
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace \
  --version 2.14.0 \
  --set operator.replicaCount=1 \
  --timeout 300s --wait
\`\`\`

### 6. Pods stuck in Pending
Docker Desktop → Settings → Resources → Memory: **6GB minimum** → Apply & Restart

### 7. zsh: command not found: #
Zsh doesn't accept inline \`#\` comments typed directly in terminal. Copy commands without the comment lines, or use \`bash\` instead of \`zsh\`.

---

## 🛑 Cleanup

\`\`\`bash
./scripts/99-cleanup.sh
\`\`\`

---

## 📊 Talk Resources

- 🎤 **Talk:** "Agentic AI Without Chaos" — CNCF Meetup
- 👤 **Speaker:** Ashutosh Kandpal — Cloud & AI Consultant | Corporate Trainer
- 🌐 **Website:** [ashutoshkandpal.com](https://ashutoshkandpal.com/)
- 💼 **LinkedIn:** [linkedin.com/in/ashutoshkandpal](https://linkedin.com/in/ashutoshkandpal)
---

> **Windows users:** Use WSL2 (Ubuntu) for the best experience.  
> All commands work identically inside WSL2.  
> See [WSL2 install guide](https://learn.microsoft.com/en-us/windows/wsl/install)

## ⭐ If this helped you

Give it a star and share it with your platform team.  
Found a bug or want to contribute? Open an issue — all questions welcome.
