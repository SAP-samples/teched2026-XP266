# Exercise 3 - Explore OpenShell sandboxes with JupyterHub notebooks

👉 This is your **Python playground**.  
A full **JupyterHub** runs in your cluster, pre-loaded with notebooks and wired — like everything else — to **SAP AI Core through the LiteLLM proxy**.  
Here you drive **OpenShell sandboxes** from Python: create one, run a command inside it, then let an **agent (goose)** investigate your cluster from within a sandbox.

**Contents**

- 🚀 [Sign in and spawn your server](#exercise-31---sign-in-and-spawn-your-server)
- 📦 [Drive an OpenShell sandbox from Python](#exercise-32---drive-an-openshell-sandbox-from-python)
- 🪿 [Run an agent inside a sandbox](#exercise-33---run-an-agent-inside-a-sandbox)


## Exercise 3.1 - Sign in and spawn your server

1. Open your JupyterHub URL in the browser (handed out with your runtime), e.g.:

   ```
   https://jupyterhub.xp266-NNN.<workshop-domain>/
   ```

2. 👉 Sign in with single sign-on and click **Start My Server**. After a moment JupyterLab opens.

<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td align="center" width="33%"><img src="images/jupyterhub-01.png" height="140" alt="JupyterHub sign-in" /><br/><sub><b>1.</b> sign in</sub></td>
<td align="center" width="33%"><img src="images/jupyterhub-02.png" height="140" alt="JupyterHub Start My Server" /><br/><sub><b>2.</b> start server</sub></td>
<td align="center" width="33%"><img src="images/jupyterhub-03.png" height="140" alt="JupyterHub spawning" /><br/><sub><b>3.</b> spawning</sub></td>
</tr>
</tbody>
</table>

3. 👉 In the file browser (left) you'll find the pre-loaded OpenShell notebooks:

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

   | Notebook | Track | What it does |
   |---|---|---|
   | `04-OpenShell-Sandbox-SDK` | 📦 OpenShell SDK | Sandbox create → exec → list → delete; gateway via CLI device-code login. |
   | `04b-OpenShell-Sandbox-SDK-Headless` | 📦 OpenShell SDK | Same lifecycle, **no CLI** — pure `SandboxClient(tls=None, bearer_token=…)`. |
   | `05-OpenShell-Goose-Diagnostics-Live` | 🪿 OpenShell + goose | Agent runs **live read-only kubectl** in a scoped sandbox and writes a report. |
   | `05b-OpenShell-Goose-Diagnostics-Live-Headless` / `05c-OpenShell-Sandbox-PureSDK` | 🪿 OpenShell + goose | The same live investigation, headless (client-credentials) / pure SDK. |
   | `06-OpenShell-Goose-Diagnostics-Snapshot` | 🪿 OpenShell + goose | goose over a **static** `kyma diagnose` snapshot — no live cluster access. |
   | `07-OpenShell-Goose-Diagnostics-FromReport` | 🪿 OpenShell + goose | Triage a **stored** `ClusterHealthReport`. |

> [!NOTE]
> The `04`–`07` notebooks drive **OpenShell** and need the gateway running on your cluster — your `xp266-NNN` runtime has it.

## Exercise 3.2 - Drive an OpenShell sandbox from Python

A **sandbox** is a disposable, per-session pod that _by construction_ can't reach the internet or the cluster API.  
Here you drive its whole lifecycle from Python.

👉 Open **`04-OpenShell-Sandbox-SDK.ipynb`** and run every cell.  
It registers the in-cluster OpenShell gateway, then uses the Python `SandboxClient` to **create → exec → list → delete** a minimal sandbox.

- When a cell triggers a one-time **device-code login**, open the printed URL in your browser and complete it with your workshop single sign-on — the notebook then holds the session for you.
- Watch the lifecycle: a sandbox is created, your `exec` runs a command inside it, you list the live sandboxes, and the sandbox is deleted — nothing is left running.

> [!NOTE]
> This minimal sandbox is **compute-only**: it has no cluster credentials and no route out.  
> It's the blank canvas; the next step adds an agent and a scoped, read-only cluster identity.

> [!TIP]
> Prefer no browser step? **`04b-OpenShell-Sandbox-SDK-Headless.ipynb`** runs the identical lifecycle with **no CLI** — a direct `SandboxClient(tls=None, bearer_token=…)` against the in-cluster gateway.  
> Same result, machine-to-machine auth.

## Exercise 3.3 - Run an agent inside a sandbox

Now put an agent **in** the box: **goose**, through the LiteLLM proxy, reasoning over your cluster from inside a sandbox that bounds what it can touch.

1. 👉 Open **`05-OpenShell-Goose-Diagnostics-Live.ipynb`** and run all cells.  
   goose runs **live, read-only `kubectl`** inside a scoped sandbox (the `scoped-ops` policy) and writes a cluster-health report.

2. Open **`06-OpenShell-Goose-Diagnostics-Snapshot.ipynb`** and run all cells.  
   Same agent, **no live cluster access** — it reasons over a **static** `kyma diagnose` snapshot inside a fixed-policy sandbox. Compare its report with the live one from step 1.

> [!IMPORTANT]
> The sandbox is the guardrail, not the prompt.  
> In step 1 goose gets a short-lived **read-only** identity (`get`/`list`/`watch`, no secrets) and no internet; a write or a secret-read comes back `403`. In step 2 it has **no cluster access at all**. You can hand either one any prompt and it still can't mutate your cluster or leak a token — the sandbox enforces it, not the prompt.

> [!TIP]
> Advanced variants of the same investigation live alongside: **`05b`** (headless client-credentials, no browser), **`05c`** (pure SDK, no CLI), and **`07`** (triage a stored `ClusterHealthReport` instead of the cluster).

## Summary

You signed in to JupyterHub, drove the full **OpenShell sandbox lifecycle** from the Python SDK, and ran an **agent inside a sandbox** — live read-only `kubectl` and a static snapshot — watching the same read-only, no-egress guardrails that bound the CLI agent.  
You now have the sandboxed-agent pattern in Python, inside your own Kyma cluster.  
Continue to - [Exercise 4 - Your own sandboxed agent: OpenShell on Kyma](../ex4/README.md)
