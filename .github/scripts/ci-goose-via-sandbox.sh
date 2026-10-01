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
# Optional 2nd-pass reformat (EMPTY → skip, emit the raw goose report — the admin-GHA default, unchanged). When
# set, the reformat prompt is read from the dev-toolbox-prompts CM via the OUTER kubectl, written into the box, and
# `claude -p` runs IN the box (keyless) → emits <guide> + <<<RAW-GOOSE-REPORT>>> + <raw> for the caller to split.
REFORMAT_KEY=${REFORMAT_KEY:-}
PROMPT_CM=${PROMPT_CM:-dev-toolbox-prompts}
PROMPT_CM_NS=${PROMPT_CM_NS:-dev-toolbox-system}
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

# ── 5. create the sandbox with an EXPLICIT EGRESS POLICY (LLM-only — litellm-proxy for goose + claude; NO k8s
# apiserver → NO in-box kubectl: pure snapshot summarization). The policy is REQUIRED for the claude reformat:
# openshell egress is BINARY-scoped, so the `claude` binary needs its own litellm-proxy endpoint entry. goose's
# egress is wired by the litellm-openai provider, but claude's is NOT → ConnectionRefused without this policy.
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
POL
echo "==> creating explicit-policy sandbox '$NAME' from $IMAGE (LLM-only egress) …" >&2
"$OS" sandbox create --name "$NAME" --from "$IMAGE" --provider litellm --provider litellm-openai --policy "$HOME/pol.yaml" --detach -- sleep infinity >&2
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
# --output-format json + the extractor → the clean final report, captured to /tmp/raw_report.md in the box.
"$OS" sandbox exec --name "$NAME" -- env \
  GOOSE_PROVIDER=litellm GOOSE_MODEL="$GOOSE_MODEL" LITELLM_HOST="$LITELLM_HOST" GOOSE_DISABLE_SESSION_NAMING=true \
  sh -c 'goose run --quiet --output-format json --text "$(cat /tmp/p)" 2>/dev/null | python3 /tmp/gr.py > /tmp/raw_report.md' </dev/null

# ── 7. OPTIONAL REFORMAT PASS — IN the box, KEYLESS (claude -p; provider sentinel resolved at egress) ──────────────
# Mirrors ci-goose-via-sandbox-live.sh. EMPTY REFORMAT_KEY → emit the raw goose report unchanged (admin-GHA default).
# When set: fetch the reformat prompt via the OUTER kubectl, write it into the box, run claude -p in-box, and emit
# <guide> + <<<RAW-GOOSE-REPORT>>> + <raw> so the caller splits report (executive guide) + reportRaw (raw goose).
# claude auths with ANTHROPIC_AUTH_TOKEN=$ANTHROPIC_API_KEY (the litellm-provider resolve sentinel) → NO real key in box.
REFMT=""
[ -n "$REFORMAT_KEY" ] && REFMT=$(kubectl -n "$PROMPT_CM_NS" get cm "$PROMPT_CM" -o jsonpath="{.data.$REFORMAT_KEY}" 2>/dev/null || true)
if [ -n "$REFMT" ]; then
  echo "==> reformatting the report IN the sandbox via claude -p (keyless) …" >&2
  printf '%s' "$REFMT" | "$OS" sandbox exec --name "$NAME" --no-tty -- sh -c 'umask 077; cat > /tmp/refmt'
  "$OS" sandbox exec --name "$NAME" --no-tty -- bash -lc '
    # Point claude at litellm-proxy:4001 (the egress policy above lists the claude binary against that host) and
    # auth with the resolve sentinel ($ANTHROPIC_API_KEY → ANTHROPIC_AUTH_TOKEN) → keyless, NO real key in the box.
    # BOTH the policy AND these exports are needed: the policy opens the binary→host egress, the exports tell claude
    # to use it (the provider does not inject a reachable anthropic endpoint on its own here).
    export ANTHROPIC_BASE_URL=http://litellm-proxy.default.svc.cluster.local:4001
    export ANTHROPIC_AUTH_TOKEN="$ANTHROPIC_API_KEY"; unset ANTHROPIC_API_KEY
    export ANTHROPIC_MODEL=anthropic--claude-4.7-opus CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1
    ST=$(grep -m1 "^## Health Status:" /tmp/raw_report.md | grep -oiE "HEALTHY|WARNING|CRITICAL" | head -1 | tr "[:lower:]" "[:upper:]")
    OUT=""
    [ -s /tmp/raw_report.md ] && OUT=$(claude -p "$(cat /tmp/refmt)" < /tmp/raw_report.md 2>/dev/null)
    if [ -n "$OUT" ]; then
      [ -n "$ST" ] && printf "## Health Status: %s\n\n" "$ST"
      printf "%s\n" "$OUT"
      printf "\n\n<<<RAW-GOOSE-REPORT>>>\n\n"   # separator: the caller splits this into report (guide) + reportRaw (goose)
      cat /tmp/raw_report.md
    else
      cat /tmp/raw_report.md    # reformat empty/failed → raw goose report unchanged
    fi' </dev/null
else
  "$OS" sandbox exec --name "$NAME" --no-tty -- sh -c 'cat /tmp/raw_report.md' </dev/null
fi
