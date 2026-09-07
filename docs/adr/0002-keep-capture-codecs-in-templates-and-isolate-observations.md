---
type: Architecture Decision Record
title: Keep capture codecs in templates and isolate observations
description: Capture typed predictor values with explicit template-owned codecs and retain invocation evidence with failed-scope rejection lineage.
docId: ADR-2
status: Accepted
date: 2026-09-07
timestamp: 2026-09-07T02:26:32Z
generated:
  by: process:codex
  at: 2026-09-07T02:26:32Z
---

# Keep capture codecs in templates and isolate observations

## Context

A composed `Program i o` hides intermediate types. Its outer JSON encoders cannot
encode an internal predictor's input or output. Rendered prompts lose type and
wire-format information. A successful predictor inside an attempt that later
fails validation must not become a demonstration when a retry succeeds.

## Decision

Ordinary `predict` retains its existing constraints. `predictCaptured` opts into
structured capture through `CaptureCodec`, which carries input/output encoders
and explicit schema evidence. Custom encoders are supported; schema declarations
alone do not prove runtime values are decodable.

Codecs live in executable templates, never in parameter artifacts. Captured and
ordinary predictions have the same serialized execution shape. Parameter edits
and restoration preserve the template codec. Rewrites changing internal leaf
types must adapt the codec, as the chain-of-thought compiler does for its nested
reasoning/value output, rather than silently discarding capture capability.

Sequential traced and observed execution share one control-flow walker. Observed
execution allocates fresh Prim cells per example and returns observations even
on typed root failure. Structural NodePath plus a zero-based per-example invocation
ordinal identifies an execution. Failed enclosing scopes retain rejection lineage
and mark all their observations ineligible; retries retain both rejected and
accepted attempts. Host exceptions and cancellation propagate.

Embed is opaque: an observation can report its execution boundary but cannot
invent identities or codecs for predictors hidden in its closure. No concurrent
internal observation walker is provided. Independent outer executions have
independent storage. The observation-only runner adds neither Trace/CurrentNode
nor IOE requirements to optimizer execution.

## Consequences

Public GADT consumers must handle `PredictCaptured`. Existing parameter artifacts
remain compatible. Observation consumers can inspect failures without mistaking
successful leaves from discarded attempts for accepted evidence. Raw values and
rendered fields are separate channels; missing encoders differ from model failures.

The core request-equivalence test and trace observation tests demonstrate these
contracts. [Plan 51](../plans/51-recover-node-local-bootstrap-demonstrations.md)
records the validation and recovery implementation.
