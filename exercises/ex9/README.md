# Exercise 9 - Your own sandboxed agent: the OpenShell CLI dance 🔧 *(advanced — CLI + admin access)*

> [!WARNING]
> **This is a bonus / advanced exercise, and it is admin-gated.** Unlike ex0–ex8, it needs the **`openshell` CLI** and an
> account in the operators' group — the OpenShell gateway only admits the `openshell-admin` role. **Run the CLI from your
> laptop** (it uses a browser-based login). If you're on a locked-down Windows laptop and can't install the CLI, or you
> don't have gateway access, **watch the instructor demo** — everything below is a live walk-through. *(A future
> convenience: the `openshell` CLI is already pre-installed in the [Busola web terminal](../ex2/README.md), but the
> deployed gateway version can't yet complete a browser-less login from that pod — so for now the terminal isn't a usable
> entry point.)* Nothing here is required to complete the workshop — you already finished it at
> [Exercise 8](../ex8/README.md).

[Exercise 6](../ex6/README.md) showed how the Busola web terminal is *fenced in* with **RBAC + a NetworkPolicy** — but it
still runs as an ordinary `exec` pod: those are guardrails *around* it, not kernel isolation. This exercise shows the next
step up: the **same tools image** (`goose` / Claude Code / kubectl / kyma / k9s) running **inside a runtime-isolated
`Sandbox`** — and an agent that can reason via SAP AI Core while being **physically unable** to touch the cluster API or
the public internet. **The sandbox itself is the guardrail.**

```
You (openshell CLI, laptop)
   │  OIDC-gated gRPC :8080  (port-forward)
   ▼
OpenShell gateway ──creates──▶ Sandbox pod (agent-sandbox, isolated)
   holds the key                 │  dev-toolbox-bash (goose / claude)
                                  │  POST https://inference.local  (placeholder key)
                                  ▼
                     supervisor injects the REAL key ──▶ LiteLLM :4001 ──▶ SAP AI Core
                                  ✗ apiserver   ✗ internet   ✗ other pods   (no direct route — proxy allowlist)
```

Two properties make this **contained**, not just isolated:
1. **The agent never holds the LLM credential.** It POSTs a *placeholder* `x-api-key` to `https://inference.local`; the
   OpenShell supervisor strips it, injects the real key (held by the gateway), and dials the proxy. Compromise the agent
   and you still don't get the key.
2. **Egress has exactly one exit, and it's an allowlist.** The sandbox runs in a network namespace with **no direct route
   out** — its only path is the supervisor's egress proxy, which allowlists `inference.local` (→ LiteLLM) and **denies
   everything else** (the apiserver, other workloads, the internet). This is built into the stock chart; there is no
   extra NetworkPolicy to configure. You'll prove it in 9.4.

## Exercise 9.1 - Get the CLI and reach the gateway

The gateway has a **stable HTTPS endpoint** — `openshell.<your-shoot>.<workshop-domain>` — so there's **no port-forward
to run**. It is **OIDC-gated**: it validates your Keycloak token itself.

1. Download the **`openshell`** CLI for your OS/arch from the [OpenShell releases](https://github.com/NVIDIA/OpenShell/releases)
   (match the deployed gateway version).
2. Register the gateway against Keycloak (a browser opens for single sign-on):
   ```bash
   openshell gateway add https://openshell.<your-shoot>.<workshop-domain> \
     --oidc-issuer https://keycloak.<your-shoot>.<workshop-domain>/realms/ateam-isveng \
     --oidc-client-id openshell-oidc
   #   already registered from a previous day? re-auth instead of add:
   #   openshell gateway login openshell
   ```
   > The gateway validates the JWT itself, so there's no extra API-gateway auth in front of it — just `--oidc-issuer`
   > to trigger the Keycloak browser login (Keycloak accepts the CLI's random loopback callback port; SAP IAS would not).
   >
   > *Fallback* — if your network can't reach the host: `kubectl -n openshell port-forward svc/openshell 8080:8080`, then
   > `openshell gateway add http://localhost:8080 …` (not `--local`, which is plaintext → `missing authorization header`).

## Exercise 9.2 - Wire the contained inference provider *(one-time, per gateway)*

This overrides the built-in `anthropic` provider to point at our in-cluster LiteLLM proxy, and hands the gateway the key.
The provider persists on the gateway's PVC, so this is done **once**.

```bash
# The provider profile lives in the platform repo: manifests/kro/openshell/litellm-provider.yaml
openshell provider profile lint   -f litellm-provider.yaml
openshell provider profile import -f litellm-provider.yaml --global

# Feed the LiteLLM key + base URL. The key only ever lives in the gateway.
KEY=$(kubectl get secret llm-proxy-credentials -n default -o jsonpath='{.data.PROXY_API_KEY}' | base64 -d)
openshell provider create --name litellm --type anthropic \
  --credential ANTHROPIC_API_KEY="$KEY" \
  --config ANTHROPIC_BASE_URL=http://litellm-proxy.default.svc.cluster.local:4001

openshell inference set --provider litellm --model anthropic--claude-4.7-opus --no-verify
#   → Route: inference.local
```

## Exercise 9.3 - Create a sandbox from the tools image and use it

```bash
openshell sandbox create --name mybox \
  --from localhost:32137/dev-toolbox-bash:latest --provider litellm -- sleep infinity
openshell sandbox list
```

Now prove the contained agent reasons through SAP AI Core — with only a **placeholder** key:

Command:
```bash
openshell sandbox exec --name mybox -- \
  curl -sS -XPOST https://inference.local/v1/messages -k \
  -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
  -H 'x-api-key: sk-ant-placeholder00000000000000000000000000000000000000000000' \
  -d '{"model":"anthropic--claude-4.7-opus","max_tokens":16,"messages":[{"role":"user","content":"Reply OK"}]}'
```
Output:
```json
{"id":"msg_bdrk_...","model":"anthropic--claude-4.7-opus", ... "content":[{"type":"text","text":"OK"}] ... }
```

> [!TIP]
> The `msg_bdrk_` id prefix is your proof the request round-tripped **SAP AI Core** (Bedrock). The agent sent a
> placeholder; the gateway injected the real key.

Now drop into an interactive shell and drive **Claude Code** from *inside* the isolated sandbox. The box is contained,
so you must point Claude at its one allowed endpoint (`inference.local`) — the image's baked config points at a host the
sandbox can't reach:

```bash
openshell sandbox connect mybox          # → goose@default--mybox:~$

# ...then, inside the sandbox, repoint Claude Code at the contained endpoint and use it:
export ANTHROPIC_BASE_URL=https://inference.local
export ANTHROPIC_AUTH_TOKEN=placeholder      # the gateway injects the real key; you send a placeholder
export NODE_TLS_REJECT_UNAUTHORIZED=0        # inference.local is self-signed (same reason curl needs -k)
claude -p "In one line, what is Kyma?"
```

> [!NOTE]
> It's a **reasoning box, not an ops shell**: `kubectl` / `kyma` / `k9s` are installed but **inert** (no cluster token,
> no route to the API server — you'll prove that in 9.4). For an agent whose `kubectl`/`kyma` actually reach the cluster,
> use the Busola web terminal ([Exercise 2](../ex2/README.md)); the sandbox trades cluster access for hard isolation.

## Exercise 9.4 - See the guardrail hold

The whole point: from **inside** the sandbox, the cluster API and the internet are unreachable. Two layers stack —
(1) the sandbox has **no service-account token and no cluster CA**, so nothing can even *authenticate* to the API; and
(2) it has **no direct network route out at all** — its only egress is the supervisor proxy, which **allowlists
`inference.local` and 403s everything else**. A bare `kubectl` won't demonstrate this cleanly (with no KUBECONFIG it just
hits `localhost:8080`), so probe the network directly with `curl`.

**Probe A — try to reach the apiserver (through the proxy, the normal path):**
```bash
openshell sandbox exec --name mybox -- bash -c \
  'curl -sS -m 5 -o /dev/null -w "apiserver=%{http_code}\n" http://kubernetes.default.svc/version; echo "exit=$?"'
```
Result — the supervisor proxy **denies** it:
```
apiserver=403        # the proxy returns its own 403 — the apiserver is NOT on the allowlist
exit=0
```
(Over HTTPS the same denial shows as `curl: (56) CONNECT tunnel failed, response 403` — the proxy refusing the `CONNECT`.)

**Probe B — try to bypass the proxy and dial anything directly:**
```bash
openshell sandbox exec --name mybox -- bash -c \
  'echo "HTTPS_PROXY=$HTTPS_PROXY"; \
   curl -sS -m 5 -k --noproxy "*" -o /dev/null -w "direct=%{http_code}\n" https://kubernetes.default.svc/version; echo "exit=$?"'
```
Result — there is **no direct route**; even DNS resolution times out:
```
HTTPS_PROXY=http://10.200.0.1:3128
curl: (28) Resolving timed out after 5000 milliseconds
direct=000
exit=28
```

**Probe C — the LLM key never enters the sandbox:**
```bash
openshell sandbox exec --name mybox -- printenv | grep -iE 'ANTHROPIC|_KEY|PROXY' || echo "no LLM credential in the sandbox env"
```
The real key is **absent** — the gateway injects it only at egress, so the agent only ever holds the placeholder. (With
an admin kubeconfig you can also confirm the sandbox's service account can't read it:
`kubectl auth can-i get secrets --as=system:serviceaccount:openshell:openshell-sandbox -n openshell` → **no**.)

So the sandbox can reach **only** `inference.local` (→ LiteLLM → SAP AI Core) plus DNS *via the proxy* — the apiserver,
other workloads, and the public internet are all unreachable, whether you go through the proxy (403) or try to skip it
(no route). That containment is **native to the stock OpenShell chart** — no NetworkPolicy required — a stronger boundary
than [Exercise 6](../ex6/README.md)'s RBAC-fenced Busola terminal, which is still an ordinary pod on the cluster network.
Clean up when done:

```bash
openshell sandbox delete mybox
```

## Why this matters — what a contained sandbox is *for*

This is **not** an ops shell — that's the Busola terminal ([Exercise 2](../ex2/README.md)), whose `kubectl` actually
drives the cluster. The sandbox's superpower is the opposite: **containment for _execution_.** You can let an AI agent
write and *run* code with no way to touch the cluster, other workloads, or the internet, and without ever handing it a
credential. Rule of thumb: **Busola terminal = an agent that _does things to_ the cluster; sandbox = an agent that
_computes things you don't fully trust_.** Where that's valuable:

- **Code-interpreter / analysis backend** — the agent runs the code it writes, safely (data crunching, transforms, tests).
- **Processing untrusted input** (docs, emails, tickets) — even a prompt-injected agent can't exfiltrate or pivot.
- **Per-user isolation** — each session its own sandbox + quota + network namespace, auto-reaped after use.
- **Reproducible, disposable runs** — fresh from a pinned image, gone after; no state leak.

> [!NOTE]
> **Using an agent inside the sandbox:** the image's auto-login only works where there's cluster access (the Busola
> terminal). In the *contained* sandbox you point the agent at `inference.local` yourself — the `export …` block in
> Exercise 9.3. **Claude Code works** that way (verified); **goose doesn't** (with no cluster access its config falls back
> to `localhost:4000`, and it can't use the Anthropic-native `inference.local`) — so inside the sandbox use `claude` or
> the raw `curl https://inference.local/v1/messages`.

## The options on the table — three containment tiers

OpenShell lets you dial *exactly* how much an agent can reach, per sandbox — from "compute-only" to "reads the cluster":

| Tier | Egress | Cluster access | Good for |
|---|---|---|---|
| **Contained** (this exercise) | `inference.local` only | none | run/execute untrusted code + reason — zero blast radius |
| **Scoped-ops** *(advanced/admin)* | + apiserver (read-only), still no internet | read-only `kubectl` | a diagnostic agent that *reads* the cluster and reasons |
| **Busola terminal** ([Exercise 2](../ex2/README.md)) | full pod network | RBAC-scoped `kubectl` | an agent that *operates* the cluster |

Tiers are set by the sandbox's **L7 network policy** (`openshell policy set`) plus auth: contained is the default; scoped-ops
adds an apiserver rule + a short-lived **read-only** token (the agent can `kubectl get` but not mutate, and still can't reach
the internet); the Busola terminal is a separate, RBAC-scoped surface. Same agent image, three trust levels.

### How the credential injection works (why the agent never holds a key)
The heart of the containment: the agent reasons via SAP AI Core **without ever seeing a credential**. The LLM **provider**
(configured once, on the gateway) holds the real key. Inside the sandbox the agent sends its request to `https://inference.local`
with a **placeholder** (`x-api-key: placeholder`). The sandbox's L7 proxy — which knows the provider's real credential, bound
to that one endpoint — **rewrites the placeholder with the real key** at the last moment before forwarding upstream to the
LiteLLM proxy → SAP AI Core. So the secret lives only in the gateway; compromise the agent and all you get is the placeholder.
You proved exactly this in 9.3: an `x-api-key: placeholder` request still came back with a real `msg_bdrk_…` completion.

## Summary

You ran the workshop's tools image as a **runtime-isolated OpenShell `Sandbox`**, wired it to a **contained** inference
provider (the agent never held the key), and proved the egress guardrail: the apiserver and the internet are unreachable —
denied by the supervisor proxy's allowlist, with no direct route to bypass it — while the agent still reasons through SAP
AI Core. This is the strongest containment tier in the stack — *the sandbox is the guardrail* — built entirely on the
**stock** OpenShell chart, no custom fork and no extra network config.

Back to - [Overview](../../README.md)
