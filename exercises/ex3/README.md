# Exercise 3 - Play with the autonomous Goose diagnostic jobs

This is the heart of the workshop. Two scheduled **CronJobs** run Goose *autonomously* against your cluster — no human at the keyboard — and write structured findings into Kubernetes resources you can read in Busola. In this exercise you inspect them and read a report — all in Busola — and, if you like, use the terminal to **tweak the parameters and trigger a fresh run**.

```
CronJob dev-toolbox-diagnose      (every 10 min)  ── kyma diagnose ──▶ Goose ──▶ ClusterHealthReport/cluster-health
CronJob dev-toolbox-diagnose-v2   (daily, adaptive) ── kubectl/kyma ──▶ Goose ──▶ ClusterHealthReport/cluster-health-v2
                                                                          │                 + AuditLogCatalog
                                                                          └── reasoning on ──▶ LiteLLM :4001 ──▶ SAP AI Core
```

> [!NOTE]
> Everything below runs on **your own** `xp266-NNN` runtime, so you can tweak freely — you won't affect anyone else. The diagnostic resources live in namespace **`dev-toolbox-system`**; the raw Goose transcripts land in namespace **`openclaw`**.

> [!IMPORTANT]
> **Everyone (UI-only):** 3.1 and 3.2 — inspect the jobs and read a Cluster Health Report entirely in Busola. **🔧 Go deeper (optional, terminal):** 3.3 and 3.4 tweak parameters and trigger a run. You never *have* to trigger anything — the v1 job runs **every 10 minutes** on its own, so a fresh report is always waiting for you in Busola.

> [!TIP]
> **The three report generations at a glance** (this exercise focuses on v1 + v2; a third, **v3**, and a **security audit** also run). They are a spectrum of fidelity vs. cost — all run Goose *keyless inside an OpenShell sandbox* (→ LiteLLM → SAP AI Core), then a 2nd `claude -p` pass reformats the raw report into an executive guide:
>
> | Job | Report (Busola `ClusterHealthReport`) | Schedule | Report type |
> |---|---|---|---|
> | **v1** | `cluster-health` | every 10 min (Goose ~every 12 h) | **Snapshot** — Goose summarizes a precomputed `kyma diagnose` JSON; no live cluster access |
> | **v2** | `cluster-health-v2` **+** `cluster-audit` | daily | health = **Live, bounded playbook** (15 fixed commands) · audit = **Live, adaptive** (free security investigation) |
> | **v3** | `cluster-health-v3` | daily | **Live, real-time** — read-only `kubectl` in the sandbox, uncapped |
>
> *Snapshot* = cheap, deterministic, catches regressions between runs. *Live/bounded* = real data on a leash (predictable turn count). *Live/adaptive* = richest but can over-escalate stale findings — treat it as a lead list and confirm against live state. Full reference: `docs/cluster-health-jobs-inventory.md` in the runtime repo.

## Exercise 3.1 - Inspect the two pipelines

1. In Busola, open **namespace `dev-toolbox-system` → Workloads → Cron Jobs**. You'll see the two diagnostic jobs and their schedules — click one to see its pod template, environment, and history.
<br>![](images/03_01_0010.png)

🔧 *Or, in a web terminal (as in Exercise 2):*

Command:
```bash
kubectl get cronjob -n dev-toolbox-system
```
Output:
```
NAME                        SCHEDULE       SUSPEND   ...
dev-toolbox-diagnose        */10 * * * *   False     ...
dev-toolbox-diagnose-v2     7 3 * * *      False     ...
```

- **v1 — `dev-toolbox-diagnose` (every 10 min).** `kyma alpha diagnose` produces a cluster snapshot; Goose consumes it as a static blob and emits a structured summary. Fast, cheap, catches regressions between runs.
- **v2 — `dev-toolbox-diagnose-v2` (adaptive, daily).** Goose gets live `kubectl`/`kyma` access and investigates across **12 sections**:

  | # | Section | What Goose checks |
  |---|---------|-------------------|
  | 1 | Health Status | Cluster + Kyma module conditions |
  | 2 | Issues | Degraded resources, error events |
  | 3 | Kyma Modules | Module reconciliation state |
  | 4 | Impact Assessment | Blast radius of active issues |
  | 5 | Node Resources | CPU/memory pressure, disk |
  | 6 | Workload Health | Deployments, statefulsets, daemonsets |
  | 7 | Security Assessment | RBAC surface, privileged workloads |
  | 8 | Drift Detection | Resources diverging from declared state |
  | 9 | Cost Attribution | Namespace resource consumption |
  | 10 | Network Policy Audit | Connectivity gaps, permissive policies |
  | 11 | Certificate Expiry | Certs within 30 days of expiry |
  | 12 | Recent Events | High-frequency warnings in the last hour |

Look at the knobs that shape a run:

Command:
```bash
kubectl get cronjob dev-toolbox-diagnose-v2 -n dev-toolbox-system \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[*].env[?(@.name=="GOOSE_MODEL")].value}{"\n"}'
```
Key parameters: **`GOOSE_MAX_TURNS`** (default 30), **`--max-tool-repetitions 3`**, **`GOOSE_MODEL`** (the LiteLLM tier/model), **`GOOSE_MAX_TOKENS`** (16000).

## Exercise 3.2 - Read a Cluster Health Report

The v2 job writes its findings to the `ClusterHealthReport` custom resource `cluster-health-v2`.

1. In Busola, open **namespace `dev-toolbox-system` → Custom Resources → ClusterHealthReport → `cluster-health-v2`** and browse the 12 sections (each rendered in a code viewer).
<br>![](images/03_02_0010.png)

2. Or from the terminal:

   Command:
   ```bash
   kubectl get clusterhealthreport cluster-health-v2 -n dev-toolbox-system \
     -o jsonpath='{.spec.values.healthStatus}{"\n"}'
   ```

> [!TIP]
> These aren't hypothetical checks. In production, the same pipeline surfaced things static monitoring missed — e.g. **402 ingress-gateway revisions accumulated in five days** (an unbounded revision history from a pod cycling every 17 minutes), **18 leftover cluster-admin bindings** from dev tooling, and a cert-manager ACME solver **stuck for 5+ days** on a DNS zone mismatch. Reasoning over correlated state finds what probes can't.

## Exercise 3.3 - Tweak the parameters and watch the effect 🔧 *(optional — go deeper)*

The safest way to *feel* the parameters is to run the diagnostic recipe yourself in the terminal, changing one knob at a time.

1. Capture a diagnosis and hand it to Goose with a **generous** turn budget:

   Command:
   ```bash
   kyma alpha diagnose cluster -f json > /tmp/diag.json
   goose run --max-turns 30 --max-tool-repetitions 3 \
     --text "Read /tmp/diag.json and produce a '## Health Status:' section plus the top 3 risks with evidence."
   ```

2. Now **starve it** — drop the turn budget so it runs out mid-investigation:

   Command:
   ```bash
   goose run --max-turns 3 --text "Investigate cluster health with kubectl across nodes, workloads, events, RBAC and certs, then write a 12-section report."
   ```
   You'll often see it stop with *"I've reached the maximum number of actions I can do without user input."* — **before** it writes the report.

> [!IMPORTANT]
> **A turn is one round of reasoning + tool calls, not one LLM call.** In headless mode there's no human to answer "continue?", so hitting the cap makes Goose simply **stop** — sometimes with an empty report. The production fix is *tighten the recipe, don't just raise the cap*: a named 12-section checklist + `--max-tool-repetitions 3` (stops repetitive dumps) keeps 30 turns sufficient. The job also **guards the write** — an empty extraction never overwrites the last good report.
>
> Calibration ladder: narrow task 10–15 · bounded multi-step (our v2) **30** · exploratory 50–75 · open-ended 100–200.

## Exercise 3.4 - Trigger a real run 🔧 *(optional — go deeper)*

Kick the v2 CronJob now (instead of waiting for the schedule) and watch it work:

Command:
```bash
kubectl create job --from=cronjob/dev-toolbox-diagnose-v2 diag-now -n dev-toolbox-system
kubectl get pods -n dev-toolbox-system -l job-name=diag-now -w    # Ctrl-C when Completed
```
When it completes, refresh `ClusterHealthReport/cluster-health-v2` in Busola — the `lastUpdated` timestamp and sections reflect the fresh run.

> [!IMPORTANT]
> **Hand-off — remember this for the next exercises.** The job's output is a *shared artifact*: the `ClusterHealthReport` / `AuditLogCatalog` custom resources **and** the raw transcript ConfigMaps (`goose-raw-*`, `cluster-health-*`) in namespace `openclaw`. Two downstream consumers read them: the **interactive chat agent** ([Exercise 4](../ex4/README.md)) answers questions about the findings, and a **JupyterHub notebook** ([Exercise 7](../ex7/README.md)) analyzes them in Python. *Jobs produce → agents and notebooks consume.*

## Summary

You inspected the two autonomous Goose pipelines, read a 12-section Cluster Health Report, felt how `--max-turns` / `--max-tool-repetitions` shape a headless run (and why an empty report happens), and triggered a fresh v2 run. You also met the hand-off surface the rest of the workshop builds on.

Continue to - [Exercise 4 - Chat with the interactive agent](../ex4/README.md)
