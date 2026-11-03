---
title: "Streamed judgment result parity"
type: Capability
description: "Run typed judgments in complete and stream modes with identical immutable settings, raw answers and locally derived rich results."
generated:
  by: codex-cli/gpt-6.1-sol
  at: "2026-11-03T04:46:53Z"
capabilityId: CAP-42
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.5.1.0"
packages:
  - shikumi
interface:
  - Shikumi.Stream
  - Shikumi.Program
  - Shikumi.Routing
requires:
  - CAP-5
  - CAP-39
  - CAP-40
evidence:
  - kind: test
    resource: shikumi-tools/test/SystemOneIntegrationSpec.hs
    proves: Released TypeSafe loopback proves parity, identical wire bytes, atomic order, acknowledgement, retry and cancellation boundaries.
---

# Streamed judgment result parity

`streamProgram` and `runProgram` share request preparation and settings-aware
decoding. Noul thresholds, choice weights and score cuts apply locally; the raw
provider answer remains available at the LLM boundary via `responseFromEvents`.
TypeSafe emits one atomic structured answer. Generative judgments, including
mixed free-text fields, use the same decoder and suppress field chunks.

## Limits

The LLM operation collects events before callbacks run. Decision callbacks emit
status only. A valid success terminal is required before typed return; no partial
judgment escapes. Streams bypass memoization. Capture/replay is described by
[CAP-44](atomic-structured-replay.md), and evidence acknowledgement by
[CAP-43](acknowledged-attempt-evidence.md).

This extends [CAP-5](typed-streaming.md), [CAP-39](probability-backed-decisions.md), [CAP-40](persistent-decision-settings.md).
