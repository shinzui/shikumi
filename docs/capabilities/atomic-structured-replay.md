---
title: "Atomic structured stream replay"
type: Capability
description: "Capture structured stream responses and replay them offline through either complete or stream operations without fresh provider evidence."
generated:
  by: codex-cli/gpt-6.1-sol
  at: "2026-11-03T04:46:53Z"
capabilityId: CAP-44
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.3.2.0"
packages:
  - shikumi-trace
interface:
  - Shikumi.Trace
  - Shikumi.Trace.Replay
requires:
  - CAP-12
  - CAP-42
evidence:
  - kind: test
    resource: shikumi-trace/test/DecisionReplaySpec.hs
    proves: Complete and stream captures replay in both modes after serialization and rederive answers under changed settings.
---

# Atomic structured stream replay

`tracedLLM` records successful checked structured terminals through the existing
response codec. `runLLMReplay` returns the recorded Response for Complete and pure
atomic events for Stream. Both use the same request key. Raw value, distributions,
confidence and method survive serialization; local settings apply after retrieval.

## Limits

Text-only, missing and malformed stream recordings raise ReplayDivergence without
provider fallback. Text streams retain usage-only capture. The codec omits call
evidence; observed span identity is historical, never fresh evidence for replay.
Replay creates no transport receipt or billing attempt. Cache streams still
bypass memoization. External effects in embedded program bodies are not replayed.

This extends [CAP-12](deterministic-replay.md), [CAP-42](streamed-judgment-parity.md).
