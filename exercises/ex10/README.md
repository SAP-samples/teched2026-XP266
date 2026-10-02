# Exercise 10 - External agents: Pi, opencode & Qwen via OpenRouter 🔧 *(advanced — CLI)*

> [!WARNING]
> **Advanced / builds on [Exercise 9](../ex9/README.md).** You need the `openshell` CLI (pre-installed in the Busola
> web terminal) and an active gateway session (ex9 §9.1, device-code login). If you don't have the `openshell-admin`
> role, watch the instructor demo. Everything runs on **your own** `xp266-NNN` runtime.

In Exercise 9 the sandbox had **no internet** — its only exit was the in-cluster LiteLLM proxy, and §9.4 *proved* the
agent couldn't reach the apiserver or the public web. This exercise flips exactly one dial: a **4th trust tier** — a
still-contained sandbox with **one external endpoint allow-listed** (`openrouter.ai`), so you can drive terminal
coding agents against public **OpenRouter** models. The real OpenRouter key never enters the box: it lives in the
gateway's `openrouter` **provider**, which injects a **resolve-sentinel** and swaps the real key at egress — and
*only* for the agent binaries named in the provider profile (binary-scoped injection).

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
| **Qwen Code** | `@qwen-code/qwen-code` (OpenAI-compat) | `qwen` (TUI) — reads `OPENAI_API_KEY`/`OPENAI_BASE_URL` (pre-set in the box) |

## Exercise 10.1 - Inspect the pieces (UI)

1. In Busola, open **namespace `openshell` → Custom Resources** and find the pre-built image build (`KanikoAgent`
   `kaniko-agent`) and the `openrouter` provider (it's created by the provider-setup Job because your runtime was
   given a shared OpenRouter key). The agents image is pushed to the in-cluster registry as
   `openrouter-agents:latest`.

> [!NOTE]
> The OpenRouter key is **shared and platform-provided** for the workshop — you never handle it. Use the `:free`
> models (they cost nothing). The gateway holds the key; your sandbox only ever sees `openshell:resolve:…`.

## Exercise 10.2 - Create a sandbox with the agents + OpenRouter 🔧

In a web terminal (ex2), with your gateway session active (ex9 §9.1):

Command:
```bash
openshell sandbox create --name agents \
  --from localhost:32137/openrouter-agents:latest \
  --provider openrouter \
  --env OPENAI_BASE_URL=https://openrouter.ai/api/v1 \
  --env OPENAI_MODEL=qwen/qwen3.8-27b:free \
  --detach -- sleep infinity
openshell sandbox list        # wait for PHASE=Ready
```
`--provider openrouter` grants the sandbox egress to `openrouter.ai` (+ `models.dev`) **for the agent binaries only**
and injects the key sentinel. `--env` passes the base URL + default model (OpenAI-compat agents need them).

## Exercise 10.3 - Run an agent against a free model 🔧

Command (opencode — the cleanest):
```bash
openshell sandbox exec --name agents -- opencode run -m openrouter/qwen/qwen3.8-27b:free "Reply with one word: PONG"
```
Output:
```
PONG
```
Try Pi too:
```bash
openshell sandbox exec --name agents -- pi -p --model openrouter/qwen/qwen3.8-27b:free "List 3 facts about Kyma."
```

> [!TIP]
> **Pick a model:** `openshell sandbox exec --name agents -- curl -s https://openrouter.ai/api/v1/models | grep -o '"id":"[^"]*:free"'`
> lists the free models. opencode/Pi take `openrouter/<id>`. Qwen Code (`qwen`, interactive) uses whatever
> `OPENAI_MODEL` you set at create — some models reject its tool-calling request shape, so if `qwen` errors `400`,
> switch `OPENAI_MODEL` to another `:free` model and recreate the sandbox.

## Exercise 10.4 - Prove it's still contained 🔧

The agent reaches OpenRouter — and **nothing else**:

Command:
```bash
openshell sandbox exec --name agents -- sh -c 'curl -sS -m8 -o /dev/null -w "openrouter.ai: %{http_code}\n" https://openrouter.ai/api/v1/models; curl -sS -m8 https://example.com >/dev/null 2>&1 && echo "example.com: REACHED" || echo "example.com: blocked"; curl -sS -m8 https://kubernetes.default.svc >/dev/null 2>&1 && echo "apiserver: REACHED" || echo "apiserver: blocked"; echo "key in box: $OPENROUTER_API_KEY"'
```
Output:
```
openrouter.ai: 200
example.com: blocked
apiserver: blocked
key in box: openshell:resolve:env:…      ← a sentinel, NOT the real key
```

So this is a *different* tier than ex9, not a weaker one:

| | ex9 (scoped-ops) | **ex10 (external agent)** |
|---|---|---|
| LLM | in-cluster LiteLLM → SAP AI Core (keyless) | **public OpenRouter (keyed, key in gateway only)** |
| Egress | in-cluster proxy only; **no internet** | **`openrouter.ai` + `models.dev` only; nothing else** |
| Cluster | read-only kubectl (sandbox-viewer) | none |
| Key in box | sentinel | sentinel |

Clean up: `openshell sandbox delete agents`

## Summary

You added an **external, keyed** LLM provider to the contained-sandbox model, ran three different terminal coding
agents (opencode, Pi, Qwen Code) against free OpenRouter models, and proved the sandbox still can't reach anything
but the one allow-listed endpoint — with the real key staying in the gateway. That's the OpenShell provider model
generalizing from "keyless in-cluster" to "any governed external endpoint."

Back to - [Overview](../../README.md)
