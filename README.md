# 🤖 Agentic AI Without Chaos
### Demo Repository — CNCF Meetup Talk

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

```
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
│  │              FastAPI + LangGraph + Ollama (llama3.2)              │ │
│  └──────────────────────────────────────────────────────────────────┘ │
│                                                                       │
│  ┌──────────────┐    ┌───────────────────┐    ┌──────────────────┐   │
│  │   Kyverno    │    │   Prometheus      │    │    Grafana       │   │
│  │  (Policy)    │    │   (Metrics)       │    │  (Dashboards)    │   │
│  └──────────────┘    └───────────────────┘    └──────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 📋 Prerequisites

```bash
brew install k3d kubectl helm   # macOS
docker version                  # Docker Desktop must be running
```

> **💡 No GPU / No internet needed** — demo runs in `MOCK_LLM=true` mode by default.

---

## 🚀 Quick Start

```bash
git clone https://github.com/ashutoshkandpal89/agentic-ai-k8s-demo
cd agentic-ai-k8s-demo
chmod +x scripts/*.sh

./scripts/01-setup-cluster.sh    # Bootstrap k3d + KEDA + Kyverno + Prometheus (~8 min)
./scripts/02-deploy-platform.sh  # Build images + deploy AI platform (~3 min)
./scripts/03-demo-flow.sh        # Live demo — pauses at each step
```

---

## 📁 Repository Structure

```
agentic-ai-k8s-demo/
├── src/
│   ├── agent/                        # Agent Orchestrator (FastAPI + LangGraph)
│   │   ├── main.py                   # REST API + Prometheus metrics + OTel
│   │   ├── orchestrator.py           # 3-node workflow: plan → tools → synthesize
│   │   ├── token_budget.py           # Redis rolling-window token budget enforcer
│   │   └── Dockerfile
│   └── worker/                       # AI Worker (queue consumer — KEDA scales this)
│       ├── main.py                   # BRPOP queue poller + graceful SIGTERM handler
│       └── Dockerfile
├── manifests/
│   ├── base/                         # Namespace, ResourceQuota, Redis, Deployments, RBAC
│   ├── keda/                         # ScaledObject — scale on queue depth not CPU
│   ├── policy/                       # Kyverno ClusterPolicies — no root, no privilege escalation
│   ├── monitoring/                   # Prometheus alert rules + OTel Collector config
│   └── chaos/                        # Token flood + infinite retry chaos Jobs
├── grafana/
│   └── dashboards/                   # Pre-built AI Agent Platform dashboard (10 panels)
├── scripts/
│   ├── 01-setup-cluster.sh           # k3d + KEDA + Kyverno + Prometheus stack
│   ├── 02-deploy-platform.sh         # Build images, import to k3d, deploy all manifests
│   ├── 03-demo-flow.sh               # Interactive live demo with pause points
│   ├── 04-chaos-test.sh              # Token flood + infinite retry chaos scenarios
│   └── 99-cleanup.sh                 # Delete cluster entirely
└── docs/
    ├── DEMO_STEPS.md                 # Exact commands + expected output + fallback plan
    ├── SPEAKER_NOTES.md              # Full 40-minute talk script
    └── TROUBLESHOOTING.md            # Every failure mode + fix command
```

---

## 🎬 Key Demo Commands

### Submit an agent task
```bash
curl -X POST http://localhost:30080/agent/run \
  -H "Content-Type: application/json" \
  -d '{"task": "Compare AWS EKS vs GKE vs AKS for AI workloads", "token_budget": 2000}'
```

### Watch KEDA auto-scale workers
```bash
watch kubectl get pods -n ai-agents
watch kubectl get scaledobjects -n ai-agents
```

### Trigger chaos: token flood
```bash
./scripts/04-chaos-test.sh
```

### Open Grafana dashboard
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-grafana 3000:80
open http://localhost:3000  # admin / admin → Dashboard: "AI Agent Platform"
```

---

## 🔑 Key Concepts Demonstrated

| Concept | Implementation |
|---------|---------------|
| **Token budget enforcement** | Redis rolling-window counter → HTTP 429 on breach |
| **Event-driven autoscaling** | KEDA ScaledObject triggers on Redis list length |
| **Policy as code** | Kyverno ClusterPolicy — blocks privileged pods at admission |
| **Cost observability** | `agent_llm_cost_usd_total` Prometheus counter + Grafana panel |
| **Graceful shutdown** | SIGTERM handler — in-flight tasks complete before pod dies |
| **Distributed tracing** | OpenTelemetry spans: submit → plan → tool → synthesize |
| **Retry circuit breaking** | Token budget acts as circuit breaker for infinite retry loops |

---

## 🛑 Cleanup

```bash
./scripts/99-cleanup.sh
# Deletes the k3d cluster and all resources
```

---

## 📊 Talk Resources

- 🎤 **Talk:** "Agentic AI Without Chaos" — CNCF Meetup
- 👤 **Speaker:** Ashutosh Kandpal — Cloud & AI Consultant | Corporate Trainer  
- 💼 **LinkedIn:** [linkedin.com/in/ashutoshkandpal](https://www.linkedin.com/in/ashutoshkandpal)

---

## ⭐ If this helped you

Give it a star and share it with your platform team.  
Found a bug or want to contribute? Open an issue — all questions welcome.
