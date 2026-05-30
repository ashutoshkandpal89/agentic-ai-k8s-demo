# 🎤 Speaker Notes — Agentic AI Without Chaos
### Full 40-Minute Talk Script | Ashutosh Kandpal

> These are your word-for-word speaker notes. Use them as a guide — not a teleprompter.
> Timing markers are approximate. Adjust based on audience energy.

---

## PRE-TALK CHECKLIST (15 min before)

- [ ] Cluster running: `kubectl get nodes`
- [ ] All pods green: `kubectl get pods -n ai-agents`
- [ ] Browser tabs open: Grafana, API docs, terminal
- [ ] Slide deck on external display
- [ ] Notes on laptop screen
- [ ] Font size bumped: `Ctrl+Plus` × 3 in terminal
- [ ] Do Not Disturb: ON
- [ ] Slack / notifications: OFF

---

## SLIDE 1 — Title (0:00 – 0:30)

*[Walk on stage, take a breath, let the title sit for 3 seconds]*

**Say:**
> "Agentic AI Without Chaos. I picked this title because I've seen the chaos.
> And I suspect some of you have too."

---

## SLIDE 2 — Hook (0:30 – 2:00)

**Say:**
> "Everyone wants AI agents. I mean, look at the funding rounds. Look at the GitHub stars.
> Look at the LinkedIn posts about 'autonomous AI workflows.'"
>
> *[pause]*
>
> "Nobody talks about operating them."
>
> *[pause — let it land]*
>
> "Your AI agent should not have more production access than your intern."
>
> *[wait for the laugh — it will come]*
>
> "I'm serious. And if you've dealt with an autonomous agent in production, you're not laughing.
> You're having a flashback."
>
> "Quick show of hands — who here has shipped an AI agent to production?"
> *[hands go up]*
>
> "Keep your hand up if you've been paged because of one."
> *[some hands stay up — laugh with them]*
>
> "That's today's talk."

---

## SLIDE 3 — Agenda (2:00 – 3:00)

**Say:**
> "Here's what we're covering in the next 40 minutes.
> I'm not going to explain what ChatGPT is. I know you know.
> I'm not going to show you a LangChain hello world. You've seen it.
>
> What I AM going to show you:
> - Why agents fail in production — specifically and painfully
> - Why Kubernetes is not just where you run agents, but HOW you control them
> - A real architecture — not a diagram from a vendor slide
> - A live demo that either works brilliantly or proves my point about failure modes
> - Observability and governance that your SRE lead will actually thank you for"

---

## SLIDE 4 — The Demo is a Lie (3:00 – 5:00)

**Say:**
> "Let's start with the gap that nobody likes to admit."
>
> "Demo environment: you have an unlimited API key from your personal account.
> Single user. Happy path only. Five-second response time.
> And your laptop IS production."
>
> "Production reality: Day 3. Finance sends a Slack message.
> 'Did someone sign up for a new API service?'
> You check. You have $12,000 in OpenAI charges.
> From an agent. That you forgot to put limits on.
> The agent was summarizing your S3 bucket.
> All of it. Including the backup of the backup."
>
> *[pause]*
>
> "This is not hypothetical. Change the details, and this is Tuesday for a lot of teams."

---

## SLIDE 5 — 8 Failure Modes (5:00 – 8:00)

**Say:**
> "Let me be specific. These are the eight ways agentic AI systems destroy production.
> Not theoretically. Specifically."
>
> *[Walk through each — keep it punchy, 15 seconds each]*
>
> "Token Explosion — unbounded LLM calls. No ceiling. Your budget is the ceiling.
>
> Infinite Loops — agents that retry themselves. Forever. Optimistically.
> 'Infinite retries are not resilience. They're optimism.'
>
> Hallucinated Actions — the agent decided to delete the database.
> Confidently. With full conviction. And no regrets.
>
> Retry Storms — exponential backoff is a good idea. Exponential backoff without a ceiling is expensive math.
>
> Runaway Workflows — no circuit breakers. No stopping conditions.
> The agent just... keeps going.
>
> Observability Gaps — Finance found the agent before your monitoring did. 
> Think about that sentence for a second.
>
> GPU Contention — your inference jobs are eating every GPU node.
> Your batch jobs are sad.
>
> Governance Vacuum — no policy means the agent has whatever access its service account has.
> And someone gave it cluster-admin. You know who you are."

---

## SLIDE 6 — Incident Timeline (8:00 – 10:00)

**Say:**
> "Let me tell you about a production incident. 
> This is definitely fictional and definitely not from personal experience.
>
> 9am: Deploy autonomous research agent to production. 'What could go wrong?'
>
> 9:47am: Agent starts summarizing every document in the S3 bucket.
> All 47,000 of them. 429 errors start appearing.
>
> 10:12am: Retry logic — which someone copy-pasted from Stack Overflow — kicks in
> for ALL the 429 errors. Simultaneously.
>
> 10:31am: The agent, in its infinite wisdom, decides the problem is parallelism.
> It spawns sub-agents. GPU utilization: 100%.
>
> 11:05am: Finance Slack message: 'Did someone buy GPT-4?'
> Cost so far: $847.
>
> 11:22am: PagerDuty fires. SRE team assembles.
> kubectl get pods: 400 running.
>
> 11:45am: kubectl delete namespace ai-agents.
> Problem solved. Sort of.
>
> 2:30pm: Post-mortem. We need governance.
>
> *[pause]*
>
> This talk was born in that post-mortem."

---

## SLIDE 7 — The Reframe (10:00 – 12:00)

**Say:**
> "Here's the mental model shift I want you to make before lunch.
>
> Stop thinking about AI agents as prompt engineering problems.
>
> Start thinking about them as distributed systems problems.
>
> An LLM prompt IS a service call — with a latency, a cost, and a failure mode.
> A chain of thought IS a DAG execution — it can be traced and scheduled.
> A token budget IS a resource quota — enforceable at the platform layer.
> Agent memory IS a stateful workload — it needs persistence and eviction policy.
> An agent retry IS a circuit breaker situation — it needs limits and backoff.
> A tool invocation IS an RPC — it has a timeout, an SLA, and a rate limit.
>
> 'Multi-agent systems are distributed systems with confidence issues.'
>
> Once you see it this way, the solution becomes obvious:
> You already have the tools. You just need to wire them up."

---

## SLIDE 8 — Why Kubernetes (12:00 – 14:00)

**Say:**
> "And the tool you already have — that most of you are running in production right now —
> is Kubernetes.
>
> Not as a place to run your agents.
> As the control plane FOR your agents.
>
> Namespaces give you blast radius isolation — each team's agents can't eat each other's quota.
> KEDA gives you event-driven scaling on the signals that actually matter.
> OPA and Kyverno enforce policy before pods even schedule.
> OpenTelemetry, Prometheus, and Grafana — you've already deployed these. Wire AI traces in.
> Argo Workflows gives you DAG-based agent pipelines with retry budgets and timeouts.
> A service mesh gives you circuit breaking and rate limiting between agents.
>
> None of this is new. All of this is production-tested.
> The insight is applying it to AI workloads."

---

## SLIDE 9 — KEDA (14:00 – 16:00)

**Say:**
> "Let's talk about scaling for a minute. Because this is where most teams get it wrong.
>
> They scale AI workers on CPU. CPU of a Python pod waiting for an HTTP response.
> The CPU is idle. The pod is idle. The LLM is thinking.
> And you're paying for nodes that are doing nothing.
>
> Scale on what actually matters: the queue.
>
> This ScaledObject tells KEDA: for every 5 tasks in the Redis queue, add 1 worker.
> No tasks? Stay at minimum 1 — always warm, no cold start.
> 50 tasks? Scale to 10 workers. 200 tasks? You're at 20 — the hard ceiling.
>
> The ceiling matters. Without it, KEDA will scale to whatever the ResourceQuota allows.
> And if the ResourceQuota doesn't exist... you know where this goes."

---

## SLIDE 10 — Architecture (16:00 – 20:00)

**Say:**
> "Here's the production architecture. Every box earns its place. Nothing is decorative.
>
> Top layer: API Gateway handles auth, rate limiting, and webhook ingestion.
> Human approval gate is here too — any destructive action requires sign-off.
>
> Orchestration layer: LangGraph or Argo for the actual agent DAGs.
> Policy engine here — OPA evaluates every planned action before it executes.
> Cost analyzer tracks token spend in real time.
>
> AI worker layer: LLM gateway with semantic caching — saves 30% of LLM calls by similarity.
> Tool executors are sandboxed pods — they get ephemeral containers, no persistent state.
> Memory and vector DB are here — pgvector or Weaviate depending on your scale.
>
> Platform layer: Kafka or NATS for event streaming between agents.
> Prometheus scraping everything. OTel for traces. Grafana to see it all.
>
> This is not aspirational. This is what a production team should be running by month 3."

---

## SLIDE 11 — Governance YAML (20:00 – 22:00)

**Say:**
> "Let me show you the actual YAML. Because governance-as-slide-deck doesn't work.
>
> Left side: ResourceQuota for the ai-agents namespace.
> 8 CPU requested, 16Gi memory, 2 GPUs maximum, 20 pods.
> This is the cage. Everything in this namespace lives within these bounds.
> The LimitRange below sets defaults — so a developer who forgets to set limits
> doesn't take down the cluster.
>
> Right side: Kyverno ClusterPolicy.
> validationFailureAction: Enforce — this is not a warning. This is a block.
> Any pod in a namespace labelled 'type: ai-agent' cannot run as privileged.
> Cannot escalate privileges. Full stop.
>
> The policy runs as a webhook. Before the pod schedules. Before it hits the node.
> The admission controller is your last line of governance before compute is consumed."

---

## SLIDE 12 — Demo Intro (22:00 – 22:30)

**Say:**
> "Alright. Demo time.
> I want to be honest with you: live demos at tech conferences have a 67% success rate.
> I just made that up. But it feels right.
>
> If this works, it's engineering.
> If it doesn't, it proves my point about failure modes.
> Either way, we're learning something."
>
> *[switch to terminal]*

---

## SLIDES 13-17 — LIVE DEMO (22:30 – 35:00)

> *Follow scripts/03-demo-flow.sh — use the DEMO_STEPS.md notes.*
>
> Key narration points:
> - **Task submission**: "Notice the token_budget field. This is a reservation, not a suggestion."
> - **KEDA scaling**: "That pod count went from 1 to 5. KEDA read the queue. No human intervention."  
> - **429 rejection**: "That HTTP 429 is not an error. That's money saved."
> - **Kyverno block**: "The pod never scheduled. The webhook killed it in the API server."
> - **Grafana**: "This exists because we instrumented before we shipped."

---

## SLIDE 18 — GPU Scheduling (35:00 – 36:30)

**Say:**
> "Quick note on GPU workloads because I know some of you are running inference on-cluster.
>
> Without PriorityClasses, your inference pods will eat every GPU in the cluster.
> Your training jobs get evicted. Your batch pipelines stall.
> This is Kubernetes' version of the noisy neighbor problem — with a $15/hour GPU tax.
>
> The fix: PriorityClass with preemptionPolicy: Never for your agent inference.
> Low priority. They get GPUs when they're available, not by displacing critical work.
>
> For real isolation: MIG partitioning on A100/H100 — hard slices per workload.
> For cost: batch inference on spot instances, real-time on on-demand.
> That split alone is a 70% GPU cost reduction."

---

## SLIDE 19 — Key Takeaways (36:30 – 38:30)

**Say:**
> "Monday morning. Six things. Pick the one that applies most to your situation.
>
> One: Namespace everything. Before you deploy a single agent. ResourceQuota first.
>
> Two: Token budgets are non-negotiable. Hard limit in middleware. Alert at 70%, kill at 100%.
> Do not use 'rate limits' as your token budget. That's the LLM provider's limit, not yours.
>
> Three: KEDA before HPA for AI workloads. Scale on queue depth, not CPU.
>
> Four: Wire OpenTelemetry before you ship. Not after the first incident. Before.
> A trace you can't read is worse than no trace — it's false confidence.
>
> Five: Human approval gates for any destructive action. Delete, modify, deploy.
> If an agent is going to write to a database, a human reviews it first.
>
> Six: Policy as code from day one. Kyverno or OPA.
> Agents are pods. Pods have policies. This is not optional."

---

## SLIDE 20 — Closing (38:30 – 40:00)

**Say:**
> "Scaling AI is easy.
>
> *[pause]*
>
> Controlling AI is the real challenge.
>
> *[pause — longer this time]*
>
> 'The agents are coming. The question is whether you — or they — are in control.'
>
> The tools exist. Kubernetes, KEDA, Kyverno, OpenTelemetry, Prometheus, Grafana.
> You've already deployed half of them.
>
> The missing piece isn't technology. It's the mindset shift:
> AI agents are not a product problem. They're an infrastructure problem.
> Treat them like one.
>
> The demo repo is on GitHub — link is on the slide.
> Everything I showed you today is in there: working code, YAML, scripts, this dashboard.
>
> I'll be around for questions. Find me if you want to argue about YAML.
> I've been told I'm very good at that."
>
> *[smile, pause, done]*

---

## Q&A Prep — Likely Questions

**Q: "Why not just use a managed AI service like Amazon Bedrock Agents?"**
> "Managed services solve the LLM part. They don't solve the orchestration, cost governance,
> or multi-agent coordination part. You still need the control plane — it just plugs in differently."

**Q: "What about LangSmith / Langfuse for observability?"**
> "Both are excellent for LLM-specific traces. They're complementary to OTel, not replacements.
> I'd run both — LangSmith for LLM debugging, OTel for infrastructure correlation."

**Q: "How do you handle LLM provider outages?"**
> "Circuit breaker + fallback model via LLM gateway. Primary: GPT-4. Fallback: Claude Haiku.
> Emergency: Ollama on-cluster. The key is routing at the gateway layer, not in agent code."

**Q: "Isn't KEDA overkill for small teams?"**
> "KEDA is one Helm install and one YAML file. The alternative is a cron job that doesn't scale
> or a constant-running fleet that burns money. KEDA wins."

**Q: "We don't have Kubernetes. We're on Lambda/Cloud Run."**
> "The principles apply — token budgets via DynamoDB, policy via IAM conditions, observability
> via CloudWatch + OTel Lambda layer. The platform differs; the patterns are identical."

**Q: "How do you handle multi-tenant agents?"**
> "One namespace per tenant. Network policies to prevent cross-tenant traffic.
> Separate ResourceQuotas. If tenants need GPU isolation: separate node pools."
