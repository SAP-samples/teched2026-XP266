# Appendix 3 - SAP AI Core from Python (JupyterHub notebooks)

👉 This is the **SAP AI Core track** of your JupyterHub playground.  
A full **JupyterHub** runs in your cluster, pre-loaded with notebooks and wired — like everything else — to **SAP AI Core through the LiteLLM proxy**.  
The proxy holds the SAP AI Core credentials, so your notebook never does: you get the OpenAI-compatible `client` and the model is one call away.

```
JupyterHub (in your cluster)
   │  your notebook (Python)
   ▼
openai client  ──▶  http://litellm-proxy.default:4001/v1  ──▶  SAP AI Core
                    (same proxy as every other exercise)
```

> [!NOTE]
> First spin up your server — the sign-in and **Start My Server** steps are in [Exercise 3.1](../../ex3/README.md#exercise-31---sign-in-and-spawn-your-server). This appendix picks up in JupyterLab with the notebooks open.

**Contents**

- 📓 [Walk the sample notebooks](#appendix-31---walk-the-sample-notebooks)
- 🐍 [Guided exercises](#appendix-32---guided-exercises-copy-paste-into-a-new-cell)
- ✨ [Create your own](#appendix-33---create-your-own)
- 📚 [The notebook set](#appendix-34---the-notebook-set)


## Appendix 3.1 - Walk the sample notebooks

1. Open **`00-SAP-AI-Core-Credentials.ipynb`** and run every cell (**Shift+Enter**, or *Run ▸ Run All Cells*).  
   It builds the `client` you'll reuse everywhere — no OAuth, no API key handling on your part.
<br>![](images/07_02_0010.png)

2. Open **`01-Bedrock-Models-via-SAP-AI-Core.ipynb`** and run all cells — you just called Claude on SAP AI Core, from Python, in your own cluster.

3. Open **`03-SAP-AI-Core-Model-Test.ipynb`** and run it to compare several models side by side.

> [!TIP]
> Every completion you run here shows up on the **spend dashboard** — go back and watch your own JupyterHub activity appear.

## Appendix 3.2 - Guided exercises (copy-paste into a new cell)

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
It reads the same diagnostic artifacts the Goose jobs produced in [Exercise 1](../../ex1/README.md) (the `ClusterHealthReport` / `goose-raw-*` resources) and analyzes them with SAP AI Core — the *jobs produce → notebook consumes* hand-off, now in Python you can extend.

## Appendix 3.3 - Create your own

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

## Appendix 3.4 - The notebook set

The SAP AI Core notebooks and the upstream JupyterLab samples pre-loaded in your JupyterHub:

| Notebook | Track | What it demonstrates |
|---|---|---|
| `00-SAP-AI-Core-Credentials` | ☁️ AI Core | Builds the `client` (proxy → SAP AI Core). **Run first** on this track. |
| `01-Bedrock-Models-via-SAP-AI-Core` | ☁️ AI Core | Chat completions against Claude models on SAP AI Core. |
| `02-Tool-Calling-Bedrock-via-SAP-AI-Core` | ☁️ AI Core | Function / tool calling. |
| `03-SAP-AI-Core-Model-Test` | ☁️ AI Core | Sweep several models and compare responses. |
| `Cluster_Health` | ☁️ AI Core | The Python hand-off — reads the Goose diagnostic artifacts from [Exercise 1](../../ex1/README.md) and analyzes them. |
| `Lorenz`, `Crank_Nicolson`, `Complex Location`, `Earthdata`, `JupyterLab APOD` | 🧪 upstream | Stock JupyterLab samples — a familiar playground (`Lorenz` is a quick "does my kernel work?" check). |

> [!NOTE]
> Notebooks ship in the image and are copied to your home at spawn — **open a fresh server to pick up any changes.**  
> The OpenShell sandbox notebooks (`04`–`07`) are in [Exercise 3](../../ex3/README.md#exercise-31---sign-in-and-spawn-your-server).

## Summary

You ran the pre-loaded SAP AI Core notebooks, did guided Python exercises (chat, embeddings, tool calling, and the diagnostic hand-off), and created your own notebook with a copy-paste connection snippet — a full Python playground against SAP AI Core running inside your own Kyma cluster.  
To drive **OpenShell sandboxes** from the same JupyterHub, see [Exercise 3](../../ex3/README.md).  
Back to - [Overview](../../../README.md)
