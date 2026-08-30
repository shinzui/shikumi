---
title: "Native and prompt-protocol ReAct agents"
type: Capability
description: "Compose a tool-using ReAct loop as a typed Program with native or prompt action protocols, recorded trajectories, iteration limits, and context compaction."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-18
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-tools
interface:
  - Shikumi.Agent.ReAct
requires:
  - CAP-2
  - CAP-3
  - CAP-4
  - CAP-17
evidence:
  - kind: test
    resource: shikumi-tools/test/ReActSpec.hs
    proves: ReAct executes tool turns, returns typed answers and trajectories, enforces iteration limits, distinguishes recoverable tool errors, and escapes budget exhaustion.
  - kind: test
    resource: shikumi-tools/test/ProtocolSpec.hs
    proves: Native and prompt action protocols translate model replies into the same proposal and tool-dispatch loop.
  - kind: test
    resource: shikumi-tools/test/CompactionSpec.hs
    proves: Proactive and reactive trajectory compaction preserve recent steps, expose summaries, and bound retry behavior.
  - kind: example
    resource: shikumi-jitsurei/app/ReActAgent.hs
    proves: A complete offline agent invokes a typed tool and records its thought-action-observation trajectory.
---

# Native and prompt-protocol ReAct agents

`react` and `reactWithTrajectory` build tool-using agents as ordinary embedded
`Program` values. Each loop alternates thought, action, and observation until a
typed finish or an iteration limit, optionally returning the full trajectory.
The protocol can use provider-native function calling or a prompt grammar while
sharing the same execution and error-handling logic.

Longer runs can compact older steps using provider-reported context usage while
keeping recent steps verbatim, and can retry once after a recognized context
overflow. The loop consumes the [CAP-17 typed tool registry](typed-tools.md), is
represented as a [CAP-2 Program](composable-program-values.md), chooses its wire
protocol through [CAP-3 adapter capability
detection](structured-output-adapters.md), and runs model turns under the
[CAP-4 runtime](resilient-runtime-routing.md).

## Limits

- Context compaction summarizes history and can lose detail. It is best-effort
  when a provider reports oversized requests as an unclassified error.
- The agent loop itself is an opaque `Embed` node and has no tunable core
  `Params`, though programs it calls may have them.
- Tool safety remains determined by the registered handlers and their execution
  environment.
