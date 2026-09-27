# Exercise 9 - Your own sandboxed agent: OpenShell on Kyma 🔧 *(advanced — CLI + admin access)*

> [!WARNING]
> **This is a bonus / advanced exercise, and it is admin-gated.** Unlike ex0–ex8, it needs the **`openshell` CLI** and an
> account in the operators' group — the OpenShell gateway only admits the `openshell-admin` role. You can run the CLI two
> ways: **(a) from your laptop** (a browser opens for single sign-on), or **(b) from the [Busola web terminal](../ex2/README.md)**,
> where `openshell` is **pre-installed** — handy on locked-down Windows laptops with nothing to install; it uses a
> **device-code login** since the terminal pod has no browser (see the two paths in 9.1). If you don't have the
> `openshell-admin` role, **watch the instructor demo** — everything below is a live walk-through. Nothing here is required
> to complete the workshop — you already finished it at [Exercise 8](../ex8/README.md).

**Contents:** [Why OpenShell](#why-openshell) · [Common risks & controls](#common-risks-and-controls) ·
[Protection layers](#protection-layers-at-a-glance) · [Common use cases](#common-use-cases) —
[Hands-on 9.1–9.5](#hands-on-the-openshell-cli-dance) — [Deep dive: Architecture](#deep-dive-architecture) ·
[How components authenticate](#how-components-authenticate) · [Glossary](#glossary)

---

## Why OpenShell

AI agents are most useful when they can read files, install packages, call APIs, and use credentials. **That same access
is the risk.** [Exercise 6](../ex6/README.md) fenced the Busola web terminal with **RBAC + a NetworkPolicy** — but it's
still an ordinary `exec` pod: those are guardrails *around* it, not isolation *of* it. OpenShell takes the next step —
**preserve the agent's capability, but enforce explicit controls** — by running the **same tools image**
(`goose` / Claude Code / kubectl / kyma / k9s) inside a **runtime-isolated `Sandbox`** where the agent can reason via SAP
AI Core yet is **physically unable** to touch the cluster API or the public internet. **The sandbox itself is the guardrail.**

```
You (openshell CLI, laptop or Busola web terminal)
   │  OIDC-gated gRPC  (Keycloak validates who you are)
   ▼
OpenShell gateway ──creates──▶ Sandbox pod (agent-sandbox, isolated)
   holds the key                 │  dev-toolbox-bash (goose / claude)
                                  │  POST https://inference.local  (placeholder key)
                                  ▼
                     supervisor injects the REAL key ──▶ LiteLLM :4001 ──▶ SAP AI Core
                                  ✗ apiserver   ✗ internet   ✗ other pods   (no direct route — proxy allow-list)
```

Two properties make this **contained**, not merely isolated:
1. **The agent never holds the LLM credential.** It POSTs a *placeholder* to `https://inference.local`; the OpenShell
   supervisor swaps in the real key (held by the gateway) at egress. Compromise the agent and you still don't get the key.
2. **Egress has exactly one exit, and it's an allow-list.** The pod runs in a network namespace with **no direct route
   out**; its only path is the supervisor proxy, which allow-lists `inference.local` and **denies everything else**
   (apiserver, other pods, internet). No extra NetworkPolicy — it's native to the stock chart. You'll prove it in 9.4.

Rule of thumb for the whole workshop: **Busola terminal ([ex2](../ex2/README.md)) = an agent that *does things to* the
cluster; OpenShell sandbox = an agent that *computes things you don't fully trust*.**

### Common risks and controls

OpenShell neutralises the familiar agent risks **by construction** — not by asking the model to behave:

| Threat | Without controls | With OpenShell on Kyma |
|---|---|---|
| **Data exfiltration** | agent uploads code/context to any endpoint | **no route out** — the L7 allow-list resolves/permits only `inference.local` (→ LiteLLM → SAP AI Core); everything else 403s or fails to resolve (proved in 9.4) |
| **Credential theft** | agent reads the LLM key, SSH keys, cloud creds | the LLM key is **never in the box** — placeholder in, real key injected at egress; `readOnlyRootFilesystem` + **Landlock** confine the filesystem to declared paths |
| **Unauthorized API usage** | agent sends data to unapproved model providers | **provider profiles + policy** pin model traffic to our in-cluster LiteLLM → SAP AI Core |
| **Privilege escalation** | `sudo`, setuid, dangerous syscalls | **non-root** identity (uid 1000), **drop ALL** capabilities, `seccomp: RuntimeDefault`, `allowPrivilegeEscalation: false` |
| **Reading cluster secrets** | broad RBAC | contained tier holds **no cluster token at all**; scoped-ops tier is **read-only with `secrets` excluded** |
| **Mutating the cluster** | a read-write token | scoped-ops injects a **read-only** token (`get`/`list`/`watch`); writes → 403 |

### Protection layers at a glance

OpenShell applies **defense in depth** across four policy domains — some locked at creation, some hot-reloadable:

| Layer | Protection target | When applied | On our sandboxes |
|---|---|---|---|
| **Filesystem** | reads/writes outside allowed paths | locked at sandbox creation | `filesystem_policy` (read-only `/usr`,`/etc`,… · read-write `/sandbox`,`/tmp`) + **Landlock** (`best_effort`) + `readOnlyRootFilesystem` |
| **Network** | unauthorized outbound connections | **hot-reloadable at runtime** | the L7 allow-list (`openshell policy set`) — `inference.local` (contained) → + apiserver/LiteLLM (scoped-ops) |
| **Process** | privilege escalation, dangerous syscalls | locked at sandbox creation | non-root uid 1000, `drop [ALL]` caps, `seccomp: RuntimeDefault`, no privilege escalation |
| **Provider credentials** | resolve credential placeholders **only** at profile-authorized endpoints | runtime (new vars need a new process) | the supervisor swaps the placeholder/sentinel for the real key **only** on the provider's declared endpoint |

### Common use cases

| Use case | What it looks like here |
|---|---|
| **Secure coding / reasoning agents** | run Claude Code or goose with constrained file + network access — a code-interpreter / analysis backend that runs the code it writes, safely |
| **Processing untrusted input** | feed it docs / emails / tickets — even a prompt-injected agent can't exfiltrate (no egress but the LLM) or pivot (no cluster/creds) |
| **Private / self-hosted models** | the agent reasons via the in-cluster **LiteLLM → SAP AI Core**, never the public internet |
| **Compliance & audit** | the policy YAML (`sandbox-policy-*.yaml`) is **version-controlled security controls** — reviewable as a diff |
| **Per-user isolation & reproducible runs** | each session its own sandbox + quota + network namespace, auto-reaped; fresh from a pinned image, gone after — no state leak |
| **Scoped-ops diagnostics** | a read-only cluster view for an agent that *inspects* and reasons, but never mutates (9.5) |

---

## Hands-on: the OpenShell CLI dance

You'll register the gateway (9.1), wire the contained inference provider once (9.2), create a contained sandbox and drive
an agent inside it (9.3), prove the guardrail holds (9.4), then open the read-only **scoped-ops** tier (9.5).

### 9.1 - Get the CLI and reach the gateway

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

#### From the Busola web terminal instead — no local install (device-code login)

If you can't (or don't want to) install the CLI locally — e.g. a locked-down Windows laptop — the **`openshell` CLI is
pre-installed in the [Busola web terminal](../ex2/README.md)**. The terminal runs *inside* the cluster, so you target the
gateway's in-cluster Service directly (no HTTPS host, no port-forward). Because the terminal pod has **no browser**, the
loopback single-sign-on used above can't run there — so trigger the **device-code (headless) login** with `OPENSHELL_NO_BROWSER=1`:

```bash
OPENSHELL_NO_BROWSER=1 openshell gateway add http://openshell.openshell.svc.cluster.local:8080 \
  --oidc-issuer https://keycloak.<your-shoot>.<workshop-domain>/realms/ateam-isveng \
  --oidc-client-id openshell-oidc
```

It prints a verification URL and a short code, then waits:

```
To authenticate, visit:
  https://keycloak.<your-shoot>.<workshop-domain>/realms/ateam-isveng/device?user_code=XXXX-XXXX
Waiting for authorization...
```

Open that URL in your **laptop's** browser, sign in (you must hold the **`openshell-admin`** role), and the terminal unblocks:

```
✓ Authenticated via device code
```

Now `openshell sandbox list` works from the terminal — continue with 9.2 exactly as below. (Re-auth later with
`OPENSHELL_NO_BROWSER=1 openshell gateway login openshell`.)

### 9.2 - Wire the contained inference provider *(one-time, per gateway)*

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

# Second provider — for goose. goose can't use claude's /v1/messages route (it streams; the SAP path doesn't), so it
# reaches the SAME proxy over the OpenAI-compat /v1/chat/completions path with bearer auth. Also keyless — the gateway
# holds the key; the box gets only a sentinel. (Attached by scoped-ops in 9.5. See "Two providers, both keyless" below.)
openshell provider profile import -f litellm-openai-provider.yaml --global
openshell provider create --name litellm-openai --type litellm-openai --credential LITELLM_API_KEY="$KEY"

openshell inference set --provider litellm --model anthropic--claude-4.7-opus --no-verify
#   → Route: inference.local  (this default route is claude's; goose uses the litellm-openai endpoint directly)
```

### 9.3 - Create a sandbox from the tools image and use it

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
export ANTHROPIC_AUTH_TOKEN=placeholder      # sent as 'Authorization: Bearer'; the supervisor injects the real key at egress
unset  ANTHROPIC_API_KEY                      # OpenShell set this to a resolve-sentinel; drop it so Claude uses the Bearer token (see TIP)
export NODE_TLS_REJECT_UNAUTHORIZED=0        # inference.local is self-signed (same reason curl needs -k)
claude -p "In one line, what is Kyma?"
```

> [!TIP]
> **Two Anthropic auth vars — use `ANTHROPIC_AUTH_TOKEN`, not `ANTHROPIC_API_KEY`.** A `--provider litellm` sandbox already
> has `ANTHROPIC_API_KEY` set by OpenShell — but to an `openshell:resolve:env:<nonce>_…` **sentinel**, *not* a real key (the
> supervisor swaps it for the real key at egress; echo it and you get only the token). The two vars differ solely in the HTTP
> header Claude Code emits: **`ANTHROPIC_API_KEY` → `x-api-key`** (Anthropic's native scheme) vs **`ANTHROPIC_AUTH_TOKEN` →
> `Authorization: Bearer`** (the gateway/proxy scheme — ours). Claude Code guards an `x-api-key` with an interactive
> *"Detected a custom API key — use it?"* prompt (answer **No** → "not logged in"); the Bearer token has **no** prompt. So
> **keep `ANTHROPIC_AUTH_TOKEN=placeholder` and `unset ANTHROPIC_API_KEY`** — clean and non-interactive (`claude -p` works
> headless). Claude Code refuses both at once: *"Both … set · auth may not work."* Either resolves to a placeholder the
> supervisor swaps, so both *work* — but only the Bearer path is prompt-free.

> [!NOTE]
> It's a **reasoning box, not an ops shell**: `kubectl` / `kyma` / `k9s` are installed but **inert** (no cluster token,
> no route to the API server — you'll prove that in 9.4). For an agent whose `kubectl`/`kyma` actually reach the cluster,
> use the Busola web terminal ([Exercise 2](../ex2/README.md)); the sandbox trades cluster access for hard isolation.

### 9.4 - See the guardrail hold

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

### 9.5 - Scoped-ops: an agent that *reads* the cluster (one command) 🔎

The contained sandbox (9.3) is a pure **compute** box — zero cluster access. The **scoped-ops** tier adds exactly one
capability: a **read-only** view of the cluster, so an agent can *diagnose* (never mutate). From the **Busola web
terminal** it's a single command — **`scoped-ops`** — which creates the sandbox, applies the cluster-ops network policy,
mints a short-lived **read-only** token, injects a kubeconfig + the LLM env, and drops you **inside** with `kubectl`,
`goose`, and `claude` already wired:

```bash
scoped-ops                     # or give it a name:  scoped-ops mybox
#   >> creating scoped-ops sandbox 'ops-…' …
#   >> applying the cluster-ops L7 policy …
#   >> minting a short-lived (2h) sandbox-viewer token + injecting creds …
#   >> connecting …
#   >> scoped-ops agent ready — read-only cluster + goose/claude via SAP AI Core.
#      try:  kubectl get nodes   |   goose run --text '…'   |   claude -p '…'
```
You're now inside the box (`goose@default--…:~$`), env auto-loaded. Prove the read-only cluster access, then let the
agents drive it:

```bash
kubectl get nodes                        # ✓ read-only (a write → 403, refused by RBAC)
```
```bash
# goose — agentic by default: it runs kubectl / kyma itself and reasons over the output:
goose run --text "run 'kubectl get pods -A' and 'kyma alpha diagnose', then summarize any unhealthy workloads and module issues"
```
```bash
# claude — give it an IMPERATIVE, tool-directed prompt. A bare question ('which pods are unhealthy?') makes Claude
# answer conversationally and ask for context; telling it to RUN the commands makes it act like goose:
claude -p 'Use kubectl to find unhealthy pods and explain why. Run: kubectl get pods -A, then kubectl describe pod / kubectl logs on anything not Running or Completed, and summarize the root causes (CrashLoopBackOff, ImagePullBackOff, OOMKilled, failing probes). Be concise.'
```
Type **`exit`** to leave — the sandbox keeps running (reconnect any time with `openshell sandbox connect <name>`);
`openshell sandbox delete <name>` when you're done.

#### Why it's still contained — just a little wider
- **Network (L7 policy):** exactly three egresses are allowed — the **apiserver** (read-only), the **LiteLLM proxy**
  (for goose, over the OpenAI-compat path), and **`inference.local`** (for claude). **Both LLM keys stay in the gateway** —
  goose and claude each send only a placeholder/sentinel, injected at egress. The public internet and every other workload
  stay denied — same guardrail you proved in 9.4, just with the apiserver added read-only.
- **RBAC:** the injected token is a dedicated **read-only** identity — `get`/`list`/`watch` only, and **`secrets` are
  excluded** — so `kubectl get`/`describe`/`logs` and `kyma alpha diagnose` work, but writes and secret-reads are refused.
- **Honest trade-off vs 9.3:** the **LLM keys never enter the box** (both agents are placeholder-contained). The one real
  credential scoped-ops injects is the **kubectl token** — the apiserver needs a *real* token, so it's a deliberately
  **minimal, read-only, short-lived (2h)** one. The contained tier (9.3) holds **no** cluster credential at all. Choose the
  tier by how much you trust the workload.

> [!TIP]
> **goose vs claude in one line:** `goose run` runs tools on its own; `claude -p` needs the imperative *"Run … then …"*
> phrasing to act rather than ask. Both reason via SAP AI Core. The terminal image pre-allows read-only
> `kubectl get/describe/logs/top` + `kyma` for Claude Code, so those run without a permission prompt. A deep
> `kyma alpha diagnose istio` will *time out* — it reaches the mesh sidecars directly, which the sandbox's egress doesn't
> allow; the apiserver-based diagnostics work fine.

---

## Deep dive: Architecture

OpenShell separates **control-plane state** (who you are, your sandboxes, their policy and providers) from **sandbox
enforcement** (the isolation boundary + the egress broker). Crucially, it brings **no isolation runtime of its own** — it
drives the upstream **agent-sandbox controller** (see the division-of-labour note below).

| Component | Function (on Kyma) |
|---|---|
| **Gateway** | one pod in ns `openshell`, ClusterIP `:8080` gRPC. Checks who you are (OIDC / Keycloak `openshell-oidc`), **holds the secrets** (the real LLM key), delivers policy + settings, attaches providers, decides who can do what. |
| **Compute runtime** — the [agent-sandbox controller](https://github.com/kubernetes-sigs/agent-sandbox) v0.5.5 | provisions the sandbox pod, starts the supervisor + workload, and builds the network fence. Turns a `Sandbox` CR into one isolated pod (runc today — gVisor optional, not enabled on this fleet). |
| **Supervisor** | a **trusted** process *outside* the sandbox boundary. Checks each request against policy, supplies credentials, resolves DNS, and opens the approved connections. It is the sandbox's **only** way out (`HTTPS_PROXY=http://10.200.0.1:3128`). |
| **`openshell-sandbox`** | runs *inside* the boundary with the agent. Identifies **which binary** made each request and applies the process controls; it reports activity but makes **no** policy decisions. |
| **Outer network fence** | denies **all** egress from the workload except its protected channel to the supervisor — the pod's netns has no other usable route (proved in 9.4). |
| **Policies** | define what the agent can access — files, processes, network destinations. Our `sandbox-policy-*.yaml`, hot-reloadable with `openshell policy set`. |
| **Providers** | connect a service name to a stored credential; the supervisor hands that credential out **only** where policy allows. Ours: `litellm` (claude, `x-api-key`) + `litellm-openai` (goose, `Authorization: Bearer`). |

**Inside the boundary + the network request flow.** The supervisor (trusted, makes policy calls) and `openshell-sandbox`
(reports activity) sit on opposite sides of the isolation boundary. When the agent makes a request:

```
  agent (in the box)        supervisor (egress proxy)        LLM proxy → SAP AI Core
        │                            │                               │
        │ POST inference.local       │                               │
        │  x-api-key: placeholder    │                               │
        │───────────────────────────►│                               │
        │        allow-list: inference.local ✓                       │
        │        swap placeholder → REAL key (held by the gateway)    │
        │                            │ POST  x-api-key: REAL key      │
        │                            │──────────────────────────────►│
        │                       completion ✓                         │
        │◄───────────────────────────────────────────────────────────│
        │                            │                               │
        │ POST api.anthropic.com  /  the API server                  │
        │───────────────────────────►│                               │
        │     403 — not on the allow-list ✗                          │
        │◄───────────────────────────│                               │
```

1. the agent opens a connection / DNS lookup → 2. `openshell-sandbox` identifies the calling binary → 3. the request
crosses to the supervisor over the protected channel → 4. the supervisor checks policy and adds the permitted credential →
5. it opens the real connection and relays traffic. You saw exactly this in 9.3 (placeholder in → `msg_bdrk_…` out).

### Trust tiers — one image, three dials
The policy + auth you attach set how far the agent reaches:

| Tier | Egress | Cluster access | Good for |
|---|---|---|---|
| **Contained** (9.1–9.4) | `inference.local` only | none | run/execute untrusted code + reason — zero blast radius |
| **Scoped-ops** (9.5 — `scoped-ops`) | + apiserver (read-only), still no internet | read-only `kubectl` | a diagnostic agent that *reads* the cluster and reasons |
| **Busola terminal** ([ex2](../ex2/README.md)) | full pod network | RBAC-scoped `kubectl` | an agent that *operates* the cluster |

### Two providers, both keyless — how goose reaches SAP AI Core too

| Agent | Provider | Path | Auth header | In-box credential |
|---|---|---|---|---|
| **claude** | `litellm` (type `anthropic`) | `inference.local` → `/v1/messages` | `x-api-key` | sentinel |
| **goose** | `litellm-openai` | LiteLLM proxy → `/v1/chat/completions` | `Authorization: Bearer` | sentinel |

**Why two providers?** goose's Anthropic client **streams** and expects server-sent events — but the SAP AI Core backend
doesn't stream the Anthropic-native `/v1/messages` endpoint, so goose over `inference.local` returns an empty response.
goose's **`litellm` provider is non-streaming** and speaks the OpenAI-compat `/v1/chat/completions` path, which works — the
same path the platform's autonomous cluster-diagnostics use. So we expose that path as a second provider (`litellm-openai`,
bearer auth) instead of forcing goose onto claude's route. A scoped-ops box attaches **both** (`--provider litellm
--provider litellm-openai` — repeatable), and the supervisor injects the real key on **each** endpoint, so neither agent
ever holds a key. Bonus: goose dials its endpoint directly (not the pinned inference-route), so its own request model is
honored — it runs on **sonnet**.

### Agent-Sandbox controller vs OpenShell — division of labour
If the *sandbox* does the isolating, what is OpenShell **for**? Different layers:
- **The agent-sandbox controller is the isolation runtime.** You can create `Sandbox` resources **declaratively** (YAML /
  KRO, **no CLI, no gateway**) — that's how the platform's *headless* agents run (the autonomous cluster-diagnostics job,
  the OpenClaw cells). They get runtime isolation and nothing else; you wire your own RBAC + networking.
- **OpenShell is a control-plane + containment layer on the same controller.** It adds the three things you used here:
  the **OIDC-gated front door** (9.1, no cluster RBAC needed), **credential containment** (9.3), and **L7 egress
  governance** (9.5). Rule of thumb: headless/platform-owned → plain `Sandbox`; a *person* wanting an interactive shell
  into an untrusted, keyless agent → OpenShell's gateway.

### How components authenticate

Two **different** auth stories meet at the gateway — don't conflate them:

- **You → gateway (what you did in 9.1)** is a *human/operator* login: **Keycloak OIDC**, `openshell-admin` role required.
- **The components → each other** is *machine-to-machine* and fully internal — you never touch it, but it's what makes the
  containment trustworthy. Three connections:

| Connection | Who dials | Protection |
|---|---|---|
| Supervisor → gateway | supervisor dials out | **gateway JWT** over TLS |
| Supervisor → `openshell-sandbox` | supervisor dials into the workload | **mutual TLS + sandbox JWT** |
| Agent → supervisor | agent traffic relayed via the sandbox | covered by the supervisor↔sandbox channel |

**Initial credential (Kubernetes driver).** On K8s the supervisor presents the **pod's ServiceAccount token** (SA
`openshell-sandbox`); the gateway verifies it and **confirms the pod belongs to the expected sandbox** before issuing any
JWTs. (On Docker/Podman/MicroVM the driver instead drops initial tokens in files only the supervisor can read.)

**Two JWTs, per sandbox run.** The gateway then issues a pair:
- **Gateway JWT** — sent with every supervisor→gateway call; scoped to just what a supervisor needs (fetch policy, push
  logs, relay sessions).
- **Sandbox JWT** — sent with every supervisor→`openshell-sandbox` call. `openshell-sandbox` holds **only the gateway's
  public key**, so it can *verify* the token but can **never mint** one.

Both bind to **one sandbox and one run (generation)** — restart the sandbox and you get fresh tokens + certs; the old ones
expire. The supervisor keeps them in memory and renews before expiry, but **renewal only works while the sandbox exists**,
so deleting the sandbox cuts the supervisor off.

**Agent visibility.** The agent can **never** reach the gateway signing keys, the gateway JWTs, or the provider
credentials. If the supervisor disconnects, the agent **freezes** — and only the *same* supervisor process can reconnect
and resume; a new supervisor can't take over a running sandbox. That's the machine-side complement to the network fence
you proved in 9.4.

---

## Summary

You framed **why** a contained agent matters (capability *and* control), then ran the workshop's tools image as a
**runtime-isolated OpenShell `Sandbox`**: wired the keyless inference providers (the agent never holds the key), proved the
egress guardrail (apiserver + internet unreachable, no route to bypass), and opened the read-only **scoped-ops** tier for
cluster diagnostics. Under the hood it's a **gated control plane + credential-injecting supervisor + L7 allow-list** riding
the stock **agent-sandbox** runtime — no fork, no extra network config. *The sandbox is the guardrail.*

## Glossary

| Term | What it means |
|---|---|
| **Sandbox / agent-sandbox** | The isolated pod the agent runs in, created from a `Sandbox` custom resource by the `agent-sandbox` controller. The pod itself *is* the boundary — no usable network route except the supervisor. |
| **Gateway** | The OpenShell control plane: OIDC-gated, holds the LLM key, delivers policy/providers, issues the machine JWTs. |
| **Supervisor** | The trusted process (outside the boundary) that owns the box's single exit: intercepts all outbound traffic, enforces the allow-list, and injects the real LLM key at the last hop. |
| **`openshell-sandbox`** | The in-boundary agent-side component that identifies which binary made a request and applies process controls; verifies the sandbox JWT but can't mint one. |
| **L7 allow-list (policy)** | The supervisor's deny-by-default rule set — names, at the application layer, exactly *which binary* may reach *which host:port* over *which protocol* (`openshell policy set`). |
| **Landlock** | A Linux LSM the sandbox uses (`best_effort`) to confine filesystem access to declared paths — one of the protection layers. |
| **Credential injection / placeholder** | The agent sends a dummy credential; the supervisor swaps in the real key just before forwarding upstream. The key lives only in the gateway. |
| **Provider** | A named binding of a service to a stored credential (`litellm`, `litellm-openai`); the supervisor releases it only at the profile-authorized endpoint. |
| **Gateway JWT / Sandbox JWT** | The paired machine tokens for one sandbox run — supervisor→gateway and supervisor→`openshell-sandbox` respectively; the sandbox can verify but not mint. |
| **Device-code flow** | The browserless login (`OPENSHELL_NO_BROWSER=1`): the CLI prints a URL + short code you approve on another device — used from the Busola web terminal, which has no browser. |
| **Scoped-ops** | The middle trust tier: a sandbox that additionally gets a short-lived, **read-only** cluster token so an agent can *inspect* the cluster — but never mutate it, read secrets, or reach the internet. |

## References & links

| What | Where |
|---|---|
| NVIDIA OpenShell | [github.com/NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) · [docs: why](https://docs.nvidia.com/openshell/about/why-open-shell) · [docs: architecture](https://docs.nvidia.com/openshell/about/architecture) |
| agent-sandbox controller | [github.com/kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) |
| kyma CLI | [github.com/kyma-project/cli](https://github.com/kyma-project/cli) |
| Kyma Istio module | [github.com/kyma-project/istio](https://github.com/kyma-project/istio) |
| Kyma Telemetry module | [github.com/kyma-project/telemetry-manager](https://github.com/kyma-project/telemetry-manager) |
| Keycloak | [keycloak.org](https://www.keycloak.org) |
| LiteLLM (→ SAP AI Core) | [github.com/BerriAI/litellm](https://github.com/BerriAI/litellm) |

Back to - [Overview](../../README.md)
