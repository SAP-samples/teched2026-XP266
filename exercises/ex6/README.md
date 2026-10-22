# Exercise 6 - Observability and spend

Running LLMs in production raises an obvious question: **what is this costing, and who is spending it?**  
In this exercise you see how the stack answers that — every call is metered by the LiteLLM proxy, scraped by **Kyma Telemetry**, shipped to **SAP Cloud Logging**, and surfaced as spend you read straight from the **Cluster Directory** portal (one click, no Busola navigation).

```
LiteLLM proxy  ──(Prometheus metrics: spend, tokens, model)──▶  Kyma Telemetry MetricPipeline
                                                                        │
                                                                        ▼
                                                              SAP Cloud Logging (OpenSearch)
                                                                        │
                                              ┌─────────────────────────┴───────────────┐
                                              ▼                                           ▼
                                    LiteLLM Spend dashboard                      LLM Overview dashboard
                                    (one click from the Cluster Directory)       (one click from the Cluster Directory)
```

**Contents**

- 📡 [The telemetry path](#exercise-61---the-telemetry-path-concept)
- 💰 [Open the spend dashboards](#exercise-62---open-the-spend-dashboards)
- 🩺 [The FleetStatus card](#exercise-63---the-fleetstatus-card)


## 📡 Exercise 6.1 - The telemetry path (concept)

1. In Busola, open **Custom Resources → MetricPipeline** and open **`sap-cloud-logging`**. It's **cluster-scoped** — one declarative pipe that forwards scraped metrics to SAP Cloud Logging, with no Prometheus server to run and no Grafana to host:

   ```yaml
   apiVersion: telemetry.kyma-project.io/v1alpha1
   kind: MetricPipeline
   metadata:
     name: sap-cloud-logging          # cluster-scoped — one pipeline for the whole cluster
   spec:
     input:
       prometheus:                    # scrape Prometheus-style metrics from these namespaces
         enabled: true
         namespaces:
           include:
             - kube-system            # cilium-agent, cilium-operator, hubble-relay
             - default                # litellm-proxy — the LLM spend metrics
       istio:
         enabled: false
       runtime:                       # kubelet volume metrics → PVC usage as an alertable series
         enabled: true
         resources:
           volume:
             enabled: true
           # pod / container / node / statefulset / deployment / daemonset / job: disabled (keep it lean)
     output:
       otlp:                          # ship via OTLP to SAP Cloud Logging (mTLS)
         endpoint:
           valueFrom:
             secretKeyRef:
               name: sap-cloud-logging       # the CLS ingest Secret (endpoint + client cert/key), pre-created for you
               key: ingest-otlp-endpoint
         headers:
           - name: cluster
             value: xp266-NNN               # tags every metric with your runtime, so fleet dashboards split by cluster
         tls:
           cert:
             valueFrom:
               secretKeyRef:
                 name: sap-cloud-logging
                 key: ingest-otlp-cert
           key:
             valueFrom:
               secretKeyRef:
                 name: sap-cloud-logging
                 key: ingest-otlp-key
   ```

   👉 Look it up live on your own cluster — open it directly in Busola (replace `xp266-NNN` and `<workshop-domain>`):

   ```
   https://busola.xp266-NNN.<workshop-domain>/cluster/?kubeconfigID=xp266-NNN-federated.yaml&path=/metricpipelines/sap-cloud-logging
   ```
<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td>
<div>
<p float="left">
  <a href="#">
  <img src="images/05_01_0010.png" width="820" alt="" />
  </a>
</p>
</div>
</td>
</tr>
</tbody>
</table>

> [!NOTE]
> The LiteLLM proxy exposes Prometheus-style metrics (spend per key, tokens in/out, per-model latency). A **pod annotation** marks it for scraping; the `MetricPipeline` (managed by the Kyma **Telemetry** module) ships those metrics out via OTLP to **SAP Cloud Logging**, where they're stored in OpenSearch and visualized.  
> This is the same managed-telemetry pattern SAP BTP gives you for logs, metrics, and traces — you *use* it, you don't operate it.

## 💰 Exercise 6.2 - Open the spend dashboards

The dashboards are one click away from the **Cluster Directory** — no Busola navigation needed.

1. Open the Cluster Directory and scroll to the **LiteLLM spend** section (replace `xp266-NNN` and `<workshop-domain>`):

   ```
   https://busola.xp266-NNN.<workshop-domain>/clusterdir/
   ```

   It shows **today's spend** for your cluster inline — attributed by model and caller — plus two buttons that open the full **SAP Cloud Logging** (OpenSearch) dashboards in a new tab, single sign-on:

   - **LiteLLM Overview — today by model** — today's spend split
   - **LiteLLM Overview** — request volume, token throughput, and per-model latency

   The **LiteLLM Overview — today by model** dashboard looks like this — a headline **Total spend today** gauge, a cluster filter (pre-scoped to your `xp266-NNN`), and three bar charts attributing today's **spend / calls / tokens** per model:
<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td>
<div>
<p float="left">
  <a href="#">
  <img src="images/06_02_0010.png" width="820" alt="LiteLLM Overview — today by model" />
  </a>
</p>
</div>
</td>
</tr>
</tbody>
</table>

2. Read the split. You'll see spend attributed by **API key / caller** and by **model**:

   | Caller | Tier / model | Typical share |
   |---|---|---|
   | Goose diagnostic jobs | `reasoning-fast` — Sonnet | steady, scheduled |
   | Chat + terminal agents | `reasoning-hard` — Opus | bursty, interactive |
   | JupyterHub notebooks | whatever you call | your experiments show up here |

> [!TIP]
> This is the pay-off of routing **everything through one proxy**: because no agent talks to a model directly, *every* token is attributable.  
> Trigger a diagnose run or chat with the agent, wait a minute, and watch your own activity appear on the dashboard.

## 🩺 Exercise 6.3 - The FleetStatus card

1. Back on the **Cluster Directory** (`https://busola.xp266-NNN.<workshop-domain>/clusterdir/`), find the **Cluster launchpad** section — it follows the cluster selector.

2. Click the **Fleet Status + Spend** tile. In one click it opens your cluster's **`fleet-status`** card — the aggregated view with the **LLM Dashboards** / **SAP Cloud Logging** shortcuts — with no hunting through the Busola navigation tree.
<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td>
<div>
<p float="left">
  <a href="#">
  <img src="images/05_03_0010.png" width="820" alt="" />
  </a>
</p>
</div>
</td>
</tr>
</tbody>
</table>

## Summary

You followed one LLM call's metrics from the LiteLLM proxy through a Kyma Telemetry `MetricPipeline` into SAP Cloud Logging, and read the **LiteLLM Spend** and **LLM Overview** dashboards straight from the **Cluster Directory** — seeing the autonomous-jobs (Sonnet) vs interactive-agents (Opus) spend split that the single-proxy design makes possible.  
Continue to - [Overview](../../README.md)
