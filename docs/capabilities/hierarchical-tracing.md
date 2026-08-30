---
title: "Hierarchical, node-correlated tracing"
type: Capability
description: "Capture programs, modules, retries, and LM calls as a hierarchical trace tree with stable program-node paths, persisted JSON, rendering, and per-node feedback."
generated:
  by: codex/gpt-5
  at: "2026-08-30T20:48:38Z"
capabilityId: CAP-11
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - shikumi-trace
interface:
  - Shikumi.Trace
  - Shikumi.Trace.Program
  - Shikumi.Trace.Node
  - Shikumi.Trace.Store
  - Shikumi.Trace.Feedback
requires:
  - CAP-2
  - CAP-4
evidence:
  - kind: test
    resource: shikumi-trace/test/Main.hs
    proves: Nested spans, LM-call correlation, node paths, retry counts, rendering, persisted formats, and feedback logs are verified together.
  - kind: example
    resource: shikumi-jitsurei/app/TraceReplay.hs
    proves: A worked program captures and renders a trace before replaying it offline.
  - kind: guide
    resource: docs/user/caching-tracing-replay.md
    proves: Trace effect layering, automatic call capture, storage, node correlation, and feedback are documented.
---

# Hierarchical, node-correlated tracing

`shikumi-trace` records nested program, module, retry, and LM-call spans in a
`TraceTree`. The LLM wrapper tags each captured call with its enclosing span,
while program tracing adds structural `NodePath` values aligned with the core
parameter traversal. Consumers can render a readable tree, persist a versioned
JSON file, or attach critiques to individual nodes for reflective optimizers.

This capability observes the program and runtime from
[CAP-2](composable-program-values.md) and
[CAP-4](resilient-runtime-routing.md).

## Limits

- `runTrace` and `tracedLLM` support sequential span-stack mutation. Unsupported
  concurrent use fails loudly rather than risking a silently corrupted tree.
- Trace files may contain prompts and responses; storage access and redaction
  are the consumer's responsibility.
- File-format compatibility is versioned and bounded by
  `minSupportedFormatVersion`.
