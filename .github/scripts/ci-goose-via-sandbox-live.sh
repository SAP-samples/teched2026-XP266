#!/usr/bin/env bash
# ci-goose-via-sandbox-live.sh — run goose KEYLESS inside an OpenShell sandbox with LIVE read-only kubectl (headless client-creds).
#
# The "Investigate" twin of ci-goose-via-sandbox.sh. Where that script pipes a STATIC snapshot into a baked-policy sandbox
# ("do not use tools"), THIS one creates an EXPLICIT-POLICY sandbox (sandbox-policy-cluster-ops.yaml, embedded inline) with a
# READ-ONLY kubeconfig injected, so goose drives live `kubectl`/`kyma` against the cluster and investigates in real time.
# Proven headless via JupyterHub notebook 05b (client-credentials + the 900s openshell-admin-sa token).
#
# Auth: client-credentials (openshell-admin-sa secret, READ FROM THE CLUSTER at runtime) — same headless identity as ci-goose
# and the provider-setup Job. Read-only cluster access INSIDE the box = a minted `sandbox-viewer` SA token (ns openshell,
# bound to the read-only `sandbox-readonly` ClusterRole). The real LLM key never leaves the cluster (litellm-openai provider
# resolves an injected sentinel at egress → LiteLLM → SAP AI Core).
#
# Prompt: the CH v2 prompt loaded from the dev-toolbox-prompts ConfigMap (key health-v2-report-first, __SHOOT__ substituted),
# or an explicit prompt file / stdin override.
#
#   KUBECONFIG=… SHOOT_NAME=xp266-001 ./ci-goose-via-sandbox-live.sh            # v2 prompt from the CM (default)
#   KUBECONFIG=… ./ci-goose-via-sandbox-live.sh <prompt-file>                   # explicit prompt override (file)
#   echo "…" | KUBECONFIG=… ./ci-goose-via-sandbox-live.sh -                    # explicit prompt override (stdin)
#   KEEP_SANDBOX=true KUBECONFIG=… ./ci-goose-via-sandbox-live.sh               # leave the box alive for log inspection
#
# Requires: kubectl (cluster-admin on an OpenShell+dev-toolbox shoot), curl, tar, sha256sum. The openshell CLI is
# auto-installed (version-matched to the live gateway) if not on PATH. Skips cleanly where the live prereqs are absent.
set -euo pipefail

# ── inputs ──────────────────────────────────────────────────────────────────────
PROMPT_SRC=${1:-}                                              # a file path, '-' for stdin, or empty → load the CM prompt
IMAGE=${IMAGE:-localhost:32137/dev-toolbox-bash:latest}        # in-cluster registry NodePort ref (goose+kubectl+kyma baked)
GOOSE_MODEL=${GOOSE_MODEL:-anthropic--claude-4.6-sonnet}       # SAP AI Core model via the proxy
LITELLM_HOST=${LITELLM_HOST:-http://litellm-proxy.default.svc.cluster.local:4001}
KEEP_SANDBOX=${KEEP_SANDBOX:-false}                            # true → do NOT delete the sandbox (students inspect logs)
PROMPT_CM=${PROMPT_CM:-dev-toolbox-prompts}                    # CH v2 prompt source
PROMPT_CM_NS=${PROMPT_CM_NS:-dev-toolbox-system}
PROMPT_KEY=${PROMPT_KEY:-health-v2-report-first}
SHOOT=${SHOOT_NAME:-$(kubectl config current-context 2>/dev/null || echo cluster)}
# CLI version: MATCH the cluster's deployed gateway (self-adapting to a per-shoot openshell_version).
OPENSHELL_VER=${OPENSHELL_VER:-$(kubectl get statefulset openshell -n openshell -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's#.*:##')}
OPENSHELL_VER=${OPENSHELL_VER:-0.1.1}
CLI_URL=${CLI_URL:-https://github.com/NVIDIA/OpenShell/releases/download/v${OPENSHELL_VER}/openshell-x86_64-unknown-linux-musl.tar.gz}
case "$OPENSHELL_VER" in
  0.1.1) CLI_SHA256=${CLI_SHA256:-822e8e462944366cb1b3d3b023be20a675016714666124b05ad8699a03c43143} ;;
  *)     CLI_SHA256=${CLI_SHA256:-} ;;
esac
NAME=${NAME:-ci-goose-live-$(date +%s)}; NAME=$(printf '%.19s' "$NAME")   # 19-char sandbox-name cap

command -v kubectl >/dev/null || { echo "kubectl required (cluster-admin on an OpenShell shoot)" >&2; exit 2; }

# ── keyless-only + live prereqs (skip cleanly where absent — like ci-goose) ───────
if ! kubectl -n openshell get secret openshell-admin-sa >/dev/null 2>&1; then
  echo "==> OpenShell not available on this shoot — skipping live goose (keyless-only)" >&2; exit 0
fi
if ! kubectl -n openshell get sa sandbox-viewer >/dev/null 2>&1; then
  echo "==> no sandbox-viewer SA (read-only identity) on this shoot — skipping live goose" >&2; exit 0
fi

# ── isolate the CLI config in a fresh HOME (kubectl uses explicit $KUBECONFIG) ────
export HOME; HOME=$(mktemp -d); trap 'rm -rf "$HOME"' EXIT

# ── 1. openshell CLI (install if not on PATH; version matches the gateway) ────────
OS=$(command -v openshell || true)
if [ -z "$OS" ]; then
  echo "==> installing openshell CLI v$OPENSHELL_VER (matches cluster gateway) …" >&2
  curl -fsSL "$CLI_URL" -o "$HOME/os.tgz"
  if [ -n "$CLI_SHA256" ]; then echo "$CLI_SHA256  $HOME/os.tgz" | sha256sum -c -; else echo "==> no pinned sha for v$OPENSHELL_VER — skipping checksum (official signed release)" >&2; fi
  tar -xzf "$HOME/os.tgz" -C "$HOME"
  OS="$(find "$HOME" -maxdepth 4 -type f -name openshell | head -1)"
  chmod +x "$OS"
fi
"$OS" --version >&2

# ── 2. derive gateway host + Keycloak issuer from the cluster (no hardcoded values) ──
VS_HOST=$(kubectl -n openshell get virtualservice -o jsonpath='{.items[0].spec.hosts[0]}' 2>/dev/null || true)
[ -n "$VS_HOST" ] || { echo "ERROR: no openshell VirtualService in ns openshell" >&2; exit 2; }
GW_URL="https://$VS_HOST"
ISSUER="https://keycloak.${VS_HOST#openshell.}/realms/ateam-isveng"
echo "==> gateway=$GW_URL  issuer=$ISSUER  shoot=$SHOOT" >&2

# ── 3. read the confidential client secret + register client-credentials (headless) ──
OPENSHELL_OIDC_CLIENT_SECRET=$(kubectl -n openshell get secret openshell-admin-sa \
  -o jsonpath='{.data.OPENSHELL_OIDC_CLIENT_SECRET}' 2>/dev/null | base64 -d || true)
[ -n "$OPENSHELL_OIDC_CLIENT_SECRET" ] || { echo "ERROR: Secret openshell-admin-sa not readable" >&2; exit 2; }
export OPENSHELL_OIDC_CLIENT_SECRET
"$OS" gateway add "$GW_URL" --oidc-issuer "$ISSUER" \
  --oidc-client-id openshell-admin-sa --oidc-audience openshell-oidc >&2

# ── 4. mint a short-lived READ-ONLY sandbox-viewer token → in-box kubeconfig ──────
SBV_TOKEN=$(kubectl -n openshell create token sandbox-viewer --duration=3600s 2>/dev/null || true)
[ -n "$SBV_TOKEN" ] || { echo "ERROR: could not mint sandbox-viewer token (RBAC?)" >&2; exit 2; }

# ── 5. create the EXPLICIT-POLICY sandbox (canonical policy inline; both providers) ──
# = modules/k8s/manifests/kro/openshell/sandbox-policy-cluster-ops.yaml (embedded so this script stays portable).
cat > "$HOME/pol.yaml" <<'POL'
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /bin, /sbin, /lib, /lib64, /etc, /opt, /proc, /dev/urandom, /var/log, /app]
  read_write: [/sandbox, /tmp, /home, /run, /var/tmp, /dev/null]
landlock:
  compatibility: best_effort
network_policies:
  litellm:
    name: litellm-proxy
    endpoints:
      - { host: litellm-proxy.default.svc.cluster.local, port: 4001, protocol: rest, enforcement: enforce, access: read-write }
    binaries:
      - { path: /usr/local/bin/claude }
      - { path: /usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe }
      - { path: /usr/local/bin/goose }
      - { path: /usr/local/bin/node }
      - { path: /usr/bin/curl }
  k8s_api:
    name: k8s-apiserver
    endpoints:
      - { host: kubernetes.default.svc.cluster.local, port: 443, protocol: rest, tls: skip, enforcement: enforce, access: read-only }
    binaries:
      - { path: /usr/local/bin/kubectl }
      - { path: /usr/local/bin/kyma }
POL

echo "==> creating explicit-policy sandbox '$NAME' from $IMAGE …" >&2
"$OS" sandbox create --name "$NAME" --from "$IMAGE" \
  --provider litellm --provider litellm-openai --policy "$HOME/pol.yaml" --detach -- sleep infinity >&2
for _ in $(seq 1 60); do "$OS" sandbox list 2>/dev/null | grep "$NAME" | grep -qiE 'ready|running' && break; sleep 2; done
if ! "$OS" sandbox list 2>/dev/null | grep "$NAME" | grep -qiE 'ready|running'; then
  echo "ERROR: sandbox '$NAME' did not become ready" >&2; "$OS" sandbox delete "$NAME" >/dev/null 2>&1 || true; exit 1
fi
sleep 10   # let the policy + provider egress attach before goose connects

# Cleanup on exit — UNLESS KEEP_SANDBOX=true (leave it for students to inspect the logs).
if [ "$KEEP_SANDBOX" = "true" ]; then
  echo "==> KEEP_SANDBOX=true — leaving '$NAME' alive. Inspect: kubectl -n $SHOOT logs default--$NAME  (the reaper backstops it)" >&2
else
  trap '"$OS" sandbox delete "$NAME" >/dev/null 2>&1 || true; rm -rf "$HOME"' EXIT
fi

# ── 6. inject the read-only kubeconfig + goose env (like scoped-ops / notebook 05b) ──
"$OS" sandbox exec --name "$NAME" --no-tty -- sh -c 'umask 077; cat > /tmp/sandbox-kubeconfig' <<KCFG
apiVersion: v1
kind: Config
clusters:
- {name: c, cluster: {server: https://kubernetes.default.svc.cluster.local, insecure-skip-tls-verify: true}}
contexts:
- {name: c, context: {cluster: c, user: u}}
current-context: c
users:
- {name: u, user: {token: ${SBV_TOKEN}}}
KCFG
"$OS" sandbox exec --name "$NAME" --no-tty -- sh -c 'umask 077; cat > /tmp/scoped-ops.env' <<ENV
export KUBECONFIG=/tmp/sandbox-kubeconfig
export GOOSE_PROVIDER=litellm GOOSE_MODEL=${GOOSE_MODEL}
export LITELLM_HOST=${LITELLM_HOST}
export GOOSE_DISABLE_SESSION_NAMING=true
ENV

# ── 7. resolve the prompt: explicit file/stdin override, else the CH v2 prompt from the CM ──
if [ "$PROMPT_SRC" = "-" ]; then
  PROMPT=$(cat)
elif [ -n "$PROMPT_SRC" ]; then
  PROMPT=$(cat "$PROMPT_SRC")
else
  PROMPT=$(kubectl -n "$PROMPT_CM_NS" get cm "$PROMPT_CM" -o jsonpath="{.data.$PROMPT_KEY}" 2>/dev/null | sed "s/__SHOOT__/$SHOOT/g")
  [ -n "$PROMPT" ] || { echo "ERROR: CH v2 prompt '$PROMPT_KEY' not in cm/$PROMPT_CM (ns $PROMPT_CM_NS)" >&2; exit 2; }
fi
printf '%s' "$PROMPT" | "$OS" sandbox exec --name "$NAME" --no-tty -- sh -c 'umask 077; cat > /tmp/p'

# ── 8. report extractor (goose --output-format json → the FINAL report only) ──────
"$OS" sandbox exec --name "$NAME" --no-tty -- sh -c 'umask 077; cat > /tmp/gr.py' <<'PYX'
import json, sys
raw = sys.stdin.read(); i = raw.find("{")
try:
    msgs = json.loads(raw[i:]).get("messages", [])
    lt = -1
    for idx, m in enumerate(msgs):
        if any("tool" in (b.get("type", "").lower()) for b in m.get("content", [])):
            lt = idx
    tail = msgs[lt + 1:] if lt >= 0 else msgs
    t = [b.get("text", "") for m in tail if m.get("role") == "assistant"
         for b in m.get("content", []) if b.get("type") == "text"]
    if not t:
        a = [m for m in msgs if m.get("role") == "assistant"]
        t = [b.get("text", "") for b in a[-1].get("content", []) if b.get("type") == "text"] if a else []
    o = "\n".join(x for x in t if x).strip()
    sys.stdout.write(o if o else raw)
except Exception:
    sys.stdout.write(raw)
PYX

# ── 9. run goose with LIVE read-only kubectl (keyless via litellm) ────────────────
# Pass env via `env …` (NOT `source /tmp/scoped-ops.env`): the box's sh is dash, which has no `source` builtin, so a
# sourced file silently no-ops and goose falls back to its litellm default (localhost:4000) → "connection refused".
# KUBECONFIG is set here so goose's kubectl subprocess inherits the read-only sandbox-viewer config.
echo "==> running goose LIVE (read-only kubectl, keyless via $LITELLM_HOST, model $GOOSE_MODEL) …" >&2
"$OS" sandbox exec --name "$NAME" -- env \
  KUBECONFIG=/tmp/sandbox-kubeconfig \
  GOOSE_PROVIDER=litellm GOOSE_MODEL="$GOOSE_MODEL" LITELLM_HOST="$LITELLM_HOST" GOOSE_DISABLE_SESSION_NAMING=true \
  sh -c 'goose run --quiet --output-format json --text "$(cat /tmp/p)" 2>/dev/null | python3 /tmp/gr.py'
