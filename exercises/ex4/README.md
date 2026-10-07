# Exercise 4 - JupyterHub playground: SAP AI Core from Python

This is your **open playground**.

A full **JupyterHub** is running in your cluster, pre-loaded with notebooks, and — like every other component — wired to **SAP AI Core through the LiteLLM proxy**.

Here you run the sample notebooks, do a few guided Python exercises, and then **create your own**.

It's a safe sandbox: experiment freely, nothing you do here affects the rest of the workshop.

```
JupyterHub (in your cluster)
   │  your notebook (Python)
   ▼
openai client  ──▶  http://litellm-proxy.default:4001/v1  ──▶  SAP AI Core
                    (same proxy as every other exercise)
```

## Exercise 4.1 - Sign in and spawn your server

1. Open your JupyterHub URL in the browser (handed out with your runtime), e.g.:

   ```
   https://jupyterhub.xp266-NNN.<workshop-domain>/
   ```
   Sign in with single sign-on and click **Start My Server**. After a moment JupyterLab opens.
<br>![](images/07_01_0010.png)

2. In the file browser (left) you'll find the **pre-loaded notebooks**:

   | Notebook | What it shows |
   |---|---|
   | `00-SAP-AI-Core-Credentials.ipynb` | Establishes the `client` — the OpenAI-compatible connection to the LiteLLM proxy. **Run this first.** |
   | `01-Bedrock-Models-via-SAP-AI-Core.ipynb` | Chat completions against Claude models on SAP AI Core |
   | `02-Tool-Calling-Bedrock-via-SAP-AI-Core.ipynb` | Function / tool calling |
   | `03-SAP-AI-Core-Model-Test.ipynb` | Sweep several models and compare responses |
   | `Cluster_Health.ipynb` | **The hand-off:** reads the Goose diagnostic output (ex1) and analyzes it in Python |

## Exercise 4.2 - Walk the sample notebooks

1. Open **`00-SAP-AI-Core-Credentials.ipynb`** and run every cell (**Shift+Enter**, or *Run ▸ Run All Cells*). It builds the `client` you'll reuse everywhere — no OAuth, no API key handling on your part.
<br>![](images/07_02_0010.png)

2. Open **`01-Bedrock-Models-via-SAP-AI-Core.ipynb`** and run all cells. You just called Claude on SAP AI Core, from Python, in your own cluster.

3. Open **`03-SAP-AI-Core-Model-Test.ipynb`** and run it to compare several models side by side.

> [!TIP]
> Every completion you run here shows up on the **spend dashboard** from [Exercise 3](../ex3/README.md) — go back and watch your own JupyterHub activity appear.

## Exercise 4.3 - Guided exercises (copy-paste into a new cell)

After running `00-SAP-AI-Core-Credentials` (so `client` exists), try these.

Each is self-contained — paste into a new cell and **Shift+Enter**.

**A - List the models the proxy can route to:**
```python
for m in client.models.list().data:
    print(m.id)
```

**B - A chat completion (routine tier):**
```python
resp = client.chat.completions.create(
    model="reasoning-fast",                       # Claude Sonnet on SAP AI Core
    messages=[{"role": "user",
               "content": "In two sentences, what is SAP BTP, Kyma runtime?"}],
)
print(resp.choices[0].message.content)
```

**C - Embeddings + cosine similarity:**
```python
import numpy as np
texts = ["Kubernetes pod", "a container workload", "quarterly sales report"]
vecs = [e.embedding for e in
        client.embeddings.create(model="text-embedding-3-small", input=texts).data]
def cos(a, b): a, b = np.array(a), np.array(b); return a @ b / (np.linalg.norm(a) * np.linalg.norm(b))
print("pod vs container:", round(cos(vecs[0], vecs[1]), 3))   # high — related
print("pod vs sales:    ", round(cos(vecs[0], vecs[2]), 3))   # low  — unrelated
```

**D - Tool / function calling:**
```python
tools = [{"type": "function", "function": {
    "name": "get_pod_count", "description": "Return the number of pods in a namespace",
    "parameters": {"type": "object", "properties": {"namespace": {"type": "string"}},
                   "required": ["namespace"]}}}]
resp = client.chat.completions.create(
    model="reasoning-fast",
    messages=[{"role": "user", "content": "How many pods are in the default namespace?"}],
    tools=tools,
)
print(resp.choices[0].message.tool_calls)   # the model asks to CALL your function, with arguments
```

**E - The hand-off in Python:** open and run **`Cluster_Health.ipynb`**.

It reads the same diagnostic artifacts the Goose jobs produced in [Exercise 1](../ex1/README.md) (the `ClusterHealthReport` / `goose-raw-*` resources) and analyzes them with SAP AI Core — the *jobs produce → notebook consumes* hand-off, now in Python you can extend.

## Exercise 4.4 - Create your own

Open **File ▸ New ▸ Notebook** (pick the Python 3 kernel) and start experimenting.

Paste this once to connect — it mirrors what `00-SAP-AI-Core-Credentials` does — then the model is one call away:

```python
import os, base64
from kubernetes import client as k8s, config
from openai import OpenAI

config.load_incluster_config()
key = base64.b64decode(
    k8s.CoreV1Api().read_namespaced_secret("llm-proxy-credentials", "default")
    .data["PROXY_API_KEY"]).decode()

client = OpenAI(base_url="http://litellm-proxy.default.svc.cluster.local:4001/v1", api_key=key)
print("connected:", [m.id for m in client.models.list().data][:5])
```

> [!TIP]
> Ideas to try: ask a model to **explain a `kubectl get events` dump** you paste in; build a tiny **retrieval** demo with embeddings over a handful of docs; have the model **draft a NetworkPolicy** from a plain-English description; or chain a **tool call** to a real `kubernetes` client read. The proxy, the models, and the spend tracking are all already there — just write Python.

> [!NOTE]
> This is the same LLM path as every other exercise — the `openai` client simply points at the in-cluster LiteLLM proxy. Anything you prototype here uses the exact routing, auth, and cost-tracking that the production agents use.

## Exercise 4.5 - The full notebook set (what else is pre-loaded)

Beyond the SAP AI Core notebooks above, your JupyterHub is pre-loaded with the **OpenShell agent** notebooks — the Python
twins of [Exercise 5](../ex5/README.md) — plus a few upstream JupyterLab samples.

| Notebook | What it demonstrates |
|---|---|
| `00`–`03`, `Cluster_Health` | SAP AI Core from Python (the notebooks above). |
| `04-OpenShell-Sandbox-SDK` | Drive an OpenShell sandbox (create → exec → delete) via the **Python SDK** — gateway registered with a CLI device-code login. |
| `04b-OpenShell-Sandbox-SDK-Headless` | The same lifecycle, **pure SDK, no CLI** — connects straight to the in-cluster gateway (`tls=None` + a self-minted bearer token). |
| `05-OpenShell-Goose-Diagnostics-Live` | An agent (**goose**) runs **live read-only kubectl** inside a scoped sandbox and writes a health report — the notebook twin of ex5's `scoped-ops`. |
| `05b` / `05c` | The same live-goose investigation, headless (client-credentials) / via the **pure SDK**. |
| `06` / `07` | goose over a **static** cluster snapshot / over the **baked** health reports from [Exercise 1](../ex1/README.md). |
| `Lorenz`, `2013-12-03-Crank_Nicolson`, `Complex Location`, `Earthdata`, `JupyterLab APOD` | Upstream JupyterLab sample notebooks — a familiar playground (`Lorenz` is a nice "does my kernel work?" check). |

> The `04`/`05` OpenShell notebooks are **advanced** and need OpenShell on your cluster — pair them with
> [Exercise 5](../ex5/README.md). Full design notes for every notebook (gating, auth variants, us-vs-teched) live in the
> platform repo: `docs/jupyterhub-notebooks-inventory.md`.

## Summary

You signed in to JupyterHub, ran the pre-loaded SAP AI Core notebooks, did guided Python exercises (chat, embeddings, tool calling, and the diagnostic hand-off), and created your own notebook with a copy-paste connection snippet.

You now have a full, safe Python playground against SAP AI Core running inside your own Kyma cluster.

Continue to - [Exercise 5 - Your own sandboxed agent: OpenShell on Kyma](../ex5/README.md)
