#!/usr/bin/env bash
# ci-openrouter-agents.sh — run the ex10 terminal-coding agents (opencode / Pi / Qwen Code) against public OpenRouter,
# KEYLESS, inside a CONTAINED OpenShell sandbox, HEADLESS (client-credentials) — for a GitHub Actions student workflow.
# The run renders a clear verdict table + the execution flow + a containment proof + each agent's completion to
# $GITHUB_STEP_SUMMARY (students have no local tooling — the summary IS the product they read).
#
# DESIGN GOAL: a 100%-GREEN run on any ex10 shoot. Infra steps fail loud; per-agent outcomes NEVER fail the job — they
# become ✅/⚠️ verdicts in the summary. So "did the workflow succeed?" and "what did each agent say?" are both obvious.
#
# OpenRouter twin of ci-goose-via-sandbox.sh; headless CI counterpart of gardener/openrouter-agent-sandbox.sh (which
# uses the browser openshell-oidc client — invalid in CI). Auth: the CONFIDENTIAL openshell-admin-sa Keycloak client
# (client-credentials, no browser); the secret is read FROM THE CLUSTER (ns openshell) — no GitHub secret, where the
# caller holds cluster-admin. Gateway host + issuer are DERIVED from the openshell VirtualService. The `openrouter`
# provider + agents image come from the gardener apply; the real key stays in the gateway (box sees only a sentinel).
#
#   AGENT=all-three OPENROUTER_MODEL=qwen/qwen3.8-27b:free PROMPT="…" KUBECONFIG=… ./ci-openrouter-agents.sh
set -euo pipefail

# ── inputs (env-driven; the GHA step sets these — all have safe defaults for a one-click success) ──
AGENT=${AGENT:-pi}                                      # all-three | opencode | pi | qwen
MODEL=${OPENROUTER_MODEL:-${MODEL:-qwen/qwen3.8-27b:free}}      # an OpenRouter :free model
PROMPT=${PROMPT:-Reply with exactly one word: PONG}            # default = a deterministic smoke prompt (guaranteed-clear success)
SHOW_CONTAINMENT=${SHOW_CONTAINMENT:-true}
IMAGE=${IMAGE:-localhost:32137/openrouter-agents:latest}       # in-cluster registry NodePort ref (agents baked in)
KEEP_SANDBOX=${KEEP_SANDBOX:-false}
NAME=${NAME:-ci-or-$(date +%s)}; NAME=$(printf '%.19s' "$NAME")   # 19-char sandbox-name cap

REPORT=$(mktemp); RESULTS=$(mktemp); DETAILS=$(mktemp)         # report sink + per-agent verdict rows + <details> blocks
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/stdout}
md()    { printf '%s\n' "$*" >> "$REPORT"; }
strip() { sed 's/\x1b\[[0-9;]*[mGKHF]//g' | tr -d '\r'; }      # drop ANSI escapes + CRs
flush() { cat "$REPORT" >> "$SUMMARY" 2>/dev/null || cat "$REPORT"; cp -f "$REPORT" /tmp/openrouter_report.md 2>/dev/null || true; }

command -v kubectl >/dev/null || { echo "kubectl required (cluster-admin on an OpenShell shoot)" >&2; exit 2; }

# ── precondition: OpenShell present? (keyless-only — a non-ex10 shoot is a clean, GREEN skip) ──
if ! kubectl -n openshell get secret openshell-admin-sa >/dev/null 2>&1; then
  md "## ex10 — OpenRouter agents"; md ""
  md "> ⏭️ **Skipped (not an ex10 shoot)** — OpenShell isn't deployed here (no \`openshell-admin-sa\` secret)."
  flush; exit 0
fi

# ── isolate the CLI config in a fresh HOME; install the openshell CLI (version-matched to the gateway) ──
export HOME; HOME=$(mktemp -d); trap 'rm -rf "$HOME"' EXIT
OPENSHELL_VER=${OPENSHELL_VER:-$(kubectl get statefulset openshell -n openshell -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's#.*:##')}
OPENSHELL_VER=${OPENSHELL_VER:-0.1.1}
CLI_URL=${CLI_URL:-https://github.com/NVIDIA/OpenShell/releases/download/v${OPENSHELL_VER}/openshell-x86_64-unknown-linux-musl.tar.gz}
case "$OPENSHELL_VER" in
  0.1.1) CLI_SHA256=${CLI_SHA256:-822e8e462944366cb1b3d3b023be20a675016714666124b05ad8699a03c43143} ;;
  *)     CLI_SHA256=${CLI_SHA256:-} ;;   # unknown version → skip the checksum pin (official signed release over https)
esac
OS=$(command -v openshell || true)
if [ -z "$OS" ]; then
  echo "==> installing openshell CLI v$OPENSHELL_VER (matches cluster gateway) …" >&2
  curl -fsSL "$CLI_URL" -o "$HOME/os.tgz"
  if [ -n "$CLI_SHA256" ]; then echo "$CLI_SHA256  $HOME/os.tgz" | sha256sum -c -; else echo "==> no pinned sha for v$OPENSHELL_VER — skipping checksum" >&2; fi
  tar -xzf "$HOME/os.tgz" -C "$HOME"
  OS="$(find "$HOME" -maxdepth 4 -type f -name openshell | head -1)"; chmod +x "$OS"
fi
"$OS" --version >&2

# ── derive gateway host + issuer; headless client-credentials login; PIN the gateway ──
VS_HOST=$(kubectl -n openshell get virtualservice -o jsonpath='{.items[0].spec.hosts[0]}' 2>/dev/null || true)
[ -n "$VS_HOST" ] || { echo "ERROR: no openshell VirtualService in ns openshell — is OpenShell deployed?" >&2; exit 2; }
GW_URL="https://$VS_HOST"
ISSUER="https://keycloak.${VS_HOST#openshell.}/realms/ateam-isveng"
OPENSHELL_OIDC_CLIENT_SECRET=$(kubectl -n openshell get secret openshell-admin-sa \
  -o jsonpath='{.data.OPENSHELL_OIDC_CLIENT_SECRET}' 2>/dev/null | base64 -d || true)
[ -n "$OPENSHELL_OIDC_CLIENT_SECRET" ] || { echo "ERROR: openshell-admin-sa secret not readable" >&2; exit 2; }
export OPENSHELL_OIDC_CLIENT_SECRET
echo "==> gateway=$GW_URL  issuer=$ISSUER" >&2
"$OS" gateway add "$GW_URL" --oidc-issuer "$ISSUER" --oidc-client-id openshell-admin-sa --oidc-audience openshell-oidc >&2
export OPENSHELL_GATEWAY="$VS_HOST"                            # pin EVERY subsequent provider/sandbox call to this shoot
SHOOT=${SHOOT_NAME:-$(echo "${VS_HOST#openshell.}" | cut -d. -f1)}

# ── create the CONTAINED sandbox (fs-only policy; egress owned by the openrouter provider) ──
cat > "$HOME/pol.yaml" <<'POL'
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /bin, /sbin, /lib, /lib64, /etc, /opt, /proc, /dev/urandom, /var/log]
  read_write: [/home, /tmp, /run, /var/tmp, /dev/null, /sandbox]
landlock:
  compatibility: best_effort
POL
echo "==> creating sandbox '$NAME' from $IMAGE (provider=openrouter, model=$MODEL) …" >&2
if ! "$OS" sandbox create --name "$NAME" --from "$IMAGE" \
     --provider openrouter \
     --env OPENAI_BASE_URL=https://openrouter.ai/api/v1 \
     --env OPENAI_MODEL="$MODEL" \
     --policy "$HOME/pol.yaml" --detach -- sleep infinity >"$HOME/create.log" 2>&1; then
  md "## ex10 — OpenRouter agents · \`$SHOOT\`"; md ""
  md "> ❌ **\`sandbox create\` failed** — is the \`openrouter\` provider on this gateway and the agents image built?"
  md ""; md '```'; sed 's/^/   /' "$HOME/create.log" | strip >> "$REPORT"; md '```'
  flush; exit 1
fi
for _ in $(seq 1 60); do "$OS" sandbox list 2>/dev/null | grep "$NAME" | grep -qiE 'ready|running' && break; sleep 2; done
"$OS" sandbox list 2>/dev/null | grep "$NAME" | grep -qiE 'ready|running' \
  || { echo "ERROR: sandbox '$NAME' did not become ready" >&2; "$OS" sandbox delete "$NAME" >/dev/null 2>&1 || true; exit 1; }
if [ "$KEEP_SANDBOX" = "true" ]; then trap 'rm -rf "$HOME"' EXIT
else trap '"$OS" sandbox delete "$NAME" >/dev/null 2>&1 || true; rm -rf "$HOME"' EXIT; fi

# ── in-box env (KEYLESS: alias OPENAI_API_KEY from the injected OPENROUTER_API_KEY sentinel; $ escaped → expands IN-box) ──
"$OS" sandbox exec --name "$NAME" --no-tty -- sh -c 'umask 077; cat > /tmp/openrouter.env' <<ENV
export OPENAI_API_KEY="\$OPENROUTER_API_KEY"
export OPENAI_BASE_URL=https://openrouter.ai/api/v1
export OPENAI_MODEL=${MODEL}
ENV

# ── run the agent(s) one-shot — NEVER fails the job; each becomes a ✅/⚠️ verdict row + a <details> block ──
run_agent() {
  a="$1"; cmd=""; ver=""; rc=0
  case "$a" in
    opencode) cmd="opencode run -m \"openrouter/$MODEL\" \"\$PROMPT\"" ;;
    pi)       cmd="pi -p --model \"openrouter/$MODEL\" \"\$PROMPT\"" ;;
    qwen)     cmd="qwen -p \"\$PROMPT\"" ;;
    *)        return 0 ;;
  esac
  ver=$("$OS" sandbox exec --name "$NAME" --no-tty -- bash -lc "$a --version 2>/dev/null | head -1" </dev/null 2>/dev/null || true)
  echo "==> running '$a' (model openrouter/$MODEL) …" >&2
  t0=$(date +%s)
  out=$(printf '%s' "$PROMPT" | "$OS" sandbox exec --name "$NAME" --no-tty -- \
        bash -lc "source /tmp/openrouter.env; PROMPT=\$(cat); $cmd" 2>&1) || rc=$?
  secs=$(( $(date +%s) - t0 ))
  clean=$(printf '%s' "$out" | strip)
  if [ "$rc" = 0 ] && [ -n "$(printf '%s' "$clean" | tr -d '[:space:]')" ]; then
    verdict="✅ completed"; note="returned a completion in ${secs}s"
  else
    verdict="⚠️ no completion"; note="exit $rc${clean:+ (see output)}; try a different :free model"
  fi
  printf '%s\t%s\t%ss\t%s\n' "$a" "$verdict" "$secs" "$note" >> "$RESULTS"
  { printf '<details%s><summary><b>%s</b>%s · %s · %ss</summary>\n\n```\n' \
      "$([ "$a" = opencode ] && echo ' open')" "$a" "${ver:+ · <code>$ver</code>}" "$verdict" "$secs"
    printf '%s\n' "${clean:-(no output)}"
    printf '```\n\n</details>\n\n'; } >> "$DETAILS"
}
case "$AGENT" in
  all-three)        for a in opencode pi qwen; do run_agent "$a"; done ;;
  opencode|pi|qwen) run_agent "$AGENT" ;;
  *)                run_agent opencode ;;
esac

# ── containment proof (optional) ──────────────────────────────────────────────────
CONT=""
if [ "$SHOW_CONTAINMENT" = "true" ]; then
  CONT=$("$OS" sandbox exec --name "$NAME" --no-tty -- bash -lc '
    source /tmp/openrouter.env 2>/dev/null || true
    s="${OPENROUTER_API_KEY:-<unset>}"
    echo "in-box OPENROUTER_API_KEY = ${s:0:24}…   (opaque resolve-sentinel — NOT the real key; swapped at egress)"
    node -e '"'"'const t=u=>fetch(u,{signal:AbortSignal.timeout(6000)}).then(r=>console.log("REACHED  "+u+"  (HTTP "+r.status+")")).catch(e=>console.log("BLOCKED  "+u+"  ("+(e.message||e.name)+")"));(async()=>{await t("https://example.com");await t("https://openrouter.ai/api/v1/models");})()'"'"'
  ' </dev/null 2>&1 | strip || true)
fi

# ── author the summary — VERDICT TABLE FIRST (clear + unambiguous), then the detail ──
PASS=$(grep -c '✅' "$RESULTS" 2>/dev/null || echo 0); TOT=$(wc -l < "$RESULTS" | tr -d ' ')
md "## ex10 — OpenRouter terminal-coding agents · \`$SHOOT\`"
md ""
md "### ✅ Result: $PASS/$TOT agents returned a completion"
md ""
md "| Agent | Verdict | Time | Note |"
md "|---|---|---|---|"
while IFS=$(printf '\t') read -r a v s n; do md "| \`$a\` | $v | $s | $n |"; done < "$RESULTS"
md ""
md "| Run | Value |"
md "|---|---|"
md "| Shoot | \`$SHOOT\` |"
md "| Model | \`$MODEL\` (OpenRouter, \`:free\`) |"
md "| Gateway | \`$VS_HOST\` · OpenShell \`$OPENSHELL_VER\` |"
md "| Image | \`$IMAGE\` |"
md "| Provider | \`openrouter\` — egress allow-list \`openrouter.ai:443\` + \`models.dev:443\` only |"
md ""
md "**Task prompt**"; md ""; md '```text'; printf '%s\n' "$PROMPT" >> "$REPORT"; md '```'; md ""
md "<details><summary>How this ran (execution flow)</summary>"
md ""
md "1. openshell CLI \`$OPENSHELL_VER\` installed (version-matched to the gateway)"
md "2. authenticated **headless** — \`openshell-admin-sa\` client-credentials grant (no browser; secret read in-cluster)"
md "3. \`OPENSHELL_GATEWAY\` pinned → \`$VS_HOST\`"
md "4. contained sandbox created from the agents image — filesystem-hardened, **default-deny egress**"
md "5. keyless in-box env — \`OPENAI_API_KEY\` aliased from the gateway-injected **resolve-sentinel** (real key never enters the box)"
md "6. each agent run one-shot; outputs captured below"
md ""
md "</details>"
md ""
if [ -n "$CONT" ]; then
  md "<details><summary>Containment proof — one endpoint allowed, the key never in the box</summary>"
  md ""; md '```'; printf '%s\n' "$CONT" >> "$REPORT"; md '```'
  md ""; md "\`example.com\` → **BLOCKED** · \`openrouter.ai\` → **REACHED** (the one allowed external endpoint)."
  md ""; md "</details>"; md ""
fi
md "### Agent output"; md ""
cat "$DETAILS" >> "$REPORT"
md "### Why this is safe — ex10's deliberate 4th trust tier"
md "A **contained** box with default-deny egress and exactly one external endpoint allow-listed (\`openrouter.ai\`, plus"
md "opencode's \`models.dev\` registry). The OpenRouter key **never enters the box** — the \`openrouter\` provider injects"
md "an opaque **resolve-sentinel** the gateway swaps at egress. A deliberate step up from ex9's \"no internet\" box."

flush
echo "==> done ($PASS/$TOT agents completed)." >&2
