# Exercise 4 - Your own sandboxed agent: OpenShell on Kyma 🔧

**OpenShell** runs the workshop's tools image (`goose` / Claude Code / `kubectl` / `kyma`) inside a **runtime-isolated `Sandbox`** that can reason via SAP AI Core yet is **physically unable** to touch the cluster API or the public internet — *the sandbox itself is the guardrail*.  
The *why*, the protection layers, the architecture, and a glossary are in **[Appendix 4 - OpenShell: concepts & architecture](../Appendices/4-openshell-concepts/README.md)**.  
This exercise is the **hands-on** — run it either way:

**Contents**

- ⚡ **4a** *(easy path)* — run it as a **GitHub Action** (the Tip below)
- 🛠️ **4b** *(optional)* — [Hands-on: the OpenShell CLI in the Busola web terminal](#hands-on-the-openshell-cli-in-the-busola-web-terminal)
  - 🔑 [4.1 terminal & gateway](#41---open-the-terminal-and-reach-the-gateway)
  - 🔀 [4.2 provider](#42---wire-the-contained-inference-provider-one-time-per-gateway)
  - 📦 [4.3 sandbox](#43---create-a-sandbox-from-the-tools-image-and-use-it)
  - 🛡️ [4.4 guardrail](#44---see-the-guardrail-hold)
  - 🔎 [4.5 scoped-ops](#45---scoped-ops-an-agent-that-reads-the-cluster-one-command-)

> [!TIP]
> **Easy path — run it as a workflow (no CLI, no admin role).** The hands-on below is the full manual OpenShell CLI
> dance — do it if you want to *feel* every layer. But you can see **Goose running inside a contained OpenShell sandbox**
> on your cluster — the real production path this exercise builds by hand — by dispatching one workflow from your fork:
>
> | Run this workflow | What it does |
> |---|---|
> | [**`all-fleets-teched-admin`**](../../../../actions/workflows/all-fleets-teched-admin.yaml) | Provisions a **contained OpenShell sandbox** on your cluster and runs **Goose** inside it to produce a Cluster Health report — the same sandboxed-agent path §4 wires up manually. Pick your `student_cluster` (`xp266-NNN`) and `goose_mode` (`snapshot` / `live`) → **Run workflow** → read the run **Summary** (and the report in Busola). |
>
> Want to see it under the hood? Keep reading — the manual walk-through is below.

---

## Hands-on: the OpenShell CLI in the Busola web terminal

You'll register the gateway (4.1), wire the contained inference provider once (4.2), create a contained sandbox and drive
an agent inside it (4.3), prove the guardrail holds (4.4), then open the read-only **scoped-ops** tier (4.5).

### 4.1 - Open the terminal and reach the gateway

The `openshell` CLI is **pre-installed in the Busola web terminal** — nothing to download.  
The terminal runs *inside* the cluster, so you reach the gateway's in-cluster Service directly (no HTTPS host, no port-forward).  
The gateway is **OIDC-gated** — it validates your Keycloak token itself.

1. In Busola, open a **web terminal** (top-right cluster menu → **Terminal**).
2. Register the gateway. The terminal pod has **no browser**, so use the **device-code (headless) login** (`OPENSHELL_NO_BROWSER=1`):
   ```bash
   OPENSHELL_NO_BROWSER=1 openshell gateway add http://openshell.openshell.svc.cluster.local:8080 \
     --oidc-issuer https://keycloak.<your-shoot>.<workshop-domain>/realms/ateam-isveng \
     --oidc-client-id openshell-oidc
   #   already registered from a previous day? re-auth instead:
   #   OPENSHELL_NO_BROWSER=1 openshell gateway login openshell
   ```
   It prints a verification URL and a short code, then waits:
   ```
   To authenticate, visit:
     https://keycloak.<your-shoot>.<workshop-domain>/realms/ateam-isveng/device?user_code=XXXX-XXXX
   Waiting for authorization...
   ```
3. Open that URL in your **laptop's** browser, sign in (you must hold the **`openshell-admin`** role), and the terminal unblocks:
   ```
   ✓ Authenticated via device code
   ```

Now `openshell sandbox list` works from the terminal — continue with 4.2.

### 4.2 - Wire the contained inference provider *(one-time, per gateway)*

This registers our in-cluster LiteLLM proxy as a provider and hands the gateway the key.  
The provider persists on the
gateway's PVC, so this is done **once**.  
(OpenShell 0.1.x removed the built-in provider types, so we import our own
profile — which already carries the endpoint — rather than overriding a built-in.)  
Create `litellm-provider.yaml` with:

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

Lint the provider profile, then import it:

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

Add a **second provider for goose** — it can't use claude's `/v1/messages` route (it streams; the SAP path doesn't), so it reaches the SAME proxy over the OpenAI-compat `/v1/chat/completions` path with bearer auth. The gateway holds the key; the box gets only a sentinel (attached by `scoped-ops` in §4.5; see "Two providers" below):

```bash
openshell provider profile import -f litellm-openai-provider.yaml --global
```

```bash
openshell provider create --name litellm-openai --type litellm-openai --credential LITELLM_API_KEY="$KEY"
```

> **No `inference set`.** OpenShell 0.1.x retired the `inference` subcommand (and the synthetic `inference.local` route).
> Agents dial the provider endpoint (`litellm-proxy.default.svc.cluster.local:4001`) **directly** and send the injected
> resolve sentinel; the supervisor resolves it at egress — there's no inference route to pin.

### 4.3 - Create a sandbox from the tools image and use it

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
> no route to the API server — you'll prove that in 4.4). For an agent whose `kubectl`/`kyma` actually reach the cluster,
> use the Busola web terminal; the sandbox trades cluster access for hard isolation.

### 4.4 - See the guardrail hold

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
stronger boundary than the RBAC-fenced Busola terminal, which is still an ordinary pod on the
cluster network.  
Clean up when done:

```bash
openshell sandbox delete mybox
```

### 4.5 - Scoped-ops: an agent that *reads* the cluster (one command) 🔎

The contained sandbox (4.3) is a pure **compute** box — zero cluster access.  
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
  same guardrail you proved in 4.4, just with the apiserver added read-only.
- **RBAC:** the injected token is a dedicated **read-only** identity — `get`/`list`/`watch` only, and **`secrets` are
  excluded** — so `kubectl get`/`describe`/`logs` and `kyma alpha diagnose` work, but writes and secret-reads are refused.
- **Honest trade-off vs 4.3:** the **LLM keys never enter the box** (both agents are sentinel-contained). The one real
  credential scoped-ops injects is the **kubectl token** — the apiserver needs a *real* token, so it's a deliberately
  **minimal, read-only, short-lived (2h)** one. The contained tier (4.3) holds **no** cluster credential at all. Choose the
  tier by how much you trust the workload.

> [!TIP]
> **goose vs claude in one line:** `goose run` runs tools on its own; `claude -p` needs the imperative *"Run … then …"*
> phrasing to act rather than ask. Both reason via SAP AI Core. The terminal image pre-allows read-only
> `kubectl get/describe/logs/top` + `kyma` for Claude Code, so those run without a permission prompt. A deep
> `kyma alpha diagnose istio` will *time out* — it reaches the mesh sidecars directly, which the sandbox's egress doesn't
> allow; the apiserver-based diagnostics work fine.

---

## Summary

You ran the workshop's tools image as a
**runtime-isolated OpenShell `Sandbox`**: wired the inference providers (the agent never holds the key), proved the
egress guardrail (apiserver + internet unreachable, no route to bypass), and opened the read-only **scoped-ops** tier for
cluster diagnostics.  
Under the hood it's a **gated control plane + credential-injecting supervisor + L7 allow-list** riding
the stock **agent-sandbox** runtime — no fork, no extra network config.  
*The sandbox is the guardrail.*

Continue to - [Exercise 5 - External agents: Pi, opencode & Qwen via OpenRouter](../ex5/README.md)  
Back to - [Overview](../../README.md)
