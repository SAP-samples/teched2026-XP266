# Getting Started — access your Kyma runtime and tour the AI-ops stack

In this exercise you sign in to your **pre-provisioned** SAP BTP, Kyma runtime, get oriented in **Busola** (the Kyma dashboard), and take a quick tour of the AI operations stack that is **already running** for you. You will not deploy anything — everything is in place; you are here to understand it and play with it.

> [!NOTE]
> Each attendee has their own runtime named `xp266-NNN` (for example `xp266-011`). Wherever you see `xp266-NNN` below, use the number you were given. Your Busola URL and sign-in details are handed out at the start of the session.

## Exercise 0.1 - Sign in to Busola

1. Open your Busola URL in the browser — it looks like:

   ```
   https://busola.xp266-NNN.<workshop-domain>/
   ```

2. Sign in with the workshop identity provider when prompted (single sign-on). You land on the Busola **Cluster Overview** for your runtime.
<br>![](images/00_01_0010.png)

## Exercise 0.2 - See what is already deployed

Everything in the "pink" layer of the architecture — the LiteLLM proxy, the Goose diagnostic jobs, the interactive chat agent, JupyterHub, the telemetry and spend pipeline — was deployed for you declaratively with **KRO** (Kubernetes Resource Orchestrator) as a single unit. Let's confirm it's there.

1. In Busola, use the namespace switcher (top left) to look at the key namespaces:

   | Namespace | What runs there |
   |---|---|
   | `default` | the **LiteLLM proxy** (`litellm-proxy`), the **dev-toolbox** (Goose diagnostics), PostgreSQL, Pushgateway |
   | `openclaw` | the **interactive chat agent** + the diagnostic output ConfigMaps |
   | `jupyter` | **JupyterHub** (the Python playground) |
   | `kyma-system` | Kyma modules — Istio, Telemetry, API Gateway |

2. Open **Cluster Details → Custom Resources** (or the left-nav groups) and note the KRO-managed kinds already present — you'll meet these through the workshop:

   ```
   LiteLLMProxy · DevToolbox · ChatUI · JupyterHub
   ClusterHealthReport · AuditLogCatalog · FleetStatus
   ```

3. Open the **Autonomous Fleet Status** card (left nav) — a live summary of your cluster: health, AI Core catalog counts, and today's LiteLLM spend. It is populated by the diagnostic jobs you'll play with in [Exercise 3](../ex3/README.md).
<br>![](images/00_02_0010.png)

## Exercise 0.3 - Where this sits in the SAP AI landscape

The pink components you just found are the **self-hosted, in-cluster agent layer**. Everything else on the map — SAP Joule, the Generative AI Hub, SAP AI Core, the data and runtime layers — is the SAP AI platform your agent **consumes**. The one connection that matters for this workshop is the arrow from your agent to SAP AI Core, through the LiteLLM proxy:

```
Goose / Chat UI  ──▶  LiteLLM proxy (:4001)  ──▶  SAP AI Core  ──▶  Claude · GPT · Mistral · Nova
```

You'll follow that arrow in the next exercise.

## Summary

You signed in to your Kyma runtime in Busola, confirmed the pre-deployed AI-ops stack (LiteLLM, Goose, the interactive chat agent, JupyterHub, and the KRO custom resources), and saw where it fits in the SAP AI landscape.

Continue to - [Exercise 1 - The LLM gateway: LiteLLM and SAP AI Core](../ex1/README.md)
