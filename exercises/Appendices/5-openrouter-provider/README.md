# Appendix 5 - External agents & the OpenRouter provider model

👉 The concept behind the OpenRouter hands-on in [Exercise 5](../../ex5/README.md): how an **external, keyed provider** plugs into the OpenShell sandbox model (profile → provider → sandbox), and how OpenRouter compares to the in-cluster SAP AI Core path.

**Contents**

- 🧩 [How it works: profile → provider → sandbox](#how-it-works--profile--provider--sandbox)
- 🔀 [OpenRouter vs SAP AI Core](#openrouter-vs-sap-ai-core--the-same-shape-to-litellm)

---

## How it works — profile → provider → sandbox

Three concepts, one key that never leaves the gateway:

- **Profile** — a reusable *spec* (no secret): which credential env var, which auth style, which **endpoints** egress
  may reach, and which **binaries** are allowed to use the credential.
- **Provider** — a profile **bound to a real key**. The key (`sk-or-…`) is stored **only in the gateway**.
- **Sandbox** — `--provider openrouter` attaches it: the box receives a **sentinel** (not the key) + scoped egress;
  the supervisor swaps the sentinel for the real key **at the wire**, only for a listed binary → a listed endpoint.

```
                   ┌──────────────────── OpenShell gateway (holds the real key) ────────────────────┐
  PROFILE          │  profile "openrouter"                                                           │
  (template:       │    credential: OPENROUTER_API_KEY (bearer)                                      │
   what & where)   │    endpoints : openrouter.ai, models.dev   ← the ONLY hosts egress is opened to │
                   │    binaries  : node, opencode.exe          ← only THESE may send egress traffic │
  PROVIDER         │  provider "openrouter" = profile + REAL KEY (sk-or-…)   ← key lives ONLY here    │
  (profile + key)  └───────────────────────────────────┬─────────────────────────────────────────────┘
                           sandbox create --provider openrouter
                                                        ▼
                   ┌──────────────────────── your sandbox (the box) ─────────────────────────┐
  SANDBOX          │  OPENROUTER_API_KEY = openshell:resolve:…   ← a SENTINEL, not the key    │
  (--provider      │  agent (opencode / pi / qwen)  ──▶  Authorization: Bearer <sentinel>     │
   attaches it)    └───────────────────────────────────────┬───────────────────────────────────┘
                                                            ▼  (allowed binary + allowed host)
                        supervisor swaps  <sentinel> → sk-or-…  AT THE WIRE
                                                            ▼
                                                      openrouter.ai   (sees the real key; the box never did)
```

One image, three agents (all installed in `openrouter-agents:latest`):

| Agent | What it is | Run it |
|---|---|---|
| **opencode** | [opencode.ai](https://opencode.ai) coding agent (Bun binary) | `opencode run -m openrouter/<model> "…"` (headless) or `opencode` (TUI) |
| **Pi** | `@earendil-works/pi-coding-agent` | `pi -p --model openrouter/<model> "…"` (headless) or `pi` (TUI) |
| **Qwen Code** | `@qwen-code/qwen-code` (OpenAI-compat) | `qwen` (TUI) — reads `OPENAI_MODEL`/`OPENAI_BASE_URL` (pre-set in the box) |

## OpenRouter vs SAP AI Core — the same shape to LiteLLM

**OpenRouter** is a public LLM *aggregator*: one OpenAI-compatible endpoint + one key, routing to many models
(OpenAI, Anthropic, Google, Qwen, NVIDIA…).  
**SAP AI Core** is SAP's
managed inference gateway, reached in-cluster through the **LiteLLM proxy**.  
To LiteLLM they're the **same shape** (an
OpenAI-compatible gateway behind one credential) — and LiteLLM has a native `openrouter/…` route, so a single
in-cluster LiteLLM proxy can be pointed at **either** AI Core or OpenRouter.  
The one thing that does **not** work: **OpenRouter cannot call SAP AI Core.**  
OpenRouter only routes to its own public
upstreams and can't reach our in-cluster LiteLLM proxy — the arrow is always LiteLLM → (AI Core | OpenRouter), never
the reverse.

| | SAP AI Core (in-cluster) | OpenRouter (this exercise — **direct**) |
|---|---|---|
| Path | agent → LiteLLM proxy → **SAP AI Core** | agent → **OpenRouter** (one allow-listed external host) |
| Key in box | **sentinel** (real key in the gateway) | **sentinel** (real key in the gateway) |
| Internet | none | one host: `openrouter.ai` |

This exercise keeps the agent talking to OpenRouter **directly** — that external, allow-listed, keyed endpoint *is* the 4th
tier.  
(In production you'd often put OpenRouter *behind* LiteLLM too — one in-cluster exit, spend-tracked, key never
leaves the proxy — but then it looks just like the in-cluster path.)

> [!TIP]
> **Picking a `:free` model.** The agents are *agentic*, so the model must be a **chat/completion model with
> tool-calling**. **Embedding and rerank models won't work** (ids with `-embed-` / `-rerank-` are RAG parts, not chat
> — the agent will error). The `:free` lineup **rotates** (models go paid without notice — `qwen/qwen3.8-27b:free` did). Known-good free picks (NVIDIA Nemotron):
> **`nvidia/nemotron-3-ultra-550b-a55b:free`** and **`nvidia/nemotron-3.5-lightning:free`**. Find current ones at
> [openrouter.ai/models?max_price=0&q=nvidia](https://openrouter.ai/models?max_price=0&q=nvidia). This
> exercise replicates NVIDIA's [*Run Pi with OpenRouter*](https://docs.nvidia.com/openshell/latest/tutorials/run-pi-with-openrouter).

Back to - [Overview](../../../README.md)
