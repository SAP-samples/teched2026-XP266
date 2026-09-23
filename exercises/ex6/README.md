# Exercise 6 - Sandbox and guardrails

An AI agent with `kubectl` access is powerful — and, unchecked, dangerous. The whole system is built so the agent can **read everything it needs to reason, but change almost nothing**, runs as an unprivileged workload, and is boxed in by the platform. In this exercise you *prove* those boundaries yourself with `kubectl auth can-i`.

```
                    ┌──────────────────────────────────────────────┐
                    │  Guardrails around every agent                │
                    │                                              │
  reason freely ──▶ │  ✅ read (get/list/watch) ANY resource        │
                    │  🚫 no writes to Deployments / Secrets / RBAC │
                    │  ✅ write only ConfigMaps (its own reports)   │
                    │  ✅ create pods/exec (the terminal)           │
                    │  🧱 runs non-root, read-only rootfs           │
                    │  🧱 Chat agent isolated in a Sandbox         │
                    └──────────────────────────────────────────────┘
```

## Exercise 6.1 - The RBAC boundary

The web-terminal identity (`busola-terminal`) — the same identity your agents use in Exercise 2/3 — is deliberately **read-mostly**.

1. In Busola, open **Cluster Roles** (cluster-wide RBAC) and find **`busola-terminal`**. Read its rules: **`get`/`list`/`watch` on everything**, but write (`create`/`update`/`patch`/`delete`) only on **`configmaps`**, plus `create` on **`pods/exec`** (the terminal itself). That's the entire write surface.
<br>![](images/06_01_0010.png)

> [!IMPORTANT]
> The agent can **read broadly** (it needs the full picture to reason) but its only write surface is **ConfigMaps** — exactly where it stores its diagnostic reports (the `goose-raw-*` / `cluster-health-*` ConfigMaps from Exercise 3). It **cannot** scale a Deployment, read/write a Secret's contents beyond listing, or grant itself more power. Even if the model "decided" to delete a workload, the API server refuses.

🔧 **Prove it yourself (optional — go deeper).** In a web terminal, ask the API server directly what this identity may do:

Command:
```bash
echo "read pods:        $(kubectl auth can-i get pods -A)"
echo "read anything:    $(kubectl auth can-i list nodes)"
echo "write configmap:  $(kubectl auth can-i create configmaps)"
echo "delete deploy:    $(kubectl auth can-i delete deployments)"
echo "create secret:    $(kubectl auth can-i create secrets)"
echo "modify RBAC:      $(kubectl auth can-i create clusterrolebindings)"
echo "cluster-admin:    $(kubectl auth can-i '*' '*')"
```
Output:
```
read pods:        yes
read anything:    yes
write configmap:  yes
delete deploy:    no
create secret:    no
modify RBAC:      no
cluster-admin:    no
```

## Exercise 6.2 - Non-root, minimal container

1. In Busola, open **namespace `dev-toolbox-system` → Workloads** and look at the diagnostic job's Pod **security context**: it runs as a **non-root** user with a **read-only root filesystem** and dropped capabilities.
<br>![](images/06_02_0010.png)

2. Confirm from the terminal (the diagnostic container's identity):

   Command:
   ```bash
   kubectl get cronjob dev-toolbox-diagnose-v2 -n dev-toolbox-system \
     -o jsonpath='{.spec.jobTemplate.spec.template.spec.securityContext}{"\n"}'
   ```

## Exercise 6.3 - The chat agent's sandbox

The interactive chat agent (Exercise 4) executes agent actions inside a dedicated **`Sandbox`** custom resource managed by an agent-sandbox controller — an isolated workload boundary, separate from the rest of the cluster.

1. In Busola, open **namespace `openclaw` → Custom Resources → Sandbox** and inspect the running sandbox: its own isolated pod, network stance, and lifecycle.
<br>![](images/06_03_0010.png)

> [!NOTE]
> **Defense in depth.** No single control is trusted alone: scoped RBAC (can't write), non-root + read-only rootfs (can't escalate on the node), the sandbox boundary (can't roam the cluster), and `drop_params` at the proxy (can't send SAP AI Core a malformed/oversized request). The agent is useful precisely *because* it's boxed in.

## Summary

You inspected the agent's RBAC boundary in Busola — and, optionally, proved it with `kubectl auth can-i` (reads broadly, writes only ConfigMaps, no secrets/RBAC/workload writes) — saw it runs non-root with a read-only root filesystem, and inspected the chat agent's isolating `Sandbox`. Layered guardrails are what make an autonomous kubectl agent safe to run in production.

Continue to - [Exercise 7 - JupyterHub playground: SAP AI Core from Python](../ex7/README.md)
