# Exercise 5 - Observability and spend

Running LLMs in production raises an obvious question: **what is this costing, and who is spending it?**

In this exercise you see how the stack answers that — every call is metered by the LiteLLM proxy, scraped by **Kyma Telemetry**, shipped to **SAP Cloud Logging**, and rendered as dashboards you read straight from Busola.

```
LiteLLM proxy  ──(Prometheus metrics: spend, tokens, model)──▶  Kyma Telemetry MetricPipeline
                                                                        │
                                                                        ▼
                                                              SAP Cloud Logging (OpenSearch)
                                                                        │
                                              ┌─────────────────────────┴───────────────┐
                                              ▼                                           ▼
                                    LiteLLM Spend dashboard                      LLM Overview dashboard
                                    (opened from Busola)                         (opened from Busola)
```

> [!NOTE]
> ✅ **No terminal needed** — this exercise is entirely browser-based.

## Exercise 5.1 - The telemetry path (concept)

1. In Busola, open **namespace `kyma-system` → Custom Resources → MetricPipeline**. This is the declarative pipe that forwards scraped metrics to SAP Cloud Logging — no Prometheus server to run, no Grafana to host.
<br>![](images/05_01_0010.png)

> [!NOTE]
> The LiteLLM proxy exposes Prometheus-style metrics (spend per key, tokens in/out, per-model latency). A **pod annotation** marks it for scraping; the `MetricPipeline` (managed by the Kyma **Telemetry** module) ships those metrics out via OTLP to **SAP Cloud Logging**, where they're stored in OpenSearch and visualized. This is the same managed-telemetry pattern SAP BTP gives you for logs, metrics, and traces — you *use* it, you don't operate it.

## Exercise 5.2 - Open the spend dashboards

The dashboards are one click away from Busola's left navigation.

1. In Busola, open the **SAP Cloud Logging** navigation entry, then the **LiteLLM Spend** dashboard link. It opens SAP Cloud Logging (OpenSearch Dashboards) in a new tab, single sign-on.
<br>![](images/05_02_0010.png)

2. Read the split. You'll see spend attributed by **API key / caller** and by **model**:

   | Caller | Tier / model | Typical share |
   |---|---|---|
   | Goose diagnostic jobs (ex3) | `reasoning-fast` — Sonnet | steady, scheduled |
   | Chat + terminal agents (ex2, ex4) | `reasoning-hard` — Opus | bursty, interactive |
   | JupyterHub notebooks (ex7) | whatever you call | your experiments show up here |

3. Open the **LLM Overview** dashboard for request volume, token throughput, and per-model latency.

> [!TIP]
> This is the pay-off of routing **everything through one proxy** (Exercise 1): because no agent talks to a model directly, *every* token is attributable. Trigger a diagnose run (ex3) or chat with the agent (ex4), wait a minute, and watch your own activity appear on the dashboard.

## Exercise 5.3 - The FleetStatus card

1. In Busola, open the **FleetStatus** custom resource (cluster overview). It surfaces the health and the **LLM Dashboards** / **SAP Cloud Logging** shortcuts as cards — a single pane that links the running system to its observability.
<br>![](images/05_03_0010.png)

## Summary

You followed one LLM call's metrics from the LiteLLM proxy through a Kyma Telemetry `MetricPipeline` into SAP Cloud Logging, and read the **LiteLLM Spend** and **LLM Overview** dashboards from Busola — seeing the autonomous-jobs (Sonnet) vs interactive-agents (Opus) spend split that the single-proxy design makes possible.

Continue to - [Exercise 6 - Sandbox and guardrails](../ex6/README.md)
