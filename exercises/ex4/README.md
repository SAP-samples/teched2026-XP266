# Exercise 4 - Explore SAP AI Core and OpenShell sandboxes with JupyterHub notebooks

👉 This is your **Python playground**.  
A full **JupyterHub** runs in your cluster, pre-loaded with notebooks and wired — like everything else — to **SAP AI Core through the LiteLLM proxy**.  
It has two tracks, and the **focus is the second**:

- ☁️ *(optional on-ramp)* call **SAP AI Core** from Python — keyless, through the proxy.
- 📦 **the main event** — drive **OpenShell sandboxes** from Python: create one, run a command inside it, then let an **agent (goose)** investigate your cluster from within a sandbox.

It is the Python twin of the CLI walkthrough in [Exercise 5](../ex5/README.md) — the same sandboxing and the same guardrails, driven from a notebook instead of a terminal.

**Contents**

- 🚀 [Sign in and spawn your server](#exercise-41---sign-in-and-spawn-your-server)
- ☁️ [SAP AI Core from Python](#exercise-42---sap-ai-core-from-python-optional) *(optional)*
- 📦 [Drive an OpenShell sandbox from Python](#exercise-43---drive-an-openshell-sandbox-from-python)
- 🪿 [Run an agent inside a sandbox](#exercise-44---run-an-agent-inside-a-sandbox)
- 📚 [The full notebook set](#exercise-45---the-full-notebook-set)


## Exercise 4.1 - Sign in and spawn your server

1. Open your JupyterHub URL in the browser (handed out with your runtime), e.g.:

   ```
   https://jupyterhub.xp266-NNN.<workshop-domain>/
   ```

2. Sign in with single sign-on and click **Start My Server**. After a moment JupyterLab opens.
<br>![](images/07_01_0010.png)

3. In the file browser (left) the notebooks are grouped by what they drive:

   | Prefix | Track | What it drives |
   |---|---|---|
   | `00`–`03` | ☁️ SAP AI Core | call AI Core models from Python — keyless, through the proxy *(optional)* |
   | `04`, `04b` | 📦 OpenShell SDK | create → exec → delete a sandbox from Python |
   | `05`, `06`, `07` | 🪿 OpenShell + goose | run an agent **inside** a sandbox against your cluster |

   The full list (every variant, plus the upstream JupyterLab samples) is in [Exercise 4.5](#exercise-45---the-full-notebook-set).

> [!NOTE]
> The `04`–`07` notebooks drive **OpenShell** and need the gateway running on your cluster — your `xp266-NNN` runtime has it.

## Exercise 4.2 - SAP AI Core from Python *(optional)*

A quick on-ramp: prove you can reach SAP AI Core from Python before you wrap an agent around it.  
Skip straight to [4.3](#exercise-43---drive-an-openshell-sandbox-from-python) if you only want the sandboxing track.

1. Open **`00-SAP-AI-Core-Credentials.ipynb`** and run every cell (**Shift+Enter**, or *Run ▸ Run All Cells*).  
   It builds the `client` the other notebooks reuse — no OAuth, no API key handling on your part.
<br>![](images/07_02_0010.png)

2. Open **`01-Bedrock-Models-via-SAP-AI-Core.ipynb`** and run all cells — you just called Claude on SAP AI Core, from Python, in your own cluster.

3. Open **`03-SAP-AI-Core-Model-Test.ipynb`** and run it to compare several models side by side.

> [!TIP]
> Every completion here shows up on the **spend dashboard** from [Exercise 3](../ex3/README.md) — go back and watch your own JupyterHub activity appear.  
> To go further, open **`02-Tool-Calling-Bedrock-via-SAP-AI-Core.ipynb`** (function calling), or start a blank notebook and reuse the `client` from `00` — the proxy, the models, and the cost tracking are already there.

## Exercise 4.3 - Drive an OpenShell sandbox from Python

A **sandbox** is a disposable, per-session pod that _by construction_ can't reach the internet or the cluster API — the containment [Exercise 5](../ex5/README.md) builds by hand on the CLI.  
Here you drive its whole lifecycle from Python.

👉 Open **`04-OpenShell-Sandbox-SDK.ipynb`** and run every cell.  
It registers the in-cluster OpenShell gateway, then uses the Python `SandboxClient` to **create → exec → list → delete** a minimal sandbox.

- When a cell triggers a one-time **device-code login**, open the printed URL in your browser and complete it with your workshop single sign-on — the notebook then holds the session for you.
- Watch the lifecycle: a sandbox is created, your `exec` runs a command inside it, you list the live sandboxes, and the sandbox is deleted — nothing is left running.

> [!NOTE]
> This minimal sandbox is **compute-only**: it has no cluster credentials and no route out. It's the blank canvas; [4.4](#exercise-44---run-an-agent-inside-a-sandbox) adds an agent and a scoped, read-only cluster identity.

> [!TIP]
> Prefer no browser step? **`04b-OpenShell-Sandbox-SDK-Headless.ipynb`** runs the identical lifecycle with **no CLI** — a direct `SandboxClient(tls=None, bearer_token=…)` against the in-cluster gateway. Same result, machine-to-machine auth.

## Exercise 4.4 - Run an agent inside a sandbox

Now put an agent **in** the box: **goose**, keyless through the LiteLLM proxy, reasoning over your cluster from inside a sandbox that bounds what it can touch.

1. 👉 Open **`05-OpenShell-Goose-Diagnostics-Live.ipynb`** and run all cells.  
   goose runs **live, read-only `kubectl`** inside a scoped sandbox (the `scoped-ops` policy) and writes a cluster-health report — the Python twin of [Exercise 1](../ex1/README.md)'s diagnostic jobs and [Exercise 5](../ex5/README.md)'s `scoped-ops` demo.

2. Open **`06-OpenShell-Goose-Diagnostics-Snapshot.ipynb`** and run all cells.  
   Same agent, **no live cluster access** — it reasons over a **static** `kyma diagnose` snapshot inside a baked-policy sandbox. Compare its report with the live one from step 1.

> [!IMPORTANT]
> The sandbox is the guardrail, not the prompt. In step 1 goose gets a short-lived **read-only** identity (`get`/`list`/`watch`, no secrets) and no internet; a write or a secret-read comes back `403`. In step 2 it has **no cluster access at all**. You can hand either one any prompt and it still can't mutate your cluster or leak a token — exactly the containment proven on the CLI in [Exercise 5](../ex5/README.md).

> [!TIP]
> Advanced variants of the same investigation live alongside: **`05b`** (headless client-credentials, no browser), **`05c`** (pure SDK, no CLI), and **`07`** (triage the baked `ClusterHealthReport` from [Exercise 1](../ex1/README.md) instead of the cluster).

## Exercise 4.5 - The full notebook set

Everything pre-loaded in your JupyterHub:

| Notebook | Track | What it demonstrates |
|---|---|---|
| `00-SAP-AI-Core-Credentials` | ☁️ AI Core | Builds the keyless `client` (proxy → SAP AI Core). **Run first** on this track. |
| `01-Bedrock-Models-via-SAP-AI-Core` | ☁️ AI Core | Chat completions against Claude models on SAP AI Core. |
| `02-Tool-Calling-Bedrock-via-SAP-AI-Core` | ☁️ AI Core | Function / tool calling. |
| `03-SAP-AI-Core-Model-Test` | ☁️ AI Core | Sweep several models and compare responses. |
| `04-OpenShell-Sandbox-SDK` | 📦 SDK | Sandbox create → exec → list → delete; gateway via CLI device-code login. |
| `04b-OpenShell-Sandbox-SDK-Headless` | 📦 SDK | Same lifecycle, **no CLI** — pure `SandboxClient(tls=None, bearer_token=…)`. |
| `05-OpenShell-Goose-Diagnostics-Live` | 🪿 goose | Agent runs **live read-only kubectl** in a scoped sandbox and writes a report. |
| `05b` / `05c` | 🪿 goose | The same live investigation, headless (client-credentials) / pure SDK. |
| `06-…-Snapshot` | 🪿 goose | goose over a **static** `kyma diagnose` snapshot — no live cluster access. |
| `07-…-FromReport` | 🪿 goose | Triage the **baked** `ClusterHealthReport` from [Exercise 1](../ex1/README.md). |
| `Cluster_Health` | ⚙️ ops | Standalone cluster-health walkthrough (kubectl + AI Core). |
| `Lorenz`, `Crank_Nicolson`, `Complex Location`, `Earthdata`, `JupyterLab APOD` | 🧪 upstream | Stock JupyterLab samples — a familiar playground (`Lorenz` is a quick "does my kernel work?" check). |

> [!NOTE]
> Notebooks are baked into the image and copied to your home at spawn — **open a fresh server to pick up any changes.** Full design notes (gating, auth variants) live in the platform repo: `docs/jupyterhub-notebooks-inventory.md`.

## Summary

You signed in to JupyterHub, optionally called **SAP AI Core from Python** through the proxy, then drove the full **OpenShell sandbox lifecycle** from the Python SDK and ran an **agent inside a sandbox** — live read-only `kubectl` and a static snapshot — watching the same read-only, no-egress guardrails that bound the CLI agent.  
You now have the sandboxed-agent pattern in Python, inside your own Kyma cluster.  
Continue to - [Exercise 5 - Your own sandboxed agent: the OpenShell CLI dance](../ex5/README.md)
