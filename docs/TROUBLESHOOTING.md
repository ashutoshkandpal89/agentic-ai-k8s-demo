# 🔧 Troubleshooting Guide

## Common Issues and Fixes

---

### ❌ k3d cluster create fails

**Symptom:** `FATA[...] Failed to create cluster`

**Fix:**
```bash
# Ensure Docker is running with enough resources
docker system prune -f
# Increase Docker Desktop memory to at least 6GB
# Docker Desktop → Settings → Resources → Memory: 6GB
```

---

### ❌ Pods stuck in `Pending`

**Symptom:** `kubectl get pods -n ai-agents` shows pods in Pending

**Diagnose:**
```bash
kubectl describe pod <pod-name> -n ai-agents
# Look for: Events section at the bottom
```

**Common causes:**
1. **Insufficient resources** → Check ResourceQuota: `kubectl describe resourcequota -n ai-agents`
2. **Image pull failure** → Re-import: `k3d image import ai-worker:latest -c ai-demo`
3. **Node not ready** → `kubectl get nodes` — wait for Ready

---

### ❌ KEDA not scaling

**Symptom:** Queue has tasks but worker count stays at 1

**Diagnose:**
```bash
kubectl describe scaledobject ai-worker-scaler -n ai-agents
kubectl logs -n keda deploy/keda-operator --tail=50
```

**Common causes:**
1. **Redis address mismatch** → Check `address` field in ScaledObject matches Service name
2. **KEDA not watching namespace** → Check `watchNamespace` in KEDA helm values
3. **ScaledObject not ready** → `kubectl get scaledobjects -n ai-agents` → READY should be True

**Fix:**
```bash
# Restart KEDA operator
kubectl rollout restart deployment/keda-operator -n keda

# Check ScaledObject status
kubectl get scaledobject ai-worker-scaler -n ai-agents -o yaml | grep -A 10 status
```

---

### ❌ Kyverno not blocking privileged pods

**Symptom:** Privileged pod gets created despite policy

**Check:**
```bash
kubectl get clusterpolicy
# Look at READY and BACKGROUND columns

kubectl describe clusterpolicy restrict-ai-agent-privileges
```

**Common causes:**
1. **Policy in Audit mode** (not Enforce) → Check `validationFailureAction`
2. **Namespace not labelled correctly** → Check label `type: ai-agent` on namespace
3. **Kyverno webhook not ready** → Wait 30s after install, retry

**Fix:**
```bash
# Verify namespace label
kubectl get namespace ai-agents --show-labels

# If missing label:
kubectl label namespace ai-agents type=ai-agent

# Verify policy is Enforce
kubectl get clusterpolicy restrict-ai-agent-privileges -o jsonpath='{.spec.validationFailureAction}'
```

---

### ❌ Agent API not reachable on localhost:30080

**Fix (use port-forward as fallback):**
```bash
kubectl port-forward -n ai-agents svc/agent-orchestrator 8080:8080 &
# Then use http://localhost:8080 instead of :30080
export BASE_URL=http://localhost:8080
```

---

### ❌ Grafana dashboard not showing data

**Fix 1: Add Prometheus data source**
```
Grafana → Configuration → Data Sources → Add → Prometheus
URL: http://prometheus-operated.monitoring.svc:9090
# OR
URL: http://kube-prometheus-prometheus.monitoring.svc:9090
```

**Fix 2: Import dashboard manually**
```bash
# In Grafana UI:
# Dashboards → Import → Upload JSON file
# File: grafana/dashboards/ai-agents-dashboard.json
```

---

### ❌ Redis not responding

```bash
kubectl exec -n ai-agents deploy/redis -- redis-cli ping
# Expected: PONG

# If no PONG:
kubectl rollout restart deployment/redis -n ai-agents
kubectl rollout status deployment/redis -n ai-agents
```

---

### 🚨 Nuclear Reset (Full Platform Restart)

```bash
kubectl rollout restart deployment -n ai-agents
kubectl rollout restart deployment -n monitoring
kubectl rollout restart deployment -n keda
```

---

### ⚡ Quick Health Check Script

```bash
#!/bin/bash
echo "=== CLUSTER ===" && kubectl get nodes
echo "=== AI AGENTS ===" && kubectl get pods -n ai-agents
echo "=== KEDA ===" && kubectl get pods -n keda
echo "=== MONITORING ===" && kubectl get pods -n monitoring | grep -E "Running|Error"
echo "=== SCALEDOBJECTS ===" && kubectl get scaledobjects -n ai-agents
echo "=== API HEALTH ===" && curl -sf http://localhost:30080/healthz || echo "API not reachable"
echo "=== QUEUE ===" && kubectl exec -n ai-agents deploy/redis -- redis-cli llen task-queue
```
