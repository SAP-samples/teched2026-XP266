# Exercise 2 - Chat with the interactive agent

The Goose diagnostic jobs run *autonomously*.  
The other half of the story is an **interactive** AI agent — a chat UI (for instance **OpenClaw**, or a similar chat front-end) running in your cluster as a sandboxed workload and, like everything else, routed to SAP AI Core through the LiteLLM proxy.  
In this exercise you chat with it and see how it picks up where the diagnostic jobs leave off.

```
You (browser)  ──▶  Chat UI  ──▶  LiteLLM proxy :4001  ──▶  SAP AI Core (Claude Opus by default)
                      │
                      └── reads the diagnostic artifacts
                          (ClusterHealthReport · goose-raw-* ConfigMaps)
```

**Contents**

- 💬 [Open the chat UI and chat](#exercise-21---open-the-chat-ui-and-chat)
- 🤝 [The hand-off: ask about your cluster's diagnosis](#exercise-22---the-hand-off-ask-about-your-clusters-diagnosis)
- ⚖️ [Autonomous vs interactive — when to use which](#exercise-23---autonomous-vs-interactive--when-to-use-which)


## Exercise 2.1 - Open the chat UI and chat

1. Open your chat UI URL in the browser (handed out with your runtime), e.g.:

   ```
   https://openclaw.xp266-NNN.<workshop-domain>/
   ```
   Sign in with the workshop identity provider (same single sign-on as Busola).

   You may need to sign in eventually — the sequence looks like this:

<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td align="center" width="50%"><img src="images/oauth2-proxy.png" width="400" alt="oauth2-proxy sign-in gate" /><br/><sub><b>1.</b> oauth2-proxy gate</sub></td>
<td align="center" width="50%"><img src="images/sap-ias-01.png" width="400" alt="SAP IAS — identity provider pick" /><br/><sub><b>2.</b> SAP IAS — pick provider</sub></td>
</tr>
<tr>
<td align="center"><img src="images/sap-ias-02.png" width="400" alt="SAP IAS — credentials" /><br/><sub><b>3.</b> SAP IAS — credentials</sub></td>
<td align="center"><img src="images/sap-ias-03.png" width="400" alt="SAP IAS — consent / 2FA" /><br/><sub><b>4.</b> SAP IAS — consent / 2FA</sub></td>
</tr>
</tbody>
</table>

   Once signed in, you land on the chat UI:

<table style="width: 100%; border-collapse: collapse; background-color: #f5f5f5;" border="1">
<tbody>
<tr>
<td>
<div>
<p float="left">
  <a href="#">
  <img src="images/04_01_0010.png" width="820" alt="" />
  </a>
</p>
</div>
</td>
</tr>
</tbody>
</table>

2. Ask it something general to confirm it's live and reasoning via SAP AI Core:

   > *Explain, in three sentences, what SAP BTP, Kyma runtime gives me over plain Kubernetes.*

> [!NOTE]
> **Model routing.** The chat agent defaults to the `reasoning-hard` tier — **Claude Opus** on SAP AI Core — with automatic fallbacks (Sonnet, GPT-5.5, GPT-4.1, Nova, Mistral) if a model is busy.  
> That's why interactive traffic shows up as *Opus* on the spend dashboard, while the Goose jobs (Sonnet) show up as *diagnostics*.

## Exercise 2.2 - The hand-off: ask about your cluster's diagnosis

👉 This is the pay-off of the "jobs produce → agents consume" pattern.  
The Goose jobs already wrote a **Cluster Health Report** and archived their raw findings.  
Now ask the *interactive* agent about them:

> *Summarize the latest cluster health report for this cluster.  
> What are the top risks, and what would you do about the most urgent one?*

The agent reasons over the diagnostic findings and gives you a conversational, follow-up-able answer — the beginnings of an **on-call assistant**: the overnight autonomous run does the broad sweep, and in the morning you interrogate its findings in plain language.

> [!TIP]
> Follow up conversationally — *"show me the certificate section"*, *"which of these is safe to ignore?"*, *"draft the kubectl command to fix it"*. Same cluster, same SAP AI Core, but now interactive instead of scheduled.

## Exercise 2.3 - Autonomous vs interactive — when to use which

| | Goose diagnostic jobs | Chat agent (this exercise) |
|---|---|---|
| Trigger | scheduled CronJob (or manual kick) | you, in chat |
| Output | structured `ClusterHealthReport` CR | conversation |
| Best for | unattended, repeatable, auditable sweeps | ad-hoc questions, "explain this", drafting fixes |
| Model tier | `reasoning-fast` (Sonnet) | `reasoning-hard` (Opus) |
| Both route through | **LiteLLM proxy → SAP AI Core** | **LiteLLM proxy → SAP AI Core** |

## Summary

You chatted with the interactive agent, saw it route to SAP AI Core (Claude Opus) via the same LiteLLM proxy, and used it to interrogate the diagnostic findings the autonomous jobs produced — the interactive half of the "autonomous sweep + human follow-up" pattern.  
Continue to - [Exercise 3 - Explore OpenShell sandboxes with JupyterHub notebooks](../ex3/README.md)
