---
type: Architecture Decision Record
title: Preserve completed ReAct exchanges in versioned sessions
description: Keep rich tool results and full assistant exchanges in validated checkpoints while compacting only the provider-facing history.
docId: ADR-6
status: Accepted
date: 2026-09-06
timestamp: 2026-09-07T04:26:19Z
generated:
  by: process:codex
  at: 2026-09-07T04:26:19Z
---

# Preserve completed ReAct exchanges in versioned sessions

## Context

Legacy ReAct reduces native tool calls to names and arguments and later extracts a
separate typed answer from a textual trajectory. Resumable conversations require
original call IDs, assistant blocks (including reasoning signatures), and ordered
results. Generic structured tool output also needs a home independent of external
MCP integration. [Plan 54](../plans/54-add-structured-resumable-react-history.md)
implements these requirements alongside the legacy API.

## Decision

`Shikumi.Tool.Output` owns native text/image results, structured JSON, and raw
extension blocks. Dynamic tools use the same `LLM`/`Error ShikumiError` effect row
as typed tools. Text projections label JSON, error flags, and image data; provider
projections retain native image blocks. Local preservation does not imply image
tool-result support in a provider. Dependencies and transport behavior remain
unchanged.

`Shikumi.Agent.History` owns opaque completed-exchange sessions and a versioned
local JSON transfer format. Preserve all assistant metadata and rich outputs,
including exact rational costs. Do not depend on a dependency's incidental JSON
encoding as the checkpoint schema. Invalid proposals remain audit-only with a
corrective user message in the request view. Validate the whole proposal before
any dispatch, preserving valid native IDs and assigning synthetic IDs only to
prompt-protocol actions. Share the prompt parser between proposal acceptance and
checkpoint validation so validity cannot diverge after dispatch. Compaction
replaces whole entries in the request view;
the full audit remains available and serializable.

Session operations in `Shikumi.Agent.ReAct` use a reserved final-submission tool,
with `FromModel` decoding and `Validatable` checks. A valid final needs no extraction
call. Legacy APIs retain their existing extraction and trajectory behavior.
Compatibility uses exact instruction, input-field metadata, output schema,
resolved protocol, and ordered registry name/schema/description values rather
than a lossy hash. Signature demonstrations are unused by both ReAct paths.
Changed registries require an explicit new session; bodies and live connections
are caller-owned and never serialized. Body identity cannot be checked by schema.

A returned checkpoint contains all results of its accepted assistant turn.
Continuation appends input without dispatching old calls. Context-window recovery
retries a model request at most once and never wraps tool dispatch in a retry.
These are completed-turn checkpoints, not exactly-once execution across crashes:
if a tool or a later operation fails before the checkpoint returns, the caller
must reconcile any effects before retrying. The per-user iteration limit resets
on continuation while the cumulative exchange count remains available.

## Consequences

Scripted tests can prove original message ordering, rich-result round-trips,
no duplicate tool dispatch on resume, bounded retries, and zero extraction calls
for valid final submissions. A complete audit may grow indefinitely; callers own
storage limits. Checkpoints are conversation data, not serialized programs or
credentials. Do not resume untrusted edited checkpoints as an authenticity claim;
validation establishes structural and schema compatibility, not provenance.
