# Exercise 2 - The Busola web terminal 🔧 *(optional — go deeper)*

> [!NOTE]
> **This whole exercise is the optional "go deeper" track** — it's the most fun if you're comfortable with a shell, but **nothing here is required to finish the workshop**. If you'd rather stay UI-only, skip straight to [Exercise 3](../ex3/README.md): you'll see these same agents running *for* you, autonomously, with everything readable in Busola.

Busola ships an **in-cluster web terminal** — a pod, in your browser, that already has **`goose`**, **`Claude Code`**, `kubectl`, and the `kyma` CLI installed and **pre-authenticated to the LiteLLM proxy**. No local install, no login, no API key. In this exercise you run both AI agents against your own cluster and see them answer via SAP AI Core.

```
You (browser)
   │  Busola web terminal (a pod)
   ▼
goose / claude ──▶ LiteLLM proxy :4001 ──▶ SAP AI Core
   │
   └── kubectl / kyma ──▶ your Kyma cluster
```

## Exercise 2.1 - Open the terminal and check the tools

1. In Busola, open the cluster menu (top-right) and choose **Terminal**. A shell opens in the browser.
<br>![](images/02_01_0010.png)

2. Confirm the pre-installed toolchain:

   Command:
   ```bash
   goose --version && claude --version && kubectl version --client -o yaml | grep gitVersion
   ```
   Output (versions may differ):
   ```
   goose 1.49.0
   2.1.278 (Claude Code)
   gitVersion: v1.35.0
   ```

> [!NOTE]
> The terminal is **auto-authenticated**: a start-up script fetches the LiteLLM key from the `llm-proxy-credentials` Secret and exports the environment both agents need (`GOOSE_PROVIDER=litellm`, `ANTHROPIC_BASE_URL`, model tiers…). You never see or handle a key.

## Exercise 2.2 - Ask Goose

Goose is an autonomous agent with shell-tool access. Give it a one-shot task:

Command:
```bash
goose run --max-turns 3 --text "Using kubectl, how many namespaces are in this cluster, and which are not Active?"
```
Goose will run `kubectl get ns`, reason over the result, and answer in prose — the reasoning happens on SAP AI Core via the proxy.

> [!TIP]
> For a back-and-forth session instead of one-shot, run `goose session` and type your questions; `Ctrl-D` to exit.

## Exercise 2.3 - Ask Claude Code, and pipe real cluster data

`claude -p` runs Claude Code headlessly. It shines when you **pipe cluster data into it**:

Command:
```bash
kubectl get pods -A -o wide | claude -p "Which pods look unhealthy or mis-scheduled? Give a short table by severity."
```

Or hand it a full Kyma diagnosis:

Command:
```bash
kyma alpha diagnose cluster -f json | claude -p "Summarize this cluster's health in 3 bullets and flag anything risky."
```

> [!IMPORTANT]
> This is the **same LLM path** as Exercise 1 — the agents are just convenient front-ends over the LiteLLM proxy → SAP AI Core. In [Exercise 3](../ex3/README.md) you'll see this exact pattern (`kyma diagnose` → Goose) running **autonomously on a schedule**, writing its findings into Kubernetes.

## Summary

You opened the in-cluster web terminal, confirmed Goose and Claude Code are pre-authenticated to the LiteLLM proxy, and ran both against your cluster — one-shot Goose, and Claude Code fed live `kubectl`/`kyma` output. Same proxy, same SAP AI Core, now driven by an agent.

Continue to - [Exercise 3 - Play with the autonomous Goose diagnostic jobs](../ex3/README.md)
