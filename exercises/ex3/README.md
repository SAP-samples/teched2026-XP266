# Exercise 3 - Observability and spend

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

**Contents**

- 📡 [The telemetry path](#exercise-31---the-telemetry-path-concept)
- 💰 [Open the spend dashboards](#exercise-32---open-the-spend-dashboards)
- 🩺 [The FleetStatus card](#exercise-33---the-fleetstatus-card)


## Exercise 3.1 - The telemetry path (concept)

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
<br>![](images/05_01_0010.png)

> [!NOTE]
> The LiteLLM proxy exposes Prometheus-style metrics (spend per key, tokens in/out, per-model latency). A **pod annotation** marks it for scraping; the `MetricPipeline` (managed by the Kyma **Telemetry** module) ships those metrics out via OTLP to **SAP Cloud Logging**, where they're stored in OpenSearch and visualized. This is the same managed-telemetry pattern SAP BTP gives you for logs, metrics, and traces — you *use* it, you don't operate it.

## Exercise 3.2 - Open the spend dashboards

The dashboards are one click away from Busola's left navigation.

1. In Busola, open the **SAP Cloud Logging** navigation entry, then the **LiteLLM Spend** dashboard link. It opens SAP Cloud Logging (OpenSearch Dashboards) in a new tab, single sign-on.
<br>![](images/05_02_0010.png)

2. Read the split. You'll see spend attributed by **API key / caller** and by **model**:

   | Caller | Tier / model | Typical share |
   |---|---|---|
   | Goose diagnostic jobs (ex1) | `reasoning-fast` — Sonnet | steady, scheduled |
   | Chat + terminal agents (Appendix 2, ex2) | `reasoning-hard` — Opus | bursty, interactive |
   | JupyterHub notebooks (ex4) | whatever you call | your experiments show up here |

3. Open the **LLM Overview** dashboard for request volume, token throughput, and per-model latency.

> [!TIP]
> This is the pay-off of routing **everything through one proxy** (Appendix 1): because no agent talks to a model directly, *every* token is attributable. Trigger a diagnose run (ex1) or chat with the agent (ex2), wait a minute, and watch your own activity appear on the dashboard.

## Exercise 3.3 - The FleetStatus card

1. In Busola, switch to namespace **`dev-toolbox-system`**.

2. In the left navigation, open **Autonomous Fleet → Autonomous Fleet Status**, then the **`fleet-status`** resource. It displays the **LLM Dashboards** / **SAP Cloud Logging** shortcuts as cards.

   👉 Or open it directly in Busola (replace `xp266-NNN` and `<workshop-domain>`):

   ```
   https://busola.xp266-NNN.<workshop-domain>/cluster/?kubeconfigID=xp266-NNN-federated.yaml&path=/namespaces/dev-toolbox-system/fleetstatuses/fleet-status
   ```
<br>![](images/05_03_0010.png)

## Summary

You followed one LLM call's metrics from the LiteLLM proxy through a Kyma Telemetry `MetricPipeline` into SAP Cloud Logging, and read the **LiteLLM Spend** and **LLM Overview** dashboards from Busola — seeing the autonomous-jobs (Sonnet) vs interactive-agents (Opus) spend split that the single-proxy design makes possible.  
Continue to - [Exercise 4 - Explore OpenShell sandboxes with JupyterHub notebooks](../ex4/README.md)
