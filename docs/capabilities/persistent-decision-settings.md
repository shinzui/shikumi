---
title: "Persistent decision calibration settings"
type: Capability
description: "Persist per-field thresholds, score cuts and choice weights and rederive answers from cached or replayed evidence without changing request identity."
generated:
  by: openai/codex
  at: "2026-11-03T04:38:56Z"
capabilityId: CAP-40
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.5.0.0"
packages:
  - shikumi
interface:
  - Shikumi.Decision.Setting
  - Shikumi.Program
requires:
  - CAP-39
  - CAP-2
evidence:
  - kind: test
    resource: shikumi/test/DecisionDeriveSpec.hs
    proves: Thresholds, cuts, sparse weights and tie rules are validated and derive deterministic answers.
  - kind: test
    resource: shikumi-testing/test/DecisionParamsSpec.hs
    proves: Old parameter JSON remains compatible and settings affect both executors without provider dispatch on invalid settings.
  - kind: test
    resource: shikumi-cache/test/Main.hs
    proves: Changed settings reuse structured cached evidence.
  - kind: test
    resource: shikumi-trace/test/DecisionReplaySpec.hs
    proves: Changed settings derive a new answer from a recorded response.
  - kind: guide
    resource: docs/user/decisions-and-calibration.md
    proves: Demonstrates two thresholds over one cached response and explains node-local settings and persistence.
---

# Persistent decision calibration settings

`Params.decisionSettings` stores validated per-field settings. Use
`decisionSettingFor`, `setDecisionSetting` and `clearDecisionSetting` to manage
thresholds, ordered score cuts and choice weights. Decoding applies settings
after evidence retrieval; numeric settings never become provider request or
cache identity material. Old parameter JSON decodes with empty settings, and
empty settings are omitted when encoding.

Native Boolean and enum outputs opt into evidence through explicit settings.

Builds on [CAP-39 probability-backed decisions](probability-backed-decisions.md), [CAP-2 program values](composable-program-values.md).

## Limits

- Settings must match declared domains; invalid settings fail before dispatch.
- Changing upstream answers may change downstream requests, requiring new
  evidence rather than an unconditional cache or replay hit.
- Existing positional `Params` construction needs migration to the new field;
  prefer record updates from `emptyParams`.
- This capability supplies settings and derivation, not automatic fitting.
