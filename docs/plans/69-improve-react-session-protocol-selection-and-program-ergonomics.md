---
id: 69
slug: improve-react-session-protocol-selection-and-program-ergonomics
title: "Improve ReAct session protocol selection and program ergonomics"
kind: exec-plan
created_at: 2026-11-03T23:28:37Z
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-03T23:28:37Z
---

# Improve ReAct session protocol selection and program ergonomics

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill durable decisions into `docs/adr/` before completion. Follow `.codex/skills/exec-plan/FRICTION.md` when recording implementation friction.


## Purpose / Big Picture


Let an application supply a model once, obtain native tool calling automatically when that model supports it, and run a resumable agent through an ordinary Shikumi `Program`. Let applications distinguish a completed tool exchange, a rejected model proposal, and an exhausted iteration budget through typed results. A checkpoint is the explicit conversation value that can be saved and resumed; a proposal is one assistant response requesting tools or submitting the final answer.

These three improvements belong together because protocol selection determines how the session starts, pause reasons describe its execution, and the new program constructor composes both. Demonstrate them with an offline program that requests two tools, preserves their IDs, and submits a validated answer in two assistant exchanges, with no separate answer-extraction call. With a one-exchange budget, the same program must return a typed budget pause and a resumable checkpoint.

The implementation scope is these three API improvements and their tests and documentation. Execution journaling, concurrent tool dispatch, forced final submission, new provider support, optimizer support for embedded agents, and release publication are outside this plan. Creating this plan does not implement it.


## Progress


- [ ] M1: Explicit-model sessions select and retain the correct automatic protocol across advancement, continuation, and checkpoint restoration; existing explicit choices remain compatible.
- [ ] M2: Additive detailed session results distinguish exchange completion, proposal rejection, and iteration exhaustion while legacy session operations retain their public types and behavior.
- [ ] M3: Session-backed program constructors return a validated answer or typed pause with its checkpoint through `runProgram`; a compiled offline example proves the combined behavior.
- [ ] M4: Guides, capability documentation, changelog, and relevant ADRs describe the additive API; package tests, workspace build, Haddock checks, and formatting checks pass.


## Surprises & Discoveries


(None yet.)


## Decision Log


2026-11-03: Combine the three requested improvements in one standalone plan. The completed session runtime from plan 54 is already present; no new MasterPlan or dependency feature is needed.

2026-11-03: Keep `SessionResult`, `advanceSession`, `runSession`, `react`, and `reactWithTrajectory` source-compatible. Introduce a separate detailed result and operations, and have legacy operations project from the shared implementation. This avoids changing constructor arities or silently changing legacy extraction.

2026-11-03: Resolve automatic protocol selection from an explicit model at construction and store the concrete protocol in the checkpoint. Automatic configuration accepts that stored choice on resume; it never renegotiates existing history. Model-free construction retains the conservative prompt fallback because the actual ambient model is unavailable in the session effect row.

2026-11-03: Return the detailed outcome from new `Program` constructors so an exhausted session remains available to the caller. Pause reasons describe an invocation's result, remain outside serialized checkpoints, and require no new checkpoint version.


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


`shikumi-tools/src/Shikumi/Agent/ReAct.hs` contains both the legacy loop and the completed-exchange session runtime. Legacy `react` and `reactWithTrajectory` build a `Program` using `embed` and perform separate typed answer extraction. The session functions are `startSession`, `startSessionWithModel`, `advanceSession`, `continueSession`, and `runSession`. Sessions accept final arguments through `shikumi_submit_final`, applying schema decoding and semantic validation, and dispatch ordinary tools sequentially.

`resolveProtocolKind` distinguishes native tool calling from the prompt protocol, which encodes calls as JSON text. Its automatic policy permits first-party OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages, and falls back for CLI and other transports. However, `protocolText` always calls that resolver with `emptyModel`. `startSessionWithModel` calls `startSession` before binding the model origin, so an explicit supported model still gets the prompt protocol under `ProtocolAuto`. `checkSession` repeats the empty-model resolution; changing construction alone would reject a new native checkpoint on its first advance.

`shikumi-tools/src/Shikumi/Agent/History.hs` owns the opaque `ReActSession`, exact signature and registry compatibility values, concrete `sessionProtocol`, full audit history, compacted request history, and versioned JSON persistence. It writes version 2 and reads versions 1 and 2. The current `SessionResult o` is `SessionPaused ReActSession` or `SessionFinished o ReActSession`; all nonterminal cases share the same pause constructor. `runSession` keeps advancing rejected and successful ordinary exchanges until final submission or the per-user iteration limit. `continueSession` appends input and resets that limit. Raising `maxIters` permits more advancement without inserting a user message.

`shikumi/src/Shikumi/Program.hs` defines `Program i o` and `embed`, which wraps an effectful function needing only `LLM` and `Error ShikumiError`. Embedded agents have no optimizer parameter traversal and appear as `ShapeEmbed`. `shikumi/src/Shikumi/Routing.hs` chooses the ambient model at the LLM boundary and can overwrite the requested placeholder. Explicit session origins must still agree with the resolved model. Preserve continuation guards and supply credentials through runtime routing rather than checkpoint persistence.

`shikumi-tools/test/AgentHistorySpec.hs` is the primary session suite, covering exact replay, malformed proposals, final validation, persistence, compaction, and infrastructure failures. `shikumi-tools/test/SessionSpec.hs` tests a separate bounded code-execution session and is not the target suite. `shikumi-tools/test/ProtocolSpec.hs` covers protocol policy. `shikumi-tools/test/ReActSessionExample.hs` is compiled and executed by the documented continuation test. `shikumi-testing/src/Shikumi/Testing.hs` exposes reusable offline helpers; `AgentHistorySpec.hs` also owns session-specific request and dispatch recording. `shikumi-tools/test/Main.hs` and `shikumi-tools/shikumi-tools.cabal` register tests and examples.

[ADR-6](../adr/0006-preserve-completed-react-exchanges-in-versioned-sessions.md) requires complete exchanges, original native IDs, validated final submission, guarded continuation, and a separate legacy extraction path. [ADR-14](../adr/0014-separate-schema-enforcement-from-tool-calling-capability.md) keeps native tools independent of schema enforcement and excludes CLI tools from automatic native selection. [ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md) places reusable scripted interpreters in `shikumi-testing`. [ADR-11](../adr/0011-preserve-provider-errors-and-centralize-retry-policy.md) preserves provider errors and cancellation. [ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md) preserves routing, defaults, cache, and transport ordering. Extend ADR-6 and ADR-14 during implementation with the protocol-pinning and additive API rules. Existing `docs/adr/profile.dhall` and `just check-adr` govern ADR edits.

Dependency discovery used `mori registry list`, `mori registry show shinzui/baikai --full`, and `mori registry docs shinzui/baikai`. Verified guides are `mori://shinzui/baikai/docs/tools` and `mori://shinzui/baikai/docs/models-and-providers`. In project `mori://shinzui/baikai`, project-relative `baikai/src/Baikai/Model.hs` defines model identity and runtime headers/compatibility data; its artifact-level source URI is pending. No dependency bounds or pins change here. If implementation unexpectedly needs a dependency change, use Mori to discover source and verify the authoritative package registry release and upstream tag before choosing bounds.


## Plan of Work


### M1: Resolve explicit-model protocols once and preserve compatibility


Refactor construction in `shikumi-tools/src/Shikumi/Agent/ReAct.hs` so both start functions share validation and history creation, but `startSessionWithModel` resolves `protocol cfg` against its supplied model before creating the session. `startSession` continues resolving against `emptyModel`. Keep `resolveProtocolKind` and its supported-provider table as policy authority. Explicit `ProtocolNative` and `ProtocolPrompt` still override automatic policy, including deliberately forced native mode with a custom interpreter.

Separate configuration compatibility from initial resolution. For an existing session, explicit native or prompt configuration must equal the stored concrete protocol; automatic configuration accepts the stored valid native or prompt choice. Origin and protected-prefix validation remain enforced independently. Do not reconstruct protocol from an old origin, promote a restored prompt checkpoint to native, or rewrite assistant history. Version-1 checkpoints and pre-change checkpoints keep their stored protocol. An explicit conflicting choice fails before any model or tool call.

Add regressions in `shikumi-tools/test/AgentHistorySpec.hs` and `shikumi-tools/test/ProtocolSpec.hs`. A credential-free first-party HTTP model plus `ProtocolAuto` must produce native tools and assistant/tool messages preserving call IDs. The native checkpoint must advance, continue, encode/decode, and advance again under the automatic configuration without a compatibility error. Cover CLI, custom, and third-party fallbacks, both explicit overrides, and an older prompt checkpoint whose origin identifies a native-capable model. Test matching `runRouting`/`routeLLM` identity and prove a mismatch fails before dispatch. Acceptance requires captured requests to establish selection and preserved history. Run focused tests and then the package suite.


### M2: Expose detailed pause outcomes through one session engine


Add the types and detailed operations specified in Interfaces and Dependencies to `Shikumi.Agent.ReAct`. Move execution into `advanceSessionDetailed`, taking rejection reasons directly from the rejection branch. An ordinary accepted exchange returns `SessionSuspended ExchangeCompleted checkpoint`, including recoverable tool-error results. A rejected proposal returns `SessionSuspended (ProposalRejected reason) checkpoint`, with the same correction text retained in audit history. Advance on an already exhausted budget returns `SessionSuspended IterationLimitReached original` without a model call. Negative and zero limits retain their effective zero-limit behavior. A valid final returns `SessionCompleted answer checkpoint`.

Implement `runSessionDetailed` as the bounded driver. Continue after `ExchangeCompleted` and `ProposalRejected` while budget remains. If either consumes the final available iteration, return `IterationLimitReached` with that latest checkpoint; the exchange or rejection remains in its audit. The single-step function reports what its step did, whereas the runner reports why its loop stopped. Document and test this distinction. Advancing a finished session still raises the existing validation error until a new user turn is appended.

Implement `advanceSession` and `runSession` as projections to existing `SessionResult`. Do not infer reasons by parsing diagnostic strings or rerun tools to determine a result. Provider failures, infrastructure exceptions, cancellation, incompatible checkpoints, and unsafe reasoning recovery keep their existing error paths. Pause reasons are invocation results; neither checkpoint JSON nor `HistoryEntry` needs a new field.

Verify all three reasons, successful final submission, invalid final arguments, malformed calls, mixed final/tool proposals, recoverable tool errors, and exhaustion at zero and at the final consumed iteration. A rejected proposal followed by a valid final proves bounded continuation in the detailed runner. Compare projected detailed runs and legacy runs against identical fresh scripts: answers, checkpoints, request order, dispatch counts, and proposal counts must agree. Existing compaction and legacy ReAct regressions remain green. This milestone is independently accepted by focused AgentHistory tests and the package suite.


### M3: Add program constructors and a combined consumer example


Add `reactSession` and `reactSessionWithModel` in `shikumi-tools/src/Shikumi/Agent/ReAct.hs`, with the signatures below. Each embeds session start followed by `runSessionDetailed`; the explicit-model variant uses the corrected explicit-model start. Its output preserves typed completion, checkpoint, and pause reason. A suspended outcome is a normal return of the embedded program, so `FMap` or composition can decide what follows. Existing `react` and `reactWithTrajectory` retain extraction, output types, and trajectory semantics.

Extend `shikumi-tools/test/ReActSessionExample.hs` with a second exported example using `reactSessionWithModel` and `runProgram`, keeping the original continuation example callable. Use a credential-free first-party identity and `ProtocolAuto` so it exercises M1. A strict scripted interpreter returns one two-tool proposal and one final submission, failing on unexpected extra calls. Tool bodies stay within the rank-polymorphic LLM/error boundary; reuse the nested-call recording technique if observing dispatch. Compare the constructor run with direct start plus detailed run under equivalent scripts.

Run the same program with `maxIters = 1`. It must return `SessionSuspended IterationLimitReached checkpoint` after both tools have resolved. Encode/decode it, increase `maxIters`, and call `runSessionDetailed` to finish without redispatching either tool. This demonstrates budget extension without inserting a user turn. Separately prove that `continueSession` accepts new input and resets the per-user limit. Test the model-free constructor with a prompt script. Register example checks in `AgentHistorySpec.hs`; update Cabal and `Main.hs` only if a new test module is introduced.

Run the package suite and workspace build. Acceptance requires the public `runProgram` path, composition with a following transformation, existing `ShapeEmbed` behavior, zero extraction calls, and equal direct-versus-program outcomes. The two-tool program is the early combined consumer proof before expanding documentation variants.


### M4: Document and validate the public contract


Update `docs/user/resumable-react-sessions.md` with the compiled program example, explicit-model automatic selection, pinned protocol on restoration, detailed pause handling, and budget extension. Replace the blanket statement that session auto always selects prompt with the explicit-model versus model-free rule. Link the entry points from `docs/user/tools-and-agents.md` and the agent overview in `README.md`. Keep legacy extraction and session final submission accurately described.

Update `docs/capabilities/resumable-react-sessions.md` and `docs/capabilities/react-agents.md` where behavior changes, retaining stable capability IDs and following existing bundle index/log conventions. Add an unreleased entry to `shikumi-tools/CHANGELOG.md`. Update the module-level Haddock in `Shikumi.Agent.ReAct`, whose opening currently implies every agent extracts an answer. Distill durable rules into ADR-6 and ADR-14, preserving stable IDs and recording meaningful timestamp changes with the local OKF log tooling. These documentation edits are implementation work; plan creation does not preemptively change accepted ADRs.

Run final checks in Concrete Steps and record actual evidence in Progress and Outcomes & Retrospective. Completion requires all three requested behaviors and compatibility obligations, plus documentation that allows a reader to choose the appropriate entry point and handle its result.


## Concrete Steps


Run from the repository root. These are implementation checks; authoring this plan requires document validation only. Nix provides GHC/Cabal, and tests use scripted responses without paid calls or credentials.

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
mori registry show shinzui/baikai --full
mori registry docs shinzui/baikai
mori path mori://shinzui/baikai/docs/tools
nix develop .#ghc9124 -c cabal test shikumi-tools --test-options='-p AgentHistory'
nix develop .#ghc9124 -c cabal test shikumi-tools
nix develop .#ghc9124 -c cabal build all
nix develop .#ghc9124 -c just check-haddock shikumi-tools
nix develop .#ghc9124 -c just check-adr
nix fmt
git diff --check
```

Use focused AgentHistory checks after M1 and M2 and package tests after cohesive implementation changes. Run the workspace build and final documentation gates at M3/M4; repeat only when subsequent changes invalidate evidence. The capabilities bundle declares `docs/capabilities/profile.dhall`; after capability changes run:

```bash
nix develop .#ghc9124 -c okf validate docs/capabilities --strict --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
```

Successful package output includes the equivalent of the following, with the actual test total recorded rather than this placeholder:

```text
All <actual count> tests passed
Test suite shikumi-tools-test: PASS
```

The combined example asserts its full typed fixture answer and two cumulative assistant exchanges. Its one-iteration variant reports `IterationLimitReached`. Restoration and budget extension finish with both original dispatch counts still equal to one. Use either existing weather or city fixtures, asserting complete typed values.


## Validation and Acceptance


The primary consumer proof runs `runProgram (reactSessionWithModel model signature registry defaultReActConfig) input` under a strict script. For a supported first-party HTTP identity, requests advertise native tools and retain original assistant/tool messages. The final value passes `Validatable`, and exactly two proposal responses are consumed. No extraction or protocol-discovery request is allowed. Nested tool-owned LLM calls used to record dispatch count separately from proposals.

The pause proof feeds one valid ordinary exchange, one malformed proposal, and one zero-budget session separately into `advanceSessionDetailed`. They return `ExchangeCompleted`, `ProposalRejected reason`, and `IterationLimitReached`. The rejection reason agrees with the audit correction; zero budget produces zero model and tool calls. The detailed runner continues through rejection if budget permits and returns a budget pause otherwise. A valid final on the last allowed iteration succeeds.

The persistence proof starts a native automatic session, records `call-A` and `call-B`, serializes/restores it, and continues under automatic configuration. Results remain paired with original IDs and neither tool repeats. An older prompt checkpoint stays prompt even when its origin is first-party HTTP. An explicitly conflicting protocol or incompatible routed model fails before dispatch. Immutable version-1 and version-2 round-trip regressions stay valid; pause metadata never appears in checkpoint bytes.

The compatibility proof retains compilation of existing `SessionPaused checkpoint` and `SessionFinished answer checkpoint` matches. Legacy `react` retains extraction, while new constructors use final submission. Ordinary tool errors stay model-visible. Infrastructure failures and provider refusals remain failures rather than pauses. Existing compaction, reasoning guards, context-window retry limits, and request-default behavior remain intact.

These checks establish local protocol selection, request construction, and session semantics. They do not establish new provider capabilities or exactly-once external effects. No new live provider test or performance benchmark is required for these API changes.


## Idempotence and Recovery


Required checks are repeatable and offline. Entry points are additive, allowing incremental adoption. No storage migration, checkpoint rewrite, or automatic promotion of existing prompt history is needed. Preserve original checkpoint bytes when diagnosing restore failures.

A returned checkpoint still contains a whole completed exchange. An infrastructure failure or crash during dispatch may leave external effects without a returned checkpoint. This plan adds no execution journal and must not retry uncertain side effects automatically. Increasing the iteration limit continues from the last returned checkpoint; appending a user turn is an explicit alternative with its documented budget reset. Error and cancellation paths retain current behavior.

Keep dependency bounds and current branch unchanged. Publication and changes to other repositories are separate tasks. Implementation commits follow Conventional Commits and include an `ExecPlan:` trailer naming this file. Record provenance and friction according to the exec-plan skill and triage implementation friction before completion.


## Interfaces and Dependencies


All new API belongs in `Shikumi.Agent.ReAct`, package `shikumi-tools`. Export these types with their constructors. `Text` is `Data.Text.Text`; `ReActSession` is the existing opaque history type.

```haskell
data SessionPauseReason
  = ExchangeCompleted
  | ProposalRejected Text
  | IterationLimitReached
  deriving stock (Eq, Show)

data SessionOutcome o
  = SessionSuspended SessionPauseReason ReActSession
  | SessionCompleted o ReActSession
  deriving stock (Eq, Show)
```

Expose these detailed operations and constructors. `i` is fixed by the signature even though advancement receives no new input.

```haskell
advanceSessionDetailed, runSessionDetailed
  :: ( ToSchema o, FromModel o, Validatable o
     , LLM :> es, Error ShikumiError :> es
     )
  => Signature i o
  -> ToolRegistry
  -> ReActConfig
  -> ReActSession
  -> Eff es (SessionOutcome o)

reactSession
  :: (ToPrompt i, ToSchema o, FromModel o, Validatable o)
  => Signature i o
  -> ToolRegistry
  -> ReActConfig
  -> Program i (SessionOutcome o)

reactSessionWithModel
  :: (ToPrompt i, ToSchema o, FromModel o, Validatable o)
  => Model
  -> Signature i o
  -> ToolRegistry
  -> ReActConfig
  -> Program i (SessionOutcome o)
```

Use existing start operations followed by `runSessionDetailed` inside `embed`. Keep `SessionResult` unchanged. A private projection maps `SessionSuspended _ s` to `SessionPaused s` and `SessionCompleted answer s` to `SessionFinished answer s`. Both old operations share the detailed engine rather than maintain separate loops.

`ExchangeCompleted` means every ordinary tool result is recorded, not that the task is finished. `ProposalRejected` means the response is audit-only and its correction enters the request view. `IterationLimitReached` means the invocation cannot make another proposal within its configured bound. Finished state and cumulative/per-user counters remain session properties. No new `ReActConfig` field, `Program` node, effect, provider policy, or checkpoint version is needed.

The prerequisites are the completed [plan 54](54-add-structured-resumable-react-history.md), [plan 59](59-guard-reasoning-state-across-session-compaction-and-model-changes.md), and [plan 67](67-enforce-typed-output-schemas-on-cli-providers.md). There is no pending cross-plan prerequisite or external API work. Use already-declared dependency versions and canonical Mori URIs for durable cross-repository references.
