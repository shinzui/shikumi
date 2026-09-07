---
id: 54
slug: add-structured-resumable-react-history
title: "Add structured resumable ReAct history"
kind: exec-plan
created_at: 2026-09-07T01:50:18Z
master_plan: "docs/masterplans/10-dspy-informed-optimizer-and-agent-evolution.md"
---

# Add structured resumable ReAct history


This ExecPlan is a living document. Update its living sections during implementation and distill durable decisions into ADRs before completion.

## Purpose / Big Picture


A caller will run a tool-using agent, save a completed-turn checkpoint, and continue with another user message without repeating completed tools. Native model requests will preserve assistant messages, original tool-call IDs, results, and their ordering. A typed final-submission tool will return a validated answer without the current extra extraction call. Tests with scripted responses will prove these behaviors without credentials.

## Progress


Implementation has not started.

## Surprises & Discoveries


No implementation discoveries recorded.

## Decision Log


Decision (2026-09-06): this plan owns generic rich tool output and dynamic tool registration in `Shikumi.Tool`; MCP adaptation consumes these in `docs/plans/30-mcp-to-tool-adapter-surfacing-mcp-tools-into-the-registry.md`. This keeps ordinary ReAct usable without waiting for an external MCP release.

Decision (2026-09-06): add explicit session APIs while retaining the existing `react`, `reactWithTrajectory`, `Step`, and `Trajectory` views. Default legacy calls retain their extraction behavior; the session API uses validated final submission. This makes the call-count change explicit.

Decision (2026-09-06): checkpoints represent completed exchanges only. They are resumable conversations, not a guarantee of exactly-once external side effects across a crash during a tool call.

## Outcomes & Retrospective


Implementation results and ADR distillation are pending.

## Context and Orientation


`shikumi-tools/src/Shikumi/Agent/ReAct.hs` implements prompt and native protocols behind `ProtocolImpl`. `Proposal` currently reduces native calls to `(Text, Value)`, discarding IDs. Both renderers flatten a `Trajectory` into one user message. `reactLoop` always invokes `extract`; `Step` holds only textual observations. `Shikumi.Compaction` in `shikumi/src/Shikumi/Compaction.hs` summarizes old steps and retries context-window failures. `shikumi-tools/test/ReActSpec.hs` supplies scripted model tests and must remain the basis for regression coverage.

`shikumi-tools/src/Shikumi/Tool.hs` owns typed `Tool i o`, existential `SomeTool`, and `runToolCall :: ToolRegistry -> ToolCall -> Eff es (Either ToolError Text)` under the `LLM` and `Error ShikumiError` capabilities. Those are the two effects allowed inside `Program.Embed`, defined in `shikumi/src/Shikumi/Program.hs`.

Mori discovery of `mori://shinzui/baikai` and `mori://shinzui/baikai/docs/tools` established that the dependency already supports assistant messages, `ToolResultMessage`, original IDs, and `ToolResult` with text/image blocks and an error flag. Source artifact handles are pending: consult canonical project `mori://shinzui/baikai` at project-relative `baikai/src/Baikai/Message.hs` and `baikai/src/Baikai/Content.hs`. `Message` currently derives `ToJSON` only; do not assume it has a decoder. Current provider mappings reject image tool results, so preserving an image locally must not imply provider support. Current shikumi bounds are `baikai >=0.6 && <0.7`; no new bound is chosen by this plan.

[ADR-1](../adr/0001-use-profile-governed-architecture-decisions.md) now governs decision records: allocate stable ADR-N handles, preserve decision/provenance metadata, update the bundle index/log, and run `just check-adr`. No earlier feature-specific ADR was found during the initial review. Preserve the effect boundary and compaction semantics summarized here; record the new session and output ownership in an ADR during implementation.

## Plan of Work


### Milestone 1: rich output and dynamic tool dispatch


Add `shikumi-tools/src/Shikumi/Tool/Output.hs` containing `ToolOutput`, which carries a `Baikai.ToolResult` plus `Maybe Value` structured data and raw extension blocks as `[Value]`. This preserves results that the provider message vocabulary cannot represent. Provide deterministic `renderToolOutput` and `toolOutputMessage` projections: structured JSON and extension blocks become explicitly labeled JSON text blocks, while native text/image blocks preserve their type. Never silently discard blocks or claim that image support is available where the provider rejects it.

In `Shikumi.Tool`, add a dynamic existential arm carrying name, description, input schema and a rank-polymorphic body returning `Either ToolError ToolOutput`. Add `mkDynTool`, `runErasedOutput`, and `runToolCallOutput`. Existing typed results convert to one text block; retain `runErased` and `runToolCall` as textual projections. Test typed compatibility, structured-only results, mixed blocks and model-visible failures in `shikumi-tools/test/ToolOutputSpec.hs`. Run the package test command below; every result field must remain recoverable before projection.

### Milestone 2: structured completed-turn session


Create `shikumi-tools/src/Shikumi/Agent/History.hs` and `shikumi-tools/test/AgentHistorySpec.hs`. Represent a session as ordered user turns and completed assistant exchanges; an exchange contains the exact assistant message and ordered `(ToolCall, ToolOutput)` results. Validate unique nonempty call IDs, one result per call, names matching their calls, and no orphan results before sending any request. A malformed whole exchange, including missing or duplicate native call IDs or cut-off arguments, is never dispatched. Omit that invalid exchange from the provider-facing request and append a protocol-level corrective user message describing the fault; retain the original response in the audit record. Never manufacture orphan tool results for invalid native IDs. Only the prompt fallback may assign documented session-local synthetic IDs to its own parsed actions, since that protocol has no provider-assigned IDs. Keep full audit exchanges distinct from the compacted prompt view.

Add session start, bounded advance, and continuation APIs in `ReAct.hs`. Execute requested calls sequentially in response order. A completed advance returns either a validated final value or a checkpoint after all tools in that assistant turn have resolved. Resume appends the new user input to a validated checkpoint and rebuilds the context from messages; it never dispatches existing exchanges. Add a namespaced final tool derived from `ToSchema o`, reject registry collisions at startup, and validate its arguments through `FromModel` and `Validatable`. A turn mixing final submission with ordinary calls is rejected before dispatch; a malformed final produces a corrective observation and consumes an iteration. Prompt fallback encodes equivalent actions as JSON and preserves continuation semantics.

Test with calls `call-A` and `call-B`: the second model request contains the original assistant message followed by results with exactly those IDs, both tools ran once, and final submission returns the expected typed record with no extraction call. Existing legacy tests still pass.

### Milestone 3: persistence, compaction and recovery


Implement explicit version-1 checkpoint encoding/decoding in `History.hs`; use a local transfer representation with parsers for every supported message and output block instead of relying on a nonexistent `FromJSON Message` instance. Store protocol, schema version, signature/output-schema fingerprint, tool names and schemas, cumulative turn count, full exchanges and prompt-view compaction summaries. On continuation reject incompatible signatures or tool schemas before any model/tool execution. Allow additional tools only through an explicit validated session restart, not silently on resume. Caller-owned registry bodies and live connections are never serialized.

Compact only whole completed assistant exchanges. Keep the full history for audit and the summary plus retained tail for requests. Ensure the retained tail never starts with orphan tool results. Context-window retries perform at most the existing bounded retry and do not repeat dispatched tools. Reject unknown checkpoint versions, duplicate IDs, invalid JSON and unresolved exchanges. A checkpoint after a full turn survives encode/decode and resumes with the same next request as an uninterrupted run.

### Milestone 4: package integration and documentation


Expose new modules and register tests in `shikumi-tools/shikumi-tools.cabal` and the existing test entry point. Add a complete scripted continuation example in `docs/user/` following existing documentation conventions, showing the legacy API and explicit session API. Explain model-call accounting, final validation, unsupported image behavior, and the crash boundary. Run the tests below and the full workspace build; record output and durable ADR decisions before marking completion.

## Concrete Steps


Run from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
nix develop .#ghc9124 -c cabal build shikumi-tools
nix develop .#ghc9124 -c cabal test shikumi-tools
nix develop .#ghc9124 -c cabal build all
```

Read Mori-located sources before using additional dependency APIs. If a new dependency version becomes necessary, verify its Hackage release and upstream release tag before editing Cabal bounds. Successful test output reports the shikumi-tools test suite passing, including the new history/output tests; capture actual totals during implementation rather than assuming a count.

## Validation and Acceptance


The headline scenario runs one two-tool turn, serializes the checkpoint, resumes with a follow-up user message and obtains a validated answer. Assert exact request message order and call IDs, dispatch counters equal to one for each completed tool, preservation of structured JSON after round-trip, and zero extra extraction calls for a valid final submission. Compare resumed and uninterrupted next requests.

Exercise missing/duplicate IDs, cut-off arguments, invalid final schemas, mixed final/tool calls, registry name collisions, incompatible checkpoint signatures, unknown versions, iteration exhaustion and infrastructure failures. Failures must occur before any prohibited dispatch. Force compaction and a context-window retry and prove completed tool counters remain unchanged. Legacy ReAct and CodeAct tests must pass because their public trajectory types remain usable. Rich image blocks remain preserved locally and provider rejection remains explicit.

## Idempotence and Recovery


Builds and tests are repeatable. Checkpoint serialization does not execute tools. Resume only a validated completed-turn checkpoint; a process failure during a tool call requires caller reconciliation because repeating a remote action can duplicate effects. Never automatically retry side-effectful tools after an uncertain transport outcome. Keep legacy APIs until migration tests pass; retain the original checkpoint when decoding fails.

## Interfaces and Dependencies


`Shikumi.Tool.Output` owns `ToolOutput`, `renderToolOutput :: ToolOutput -> Text`, and `toolOutputMessage :: ToolCall -> ToolOutput -> Message`. Its fields are `result :: Baikai.ToolResult`, `structuredContent :: Maybe Value`, and `extensionBlocks :: [Value]`. `Shikumi.Tool` owns `mkDynTool :: Text -> Text -> Value -> (forall es. (LLM :> es, Error ShikumiError :> es) => Value -> Eff es (Either ToolError ToolOutput)) -> SomeTool`; rich dispatch uses the same constraints and returns `Either ToolError ToolOutput`. Text dispatch remains a compatibility projection.

`Shikumi.Agent.History` owns opaque `ReActSession`, `HistoryError`, `encodeSession :: ReActSession -> Value`, and `decodeSession :: Value -> Either HistoryError ReActSession`. Expose read-only audit and prompt-message accessors. `ReAct.hs` owns `SessionResult o = SessionPaused ReActSession | SessionFinished o ReActSession` and `startSession`, `advanceSession`, `continueSession`; each effectful operation uses the existing `LLM`/`Error ShikumiError` row and the same signature constraints as `reactWithTrajectory`. `advanceSession` completes at most one assistant exchange; `continueSession` appends a user turn at a completed-exchange boundary and rejects unresolved exchanges; a paused conversation is a valid continuation input. A convenience runner advances until finish or the configured limit.

This plan has no hard dependency on MCP or other new optimizer plans. Plan 30 consumes its generic output/dynamic tool seam. Use existing `aeson`, `text`, `vector`, `containers`, `effectful` and Baikai capabilities. No provider transport code or unrelated CodeAct behavior is owned here.

Revision (2026-09-06): linked the newly bootstrapped ADR bundle and its authoring/check contract; implementation status is unchanged.
