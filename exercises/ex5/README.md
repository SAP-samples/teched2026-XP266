# Exercise 5 - Your own sandboxed agent: OpenShell on Kyma 🔧 *(advanced — CLI + admin access)*

> [!WARNING]
> **Bonus / advanced, and admin-gated.** The `openshell` CLI is **pre-installed in the [Busola web terminal](../Appendices/2-web-terminal/README.md)** (and the sandbox images) — nothing to install; it signs in via device-code (§5.1). The OpenShell gateway only admits the **`openshell-admin`** role — if you don't have it, **watch the instructor demo**. Nothing here is required to complete the workshop; everything runs on **your own** `xp266-NNN` runtime.

> [!TIP]
> **Easy path — run it as a workflow (no CLI, no admin role).** The hands-on below is the full manual OpenShell CLI
> dance — do it if you want to *feel* every layer. But you can see **Goose running inside a contained OpenShell sandbox**
> on your cluster — the real production path this exercise builds by hand — by dispatching one workflow from your fork:
>
> | Run this workflow | What it does |
> |---|---|
> | [**`all-fleets-teched-admin`**](../../../../actions/workflows/all-fleets-teched-admin.yaml) | Provisions a **contained OpenShell sandbox** on your cluster and runs **Goose** inside it to produce a Cluster Health report — the same sandboxed-agent path §5 wires up manually. Pick your `student_cluster` (`xp266-NNN`) and `goose_mode` (`snapshot` / `live`) → **Run workflow** → read the run **Summary** (and the report in Busola). |
>
> Want to see it under the hood? Keep reading — the manual walk-through is below.

**Contents**

- 🧭 [Why OpenShell](#why-openshell)
- ⚠️ [Common risks & controls](#common-risks-and-controls)
- 🛡️ [Protection layers](#protection-layers-at-a-glance)
- 💡 [Common use cases](#common-use-cases)
- 🛠️ [Hands-on 5.1–5.5](#hands-on-the-openshell-cli-dance)
- 🏗️ [Deep dive: Architecture](#deep-dive-architecture)
- 🔑 [How components authenticate](#how-components-authenticate)
- 📖 [Glossary](#glossary)

---

## Why OpenShell

AI agents are most useful when they can read files, install packages, call APIs, and use credentials.  
👉 **That same access
is the risk.**  
[Appendix 2](../Appendices/2-web-terminal/README.md) fenced the Busola web terminal with **RBAC + a NetworkPolicy** — but it's
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
   **denies everything else** (apiserver, other pods, internet). No extra NetworkPolicy — it's native to the stock chart. You'll prove it in 5.4.  
Rule of thumb for the whole workshop: **Busola terminal ([Appendix 2](../Appendices/2-web-terminal/README.md)) = an agent that *does things to* the
cluster; OpenShell sandbox = an agent that *computes things you don't fully trust*.**

### Common risks and controls

OpenShell neutralises the familiar agent risks **by construction** — not by asking the model to behave:

| Threat | Without controls | With OpenShell on Kyma |
|---|---|---|
| **Data exfiltration** | agent uploads code/context to any endpoint | **no route out** — the L7 allow-list resolves/permits only the LiteLLM provider endpoint `litellm-proxy…:4001` (→ SAP AI Core); everything else fails to resolve or 403s (proved in 5.4) |
| **Credential theft** | agent reads the LLM key, SSH keys, cloud creds | the LLM key is **never in the box** — the agent holds only a resolve *sentinel*, the real key is injected at egress; `readOnlyRootFilesystem` + **Landlock** confine the filesystem to declared paths |
| **Unauthorized API usage** | agent sends data to unapproved model providers | **provider profiles + policy** pin model traffic to our in-cluster LiteLLM → SAP AI Core |
| **Privilege escalation** | `sudo`, setuid, dangerous syscalls | **non-root** identity (uid 10001), **drop ALL** capabilities, `seccomp: RuntimeDefault`, `allowPrivilegeEscalation: false` |
| **Reading cluster secrets** | broad RBAC | contained tier holds **no cluster token at all**; scoped-ops tier is **read-only with `secrets` excluded** |
| **Mutating the cluster** | a read-write token | scoped-ops injects a **read-only** token (`get`/`list`/`watch`); writes → 403 |

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
>   filesystem access at the syscall level. The supervisor builds a Landlock ruleset from the `filesystem_policy`
>   (read-only `/usr`,`/etc`; read-write `/sandbox`,`/tmp`) before the agent runs. The agent then **cannot** reach a
>   path outside the policy *regardless of what the container or its own code tries* — and it can't take the restriction
>   back off (Landlock rules are one-way). `best_effort` means "apply the strongest ruleset this kernel's Landlock ABI
>   supports."
> - **seccomp** (`RuntimeDefault`) filters the syscalls the process may make at all — blocking privilege-escalation /
>   setuid / dangerous syscalls below the application.
>
> Because these are **host-kernel** features, the node's kernel must actually have them **enabled**. Managed Kyma /
> Gardener nodes and most modern Linux (e.g. Ubuntu) ship Landlock active, so sandboxes "just work" there. On a host
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
| **Scoped-ops diagnostics** | a read-only cluster view for an agent that *inspects* and reasons, but never mutates (5.5) |

---

## Hands-on: the OpenShell CLI dance

You'll register the gateway (5.1), wire the contained inference provider once (5.2), create a contained sandbox and drive
an agent inside it (5.3), prove the guardrail holds (5.4), then open the read-only **scoped-ops** tier (5.5).

### 5.1 - Get the CLI and reach the gateway

The gateway has a **stable HTTPS endpoint** — `openshell.<your-shoot>.<workshop-domain>` — so there's **no port-forward
to run**.  
It is **OIDC-gated**: it validates your Keycloak token itself.

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
pre-installed in the [Busola web terminal](../Appendices/2-web-terminal/README.md)**.  
The terminal runs *inside* the cluster, so you target the
gateway's in-cluster Service directly (no HTTPS host, no port-forward).  
Because the terminal pod has **no browser**, the
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

Now `openshell sandbox list` works from the terminal — continue with 5.2 exactly as below.  
(Re-auth later with
`OPENSHELL_NO_BROWSER=1 openshell gateway login openshell`.)

### 5.2 - Wire the contained inference provider *(one-time, per gateway)*

This registers our in-cluster LiteLLM proxy as a provider and hands the gateway the key.  
The provider persists on the
gateway's PVC, so this is done **once**.  
(OpenShell 0.1.x removed the built-in provider types, so we import our own
profile — which already carries the endpoint — rather than overriding a built-in.)  
Lint the provider profile (`litellm-provider.yaml`), then import it:

```bash
openshell provider profile lint -f litellm-provider.yaml
```

```bash
openshell provider profile import -f litellm-provider.yaml --global
```

Feed the LiteLLM key — it only ever lives in the gateway (the endpoint `litellm-proxy…:4001` is declared in the profile, so there's no `--config`):

```bash
KEY=$(kubectl get secret llm-proxy-credentials -n default -o jsonpath='{.data.PROXY_API_KEY}' | base64 -d)
```

```bash
openshell provider create --name litellm --type anthropic --credential ANTHROPIC_API_KEY="$KEY"
```

Add a **second provider for goose** — it can't use claude's `/v1/messages` route (it streams; the SAP path doesn't), so it reaches the SAME proxy over the OpenAI-compat `/v1/chat/completions` path with bearer auth. The gateway holds the key; the box gets only a sentinel (attached by `scoped-ops` in §5.5; see "Two providers" below):

```bash
openshell provider profile import -f litellm-openai-provider.yaml --global
```

```bash
openshell provider create --name litellm-openai --type litellm-openai --credential LITELLM_API_KEY="$KEY"
```

> **No `inference set`.** OpenShell 0.1.x retired the `inference` subcommand (and the synthetic `inference.local` route).
> Agents dial the provider endpoint (`litellm-proxy.default.svc.cluster.local:4001`) **directly** and send the injected
> resolve sentinel; the supervisor resolves it at egress — there's no inference route to pin.

### 5.3 - Create a sandbox from the tools image and use it

```bash
openshell sandbox create --name mybox \
  --from localhost:32137/dev-toolbox-bash:latest --provider litellm -- sleep infinity
openshell sandbox list
```

Now prove the contained agent reasons through SAP AI Core — sending only the injected **sentinel**, never a real key.  
The sandbox's own `ANTHROPIC_API_KEY` env *is* that sentinel (`openshell:resolve:env:…`), so pass it straight through:  
Command:
```bash
openshell sandbox exec --name mybox -- bash -c \
  'curl -sS -XPOST http://litellm-proxy.default.svc.cluster.local:4001/v1/messages \
   -H "content-type: application/json" -H "anthropic-version: 2023-06-01" \
   -H "x-api-key: $ANTHROPIC_API_KEY" \
   -d "{\"model\":\"anthropic--claude-4.7-opus\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply OK\"}]}"'
```
Output:
```json
{"id":"msg_bdrk_...","model":"anthropic--claude-4.7-opus", ... "content":[{"type":"text","text":"OK"}] ... }
```

> [!TIP]
> The `msg_bdrk_` id prefix is your proof the request round-tripped **SAP AI Core** (Bedrock). The `x-api-key` you sent was
> the OpenShell **sentinel** (`$ANTHROPIC_API_KEY`), *not* a real key — the supervisor resolved it and injected the real key at egress.

Now drop into an interactive shell and drive **Claude Code** from *inside* the isolated sandbox.  
Point Claude at its one
allowed endpoint (`litellm-proxy…:4001`) and reuse the injected sentinel as the Bearer token:

```bash
openshell sandbox exec --name mybox -- bash   # interactive shell → goose@default--mybox:~$

# ...then, inside the sandbox, point Claude Code at the contained endpoint and use it:
export ANTHROPIC_BASE_URL=http://litellm-proxy.default.svc.cluster.local:4001
export ANTHROPIC_AUTH_TOKEN="$ANTHROPIC_API_KEY"   # copy the injected sentinel → sent as 'Authorization: Bearer'; supervisor injects the real key at egress
unset  ANTHROPIC_API_KEY                            # drop the x-api-key path — it triggers Claude's "use this custom key?" prompt → hangs headless (see TIP)
claude -p "In one line, what is Kyma?"
```

> [!TIP]
> **Two Anthropic auth vars — use `ANTHROPIC_AUTH_TOKEN`, not `ANTHROPIC_API_KEY`.** A `--provider litellm` sandbox already
> has `ANTHROPIC_API_KEY` set by OpenShell — but to an `openshell:resolve:env:<nonce>_…` **sentinel**, *not* a real key (the
> supervisor swaps it for the real key at egress; echo it and you get only the token). The two vars differ solely in the HTTP
> header Claude Code emits: **`ANTHROPIC_API_KEY` → `x-api-key`** (Anthropic's native scheme) vs **`ANTHROPIC_AUTH_TOKEN` →
> `Authorization: Bearer`** (the gateway/proxy scheme — ours). Claude Code guards an `x-api-key` with an interactive
> *"Detected a custom API key — use it?"* prompt (answer **No** → "not logged in"); the Bearer token has **no** prompt. So
> **copy the sentinel into `ANTHROPIC_AUTH_TOKEN` and `unset ANTHROPIC_API_KEY`** — clean and non-interactive (`claude -p` works
> headless). Claude Code refuses both at once: *"Both … set · auth may not work."* The supervisor resolves the sentinel in
> **either** header, so both *work* — but only the Bearer path is prompt-free.

> [!NOTE]
> It's a **reasoning box, not an ops shell**: `kubectl` / `kyma` / `k9s` are installed but **inert** (no cluster token,
> no route to the API server — you'll prove that in 5.4). For an agent whose `kubectl`/`kyma` actually reach the cluster,
> use the Busola web terminal ([Appendix 2](../Appendices/2-web-terminal/README.md)); the sandbox trades cluster access for hard isolation.

### 5.4 - See the guardrail hold

The whole point: from **inside** the sandbox, the cluster API and the internet are unreachable.  
Two layers stack —
(1) the sandbox has **no service-account token and no cluster CA**, so nothing can even *authenticate* to the API; and
(2) it has **no direct network route out at all** — egress is intercepted **transparently** by the supervisor (there's no
`HTTPS_PROXY` to point at): it opens connections **only** to policy-allowed hosts.

The contained tier allows just
`litellm-proxy…:4001`; every other host is **refused** (the name may resolve to a synthetic intercept address, but the
connection never completes).  
A bare `kubectl` won't demonstrate this cleanly (with no KUBECONFIG it just hits
`localhost:8080`), so probe the network directly with `curl`.

**Probe A — try to reach the apiserver:**
```bash
openshell sandbox exec --name mybox -- bash -c \
  'curl -sS -m 5 -o /dev/null -w "apiserver=%{http_code}\n" http://kubernetes.default.svc.cluster.local/version; echo "exit=$?"'
```
Result — the apiserver host is **not on the allow-list**, so the supervisor refuses the connection:
```
curl: (7) Failed to connect to kubernetes.default.svc.cluster.local port 80: Couldn't connect to server
apiserver=000
exit=7
```

**Probe B — confirm there's no proxy to bypass, and the internet is unreachable:**
```bash
openshell sandbox exec --name mybox -- bash -c \
  'echo "HTTPS_PROXY=${HTTPS_PROXY:-<unset>}"; \
   curl -sS -m 5 -o /dev/null -w "internet=%{http_code}\n" https://api.anthropic.com; echo "exit=$?"'
```
Result — egress is **transparent** (no proxy env to bypass), and any non-allow-listed host is refused:
```
HTTPS_PROXY=<unset>
curl: (7) Failed to connect to api.anthropic.com port 443: Couldn't connect to server
internet=000
exit=7
```

**Probe C — the real LLM key never enters the sandbox (only a sentinel does):**
```bash
openshell sandbox exec --name mybox -- bash -c 'echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"'
```
The value is a **resolve sentinel** — `openshell:resolve:env:<nonce>_ANTHROPIC_API_KEY` — **not** the real key.  
The
supervisor swaps it for the real key only at the allow-listed egress; echo it inside the box and you get only the token.  
(With an admin kubeconfig you can also confirm the sandbox's service account can't read the key from the cluster:
`kubectl auth can-i get secrets --as=system:serviceaccount:openshell:openshell-sandbox -n openshell` → **no**.)

So the sandbox can reach **only** `litellm-proxy…:4001` (→ SAP AI Core) — the apiserver, other workloads, and the public
internet are all **refused** by the egress broker.  
That containment is **native to the stock OpenShell chart** — no NetworkPolicy required — a
stronger boundary than [Appendix 2](../Appendices/2-web-terminal/README.md)'s RBAC-fenced Busola terminal, which is still an ordinary pod on the
cluster network.  
Clean up when done:

```bash
openshell sandbox delete mybox
```

### 5.5 - Scoped-ops: an agent that *reads* the cluster (one command) 🔎

The contained sandbox (5.3) is a pure **compute** box — zero cluster access.  
The **scoped-ops** tier adds exactly one
capability: a **read-only** view of the cluster, so an agent can *diagnose* (never mutate).  
From the **Busola web
terminal** it's a single command — **`scoped-ops`** — which creates the sandbox, applies the cluster-ops network policy,
mints a short-lived **read-only** token, injects a kubeconfig + the LLM env, and drops you **inside** with `kubectl`,
`goose`, and `claude` already wired:

```bash
scoped-ops                     # or give it a name:  scoped-ops mybox
#   >> creating scoped-ops sandbox 'ops-…' from …/dev-toolbox-bash (policy applied at CREATE) …
#   >> minting a short-lived (2h) sandbox-viewer token + injecting creds …
#   >> entering 'ops-…' …
#   >> scoped-ops agent ready — read-only cluster + goose/claude via SAP AI Core. Try:
#      kubectl get nodes   |   goose run --text '…'   |   claude -p '…'
```
You're now inside the box (`[<shoot>] goose@default--…:~$` — the prompt shows your logical shoot name, e.g. `xp266-001`),
env auto-loaded.  
Prove the read-only cluster access, then let the agents drive it:

```bash
kubectl get nodes                        # ✓ read-only (a write → 403, refused by RBAC)
```
```bash
# goose — agentic by default: it runs kubectl / kyma itself and reasons over the output:
goose run --text "run 'kubectl get pods -A' and 'kyma alpha diagnose', then summarize any unhealthy workloads and module issues"
```
```bash
# Clean report only — strip goose's tool-call trail + deliberations and print just the final answer. `--output-format
# json` emits the whole session; the tiny extractor keeps the assistant text AFTER the last tool call:
goose run --quiet --output-format json --text 'which pods are unhealthy and why, any orphaned pvcs?' \
| python3 -c 'import sys,json;m=json.load(sys.stdin).get("messages",[]);lt=max([-1]+[i for i,x in enumerate(m) if any("tool" in b.get("type","").lower() for b in x.get("content",[]))]);print("\n".join(b.get("text","") for x in m[lt+1:] if x.get("role")=="assistant" for b in x.get("content",[]) if b.get("type")=="text").strip())'
```
```bash
# claude — give it an IMPERATIVE, tool-directed prompt. A bare question ('which pods are unhealthy?') makes Claude
# answer conversationally and ask for context; telling it to RUN the commands makes it act like goose:
claude -p 'Use kubectl to find unhealthy pods and explain why. Run: kubectl get pods -A, then kubectl describe pod / kubectl logs on anything not Running or Completed, and summarize the root causes (CrashLoopBackOff, ImagePullBackOff, OOMKilled, failing probes). Be concise.'
```
Type **`exit`** to leave — the sandbox keeps running (re-enter any time with `openshell sandbox exec --name <name> -- bash`);
`openshell sandbox delete <name>` when you're done.

#### Why it's still contained — just a little wider
- **Network (L7 policy):** exactly two egresses are allowed — the **apiserver** (read-only) and the **LiteLLM proxy**
  (`litellm-proxy…:4001`, for **both** goose and claude). **Both LLM keys stay in the gateway** — each agent sends only the
  injected resolve sentinel, swapped for the real key at egress. The public internet and every other workload stay denied —
  same guardrail you proved in 5.4, just with the apiserver added read-only.
- **RBAC:** the injected token is a dedicated **read-only** identity — `get`/`list`/`watch` only, and **`secrets` are
  excluded** — so `kubectl get`/`describe`/`logs` and `kyma alpha diagnose` work, but writes and secret-reads are refused.
- **Honest trade-off vs 5.3:** the **LLM keys never enter the box** (both agents are sentinel-contained). The one real
  credential scoped-ops injects is the **kubectl token** — the apiserver needs a *real* token, so it's a deliberately
  **minimal, read-only, short-lived (2h)** one. The contained tier (5.3) holds **no** cluster credential at all. Choose the
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
enforcement** (the isolation boundary + the egress broker).  
Crucially, it brings **no isolation runtime of its own** — it
drives the upstream **agent-sandbox controller** (see the division-of-labour note below).

| Component | Function (on Kyma) |
|---|---|
| **Gateway** | one pod in ns `openshell`, ClusterIP `:8080` gRPC. Checks who you are (OIDC / Keycloak `openshell-oidc`), **holds the secrets** (the real LLM key), delivers policy + settings, attaches providers, decides who can do what. |
| **Compute runtime** — the [agent-sandbox controller](https://github.com/kubernetes-sigs/agent-sandbox) v0.5.5 | provisions the sandbox pod, starts the supervisor + workload, and builds the network fence. Turns a `Sandbox` CR into one isolated pod (runc today — gVisor optional, not enabled on this fleet). |
| **Supervisor** | a **trusted** process *outside* the sandbox boundary. Checks each request against policy, supplies credentials, resolves DNS, and opens the approved connections. It is the sandbox's **only** way out — egress is intercepted **transparently** (no `HTTPS_PROXY` in the box; its DNS resolves only allow-listed hosts). |
| **`openshell-sandbox`** | runs *inside* the boundary with the agent. Identifies **which binary** made each request and applies the process controls; it reports activity but makes **no** policy decisions. |
| **Outer network fence** | denies **all** egress from the workload except its protected channel to the supervisor — the pod's netns has no other usable route (proved in 5.4). |
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
5. it opens the real connection and relays traffic. You saw exactly this in 5.3 (sentinel in → `msg_bdrk_…` out).

### Trust tiers — one image, three dials
The policy + auth you attach set how far the agent reaches:

| Tier | Egress | Cluster access | Good for |
|---|---|---|---|
| **Contained** (5.1–5.4) | `litellm-proxy…:4001` only | none | run/execute untrusted code + reason — zero blast radius |
| **Scoped-ops** (5.5 — `scoped-ops`) | + apiserver (read-only), still no internet | read-only `kubectl` | a diagnostic agent that *reads* the cluster and reasons |
| **Busola terminal** ([Appendix 2](../Appendices/2-web-terminal/README.md)) | full pod network | RBAC-scoped `kubectl` | an agent that *operates* the cluster |

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

### Agent-Sandbox controller vs OpenShell — division of labour
If the *sandbox* does the isolating, what is OpenShell **for**?  
Different layers:
- **The agent-sandbox controller is the isolation runtime.** You can create `Sandbox` resources **declaratively** (YAML /
  KRO, **no CLI, no gateway**) — that's how the platform's *headless* agents run (the autonomous cluster-diagnostics job,
  the OpenClaw cells). They get runtime isolation and nothing else; you wire your own RBAC + networking.
- **OpenShell is a control-plane + containment layer on the same controller.** It adds the three things you used here:
  the **OIDC-gated front door** (5.1, no cluster RBAC needed), **credential containment** (5.3), and **L7 egress
  governance** (5.5). Rule of thumb: headless/platform-owned → plain `Sandbox`; a *person* wanting an interactive shell
  into an untrusted agent → OpenShell's gateway.

### How components authenticate

Two **different** auth stories meet at the gateway — don't conflate them:

- **You → gateway (what you did in 5.1)** is a *human/operator* login: **Keycloak OIDC**, `openshell-admin` role required.
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
you proved in 5.4.  
---

## Summary

You framed **why** a contained agent matters (capability *and* control), then ran the workshop's tools image as a
**runtime-isolated OpenShell `Sandbox`**: wired the inference providers (the agent never holds the key), proved the
egress guardrail (apiserver + internet unreachable, no route to bypass), and opened the read-only **scoped-ops** tier for
cluster diagnostics.  
Under the hood it's a **gated control plane + credential-injecting supervisor + L7 allow-list** riding
the stock **agent-sandbox** runtime — no fork, no extra network config.  
*The sandbox is the guardrail.*

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
| NVIDIA OpenShell | [github.com/NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) · [docs: why](https://docs.nvidia.com/openshell/about/why-open-shell) · [docs: architecture](https://docs.nvidia.com/openshell/about/architecture) |
| OpenShell driver for Kyma (alternative approach — "Path B") | [github.com/st-gr/openshell-driver-kyma](https://github.com/st-gr/openshell-driver-kyma) |
| agent-sandbox controller | [github.com/kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) |
| kyma CLI | [github.com/kyma-project/cli](https://github.com/kyma-project/cli) |
| Kyma Istio module | [github.com/kyma-project/istio](https://github.com/kyma-project/istio) |
| Kyma Telemetry module | [github.com/kyma-project/telemetry-manager](https://github.com/kyma-project/telemetry-manager) |
| Keycloak | [keycloak.org](https://www.keycloak.org) |
| LiteLLM (→ SAP AI Core) | [github.com/BerriAI/litellm](https://github.com/BerriAI/litellm) |

Back to - [Overview](../../README.md)
