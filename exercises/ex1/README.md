# Exercise 1 - Trigger and shape the Cluster Health Reports

> ⏱ **~30 min**

> [!NOTE]
> 👉 This is the heart of the workshop.
>
> - ✅ A **Goose** agent inspects your cluster on a schedule and writes what it finds as **in-cluster health reports**  
>   — three generations, **v1 / v2 / v3** 
>   — plus a security **audit** and a **forensic post-mortem** that fires when a run skips.  
> - ✅ Every run executes Goose **inside an OpenShell sandbox** (read-only, no internet), reasoning through the LiteLLM proxy → SAP AI Core.
> - ✅ You drive all of it from one place: the **Diagnostic Toolbox** UI.

**Contents**

- 🧰 [The Diagnostic Toolbox portal](#-the-diagnostic-toolbox-portal)
- 📋 [Read the latest reports](#-exercise-11---read-the-latest-reports)
- ▶️ [Trigger a diagnostic run](#️-exercise-12---trigger-a-diagnostic-run)
- ✍️ [Write your own prompt](#️-exercise-13---write-your-own-prompt)
- 🛡️ [The guardrails](#️-exercise-14---the-guardrails-read-reason-but-dont-touch)
  - 🔧 [Prove it yourself](#-prove-it-yourself-optional--go-deeper)

## 🧰 The Diagnostic Toolbox portal

👉 Open the diagnostics either from the **Student's Portal** —

```
https://busola.xp266-NNN.<workshop-domain>/clusterdir/
```

— or directly:

```
https://dev-toolbox.xp266-NNN.<workshop-domain>/
```

<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td align="center" width="50%"><img src="images/toolbox-01.png" width="100%" alt="Student's Portal — Cluster launchpad → Diagnostic Tools tile" /><br/><sub><b>1.</b> Student's Portal — click <b>Diagnostic Tools</b> in the launchpad</sub></td>
<td align="center" width="50%"><img src="images/01_00_0010.png" width="100%" alt="SAP TechEd 2026 — Diagnostic Toolbox landing page" /><br/><sub><b>2.</b> Diagnostic Toolbox — reports, run cards, and more</sub></td>
</tr>
</tbody>
</table>

> [!NOTE]
> - ✅ Everything runs on **your own** `xp266-NNN` runtime, so tweak freely — you won't affect anyone else.   
> - ✅ The reports live in namespace `dev-toolbox-system`; each run spins up a short-lived OpenShell sandbox with a **read-only** cluster token.

### 🗂️ The three report generations plus security audit and forensic reports

They trade **fidelity for cost** — all run the same way (Goose in an OpenShell sandbox → LiteLLM → SAP AI Core), but differ in how much live cluster access Goose gets.

<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td>
<div>
<p float="left">
  <a href="#">
  <img src="images/cluster-health-01.png" width="820" alt="Cluster Health report — v1/v2/v3 badges" />
  </a>
</p>
</div>
</td>
</tr>
</tbody>
</table>


The dev-toolbox ships **four CronJob families** that write **five report CRs** between them.  
👉 Click any card below for its full wiring — schedule, Pod shape, ConfigMaps, sandbox, and output CR.

<details>
<summary>📸 <b>v1</b> · <code>cluster-health</code> — periodic <code>kyma alpha diagnose</code> snapshot; cheap, deterministic</summary>

**What Goose sees:** nothing live — the snapshot JSON produced by `kyma alpha diagnose`.
**Why run it:** catches regressions between heavier runs; cheapest tier.

```mermaid
flowchart LR
    cron["⏱️ CronJob<br/><code>dev-toolbox-diagnose</code><br/>schedule: <code>*/10 * * * *</code>"]
    cron --> job["Job<br/>(one per fire)"]
    job --> pod["Pod · 1 container<br/><code>diagnose-v1</code>"]
    cm["ConfigMap<br/><code>dev-toolbox-prompts</code><br/>key: <code>health-v1-from-diagnose</code>"] -. mounted at <code>/etc/prompts</code> .-> pod
    pod --> snap["<b>kyma alpha diagnose</b><br/>snapshot JSON"]
    snap --> llm["LiteLLM proxy<br/><code>claude -p</code> reformat"]
    llm --> cr["ClusterHealthReport<br/><b>cluster-health</b> (v1)"]
```

- ~15–25 s per run, every 10 min, uniform fleet-wide
- **No cluster access from the agent** — the snapshot comes from `kyma alpha diagnose`; the reformat LLM is `claude -p` through the LiteLLM proxy
- The prompt is the shipped `health-v1-from-diagnose` key — no sandbox, no sidecar, no live kubectl
</details>

<details>
<summary>🩺 <b>v2</b> · <code>cluster-health-v2</code> + 🛡️ <code>cluster-audit</code> — live kubectl on a leash; balanced + security audit</summary>

**What Goose sees:** live, read-only `kubectl` on a leash — a fixed **health** playbook, and a parallel **security** playbook in the same Pod.
**Why run it:** the balanced default — and the only path to a fresh **Security Audit** (the audit shares the pod, no separate trigger). This is also the **highest-spend** tier.

```mermaid
flowchart LR
    cron["⏱️ CronJob<br/><code>dev-toolbox-diagnose-v2</code><br/>daily · 05:17–07:17 UTC (azure)<br/>+ 08:37 UTC (aws)"]
    cron --> job["Job"]
    job --> pod{{"Pod · 3 containers"}}
    pod --> main["<b>diagnose-v2</b> (main)<br/>orchestrator"]
    pod --> gh["<b>goose-v2-health</b> sidecar<br/>OpenShell Sandbox + goose<br/>prompt: <code>health-v2-report-first</code>"]
    pod --> ga["<b>goose-v2-audit</b> sidecar<br/>OpenShell Sandbox + goose<br/>prompt: <code>audit-v2-security</code>"]
    vol["Volume <code>dev-toolbox-prompts</code><br/><i>projected</i>: managed + adhoc CMs merged<br/>→ <code>/etc/prompts</code>"] -. mounted .-> main
    vol -. mounted .-> gh
    gh --> sbh["Sandbox pod<br/>read-only <code>sandbox-viewer</code> token"]
    ga --> sba["Sandbox pod<br/>read-only <code>sandbox-viewer</code> token"]
    sbh --> llm["LiteLLM proxy"]
    sba --> llm
    main --> crH["<b>cluster-health-v2</b>"]
    main --> crA["<b>cluster-audit</b>"]
```

- Two independent goose runs in their own **OpenShell Sandboxes** inside the same Pod — one for health, one for security audit
- Each sandbox gets a fresh **short-lived, read-only `sandbox-viewer` token** (`get`/`list`/`watch`, `secrets` excluded) — the only identity that reaches `kubectl` from inside
- Pod-level prompts volume is **`projected`** (managed CM + `dev-toolbox-prompts-adhoc` merged) so **custom prompts** work on health runs; audit stays on its hardcoded `audit-v2-security` key
- The audit report refreshes **only when v2 runs** — there is no separate audit trigger
</details>

<details>
<summary>🔬 <b>v3</b> · <code>cluster-health-v3</code> — live, uncapped; most thorough; supports custom prompts</summary>

**What Goose sees:** live, read-only `kubectl`, real-time and **uncapped** (no turn budget).
**Why run it:** deepest investigation; the only tier that honours your **model** and **custom prompt** picks.

```mermaid
flowchart LR
    cron["⏱️ CronJob<br/><code>dev-toolbox-diagnose-v3</code><br/>daily · +15 min after v2"]
    cron --> job["Job<br/>(volume name<br/>swapped to adhoc CM<br/>at /run via API<br/>when custom prompt used)"]
    job --> pod["Pod · 1 container<br/><code>diagnose-v3</code>"]
    cm1["ConfigMap<br/><code>dev-toolbox-prompts</code><br/>(managed keys)"] -. default mount .-> pod
    cm2["ConfigMap<br/><code>dev-toolbox-prompts-adhoc</code><br/>(custom prompts)"] -. mount <i>when swapped</i> .-> pod
    pod --> sb["OpenShell Sandbox<br/><i>goose</i> + live read-only <code>kubectl</code>"]
    sb --> llm["LiteLLM proxy<br/>(custom model honoured)"]
    sb --> cr["ClusterHealthReport<br/><b>cluster-health-v3</b>"]
```

- Uncapped goose turn budget, live `kubectl`, honours the custom **model** picker
- Supports **adhoc prompts** via a volume-swap at job-create time (API rewrites the pod spec's CM name from `dev-toolbox-prompts` → `dev-toolbox-prompts-adhoc`)
- Post-teched follow-up: converge this to the same `projected` pattern used by v2 — removes the API swap and matches the uniform v2 mental model
</details>

<details>
<summary>🔎 <b>forensic</b> · <code>cluster-health-forensic</code> — post-mortem; emits 🎯 / 🟡 / ⚪ verdict</summary>

**What forensic sees:** the stored v2 + v3 reports, LiteLLM spend, and Kubernetes Job state — **not** the cluster directly.
**Why run it:** daily right after v3, and reactively **on-failure** of v2/v3 so a skipped main run still produces a verdict. Also triggerable **on-demand** from the Diagnostic Toolbox UI.

```mermaid
flowchart LR
    cron["⏱️ CronJob<br/><code>dev-toolbox-diagnose-forensic</code><br/>daily · +30 min after v2<br/>also fires on-failure of v2/v3"]
    cron --> job["Job"]
    job --> pod["Pod · 1 container<br/><code>diagnose-forensic</code>"]
    inA["<b>cluster-health-v2</b><br/>(latest report)"] --> pod
    inB["<b>cluster-health-v3</b><br/>(latest report)"] --> pod
    inC["LiteLLM spend<br/>(SAP Cloud Logging)"] --> pod
    inD["Kubernetes Job state<br/>(success/failure)"] --> pod
    pod --> sb["OpenShell Sandbox<br/><i>goose</i> + reformat prompt<br/><code>forensic-postmortem-v2</code>"]
    sb --> llm["LiteLLM proxy"]
    sb --> cr["ClusterHealthReport<br/><b>cluster-health-forensic</b><br/>verdict: 🎯 CONFIRMED / 🟡 LIKELY / ⚪ INCONCLUSIVE"]
```

- Cross-report analysis — does **not** touch the cluster directly
- The output verdict is one of **🎯 CONFIRMED** (strong evidence), **🟡 LIKELY** (plausible but partial), or **⚪ INCONCLUSIVE** (insufficient data)
</details>


## 📋 Exercise 1.1 - Read the latest reports

1. 👉 In the Diagnostic Toolbox UI, find the **Latest health reports** panel.

   Each report shows an **executive summary** and a **status badge** (HEALTHY / WARNING / CRITICAL). The header also carries a **run-stats** line — **Model · Duration · Cost · Tokens · Agent** — the real SAP AI Core spend and latency of that single run (the same numbers roll up into the spend dashboard).

<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td>
<div>
<p float="left">
  <a href="#">
  <img src="images/latest-health-reports-01.png" width="820" alt="Latest health reports panel in the Diagnostic Toolbox" />
  </a>
</p>
</div>
</td>
</tr>
</tbody>
</table>

   Furthermore, there is a **detailed Goose report** expander with the agent's unedited output.

<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td>
<div>
<p float="left">
  <a href="#">
  <img src="images/latest-health-reports-02.png" width="820" alt="Latest health reports — detail view with run-stats" />
  </a>
</p>
</div>
</td>
</tr>
</tbody>
</table>

> [!TIP]
> The panel auto-refreshes every ~15 s.

2. 👉 Open the same report in **Busola** by clicking the <kbd>&nbsp;🧭&nbsp; Open in Busola ↗ &nbsp;</kbd> button in the right upper corner.

   While a run is in flight, Busola shows a live **Activity** badge (`RUNNING`) and an **Elapsed** timer — the report is a Kubernetes custom resource the agent writes into, so the whole fleet can read it.

> [!TIP]
> These aren't hypothetical checks.  
> In production the same pipeline caught things static monitoring missed — **402 ingress-gateway revisions** piled up in five days (a pod cycling every 17 minutes), **18 leftover cluster-admin bindings** from dev tooling, and a cert-manager ACME solver **stuck for 5+ days** on a DNS mismatch.  
> Reasoning over correlated state finds what probes can't.

## ▶️ Exercise 1.2 - Trigger a diagnostic run

<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td>
<div>
<p float="left">
  <a href="#">
  <img src="images/diagnostics-01.png" width="820" alt="Run a diagnostic card — job, model, prompt, Run button" />
  </a>
</p>
</div>
</td>
</tr>
</tbody>
</table>

1. 👉 In the **Run a diagnostic** card, choose a **job** and a **prompt** — start with **v2** (live, balanced).

2. 👉 *(optional)* Pick a **Model**.

   The dropdown is the **intersection** of what's actually deployed and `RUNNING` in your SAP AI Core, and what the LiteLLM proxy is configured to route — so you can only pick a model the proxy will accept. (v2/v3 honour your choice; v1 keeps its fixed model.)

3. 👉 Click **Run**.

   A one-off sandboxed run starts immediately (no waiting for the schedule). Watch the **Recent runs** table; click **logs** on the new row to tail the sandbox and see the extracted *Goose answer*.

4. When it completes, the matching report in **Latest health reports** refreshes — new `lastUpdated`, new sections.

> [!NOTE]
> The sandboxed run is **uncapped** — Goose reasons for as many steps as the task needs; there's no turn budget to tune.  
> What shapes a run is the **prompt** (the recipe — next) and the **model** you pick.  
> The job also **guards the write**: a failed or empty run never overwrites your last good report, so you can experiment freely.

## ✍️ Exercise 1.3 - Write your own prompt

👉 The real power of the Diagnostic Toolbox is this: **you change what Goose investigates by changing the prompt** — no code, no redeploy.

<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td>
<div>
<p float="left">
  <a href="#">
  <img src="images/diagnostics-02.png" width="820" alt="Run a diagnostic — custom prompt dropdown and prompt-text editor" />
  </a>
</p>
</div>
</td>
</tr>
</tbody>
</table>

1. In the **Run a diagnostic** card, 
- 👉 pick the **v3** Goose adapative job
- 👉 open the **Prompt** dropdown
- 👉 choose **— custom prompt —**.
  
   Your prompt is saved to your own **adhoc prompt** store under an **auto-generated name** and used for this run — it then appears in the dropdown so you can **reuse** it, and the **delete** button clears it.

2. 👉 Paste your **prompt text**. For example — a concise variant that forces prettified output and suppresses the auto-footer:

   ```text
   You are a Kubernetes SRE. Using read-only kubectl, review this cluster's workloads and
   produce a prioritized markdown report: the top 3 risks (each with concrete evidence —
   resource names, counts, event messages) and a specific remediation for each. Finish with
   a one-line overall verdict.
   Output ONLY the report. No preamble. Be concise. Do NOT write a footer, closing line, or
   any "Report generated / Cluster / Region / Kubernetes / Provider" block — END immediately
   after the last section; a footer is appended automatically afterwards.
   Prettify the markdown — icons, colors etc.
   ```

   Or a Kyma-aware variant that also pulls in the Kyma CLI (`kyma modules`, `kyma diagnostics`) for module-level signal on top of plain `kubectl`:

   ```text
   You are a Kubernetes SRE. Using read-only kubectl and kyma cli diagnostics and modules commands,
   review this cluster's workloads and modules.
   Produce a prioritized markdown report: the top 3 risks (each with concrete evidence —
   resource names, counts, event messages) and a specific remediation for each. Finish with
   a one-line overall verdict.
   Output ONLY the report. No preamble. Be concise. Do NOT write a footer, closing line, or
   any "Report generated / Cluster / Region / Kubernetes / Provider" block — END immediately
   after the last section; a footer is appended automatically afterwards.
   Prettify the markdown — icons, colors etc.
   ```

3. 👉 Click **Run** once you've pasted the prompt text (step 2).


> [!NOTE]
> ✅ Your prompt runs inside the **same OpenShell sandbox** as the built-in ones: a read-only cluster token, no internet.  
> ✅ So even a prompt you wrote can only **look and reason** — it can't mutate the cluster or exfiltrate anything.

## 🛡️ Exercise 1.4 - The guardrails: read, reason, but don't touch

An agent with `kubectl` is powerful — and, unchecked, dangerous. The reason you can hand it a prompt you wrote and let it loose is that it is **boxed in by construction**, not by asking the model to behave.  
Three overlapping fences wrap every run:

- **A read-only identity.** The run gets a short-lived **`sandbox-viewer`** token — `get`/`list`/`watch` only, with **`secrets` excluded**. It can read the whole picture to reason, but a write or a secret-read is refused by the API server with `403`.
- **No route out.** The run executes inside an **OpenShell sandbox** with no path to the internet; its only egress is the in-cluster LiteLLM proxy. The LLM key is never in the box.
- **An unprivileged pod.** The workload runs **non-root** with a read-only root filesystem and dropped capabilities.

> [!NOTE]
> **Defense in depth.** No single control is trusted alone: the read-only token (can't write or read secrets), the sandbox boundary (no internet, no API-server mutation), non-root + read-only rootfs (can't escalate on the node), and `drop_params` at the proxy (can't send SAP AI Core a malformed request). The agent is useful *because* it's boxed in.

### 🔧 Prove it yourself (optional — go deeper)

👉 Open **All Health** (sidebar) and click the terminal `>_` icon in the top-right of the Busola toolbar — a shell pod opens in the browser.

<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td>
<div>
<p float="left">
  <a href="#">
  <img src="images/diagnostics-03.png" width="820" alt="Open the Busola web terminal from the All Health view" />
  </a>
</p>
</div>
</td>
</tr>
</tbody>
</table>

👉 In the terminal, ask the API server what the **web-terminal identity** may do, and read the report artifacts directly:

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
read secrets:     yes
cluster-admin:    no
```

> [!NOTE]
> This is **your** web-terminal identity — intentionally broader than the sandbox.
> The **sandboxed Goose run** uses a different, more restricted token (`sandbox-viewer`: `get`/`list`/`watch` only, **`secrets` excluded**, no mutations).
> That's the guardrail that matters — not what *you* can do, but what the *agent* can do.

> [!IMPORTANT]
> **Hand-off — remember this for later.** A run's output is a *shared artifact*: the `ClusterHealthReport` / `cluster-audit` custom resources, plus the detailed Goose transcripts.  
> Two downstream consumers read them — the **interactive chat agent** answers questions about the findings, and a **JupyterHub notebook** analyses them in Python.  
> *Jobs produce → agents and notebooks consume.*

## Summary

📋 You read the Cluster Health Reports in the Diagnostic Toolbox UI and in Busola.

- ▶️ triggered a fresh sandboxed run (choosing the model),
- ✍️ wrote your own prompt and watched Goose run it inside a read-only OpenShell sandbox,
- 🛡️ observed the layered guardrails (read-only token, no egress, non-root) that make an autonomous `kubectl` agent safe to run.

Continue to - [Exercise 2 - Chat with the interactive agent](../ex2/README.md)
