# Exercise 2 - The Busola web terminal 🔧 *(optional — go deeper)*

> [!NOTE]
> **This whole exercise is the optional "go deeper" track** — it's the most fun if you're comfortable with a shell, but **nothing here is required to finish the workshop**. If you'd rather stay UI-only, skip straight to [Exercise 3](../ex3/README.md): you'll see these same agents running *for* you, autonomously, with everything readable in Busola.

Busola ships an **in-cluster web terminal** — a pod, in your browser, that already has **`goose`**, **`Claude Code`**, `kubectl`, and the **`kyma`** CLI installed and **pre-authenticated to the LiteLLM proxy**.

No local install, no login, no API key.

In this exercise you drive the `kyma` CLI and both AI agents against your own cluster and see them answer via SAP AI Core.

```
You (browser)
   │  Busola web terminal (a pod)
   ▼
goose / claude ──▶ LiteLLM proxy :4001 ──▶ SAP AI Core
   │
   └── kubectl / kyma ──▶ your Kyma cluster
```

## Exercise 2.1 - Open the terminal and check the tools

1. In Busola, open the cluster menu (top-right) and choose **Terminal**. A shell opens in the browser.

2. Confirm the pre-installed toolchain:

   Command:
   ```bash
   goose --version && claude --version && kubectl version --client -o yaml | grep gitVersion && kyma version && k9s version -s
   ```
   Output (versions may differ):
   ```
   goose 1.49.0
   2.1.278 (Claude Code)
   gitVersion: v1.35.0
   3.5.0
   v0.51.0
   ```

> [!TIP]
> Prefer a **visual** cluster browser to typing `kubectl`? Run **`k9s`** — a full-screen terminal UI. Arrow-key around namespaces, pods, logs, and YAML; press `:` to jump to a resource (e.g. `:pods`, `:cronjobs`), `d` to describe, `l` for logs, and `:q` to quit. Navigating and inspecting works freely; *mutating* actions (delete/scale) are blocked by the terminal's read-mostly permissions — that's [Exercise 3](../ex3/README.md)'s guardrails in action.

> [!NOTE]
> The terminal is **auto-authenticated**: a start-up script fetches the LiteLLM key from the `llm-proxy-credentials` Secret and exports the environment both agents need (`GOOSE_PROVIDER=litellm`, `ANTHROPIC_BASE_URL`, model tiers…). You never see or handle a key. The pod runs **non-root** with a **read-mostly** RBAC role (you'll prove that in [Exercise 3](../ex3/README.md)).

## Exercise 2.2 - Zoom: the `kyma` CLI

The [`kyma` CLI](https://github.com/kyma-project/cli) (v3) is your purpose-built lens on a Kyma runtime.

In the terminal it is **pre-wired to your cluster** — the image bakes a `KUBECONFIG`, so commands just work with no setup.

The star command for this workshop is **`kyma alpha diagnose`**: it snapshots the whole cluster — nodes, Kyma modules, workloads, events — into one structured report.

Command:
```bash
kyma alpha diagnose cluster
```
This prints a human-readable health snapshot.

Now get the **machine-readable** form — the exact input the autonomous jobs feed to Goose:

Command:
```bash
kyma alpha diagnose cluster -f json | head -40
```

A few more workshop-relevant `kyma` commands to try:

| Command | What it does |
|---|---|
| `kyma version` | the CLI version (and, in-cluster, the Kyma version) |
| `kyma alpha diagnose cluster` | full cluster health snapshot (human-readable) |
| `kyma alpha diagnose cluster -f json` | same, as JSON — the agents' input |
| `kyma alpha diagnose istio` | focused Istio service-mesh diagnosis |
| `kyma alpha --help` | discover the rest (modules, kubeconfig, app push…) |

> [!IMPORTANT]
> **`kyma alpha diagnose cluster` is exactly what the autonomous diagnostic jobs run** (Exercise 3): they capture this JSON and hand it to Goose, which reasons over it via SAP AI Core. Running it by hand here is you doing manually what the CronJobs do on a schedule.

## Exercise 2.3 - Ask Goose

Goose is an autonomous agent with shell-tool access.

It does **not** read stdin — give it a file or embed the text.

Give it a one-shot task with a bounded turn budget:

Command:
```bash
goose run --max-turns 3 --text "Using kubectl, how many namespaces are in this cluster, and which are not Active?"
```

More documented one-shots to try — run them one at a time:

```bash
goose run --max-turns 1 --text "In one line, what is Kyma?"
```

```bash
goose run --max-turns 8 --text "Using kubectl, list namespaces with any non-Running pods and summarize why."
```

```bash
kyma alpha diagnose cluster -f json > /tmp/diag.json
```

```bash
goose run --max-turns 4 --text "Read /tmp/diag.json and summarize cluster health in 3 bullets."
```

> [!TIP]
> For a back-and-forth session instead of one-shot, run `goose session` and type your questions; `Ctrl-D` to exit.

## Exercise 2.4 - Ask Claude Code, and pipe real cluster data

`claude -p` runs Claude Code headlessly — the **most reliable** mode.

It shines when you **pipe cluster data into it**. Run these one at a time:

```bash
kyma alpha diagnose cluster -f json | claude -p "Summarize cluster health and flag any issues."
```

```bash
kubectl get pods -A -o wide | claude -p "Which pods look unhealthy or mis-scheduled? Table by severity."
```

<details>
<summary><b>Example output</b> (abridged — wording varies, it's a live model)</summary>

### Pod Health &amp; Scheduling Assessment

| Severity | Pod | Namespace | Signal |
|---|---|---|---|
| 🟡 Low | `busola-oauth2-proxy-…` | busola | 7 restarts (23 h ago) — early startup churn, stable since |
| 🟡 Low | `litellm-proxy-…` | default | 3 restarts (23 h ago) — settled; no recent restarts |
| ℹ️ Info | `dev-toolbox-diagnose-…`, `terraform-*` | various | `0/1 Completed` — expected terminal state for Jobs |

**Bottom line:** no critical or high-severity issues — a handful of oauth2-proxy pods churned early then stabilized; everything else is Running/ready or in an expected Completed state.

</details>

```bash
kubectl get pods -n kyma-system -o json | claude -p "List workloads with no CPU/memory requests set and flag which block HPA scaling."
```

> [!NOTE]
> Pipe a **scoped** query into `claude -p` — a cluster-wide `kubectl get pods -A -o json` can exceed the model's input limit. Narrow it (a namespace, `-o wide`, or a `jq`/`grep` filter) so the prompt stays well within bounds.

> [!TIP]
> The **interactive** `claude` TUI may show a one-time *"Streaming response ended … retrying without streaming"* — it's **harmless** (SAP AI Core's path is non-streaming) and recovers on retry. Headless `claude -p` and pipes don't hit it.

## Exercise 2.5 - A prompt library to try

The interactive `claude` reads files and runs an **allowlisted, read-only** toolset (`kubectl get/describe/logs/top`, `kyma`, file reads) **without prompting** — so you can hand it an investigation and watch it work.

Launch `claude`, then paste any of these:

```text
# Headline SRE demo
You are an SRE doing a cluster health review. Run `kyma alpha diagnose cluster`, then use kubectl to inspect
the nodes and any unhealthy or over-committed workloads. Produce a prioritized markdown report: the top 3 risks
(each with concrete evidence — numbers, resource names, event counts) and for each a specific remediation (the
exact kubectl/patch command). Finish with a one-line overall verdict.

# Focused investigations
Which workloads on this cluster are over their CPU/memory limits or have no requests set? Show a table sorted by
risk, and flag anything that would block the HPA from scaling.

Investigate why the `busola` HorizontalPodAutoscaler is failing, from first principles using kubectl — root cause
plus the exact fix.

Walk the `kyma-system` namespace: list the Kyma modules and their states, and flag any that are degraded or drifting.
```

> [!IMPORTANT]
> This is the **same LLM path** as Exercise 1 — the agents are just convenient front-ends over the LiteLLM proxy → SAP AI Core. In [Exercise 3](../ex3/README.md) you'll see this exact pattern (`kyma alpha diagnose` → Goose) running **autonomously on a schedule**, writing its findings into Kubernetes.

## Summary

You opened the in-cluster web terminal, drove the `kyma` CLI (especially `kyma alpha diagnose cluster`), and ran both Goose and Claude Code against your cluster — one-shot, headless, and fed live `kubectl`/`kyma` output.

Same proxy, same SAP AI Core, now driven interactively by you.

Next, the same recipe runs on its own.

> [!TIP]
> Want the same agents but **fenced inside a contained, read-only sandbox** (no internet, `secrets` excluded, writes → 403)? [**Exercise 7**](../ex7/README.md) (§7.5) runs Goose/Claude from *this same terminal* via one command — **`scoped-ops`** — which provisions an OpenShell sandbox with a short-lived read-only token and drops you inside.

Continue to - [Exercise 3 - Trigger and shape the Cluster Health Reports](../ex3/README.md)
