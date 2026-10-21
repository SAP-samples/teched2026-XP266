# Exercise 3 - Explore OpenShell sandboxes with JupyterHub notebooks

> [!NOTE]
> 👉 This is your **Python playground**.
>
> - ✅ A full **JupyterHub** runs in your cluster, pre-loaded with notebooks and wired — like everything else — to **SAP AI Core through the LiteLLM proxy**.
> - ✅ Here you drive **OpenShell sandboxes** from Python: create one, run a command inside it, then let an **agent (goose)** investigate your cluster from within a sandbox.

**Contents**

- 🚀 [Sign into JupyterHub](#exercise-31---sign-into-jupyterhub)
- 📒 [OpenShell notebooks](#exercise-32---openshell-notebooks)


## Exercise 3.1 - Sign into JupyterHub

1. 👉 Open your JupyterHub UI URL in the browser from the student's portal, e.g.:

   ```
   https://busola.xp266-NNN.<workshop-domain>/
   ```

   or directly via:

   ```
   https://jupyterhub.xp266-NNN.<workshop-domain>/
   ```

2. 👉 Sign in with single sign-on and click **Start My Server**. After a moment JupyterLab opens.

<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr><td align="center"><img src="images/jupyterhub-01.png" width="700" alt="JupyterHub sign-in" /><br/><sub><b>1.</b> sign in</sub></td></tr>
<tr><td align="center"><img src="images/jupyterhub-02.png" width="700" alt="JupyterHub Start My Server" /><br/><sub><b>2.</b> start server</sub></td></tr>
<tr><td align="center"><img src="images/jupyterhub-03.png" width="700" alt="JupyterHub spawning" /><br/><sub><b>3.</b> spawning</sub></td></tr>
</tbody>
</table>

3. 👉 In the file browser (left) you'll find the pre-loaded OpenShell notebooks.

<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td>
<div>
<p float="left">
  <a href="#">
  <img src="images/jupyterhub-04.png" width="820" alt="JupyterLab file browser — pre-loaded OpenShell notebooks" />
  </a>
</p>
</div>
</td>
</tr>
</tbody>
</table>

## Exercise 3.2 - OpenShell notebooks

> [!NOTE]
> - ✅ A **sandbox** is a disposable, per-session pod that _by construction_ can't reach the internet or the cluster API.
> - ✅ Here you drive its whole lifecycle from Python — then put an **agent (goose)** inside the box, reasoning over your cluster from behind the guardrails.

**Notebooks in this section**

- 📦 [`04-OpenShell-Sandbox-SDK`](#exercise-321---04-openshell-sandbox-sdk)
- 📦 [`04b-OpenShell-Sandbox-SDK-Headless`](#exercise-322---04b-openshell-sandbox-sdk-headless)
- 🪿 [`05-OpenShell-Goose-Diagnostics-Live`](#exercise-323---05-openshell-goose-diagnostics-live)
- 🪿 [`05b` / `05c` — headless + pure-SDK variants](#exercise-324---05b-openshell-goose-diagnostics-live-headless--05c-openshell-sandbox-puresdk)
- 🪿 [`06-OpenShell-Goose-Diagnostics-Snapshot`](#exercise-325---06-openshell-goose-diagnostics-snapshot)
- 🪿 [`07-OpenShell-Goose-Diagnostics-FromReport`](#exercise-326---07-openshell-goose-diagnostics-fromreport)

| Notebook | Track | What it does |
|---|---|---|
| [`04-OpenShell-Sandbox-SDK`](#exercise-321---04-openshell-sandbox-sdk) | 📦 OpenShell SDK | Sandbox create → exec → list → delete; gateway via CLI device-code login. |
| [`04b-OpenShell-Sandbox-SDK-Headless`](#exercise-322---04b-openshell-sandbox-sdk-headless) | 📦 OpenShell SDK | Same lifecycle, **no CLI** — pure `SandboxClient(tls=None, bearer_token=…)`. |
| [`05-OpenShell-Goose-Diagnostics-Live`](#exercise-323---05-openshell-goose-diagnostics-live) | 🪿 OpenShell + goose | Agent runs **live read-only kubectl** in a scoped sandbox and writes a report. |
| [`05b-OpenShell-Goose-Diagnostics-Live-Headless` / `05c-OpenShell-Sandbox-PureSDK`](#exercise-324---05b-openshell-goose-diagnostics-live-headless--05c-openshell-sandbox-puresdk) | 🪿 OpenShell + goose | The same live investigation, headless (client-credentials) / pure SDK. |
| [`06-OpenShell-Goose-Diagnostics-Snapshot`](#exercise-325---06-openshell-goose-diagnostics-snapshot) | 🪿 OpenShell + goose | goose over a **static** `kyma diagnose` snapshot — no live cluster access. |
| [`07-OpenShell-Goose-Diagnostics-FromReport`](#exercise-326---07-openshell-goose-diagnostics-fromreport) | 🪿 OpenShell + goose | Triage a **stored** `ClusterHealthReport`. |

> [!NOTE]
> The `04`–`07` notebooks drive **OpenShell** and need the gateway running on your cluster — your `xp266-NNN` runtime has it.

### Exercise 3.2.1 - `04-OpenShell-Sandbox-SDK`

Drive the full OpenShell sandbox lifecycle from Python.

👉 Open **`04-OpenShell-Sandbox-SDK.ipynb`** and run every cell.  
It registers the in-cluster OpenShell gateway, then uses the Python `SandboxClient` to **create → exec → list → delete** a minimal sandbox.

- When a cell triggers a one-time **device-code login**, open the printed URL in your browser and complete it with your workshop single sign-on — the notebook then holds the session for you.
- Watch the lifecycle: a sandbox is created, your `exec` runs a command inside it, you list the live sandboxes, and the sandbox is deleted — nothing is left running.

> [!NOTE]
> **About the "Grant Access to openshell-oidc" page** you see in the browser during the device-code login — it's the **OAuth 2.0 Device Authorization Grant** confirmation ([RFC 8628](https://datatracker.ietf.org/doc/html/rfc8628)), not an OIDC consent screen. The protocol REQUIRES the user to explicitly approve the device at the browser side so nobody else can hijack the account by polling the device endpoint. Click **Yes** once per notebook session — it can't be suppressed via Keycloak client config.

<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td align="center" width="50%"><img src="images/device-grant-01.png" height="260" alt="Grant Access to openshell-oidc — click Yes" /><br/><sub><b>1.</b> click <b>Yes</b> to approve the device (your browser)</sub></td>
<td align="center" width="50%"><img src="images/device-grant-02.png" height="260" alt="Device approved — return to JupyterHub" /><br/><sub><b>2.</b> device approved — you can go back to the JupyterHub screen</sub></td>
</tr>
</tbody>
</table>

> [!NOTE]
> This minimal sandbox is **compute-only**: it has no cluster credentials and no route out.  
> It's the blank canvas; the next step adds an agent and a scoped, read-only cluster identity.

### Exercise 3.2.2 - `04b-OpenShell-Sandbox-SDK-Headless`

👉 Prefer no browser step? Open **`04b-OpenShell-Sandbox-SDK-Headless.ipynb`** — the identical lifecycle with **no CLI**, driven directly by `SandboxClient(tls=None, bearer_token=…)` against the in-cluster gateway.  
Same result, machine-to-machine auth.

### Exercise 3.2.3 - `05-OpenShell-Goose-Diagnostics-Live`

Now put an agent **in** the box: **goose**, through the LiteLLM proxy, reasoning over your cluster from inside a sandbox that bounds what it can touch.

👉 Open **`05-OpenShell-Goose-Diagnostics-Live.ipynb`** and run all cells.  
goose runs **live, read-only `kubectl`** inside a scoped sandbox (the `scoped-ops` policy) and writes a cluster-health report.

> [!IMPORTANT]
> **The sandbox is the guardrail, not the prompt.** goose gets a short-lived **read-only** identity (`get`/`list`/`watch`, no secrets) and no internet; a write or a secret-read comes back `403`. You can hand it any prompt and it still can't mutate your cluster or leak a token — the sandbox enforces it, not the prompt.

### Exercise 3.2.4 - `05b-OpenShell-Goose-Diagnostics-Live-Headless` / `05c-OpenShell-Sandbox-PureSDK`

👉 Open **`05b-OpenShell-Goose-Diagnostics-Live-Headless.ipynb`** — same live investigation as 3.2.3, but with **client-credentials auth (no browser step)**.  
And **`05c-OpenShell-Sandbox-PureSDK.ipynb`** — same again, this time **pure SDK, no CLI**.

### Exercise 3.2.5 - `06-OpenShell-Goose-Diagnostics-Snapshot`

👉 Open **`06-OpenShell-Goose-Diagnostics-Snapshot.ipynb`** and run all cells.  
Same agent, **no live cluster access** — it reasons over a **static** `kyma diagnose` snapshot inside a fixed-policy sandbox. Compare its report with the live one from 3.2.3.

### Exercise 3.2.6 - `07-OpenShell-Goose-Diagnostics-FromReport`

👉 Open **`07-OpenShell-Goose-Diagnostics-FromReport.ipynb`** — triage a **stored** `ClusterHealthReport` CR directly. The agent reasons over the report artifact rather than the live cluster — the Jupyter-side counterpart of the forensic post-mortem.

## Summary

You signed in to JupyterHub, drove the full **OpenShell sandbox lifecycle** from the Python SDK, and ran an **agent inside a sandbox** — live read-only `kubectl`, a static snapshot, and a report-only triage — watching the same read-only, no-egress guardrails that bound the CLI agent.  
You now have the sandboxed-agent pattern in Python, inside your own Kyma cluster.  
Continue to - [Exercise 4 - Your own sandboxed agent: OpenShell on Kyma](../ex4/README.md)
