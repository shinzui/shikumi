---
type: Architecture Decision Record
title: Preserve completed ReAct exchanges in versioned sessions
description: Keep rich tool results and full assistant exchanges in validated checkpoints while compacting only the provider-facing history.
docId: ADR-6
status: Accepted
date: 2026-09-06
timestamp: 2026-09-08T17:47:40Z
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

Version 2 adds public resolved-request origin and an exact protected request
prefix. Origin consists of provider, API, model and endpoint, never headers or
API keys; credential-shaped endpoints remain unknown. Response model identity
is the echoed request, not provider attestation. Responses replay scope must
match that request identity before tool dispatch. Version-1 histories decode
with unknown origin; opaque legacy histories require an explicit restart.
An explicit-model constructor establishes a requested identity, while the runtime
supplies credentials and compatibility settings outside persistence.

`Shikumi.LLM.Continuation` owns pure, idempotent validation and reserved private
metadata. Routing validates after selecting/translating the target. Memoization
validates before lookup; bare and resilient interpreters validate again and strip
the private metadata before transport. The system prompt, ordered tools and
protected ordered message prefix must agree exactly except for construction
timestamps. Intermediate wrappers must preserve the expectation. Custom
interpreters must enforce this contract themselves; no global session state or
provider attestation is implied.

Opaque reasoning includes signatures, redacted thinking and replay state, even
with empty visible text. Defer proactive compaction when a retained opaque block
would lose its prefix; forced context recovery fails actionably without a summary
call or second invalid request. Structural summary projection excludes opaque
reasoning, images and uninterpreted tool extensions while keeping readable text,
arguments and structured results. Preserve the lossless audit independently.
`restartSessionFromSummary` is a pure, explicit, separate unbound conversation
from caller-approved text; it never edits the original archive or runs old tools.

## Consequences

Scripted tests can prove original message ordering, rich-result round-trips,
no duplicate tool dispatch on resume, bounded retries, and zero extraction calls
for valid final submissions. A complete audit may grow indefinitely; callers own
storage limits. Checkpoints are conversation data, not serialized programs or
credentials. Do not resume untrusted edited checkpoints as an authenticity claim;
validation establishes structural and schema compatibility, not provenance.
