#!/usr/bin/env bash
# ci-goose-via-sandbox.sh — run goose KEYLESS inside an OpenShell sandbox, headless (client-credentials).
#
# Purpose: let a GitHub Actions admin workflow (or an operator) run the "interpret cluster health" goose step WITHOUT a real
# OpenAI/Anthropic key. The sandbox runs IN-cluster and reaches the in-cluster LiteLLM proxy (→ SAP AI Core); the real key
# never leaves the cluster (the supervisor resolves an injected sentinel at egress). This is the in-cluster twin of the old
# runner-local `goose run` that used real public keys — it kills the real-key GitHub secrets and routes LLM traffic through
# the governed, spend-tracked SAP AI Core proxy. Mirrors the GHA step; validated on xp266-001.
#
# Auth: reuses the CONFIDENTIAL `openshell-admin-sa` Keycloak client (OIDC client-credentials grant — no browser). The client
# secret is READ FROM THE CLUSTER at runtime (Secret openshell-admin-sa, key OPENSHELL_OIDC_CLIENT_SECRET, ns openshell) — no
# GitHub secret needed where the caller holds cluster-admin (the teched native-SA kubeconfig does). Gateway host + Keycloak
# issuer are DERIVED from the cluster's openshell VirtualService (openshell.<shoot>.<domain>) — no hardcoded per-shoot values.
#
#   KUBECONFIG=… ./ci-goose-via-sandbox.sh <prompt-file>     # prompt from a file
#   echo "…" | KUBECONFIG=… ./ci-goose-via-sandbox.sh -      # prompt from stdin (default)
#
# Requires: kubectl (cluster-admin on an OpenShell-enabled shoot), curl, tar, sha256sum. The openshell CLI is auto-installed
# (pinned v0.1.1 x86_64 musl) if not already on PATH. The reasoning goose uses the KEYLESS `litellm-openai` provider.
set -euo pipefail

# ── inputs ──────────────────────────────────────────────────────────────────────
PROMPT_SRC=${1:--}                                             # a file path, or '-' for stdin
IMAGE=${IMAGE:-localhost:32137/dev-toolbox-bash:latest}        # in-cluster registry NodePort ref (goose baked in)
GOOSE_MODEL=${GOOSE_MODEL:-anthropic--claude-4.6-sonnet}       # SAP AI Core model via the proxy
LITELLM_HOST=${LITELLM_HOST:-http://litellm-proxy.default.svc.cluster.local:4001}
# CLI version: MATCH the cluster's deployed gateway (self-adapting to a per-shoot openshell_version) — read the gateway
# StatefulSet image tag; fall back to 0.1.1. URL derived from the version; sha is best-effort (pin known versions, else
# skip — the tarball is the official signed NVIDIA release over https).
OPENSHELL_VER=${OPENSHELL_VER:-$(kubectl get statefulset openshell -n openshell -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's#.*:##')}
OPENSHELL_VER=${OPENSHELL_VER:-0.1.1}
CLI_URL=${CLI_URL:-https://github.com/NVIDIA/OpenShell/releases/download/v${OPENSHELL_VER}/openshell-x86_64-unknown-linux-musl.tar.gz}
case "$OPENSHELL_VER" in
  0.1.1) CLI_SHA256=${CLI_SHA256:-822e8e462944366cb1b3d3b023be20a675016714666124b05ad8699a03c43143} ;;
  *)     CLI_SHA256=${CLI_SHA256:-} ;;   # unknown version → skip the checksum pin
esac
NAME=${NAME:-ci-goose-$(date +%s)}; NAME=$(printf '%.19s' "$NAME")   # 19-char sandbox-name cap

command -v kubectl >/dev/null || { echo "kubectl required (cluster-admin on an OpenShell shoot)" >&2; exit 2; }

# ── keyless-only ────────────────────────────────────────────────────────────────
# goose runs ONLY inside an OpenShell sandbox — NO real LLM key anywhere (the OPENAI_API_KEY/ANTHROPIC_API_KEY secrets
# were removed from CI). Where OpenShell is not deployed (its admin-sa secret isn't readable), SKIP the analysis rather
# than fall back to a real-key run. (The runner can't reach the in-cluster litellm-proxy ClusterIP, so there is no
# keyless fallback outside the sandbox.)
if ! kubectl -n openshell get secret openshell-admin-sa >/dev/null 2>&1; then
  echo "==> OpenShell not available on this shoot — skipping goose analysis (keyless-only; no real LLM key in CI)" >&2
  exit 0
fi

# ── OpenShell (keyless) path ──────────────────────────────────────────────────────
# Isolate the openshell CLI config in a fresh HOME (mirrors a clean CI runner; avoids colliding with an operator's
# existing gateway entries). kubectl uses $KUBECONFIG (explicit), so this doesn't affect cluster access.
export HOME; HOME=$(mktemp -d); trap 'rm -rf "$HOME"' EXIT

# ── 1. openshell CLI (install if not on PATH; version matches the cluster gateway) ────────────────
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

# ── 2. derive gateway host + Keycloak issuer from the cluster (no hardcoded per-shoot values) ─────
VS_HOST=$(kubectl -n openshell get virtualservice -o jsonpath='{.items[0].spec.hosts[0]}' 2>/dev/null || true)
[ -n "$VS_HOST" ] || { echo "ERROR: no openshell VirtualService in ns openshell — is OpenShell deployed on this shoot?" >&2; exit 2; }
GW_URL="https://$VS_HOST"                                      # https://openshell.<shoot>.<domain>
ISSUER="https://keycloak.${VS_HOST#openshell.}/realms/ateam-isveng"   # swap openshell.→keycloak.
echo "==> gateway=$GW_URL  issuer=$ISSUER" >&2

# ── 3. read the confidential client secret from the cluster (no GitHub secret) ────
OPENSHELL_OIDC_CLIENT_SECRET=$(kubectl -n openshell get secret openshell-admin-sa \
  -o jsonpath='{.data.OPENSHELL_OIDC_CLIENT_SECRET}' 2>/dev/null | base64 -d || true)
[ -n "$OPENSHELL_OIDC_CLIENT_SECRET" ] || { echo "ERROR: Secret openshell-admin-sa not readable in ns openshell" >&2; exit 2; }
export OPENSHELL_OIDC_CLIENT_SECRET

# ── 4. client-credentials gateway registration (headless — no browser) ────────────
# No --client-secret flag: the secret is taken from OPENSHELL_OIDC_CLIENT_SECRET; --oidc-issuer forces the OIDC grant.
"$OS" gateway add "$GW_URL" --oidc-issuer "$ISSUER" \
  --oidc-client-id openshell-admin-sa --oidc-audience openshell-oidc >&2

# ── 5. create a CONTAINED sandbox (LLM-only egress via the litellm-openai provider profile) ───────
echo "==> creating contained sandbox '$NAME' from $IMAGE …" >&2
"$OS" sandbox create --name "$NAME" --from "$IMAGE" --provider litellm-openai --detach -- sleep infinity >&2
for _ in $(seq 1 60); do "$OS" sandbox list 2>/dev/null | grep "$NAME" | grep -qiE 'ready|running' && break; sleep 2; done
if ! "$OS" sandbox list 2>/dev/null | grep "$NAME" | grep -qiE 'ready|running'; then
  echo "ERROR: sandbox '$NAME' did not become ready" >&2; "$OS" sandbox delete "$NAME" >/dev/null 2>&1 || true; exit 1
fi
# delete the ephemeral sandbox on exit (the reaper backstops any leak within ~1h+TTL)
trap '"$OS" sandbox delete "$NAME" >/dev/null 2>&1 || true; rm -rf "$HOME"' EXIT

# ── 6. pipe the prompt into the box, then run goose keyless (reads the prompt IN-box) ─────────────
if [ "$PROMPT_SRC" = "-" ]; then cat; else cat "$PROMPT_SRC"; fi \
  | "$OS" sandbox exec --name "$NAME" --no-tty -- sh -c 'umask 077; cat > /tmp/p'
# Report extractor: goose --output-format json emits the whole agent session (tool calls + deliberations); this parses it
# and prints ONLY the final report (all assistant text after the last tool-call). Written into the box (dev-toolbox has
# python3) so there's no runner-side dependency.
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
echo "==> running goose (keyless via $LITELLM_HOST, model $GOOSE_MODEL) …" >&2
# `env … sh -c '…$(cat /tmp/p)…'` runs IN the box: env sets goose's provider/model/host, sh -c reads the in-box prompt.
# --output-format json + the extractor → stdout is the clean final report (no banner/deliberations/tool-call trail).
"$OS" sandbox exec --name "$NAME" -- env \
  GOOSE_PROVIDER=litellm GOOSE_MODEL="$GOOSE_MODEL" LITELLM_HOST="$LITELLM_HOST" GOOSE_DISABLE_SESSION_NAMING=true \
  sh -c 'goose run --quiet --output-format json --text "$(cat /tmp/p)" 2>/dev/null | python3 /tmp/gr.py'
