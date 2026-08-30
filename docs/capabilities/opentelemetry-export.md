---
title: "OpenTelemetry trace export"
type: Capability
description: "Export completed or live shikumi trace trees as nested OpenTelemetry spans with GenAI-oriented attributes, error status, and bracketed provider cleanup."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-13
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-trace-otel
interface:
  - Shikumi.Trace.OpenTelemetry
  - Shikumi.Trace.LiveExport
requires:
  - CAP-11
evidence:
  - kind: test
    resource: shikumi-trace-otel/test/Main.hs
    proves: Export preserves nesting and node attributes, reports errors and incomplete spans honestly, terminates on corrupt cycles, and shuts down after exceptions.
  - kind: guide
    resource: docs/user/caching-tracing-replay.md
    proves: Batch and live export wiring is documented as an optional layer over shikumi traces.
---

# OpenTelemetry trace export

`shikumi-trace-otel` maps the tree from
[CAP-11](hierarchical-tracing.md) to OpenTelemetry. Batch export handles a
completed tree; live export observes spans as they close. Both retain parentage,
program-node attributes, model identity, usage, error status, and incomplete
span state. Provider flushing and shutdown are bracketed even when export throws.

## Limits

- Export fidelity is bounded by the attributes recorded in the source trace.
- A corrupt cyclic trace is traversed defensively, but accepting corrupt input
  does not repair its semantics.
- Collector configuration, sampling, transport, retention, and sensitive-data
  policy belong to the consumer's OpenTelemetry deployment.
