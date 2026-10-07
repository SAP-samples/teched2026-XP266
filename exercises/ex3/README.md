# Exercise 3 - Trigger and shape the Cluster Health Reports

This is the heart of the workshop.

A **Goose** agent inspects your cluster on a schedule and writes what it finds as **Busola in-cluster health reports** — three generations, **v1 / v2 / v3** — plus a security **audit**.

Every run executes Goose **keyless, inside an OpenShell sandbox** (read-only, no internet), reasoning through the LiteLLM proxy → SAP AI Core.

You drive all of it from one place: the **dev-toolbox UI**.

👉 You never touch CronJobs or `kubectl` here — the dev-toolbox UI is the control panel: trigger a run, pick the model, read the report, and write your own prompt.

Open it (same single sign-on as Busola):

```
https://dev-toolbox.xp266-NNN.<workshop-domain>/
```

> [!NOTE]
> Everything runs on **your own** `xp266-NNN` runtime, so tweak freely — you won't affect anyone else. The reports live in namespace `dev-toolbox-system`; each run spins up a short-lived OpenShell sandbox with a **read-only** cluster token.

> [!IMPORTANT]
> **Everyone (UI):** 3.1–3.3 — read a report, trigger a run, and write your own prompt, all in the dev-toolbox UI. **🔧 Go deeper (optional):** 3.4 peeks at the same artifacts from a terminal. You never *have* to trigger anything — the reports refresh on a schedule, so one is always waiting for you.

### The three report generations

They trade **fidelity for cost** — all run the same way (Goose in an OpenShell sandbox → LiteLLM → SAP AI Core), but differ in how much live cluster access Goose gets.

| Report | Busola CR | What Goose sees | Style |
|---|---|---|---|
| **v1** | `cluster-health` | a **frozen** `kyma alpha diagnose` snapshot — no live cluster access | cheap, deterministic — catches regressions between runs |
| **v2** | `cluster-health-v2` (+ `cluster-audit`) | **live**, read-only `kubectl` on a leash — a fixed health playbook; a second sidecar runs a free-form **security audit** | the balanced default |
| **v3** | `cluster-health-v3` | **live**, read-only `kubectl`, real-time and uncapped | richest and priciest — treat it as a lead list to confirm |

> [!NOTE]
> The **security audit** (`cluster-audit`) is produced as part of a **v2** run — there's no separate button. Trigger a v2 run to refresh it, and read it in **Busola → Cluster Audit**. v3 may be disabled on some clusters.

## Exercise 3.1 - Read the latest reports

1. In the dev-toolbox UI, find the **Latest health reports** panel.

   Each report shows an **executive summary**, a **status badge** (HEALTHY / WARNING / CRITICAL), and a **raw Goose** expander with the agent's unedited output. The panel auto-refreshes every ~15 s.

2. Look at the **run-stats** line in each report's header: **Model · Duration · Cost · Tokens · Agent**.

   That's the real SAP AI Core spend and latency of that single run — the same numbers roll up into the spend dashboard in [Exercise 5](../ex5/README.md).

3. Open the same report in **Busola** → namespace `dev-toolbox-system` → **Custom Resources → ClusterHealthReport → `cluster-health-v2`**.

   While a run is in flight, Busola shows a live **Activity** badge (`RUNNING`) and an **Elapsed** timer — the report is a Kubernetes custom resource the agent writes into, so the whole fleet can read it.

> [!TIP]
> These aren't hypothetical checks. In production the same pipeline surfaced things static monitoring missed — **402 ingress-gateway revisions** piled up in five days (a pod cycling every 17 minutes), **18 leftover cluster-admin bindings** from dev tooling, and a cert-manager ACME solver **stuck for 5+ days** on a DNS mismatch. Reasoning over correlated state finds what probes can't.

## Exercise 3.2 - Trigger a run

1. In the **Run a diagnostic** card, choose a **job** — start with **v2** (live, balanced).

2. *(optional)* Pick a **Model**.

   The dropdown is the **intersection** of what's actually deployed and `RUNNING` in your SAP AI Core, and what the LiteLLM proxy is configured to route — so you can only pick a model the proxy will accept. (v2/v3 honour your choice; v1 keeps its baked model.)

3. *(optional)* Set **Max turns** — how many reason-and-act rounds Goose gets.

4. Click **Run**.

   A one-off sandboxed run starts immediately (no waiting for the schedule). Watch the **Recent runs** table; click **logs** on the new row to tail the sandbox and see the extracted *Goose answer*.

5. When it completes, the matching report in **Latest health reports** refreshes — new `lastUpdated`, new sections.

> [!TIP]
> **What does *Max turns* actually do?** A *turn* is one round of reasoning **plus** its tool calls — not one LLM call. In this headless, no-human-in-the-loop setup, hitting the cap makes Goose simply **stop** — sometimes before it has written the report. The recipe is tuned so the default is enough; the run also **guards the write**, so a short or empty run never overwrites your last good report. (Calibration rule of thumb: narrow task 10–15 · bounded playbook ~30 · open-ended exploration 100+.)

## Exercise 3.3 - Write your own prompt

The real power of the dev-toolbox is this: **you change what Goose investigates by changing the prompt** — no code, no redeploy.

1. In the **Run a diagnostic** card, open the **Prompt** dropdown and choose **— custom prompt —**.

2. Give it a **name** and paste your **prompt text**. For example:

   ```text
   You are a Kubernetes SRE. Using read-only kubectl, review this cluster's workloads and
   produce a prioritized markdown report: the top 3 risks (each with concrete evidence —
   resource names, counts, event messages) and a specific remediation for each. Finish with
   a one-line overall verdict.
   ```

3. Pick the **v2** job (so Goose gets live, read-only `kubectl`) and click **Run**.

   Your prompt is saved to your own **adhoc prompt** store and used for this run; it then appears in the dropdown so you can **reuse** it. The **delete** button removes your custom prompts (the shipped ones are read-only).

👉 The shipped **v1/v2/v3 recipes are read-only** in the UI — your custom prompts live alongside them and never change the defaults, so you can experiment safely.

> [!NOTE]
> Your prompt runs inside the **same OpenShell sandbox** as the built-in ones: a read-only cluster token, no internet, writes → `403`. So even a prompt you wrote can only **look and reason** — it can't mutate the cluster or exfiltrate anything. (That containment is [Exercise 7](../ex7/README.md).)

## Exercise 3.4 - The guardrails: read, reason, but don't touch

An agent with `kubectl` is powerful — and, unchecked, dangerous. The reason you can hand it a prompt you wrote and let it loose is that it is **boxed in by construction**, not by asking the model to behave.

Three overlapping fences wrap every run:

- **A read-only identity.** The run gets a short-lived **`sandbox-viewer`** token — `get`/`list`/`watch` only, with **`secrets` excluded**. It can read the whole picture to reason, but a write or a secret-read is refused by the API server with `403`.
- **No route out.** The run executes inside an **OpenShell sandbox** with no path to the internet; its only egress is the in-cluster LiteLLM proxy. The LLM key is never in the box.
- **An unprivileged pod.** The workload runs **non-root** with a read-only root filesystem and dropped capabilities.

> [!NOTE]
> **Defense in depth.** No single control is trusted alone: the read-only token (can't write or read secrets), the sandbox boundary (no internet, no API-server mutation), non-root + read-only rootfs (can't escalate on the node), and `drop_params` at the proxy (can't send SAP AI Core a malformed request). The agent is useful *because* it's boxed in. The deep dive is [Exercise 7](../ex7/README.md).

🔧 **Prove it yourself (optional — go deeper).** In a **web terminal** ([Exercise 2](../ex2/README.md)), ask the API server what the web-terminal identity may do, and read the report artifacts directly:

Command:
```bash
echo "read anything:    $(kubectl auth can-i list nodes)"
echo "write configmap:  $(kubectl auth can-i create configmaps)"
echo "delete deploy:    $(kubectl auth can-i delete deployments)"
echo "read secrets:     $(kubectl auth can-i get secrets)"
echo "cluster-admin:    $(kubectl auth can-i '*' '*')"

# everything the UI shows is a plain Kubernetes object:
kubectl get clusterhealthreport -n dev-toolbox-system
```
Output:
```
read anything:    yes
write configmap:  yes
delete deploy:    no
read secrets:     no
cluster-admin:    no
```

> [!IMPORTANT]
> **Hand-off — remember this for later.** A run's output is a *shared artifact*: the `ClusterHealthReport` / `cluster-audit` custom resources, plus the raw Goose transcripts. Two downstream consumers read them — the **interactive chat agent** ([Exercise 4](../ex4/README.md)) answers questions about the findings, and a **JupyterHub notebook** ([Exercise 6](../ex6/README.md)) analyses them in Python. *Jobs produce → agents and notebooks consume.*

## Summary

You read the v1/v2/v3 Cluster Health Reports in the dev-toolbox UI and in Busola, triggered a fresh sandboxed run (choosing the model and turn budget), **wrote your own prompt** and watched Goose run it keyless inside a read-only OpenShell sandbox — and saw the layered guardrails (read-only token, no egress, non-root) that make an autonomous `kubectl` agent safe to run.

You also met the hand-off surface the rest of the workshop builds on.

Continue to - [Exercise 4 - Chat with the interactive agent](../ex4/README.md)
