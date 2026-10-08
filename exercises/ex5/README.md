# Exercise 5 - External agents: Pi, opencode & Qwen via OpenRouter 🔧

The contained OpenShell sandbox has **no internet** — its only exit is the in-cluster LiteLLM proxy, so the
agent can't reach the apiserver or the public web.  
👉 This exercise flips exactly one dial: a **4th trust tier** — a
still-contained sandbox with **one external endpoint allow-listed** (`openrouter.ai`), so you can drive terminal
coding agents (opencode / Pi / Qwen Code) against public **OpenRouter** models.  
The real OpenRouter key never enters the box: it lives in the
gateway's `openrouter` **provider**, which injects a **resolve-sentinel** and swaps the real key at egress — and
*only* for the agent binaries named in the provider profile (binary-scoped injection).  
How the provider/profile model works and how OpenRouter compares to SAP AI Core are in **[Appendix 5 - External agents & the OpenRouter provider model](../Appendices/5-openrouter-provider/README.md)**.

**Contents**

- ⚡ **5a** *(easy path)* — run it as a **GitHub Action** (the Tip below)
- 🛠️ **5b** *(optional)* — the OpenShell CLI in the Busola web terminal:
  - 🔍 [Inspect the pieces](#exercise-51---inspect-the-pieces-ui)
  - 📦 [Create a sandbox with the agents + OpenRouter](#exercise-52---create-a-sandbox-with-the-agents--openrouter-)
  - ▶️ [Run an agent against a free model](#exercise-53---run-an-agent-against-a-free-model-)
  - 🛡️ [Prove it's still contained](#exercise-54---prove-its-still-contained-)
  - 🏗️ [From draft to deployable: a correct KRO RGD](#exercise-55---from-draft-to-deployable-a-correct-kro-rgd-)

> [!TIP]
> **Easy path — run it as a workflow (no CLI).** Everything below is the manual CLI flow. To run the external coding
> agents against OpenRouter **without a terminal**, dispatch one GitHub Actions workflow from your fork:
>
> | Run this workflow | What it does |
> |---|---|
> | [**`all-fleets-teched-nvidia`**](../../../../actions/workflows/all-fleets-teched-nvidia.yaml) | Creates the OpenRouter-enabled contained sandbox and runs the coding agent(s) on your cluster. Pick your `student_cluster` (`xp266-NNN`), the **`agent`** (`pi` / `opencode` / `qwen` / `all-three`), a **`model`** (a `:free` OpenRouter model), and a **`scenario`** → **Run workflow** → read the run **Summary**: a verdict table, each agent's output, and the containment proof. Same agents, same containment, zero local tooling. |
>
> Prefer the hands-on CLI? Continue below.



## Exercise 5.1 - Inspect the pieces (UI)

1. In Busola, open **namespace `openshell` → Custom Resources** and find the pre-built image build (`KanikoAgent`
   `kaniko-agent`) and the `openrouter` provider (it's created by the provider-setup Job because your runtime was
   given a shared OpenRouter key). The agents image is pushed to the in-cluster registry as
   `openrouter-agents:latest`.

> [!NOTE]
> The OpenRouter key is **shared and platform-provided** for the workshop — you never handle it. Use the `:free`
> models (they cost nothing). The gateway holds the key; your sandbox only ever sees `openshell:resolve:…`.

## Exercise 5.2 - Create a sandbox with the agents + OpenRouter 🔧

In a web terminal, with your gateway session active:  
Command:
```bash
openshell sandbox create --name agents \
  --from localhost:32137/openrouter-agents:latest \
  --provider openrouter \
  --env OPENAI_BASE_URL=https://openrouter.ai/api/v1 \
  --env OPENAI_MODEL=qwen/qwen3.8-27b:free \
  --detach -- sleep infinity
openshell sandbox list        # wait for PHASE=Ready
```
`--provider openrouter` grants the sandbox egress to `openrouter.ai` (+ `models.dev`) **for the agent binaries only**
and injects the key sentinel.

`--env` passes the base URL + default model (OpenAI-compat agents need them).

## Exercise 5.3 - Run an agent against a free model 🔧

Command (opencode — the cleanest):
```bash
openshell sandbox exec --name agents -- opencode run -m openrouter/qwen/qwen3.8-27b:free "Reply with one word: PONG"
```
Output:
```
PONG
```
Try Pi too:
```bash
openshell sandbox exec --name agents -- pi -p --model openrouter/qwen/qwen3.8-27b:free "List 3 facts about Kyma."
```

> [!TIP]
> **Pick a model:** `openshell sandbox exec --name agents -- curl -s https://openrouter.ai/api/v1/models | grep -o '"id":"[^"]*:free"'`
> lists the free models. opencode/Pi take `openrouter/<id>`. Qwen Code (`qwen`, interactive) uses whatever
> `OPENAI_MODEL` you set at create — some models reject its tool-calling request shape, so if `qwen` errors `400`,
> switch `OPENAI_MODEL` to another `:free` model and recreate the sandbox.

## Exercise 5.4 - Prove it's still contained 🔧

The agent reaches OpenRouter — and **nothing else**:  
Command:
```bash
openshell sandbox exec --name agents -- sh -c 'curl -sS -m8 -o /dev/null -w "openrouter.ai: %{http_code}\n" https://openrouter.ai/api/v1/models; curl -sS -m8 https://example.com >/dev/null 2>&1 && echo "example.com: REACHED" || echo "example.com: blocked"; curl -sS -m8 https://kubernetes.default.svc >/dev/null 2>&1 && echo "apiserver: REACHED" || echo "apiserver: blocked"; echo "key in box: $OPENROUTER_API_KEY"'
```
Output:
```
openrouter.ai: 200
example.com: blocked
apiserver: blocked
key in box: openshell:resolve:env:…      ← a sentinel, NOT the real key
```

So this is a *different* tier, not a weaker one:

| | scoped-ops (previous) | **external agent (this exercise)** |
|---|---|---|
| LLM | in-cluster LiteLLM → SAP AI Core | **public OpenRouter (keyed, key in gateway only)** |
| Egress | in-cluster proxy only; **no internet** | **`openrouter.ai` + `models.dev` only; nothing else** |
| Cluster | read-only kubectl (sandbox-viewer) | none |
| Key in box | sentinel | sentinel |

Clean up: `openshell sandbox delete agents`

## Exercise 5.5 - From draft to deployable: a correct KRO RGD 🔧

When you ask an agent for *"a KRO ResourceGraphDefinition"*, a free model's first draft is usually **confident but
wrong** — it reaches for OpenAPI schema (`type`/`properties`/`x-kro`), Helm templating (`{{ .spec.x }}`), or invented
fields (`spec.nodes`/`components`/`graph`).  
KRO is a niche CRD the model hasn't memorised.  
That's the real lesson of
this exercise: **the agent drafts, the cluster adjudicates — you iterate.**  
Always validate before trusting:

```bash
kubectl apply --dry-run=server -f weather-rgd.yaml   # the API server + KRO reject an invalid RGD
```

KRO's actual rules (what the drafts get wrong):
- **`spec.schema` is KRO *simple-schema*, not OpenAPI** — each field is `name: type | markers` (types `string`,
  `integer`, `float`, `boolean`; markers `required=true`, `default=…`). No `properties:`, no `required:` list, no `x-kro`.
- **Status fields are CEL strings** that read a created resource by its `id`: `${weatherpod.status.phase}`.
- **Templates substitute instance inputs with CEL** `${schema.spec.<field>}` — **not** `{{ }}`.
- **The instance's `apiVersion` is `kro.run/v1alpha1`** (group `kro.run`), kind = your `schema.kind`.
- KRO is **already installed** on your teched runtime — just `kubectl apply`.

A **corrected, deployable** version (keeps the production touches — namespace, ServiceAccount + RBAC, `securityContext`,
resource limits, two example instances — but uses *real* KRO):

```yaml
---
apiVersion: v1
kind: Namespace
metadata: { name: weather-system }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: weather-checker, namespace: weather-system }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: weather-checker, namespace: weather-system }
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: weather-checker, namespace: weather-system }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: weather-checker }
subjects:
  - { kind: ServiceAccount, name: weather-checker, namespace: weather-system }
---
apiVersion: kro.run/v1alpha1
kind: ResourceGraphDefinition
metadata: { name: weather }          # RGDs are cluster-scoped (no namespace)
spec:
  schema:
    apiVersion: v1alpha1
    kind: Weather
    spec:                            # KRO simple-schema (strings → drop straight into env + the URL)
      name: string | required=true
      latitude: string | required=true
      longitude: string | required=true
      currentFields: string | default="temperature_2m,relative_humidity_2m,wind_speed_10m"
      timezone: string | default="auto"
      sleepSeconds: string | default="3600"
    status:                          # CEL reading the created Pod by its resource id
      podPhase: ${weatherpod.status.phase}
      podIp: ${weatherpod.status.podIP}
      containerImage: ${weatherpod.status.containerStatuses[0].image}
  resources:
    - id: weatherpod
      template:
        apiVersion: v1
        kind: Pod
        metadata:
          name: ${schema.spec.name}
          namespace: weather-system
          labels: { app.kubernetes.io/name: weather-check, app.kubernetes.io/managed-by: kro }
        spec:
          restartPolicy: Never
          serviceAccountName: weather-checker
          securityContext: { fsGroup: 1000 }
          containers:
            - name: weather-query
              image: curlimages/curl:latest
              env:
                - { name: LATITUDE,       value: ${schema.spec.latitude} }
                - { name: LONGITUDE,      value: ${schema.spec.longitude} }
                - { name: CURRENT_FIELDS, value: ${schema.spec.currentFields} }
                - { name: TIMEZONE,       value: ${schema.spec.timezone} }
                - { name: SLEEP_SECONDS,  value: ${schema.spec.sleepSeconds} }
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -e
                  echo "Weather for $LATITUDE,$LONGITUDE ($CURRENT_FIELDS)"
                  curl -sS "https://api.open-meteo.com/v1/forecast?latitude=$LATITUDE&longitude=$LONGITUDE&current=$CURRENT_FIELDS&timezone=$TIMEZONE" | head -c 4096
                  echo; sleep "$SLEEP_SECONDS"
              resources:
                requests: { cpu: 50m, memory: 64Mi }
                limits:   { cpu: 100m, memory: 128Mi }
              securityContext:
                allowPrivilegeEscalation: false
                runAsNonRoot: true
                runAsUser: 1000
                capabilities: { drop: ["ALL"] }
---
apiVersion: kro.run/v1alpha1       # ← instance of the generated kind, group kro.run
kind: Weather
metadata: { name: berlin, namespace: weather-system }
spec:
  name: weather-berlin
  latitude: "52.52"
  longitude: "13.41"
  currentFields: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m"
  timezone: "Europe/Berlin"
  sleepSeconds: "1800"
---
apiVersion: kro.run/v1alpha1
kind: Weather
metadata: { name: newyork, namespace: weather-system }
spec:
  name: weather-newyork
  latitude: "40.7128"
  longitude: "-74.0060"
  currentFields: "temperature_2m,relative_humidity_2m,wind_speed_10m"
  timezone: "America/New_York"
  sleepSeconds: "3600"
```

```bash
kubectl apply --dry-run=server -f weather-rgd.yaml   # validate first
```

```bash
kubectl apply -f weather-rgd.yaml                    # then deploy
```

```bash
kubectl -n weather-system get weather,pods
```

```bash
kubectl -n weather-system get weather berlin -o jsonpath='{.status}'   # CEL-derived status
```

> [!NOTE]
> Treat this as *the shape KRO accepts*, not gospel — always `--dry-run=server` first. That round-trip (draft → reject
> → fix) **is** the skill this exercise is teaching.

## Summary

You added an **external, keyed** LLM provider to the contained-sandbox model, ran three different terminal coding
agents (opencode, Pi, Qwen Code) against free OpenRouter models, and proved the sandbox still can't reach anything
but the one allow-listed endpoint — with the real key staying in the gateway.  
That's the OpenShell provider model
generalizing from "the in-cluster proxy" to "any governed external endpoint."  
Continue to - [Exercise 6 - Observability and spend](../ex6/README.md)  
Back to - [Overview](../../README.md)
