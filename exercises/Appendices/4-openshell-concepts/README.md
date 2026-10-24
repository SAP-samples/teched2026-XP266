# Appendix 4 - OpenShell: concepts & architecture

👉 The **why and how** behind the sandboxed-agent hands-on in [Exercise 4](../../ex4/README.md): what OpenShell protects against, the layers that enforce it, the architecture, and a glossary.  
Read it before or after the hands-on — the exercise works without it, but this is where the *"why is this safe?"* is answered.

**Contents**

- 🧭 [Why OpenShell](#why-openshell)
- ⚠️ [Common risks & controls](#common-risks-and-controls)
- 🛡️ [Protection layers](#protection-layers-at-a-glance)
- 💡 [Common use cases](#common-use-cases)
- 🏗️ [Deep dive: Architecture](#deep-dive-architecture)
- 🔑 [How components authenticate](#how-components-authenticate)
- 🔧 [How the providers were wired (reference)](#how-the-providers-were-wired-reference)
- 📖 [Glossary](#glossary)

---

## Why OpenShell

AI agents are most useful when they can read files, install packages, call APIs, and use credentials.  
👉 **That same access
is the risk.**  
The Busola web terminal is fenced with **RBAC + a NetworkPolicy** — but it's
still an ordinary `exec` pod: those are guardrails *around* it, not isolation *of* it.  
OpenShell takes the next step —
**preserve the agent's capability, but enforce explicit controls** — by running the **same tools image**
(`goose` / Claude Code / kubectl / kyma / k9s) inside a **runtime-isolated `Sandbox`** where the agent can reason via SAP
AI Core yet is **physically unable** to touch the cluster API or the public internet.  
**The sandbox itself is the guardrail.**

```
You (openshell CLI, laptop or Busola web terminal)
   │  OIDC-gated gRPC  (Keycloak validates who you are)
   ▼
OpenShell gateway ──creates──▶ Sandbox pod (agent-sandbox, isolated)
   holds the key                 │  dev-toolbox-bash (goose / claude)
                                  │  POST http://litellm-proxy…svc:4001  (resolve sentinel, NOT the real key)
                                  ▼
                     supervisor injects the REAL key ──▶ LiteLLM :4001 ──▶ SAP AI Core
                                  ✗ apiserver   ✗ internet   ✗ other pods   (no direct route — proxy allow-list)
```

Two properties make this **contained**, not merely isolated:
1. **The agent never holds the LLM credential.** It sends a *resolve sentinel* (injected by OpenShell — a
   `openshell:resolve:env:…` token, not a real key) to the provider endpoint `litellm-proxy.default.svc.cluster.local:4001`;
   the OpenShell supervisor swaps in the real key (held by the gateway) at egress. Compromise the agent and you still don't get the key.
2. **Egress has exactly one exit, and it's an allow-list.** The pod runs in a network namespace with **no direct route
   out**; its only path is the supervisor proxy, which allow-lists the LiteLLM provider endpoint (`litellm-proxy…:4001`) and
   **denies everything else** (apiserver, other pods, internet). No extra NetworkPolicy — it's native to the stock chart. You'll prove it in the hands-on.  
Rule of thumb for the whole workshop: **Busola terminal = an agent that *does things to* the
cluster; OpenShell sandbox = an agent that *computes things you don't fully trust*.**

### Common risks and controls

OpenShell neutralises the familiar agent risks **by construction** — not by asking the model to behave:

| Threat | Without controls | With OpenShell on Kyma |
|---|---|---|
| **Data exfiltration** | agent uploads code/context to any endpoint | **no route out** — the L7 allow-list resolves/permits only the LiteLLM provider endpoint `litellm-proxy…:4001` (→ SAP AI Core); everything else fails to resolve or 403s (proved in the hands-on) |
| **Credential theft** | agent reads the LLM key, SSH keys, cloud creds | the LLM key is **never in the box** — the agent holds only a resolve *sentinel*, the real key is injected at egress; `readOnlyRootFilesystem` + **Landlock** confine the filesystem to declared paths |
| **Unauthorized API usage** | agent sends data to unapproved model providers | **provider profiles + policy** pin model traffic to our in-cluster LiteLLM → SAP AI Core |
| **Privilege escalation** | `sudo`, setuid, dangerous syscalls | **non-root** identity (uid 10001), **drop ALL** capabilities, `seccomp: RuntimeDefault`, `allowPrivilegeEscalation: false` |
| **Reading cluster secrets** | broad RBAC | contained tier holds **no cluster token at all**; scoped-ops tier is **read-only with `secrets` excluded** |
| **Mutating the cluster** | a read-write token | scoped-ops injects a **read-only** token (`get`/`list`/`watch` only) |

### Protection layers at a glance

OpenShell applies **defense in depth** across four policy domains — some locked at creation, some hot-reloadable:

| Layer | Protection target | When applied | On our sandboxes |
|---|---|---|---|
| **Filesystem** | reads/writes outside allowed paths | locked at sandbox creation | `filesystem_policy` (read-only `/usr`,`/etc`,… · read-write `/sandbox`,`/tmp`) + **Landlock** (`best_effort`) + `readOnlyRootFilesystem` |
| **Network** | unauthorized outbound connections | **hot-reloadable at runtime** | the L7 allow-list (`openshell policy set`) — `litellm-proxy…:4001` (contained) → + apiserver read-only (scoped-ops) |
| **Process** | privilege escalation, dangerous syscalls | locked at sandbox creation | non-root uid 10001, `drop [ALL]` caps, `seccomp: RuntimeDefault`, no privilege escalation |
| **Provider credentials** | resolve credential **sentinels** only at profile-authorized endpoints | runtime (new vars need a new process) | the supervisor swaps the injected resolve sentinel for the real key **only** on the provider's declared endpoint |

> [!NOTE]
> **Why "kernel-level, not container-level" matters — Landlock + seccomp.** The Filesystem and Process layers above are
> enforced by the **Linux kernel itself**, from *inside* the agent process — not by the container runtime around it:
> - **Landlock** is a Linux Security Module (kernel ≥ 5.13) that lets an *unprivileged* process restrict its **own**
> filesystem access at the syscall level.  
> The supervisor builds a Landlock ruleset from the `filesystem_policy`
> (read-only `/usr`,`/etc`; read-write `/sandbox`,`/tmp`) before the agent runs.  
> The agent then **cannot** reach a
>   path outside the policy *regardless of what the container or its own code tries* — and it can't take the restriction
>   back off (Landlock rules are one-way). `best_effort` means "apply the strongest ruleset this kernel's Landlock ABI
>   supports."
> - **seccomp** (`RuntimeDefault`) filters the syscalls the process may make at all — blocking privilege-escalation /
>   setuid / dangerous syscalls below the application.
>
> Because these are **host-kernel** features, the node's kernel must actually have them **enabled**. Managed Kyma /
> Gardener nodes and most modern Linux (e.g. Ubuntu) ship Landlock active, so sandboxes "just work" there.  
> On a host
> where Landlock is compiled but **disabled at boot** (e.g. SUSE's default `lsm=` list omits it), the supervisor can't
> build its ruleset and `sandbox create` fails with `ProvisioningTimedOut` — the fix is host-side (`lsm=landlock,…` on
> the kernel cmdline + reboot). This is the "defense extends down to the kernel" trade-off: strong isolation, but it
> depends on the host, not just the container.

### Common use cases

| Use case | What it looks like here |
|---|---|
| **Secure coding / reasoning agents** | run Claude Code or goose with constrained file + network access — a code-interpreter / analysis backend that runs the code it writes, safely |
| **Processing untrusted input** | feed it docs / emails / tickets — even a prompt-injected agent can't exfiltrate (no egress but the LLM) or pivot (no cluster/creds) |
| **Private / self-hosted models** | the agent reasons via the in-cluster **LiteLLM → SAP AI Core**, never the public internet |
| **Compliance & audit** | the policy YAML (`sandbox-policy-*.yaml`) is **version-controlled security controls** — reviewable as a diff |
| **Per-user isolation & reproducible runs** | each session its own sandbox + quota + network namespace, auto-reaped; fresh from a pinned image, gone after — no state leak |
| **Scoped-ops diagnostics** | a read-only cluster view for an agent that *inspects* and reasons, but never mutates (scoped-ops) |

---

## Deep dive: Architecture

OpenShell separates **control-plane state** (who you are, your sandboxes, their policy and providers) from **sandbox
enforcement** (the isolation boundary + the egress broker).  
Crucially, it brings **no isolation runtime of its own** — it
drives the upstream **agent-sandbox controller** (see the division-of-labour note below).

| Component | Function (on Kyma) |
|---|---|
| **Gateway** | one pod in ns `openshell`, ClusterIP `:8080` gRPC. Checks who you are (OIDC / Keycloak `openshell-oidc`), **holds the secrets** (the real LLM key), delivers policy + settings, attaches providers, decides who can do what. |
| **Compute runtime** — the [agent-sandbox controller](https://github.com/kubernetes-sigs/agent-sandbox) v0.4.5 | provisions the sandbox pod, starts the supervisor + workload, and builds the network fence. Turns a `Sandbox` CR into one isolated pod (runc today — gVisor optional, not enabled on this fleet). |
| **Supervisor** | a **trusted** process *outside* the sandbox boundary. Checks each request against policy, supplies credentials, resolves DNS, and opens the approved connections. It is the sandbox's **only** way out — egress is intercepted **transparently** (no `HTTPS_PROXY` in the box; its DNS resolves only allow-listed hosts). |
| **`openshell-sandbox`** | runs *inside* the boundary with the agent. Identifies **which binary** made each request and applies the process controls; it reports activity but makes **no** policy decisions. |
| **Outer network fence** | denies **all** egress from the workload except its protected channel to the supervisor — the pod's netns has no other usable route (proved in the hands-on). |
| **Policies** | define what the agent can access — files, processes, network destinations. Our `sandbox-policy-*.yaml`, hot-reloadable with `openshell policy set`. |
| **Providers** | connect a service name to a stored credential; the supervisor hands that credential out **only** where policy allows. Ours: `litellm` (claude, `x-api-key`) + `litellm-openai` (goose, `Authorization: Bearer`). |

**Inside the boundary + the network request flow.**  
The supervisor (trusted, makes policy calls) and `openshell-sandbox`
(reports activity) sit on opposite sides of the isolation boundary.  
When the agent makes a request:

```
  agent (in the box)        supervisor (egress proxy)        LLM proxy → SAP AI Core
        │                            │                               │
        │ POST litellm-proxy…:4001   │                               │
        │  x-api-key: sentinel       │                               │
        │───────────────────────────►│                               │
        │     allow-list: litellm-proxy…:4001 ✓                      │
        │     resolve sentinel → REAL key (held by the gateway)      │
        │                            │ POST  x-api-key: REAL key      │
        │                            │──────────────────────────────►│
        │                       completion ✓                         │
        │◄───────────────────────────────────────────────────────────│
        │                            │                               │
        │ POST api.anthropic.com  /  the API server                  │
        │───────────────────────────►│                               │
        │     not on the allow-list — fails to resolve ✗             │
        │◄───────────────────────────│                               │
```

1. the agent opens a connection / DNS lookup → 2. `openshell-sandbox` identifies the calling binary → 3. the request
crosses to the supervisor over the protected channel → 4. the supervisor checks policy and adds the permitted credential →
5. it opens the real connection and relays traffic. This is exactly the sentinel-in → `msg_bdrk_…`-out flow.

### Trust tiers — one image, three dials
The policy + auth you attach set how far the agent reaches:

| Tier | Egress | Cluster access | Good for |
|---|---|---|---|
| **Contained** | `litellm-proxy…:4001` only | none | run/execute untrusted code + reason — zero blast radius |
| **Scoped-ops** (`scoped-ops`) | + apiserver (read-only), still no internet | read-only `kubectl` | a diagnostic agent that *reads* the cluster and reasons |
| **Busola terminal** | full pod network | RBAC-scoped `kubectl` | an agent that *operates* the cluster |

### Two providers — how goose reaches SAP AI Core too

| Agent | Provider | Path | Auth header | In-box credential |
|---|---|---|---|---|
| **claude** | `litellm` (type `anthropic`) | `litellm-proxy…:4001` → `/v1/messages` | `x-api-key` | sentinel |
| **goose** | `litellm-openai` | `litellm-proxy…:4001` → `/v1/chat/completions` | `Authorization: Bearer` | sentinel |

**Why two providers?** goose's Anthropic client **streams** and expects server-sent events — but the SAP AI Core backend
doesn't stream the Anthropic-native `/v1/messages` endpoint, so goose over that route returns an empty response.  
goose's **`litellm` provider is non-streaming** and speaks the OpenAI-compat `/v1/chat/completions` path, which works — the
same path the platform's autonomous cluster-diagnostics use.  
So we expose that path as a second provider (`litellm-openai`,
bearer auth) instead of forcing goose onto claude's route.  
A scoped-ops box attaches **both** (`--provider litellm
--provider litellm-openai` — repeatable), and the supervisor injects the real key on **each** endpoint, so neither agent
ever holds a key.  
Bonus: goose dials its endpoint directly, so its own request model is honored — it runs on **sonnet**.

### How a sandbox reaches the LLM proxy — the provider *is* the egress allow-list

A fresh sandbox is **deny-by-default**: its network namespace has no route out, and all egress is intercepted
transparently by the **supervisor** (no `HTTPS_PROXY` in the box; its DNS resolves only allow-listed FQDNs). So *how* do
claude and goose reach `litellm-proxy:4001` with **no explicit `--policy`**? Because **each `--provider` you attach brings
its own egress rule** — the provider's profile declares both the endpoint it may reach and the binaries that may reach it:

| `--provider` | profile | opens egress to | for binaries | injects |
|---|---|---|---|---|
| `litellm` | `anthropic` | `litellm-proxy…:4001` (`/v1/messages`) | `claude`, `claude.exe`, `curl`, `node` | `ANTHROPIC_API_KEY` sentinel |
| `litellm-openai` | `litellm-openai` | `litellm-proxy…:4001` (`/v1/chat/completions`) | `goose`, `curl`, `node` | `LITELLM_API_KEY` sentinel |

So attaching the two providers already punches exactly the `litellm-proxy:4001` hole the agents need — an explicit
`--policy` is only for egress the providers *don't* cover (e.g. the read-only **apiserver** block `scoped-ops` adds). The
request path:

1. an agent sends `Authorization: Bearer openshell:resolve:env:…` (a **sentinel**) to `litellm-proxy…:4001`;
2. the supervisor checks **allowed binary → allowed host?** (yes, from the profile), swaps the sentinel for the **real
   key** (held by the gateway) **at the wire**, and relays to the in-cluster `litellm-proxy` Service → **SAP AI Core**;
3. the apiserver, other pods, and the internet stay **denied** — the box never holds the real key.

> [!NOTE]
> **Two layers, don't conflate them.** The **providers** open the *network path and inject the key* (so a bare
> `--provider litellm --provider litellm-openai` box already reaches SAP AI Core). The **model-id env** —
> `ANTHROPIC_MODEL` for claude, `GOOSE_PROVIDER`/`GOOSE_MODEL` for goose — is the separate *per-agent config* that
> makes the client request a model SAP AI Core actually serves.  
> Egress can be wide open and a call still errors if the
> model id is the client's built-in default (e.g. "Opus 5") rather than `anthropic--claude-4.7-opus`.

### Agent-Sandbox controller vs OpenShell — division of labour
If the *sandbox* does the isolating, what is OpenShell **for**?  
Different layers:
- **The agent-sandbox controller is the isolation runtime.** You can create `Sandbox` resources **declaratively** (YAML /
  KRO, **no CLI, no gateway**) — that's how the platform's *headless* agents run (the autonomous cluster-diagnostics job,
  the OpenClaw cells). They get runtime isolation and nothing else; you wire your own RBAC + networking.
- **OpenShell is a control-plane + containment layer on the same controller.** It adds the three things you used here:
  the **OIDC-gated front door** (no cluster RBAC needed), **credential containment**, and **L7 egress
  governance**. Rule of thumb: headless/platform-owned → plain `Sandbox`; a *person* wanting an interactive shell
  into an untrusted agent → OpenShell's gateway.

### How components authenticate

Two **different** auth stories meet at the gateway — don't conflate them:

- **You → gateway** is a *human/operator* login: **Keycloak OIDC**, `openshell-admin` role required.
- **The components → each other** is *machine-to-machine* and fully internal — you never touch it, but it's what makes the
  containment trustworthy. Three connections:

| Connection | Who dials | Protection |
|---|---|---|
| Supervisor → gateway | supervisor dials out | **gateway JWT** over TLS |
| Supervisor → `openshell-sandbox` | supervisor dials into the workload | **mutual TLS + sandbox JWT** |
| Agent → supervisor | agent traffic relayed via the sandbox | covered by the supervisor↔sandbox channel |

**Initial credential (Kubernetes driver).**  
On K8s the supervisor presents the **pod's ServiceAccount token** (SA
`openshell-sandbox`); the gateway verifies it and **confirms the pod belongs to the expected sandbox** before issuing any
JWTs.  
(On Docker/Podman/MicroVM the driver instead drops initial tokens in files only the supervisor can read.)  
**Two JWTs, per sandbox run.**  
The gateway then issues a pair:
- **Gateway JWT** — sent with every supervisor→gateway call; scoped to just what a supervisor needs (fetch policy, push
  logs, relay sessions).
- **Sandbox JWT** — sent with every supervisor→`openshell-sandbox` call. `openshell-sandbox` holds **only the gateway's
  public key**, so it can *verify* the token but can **never mint** one.  
Both bind to **one sandbox and one run (generation)** — restart the sandbox and you get fresh tokens + certs; the old ones
expire.  
The supervisor keeps them in memory and renews before expiry, but **renewal only works while the sandbox exists**,
so deleting the sandbox cuts the supervisor off.  
**Agent visibility.**  
The agent can **never** reach the gateway signing keys, the gateway JWTs, or the provider
credentials.  
If the supervisor disconnects, the agent **freezes** — and only the *same* supervisor process can reconnect
and resume; a new supervisor can't take over a running sandbox.  
That's the machine-side complement to the network fence
you prove in the hands-on.

---

## How the providers were wired (reference)

You **don't run this** — the providers in Exercise 4.2 are pre-created for you. This is **how the platform created them**, kept for reference (and if you ever stand up your own gateway). The key is handed to the gateway once and persists on its PVC. OpenShell 0.1.x removed the built-in provider types, so we import our own profile — which already carries the endpoint — rather than overriding a built-in.

The `litellm` provider is created from this profile (`litellm-provider.yaml`):

```yaml
id: anthropic
display_name: Anthropic (via in-cluster LiteLLM → SAP AI Core)
description: Override the built-in anthropic provider to point at our in-cluster LiteLLM proxy (Anthropic-native /v1/messages)
category: inference
inference_capable: true
credentials:
  - name: api_key
    description: LiteLLM proxy key (PROXY_API_KEY from secret llm-proxy-credentials, ns default)
    env_vars: [ANTHROPIC_API_KEY]
    required: true
    auth_style: header
    header_name: x-api-key          # LiteLLM accepts x-api-key on /v1/messages; if rejected, switch to Authorization/Bearer
discovery:
  credentials: [api_key]
endpoints:
  - host: litellm-proxy.default.svc.cluster.local
    port: 4001
    protocol: rest
    access: read-write
    enforcement: enforce
binaries: [/usr/local/bin/claude, /usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe, /usr/bin/curl, /usr/local/bin/node]   # client paths in the sandbox image allowed to reach the endpoint
```

Lint + import the profile, then create the provider with the key (the key only ever lives in the gateway):

```bash
openshell provider profile lint   -f litellm-provider.yaml
openshell provider profile import -f litellm-provider.yaml --global
KEY=$(kubectl get secret llm-proxy-credentials -n default -o jsonpath='{.data.PROXY_API_KEY}' | base64 -d)
openshell provider create --name litellm --type anthropic --credential ANTHROPIC_API_KEY="$KEY"
```

goose needs a **second provider** — it can't use claude's streaming `/v1/messages` route, so it reaches the SAME proxy over the OpenAI-compat `/v1/chat/completions` path with bearer auth:

```bash
openshell provider profile import -f litellm-openai-provider.yaml --global
openshell provider create --name litellm-openai --type litellm-openai --credential LITELLM_API_KEY="$KEY"
```

> **No `inference set`.** OpenShell 0.1.x retired the `inference` subcommand (and the synthetic `inference.local` route). Agents dial the provider endpoint (`litellm-proxy.default.svc.cluster.local:4001`) **directly** and send the injected resolve sentinel; the supervisor resolves it at egress — there's no inference route to pin.

---

## Glossary

| Term | What it means |
|---|---|
| **Sandbox / agent-sandbox** | The isolated pod the agent runs in, created from a `Sandbox` custom resource by the `agent-sandbox` controller. The pod itself *is* the boundary — no usable network route except the supervisor. |
| **Gateway** | The OpenShell control plane: OIDC-gated, holds the LLM key, delivers policy/providers, issues the machine JWTs. |
| **Supervisor** | The trusted process (outside the boundary) that owns the box's single exit: intercepts all outbound traffic, enforces the allow-list, and injects the real LLM key at the last hop. |
| **`openshell-sandbox`** | The in-boundary agent-side component that identifies which binary made a request and applies process controls; verifies the sandbox JWT but can't mint one. |
| **L7 allow-list (policy)** | The supervisor's deny-by-default rule set — names, at the application layer, exactly *which binary* may reach *which host:port* over *which protocol* (`openshell policy set`). |
| **Landlock** | A Linux kernel LSM (≥ 5.13) the sandbox uses (`best_effort`) to confine filesystem access to declared paths — enforced **in-kernel, from inside the agent process**, so it holds regardless of the container. One of the kernel-level protection layers; requires the **host kernel** to have Landlock enabled (see the note under *Protection layers*). |
| **Credential injection / sentinel** | The agent sends a resolve *sentinel* (`openshell:resolve:env:…`), not a real key; the supervisor swaps in the real key just before forwarding upstream. The key lives only in the gateway. |
| **Provider** | A named binding of a service to a stored credential (`litellm`, `litellm-openai`); the supervisor releases it only at the profile-authorized endpoint. |
| **Gateway JWT / Sandbox JWT** | The paired machine tokens for one sandbox run — supervisor→gateway and supervisor→`openshell-sandbox` respectively; the sandbox can verify but not mint. |
| **Device-code flow** | The browserless login (`OPENSHELL_NO_BROWSER=1`): the CLI prints a URL + short code you approve on another device — used from the Busola web terminal, which has no browser. |
| **Scoped-ops** | The middle trust tier: a sandbox that additionally gets a short-lived, **read-only** cluster token so an agent can *inspect* the cluster — but never mutate it, read secrets, or reach the internet. |

## References & links

| What | Where |
|---|---|
| NVIDIA OpenShell | [github.com/NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) · [docs: why](https://docs.nvidia.com/openshell/latest/about/overview) · [docs: architecture](https://docs.nvidia.com/openshell/about/architecture) |
| OpenShell driver for Kyma (alternative approach — "Path B") | [github.com/st-gr/openshell-driver-kyma](https://github.com/st-gr/openshell-driver-kyma) |
| agent-sandbox controller | [github.com/kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) |
| kyma CLI | [github.com/kyma-project/cli](https://github.com/kyma-project/cli) |
| Kyma Istio module | [github.com/kyma-project/istio](https://github.com/kyma-project/istio) |
| Kyma Telemetry module | [github.com/kyma-project/telemetry-manager](https://github.com/kyma-project/telemetry-manager) |
| Keycloak | [keycloak.org](https://www.keycloak.org) |
| LiteLLM (→ SAP AI Core) | [github.com/BerriAI/litellm](https://github.com/BerriAI/litellm) |

Back to - [Overview](../../../README.md)
