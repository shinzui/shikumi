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
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-05T04:46:28Z
      verdict: "changes-requested"
      note: "API idiom review against the ReAct session source: shared SessionOutcome had unreachable pause reasons on the run and program path, synonym constructors, no Functor or checkpoint projection; fixes applied in the same-session revision"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-05T04:46:28Z
      mode: "update"
      note: "Replace SessionOutcome and Detailed operations with a flat SessionStep and advanceSessionStep; programs return SessionResult; add Functor/Traversable, checkpoint projections, private pinned protocol type"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-05T04:57:07Z
      mode: "update"
      note: "Follow-up at the user's direction: dedicated run-level SessionOutcome (SessionAnswered, SessionExhausted) from runSessionOutcome and the program constructors; SessionResult left untouched"
---

# Improve ReAct session protocol selection and program ergonomics

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Distill durable decisions into `docs/adr/` before completion. Follow `.codex/skills/exec-plan/FRICTION.md` when recording implementation friction.


## Purpose / Big Picture


Let an application supply a model once, obtain native tool calling automatically when that model supports it, and run a resumable agent through an ordinary Shikumi `Program`. Let applications distinguish a completed tool exchange, a rejected model proposal, and an exhausted iteration budget through typed results. A checkpoint is the explicit conversation value that can be saved and resumed; a proposal is one assistant response requesting tools or submitting the final answer.

These three improvements belong together because protocol selection determines how the session starts, step results describe its execution, and the new program constructor composes both. Demonstrate them with an offline program that requests two tools, preserves their IDs, and submits a validated answer in two assistant exchanges, with no separate answer-extraction call. With a one-exchange budget, the same program must report that its iteration limit is exhausted and return a resumable checkpoint.

The implementation scope is these three API improvements and their tests and documentation. Execution journaling, concurrent tool dispatch, forced final submission, new provider support, optimizer support for embedded agents, and release publication are outside this plan. Creating this plan does not implement it.


## Progress


- [ ] M1: Explicit-model sessions select and retain the correct automatic protocol across advancement, continuation, and checkpoint restoration; existing explicit choices remain compatible.
- [ ] M2: Additive result types separate what a step did from where a run stopped. `SessionStep` distinguishes exchange completion, proposal rejection, iteration exhaustion, and an accepted final submission; `SessionOutcome` distinguishes an accepted answer from iteration exhaustion. `advanceSession` and `runSession` keep their public types and behavior on the same engine.
- [ ] M3: Session-backed program constructors return a `SessionOutcome` through `runProgram`, holding a validated answer or iteration exhaustion, each with its checkpoint; a compiled offline example proves the combined behavior.
- [ ] M4: Guides, capability documentation, changelog, and relevant ADRs describe the additive API; package tests, workspace build, Haddock checks, and formatting checks pass.


## Surprises & Discoveries


2026-11-04 (API review, before implementation): A run can pause for only one reason. The `runSession` loop in `shikumi-tools/src/Shikumi/Agent/ReAct.hs` advances every `SessionPaused` checkpoint again while budget remains, so a pause it returns always means the per-user-turn limit is spent. A reason attached to a run-level pause therefore has a single reachable value, and the three-way distinction exists only for a single step. This split the shared `SessionOutcome` and `SessionPauseReason` design into a step-level type and a separate run-level type.


## Decision Log


2026-11-03: Combine the three requested improvements in one standalone plan. The completed session runtime from plan 54 is already present; no new MasterPlan or dependency feature is needed.

2026-11-03: Keep `SessionResult`, `advanceSession`, `runSession`, `react`, and `reactWithTrajectory` source-compatible. Introduce a separate detailed result and operations, and have legacy operations project from the shared implementation. This avoids changing constructor arities or silently changing legacy extraction.

2026-11-03: Resolve automatic protocol selection from an explicit model at construction and store the concrete protocol in the checkpoint. Automatic configuration accepts that stored choice on resume; it never renegotiates existing history. Model-free construction retains the conservative prompt fallback because the actual ambient model is unavailable in the session effect row.

2026-11-03: Return the detailed outcome from new `Program` constructors so an exhausted session remains available to the caller. Pause reasons describe an invocation's result, remain outside serialized checkpoints, and require no new checkpoint version.

2026-11-04: Give each operation a result type that holds exactly its reachable cases. A single step returns a new flat `SessionStep o` with four constructors. A run and the new program constructors return a new flat `SessionOutcome o` with two, `SessionAnswered` and `SessionExhausted`. This refines the 2026-11-03 decision to return a detailed outcome from the program constructors. The original shared `SessionOutcome` left `ExchangeCompleted` and `ProposalRejected` unreachable for a run, so a consumer compiling with `-Wall` had to write impossible branches or a wildcard.

2026-11-04: Use a dedicated run-level type instead of returning the existing `SessionResult` from the run and the program constructors. The user chose this during the API review. `SessionPaused` names no cause, while `SessionExhausted` does. A later stop reason, such as a tool-requested interruption, can be added as a constructor with its own payload, and every exhaustive consumer then fails to compile until it handles the new case. `SessionResult`, `advanceSession`, and `runSession` stay exactly as they are and become projections of the new operations.

2026-11-04: Name constructors by meaning and the new operations by their result types. `SessionSuspended` and `SessionCompleted` were synonyms of the existing `SessionPaused` and `SessionFinished`, and "completed" described both a pause (`ExchangeCompleted`) and the terminal state. The terminal step is `FinalAccepted`, the counterpart of `ProposalRejected`. The run constructors are `SessionAnswered` and `SessionExhausted`. "Exhausted" follows `RLMExhausted` in `Shikumi.CodeExec.RLM` and the existing guide, and avoids "budget", which `ShikumiError` already uses for cost in `BudgetExceeded`. "Answered" is used because a submitted final can still be rejected. The new operations are `advanceSessionStep` and `runSessionOutcome`: each is the existing operation's name followed by its result type, in the way `readMaybe` and `eitherDecode` are named after their results, in place of a `Detailed` suffix.

2026-11-04: Make results composable and follow the module's conventions. `SessionStep` and `SessionOutcome` use strict positional fields, because `-Wpartial-fields` rules out record fields in a sum and the package does not enable `StrictData`. Both new types derive `Functor`, `Foldable`, and `Traversable`, so `FMap (fmap f)` transforms the answer of a session program. Every constructor carries the checkpoint a caller must persist, so total projections `stepCheckpoint` and `outcomeCheckpoint` are exported. `SessionResult` gains nothing.

2026-11-04: Keep the rejection payload as the `Text` correction recorded in audit history. A typed rejection taxonomy would need a matching checkpoint field to survive restoration, which is outside this plan.

2026-11-04: Model the pinned protocol inside `Shikumi.Agent.ReAct` as a private closed type with one total compatibility function, in place of further string comparison. `resolveProtocolKind` keeps its exported type, and `sessionProtocol` stays `Text` as the persisted form.


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


`shikumi-tools/src/Shikumi/Agent/ReAct.hs` contains both the legacy loop and the completed-exchange session runtime. Legacy `react` and `reactWithTrajectory` build a `Program` using `embed` and perform separate typed answer extraction. The session functions are `startSession`, `startSessionWithModel`, `advanceSession`, `continueSession`, and `runSession`. Sessions accept final arguments through `shikumi_submit_final`, applying schema decoding and semantic validation, and dispatch ordinary tools sequentially.

`resolveProtocolKind` distinguishes native tool calling from the prompt protocol, which encodes calls as JSON text. Its automatic policy permits first-party OpenAI Chat Completions, OpenAI Responses, and Anthropic Messages, and falls back for CLI and other transports. However, `protocolText` always calls that resolver with `emptyModel`. `startSessionWithModel` calls `startSession` before binding the model origin, so an explicit supported model still gets the prompt protocol under `ProtocolAuto`. `checkSession` repeats the empty-model resolution; changing construction alone would reject a new native checkpoint on its first advance.

`shikumi-tools/src/Shikumi/Agent/History.hs` owns the opaque `ReActSession`, exact signature and registry compatibility values, concrete `sessionProtocol`, full audit history, compacted request history, and versioned JSON persistence. It writes version 2 and reads versions 1 and 2. The current `SessionResult o` is `SessionPaused ReActSession` or `SessionFinished o ReActSession`; all nonterminal cases share the same pause constructor. `runSession` keeps advancing rejected and successful ordinary exchanges until final submission or the per-user iteration limit, so a pause it returns always means that limit is spent. Only `advanceSession` uses the one pause constructor for three different causes. `continueSession` appends input and resets that limit. Raising `maxIters` permits more advancement without inserting a user message.

`shikumi-tools/shikumi-tools.cabal` compiles with `GHC2024`, `-Wall`, `-Wpartial-fields`, and `-Wmissing-deriving-strategies`, and does not enable `StrictData`. Types in these modules therefore use strict fields and explicit `deriving stock`, and a sum type has positional fields. `Shikumi.Agent.ReAct` already exports the legacy trajectory type `Step`. `shikumi-tools/src/Shikumi/CodeExec/Session.hs` exports an unrelated `SessionResult`, `stepSession`, and `newSession` for the code-execution session, so new names must not add to those collisions. Operations that return more than their base are named for what they return, as in `reactWithTrajectory`, `rlmWithReport`, and `runLLMWithEvidence`.

`shikumi/src/Shikumi/Program.hs` defines `Program i o` and `embed`, which wraps an effectful function needing only `LLM` and `Error ShikumiError`. Embedded agents have no optimizer parameter traversal and appear as `ShapeEmbed`. `shikumi/src/Shikumi/Routing.hs` chooses the ambient model at the LLM boundary and can overwrite the requested placeholder. Explicit session origins must still agree with the resolved model. Preserve continuation guards and supply credentials through runtime routing rather than checkpoint persistence.

`shikumi-tools/test/AgentHistorySpec.hs` is the primary session suite, covering exact replay, malformed proposals, final validation, persistence, compaction, and infrastructure failures. `shikumi-tools/test/SessionSpec.hs` tests a separate bounded code-execution session and is not the target suite. `shikumi-tools/test/ProtocolSpec.hs` covers protocol policy. `shikumi-tools/test/ReActSessionExample.hs` is compiled and executed by the documented continuation test. `shikumi-testing/src/Shikumi/Testing.hs` exposes reusable offline helpers; `AgentHistorySpec.hs` also owns session-specific request and dispatch recording. `shikumi-tools/test/Main.hs` and `shikumi-tools/shikumi-tools.cabal` register tests and examples.

[ADR-6](../adr/0006-preserve-completed-react-exchanges-in-versioned-sessions.md) requires complete exchanges, original native IDs, validated final submission, guarded continuation, and a separate legacy extraction path. [ADR-14](../adr/0014-separate-schema-enforcement-from-tool-calling-capability.md) keeps native tools independent of schema enforcement and excludes CLI tools from automatic native selection. [ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md) places reusable scripted interpreters in `shikumi-testing`. [ADR-11](../adr/0011-preserve-provider-errors-and-centralize-retry-policy.md) preserves provider errors and cancellation. [ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md) preserves routing, defaults, cache, and transport ordering. Extend ADR-6 and ADR-14 during implementation with the protocol-pinning and additive API rules. Existing `docs/adr/profile.dhall` and `just check-adr` govern ADR edits.

Dependency discovery used `mori registry list`, `mori registry show shinzui/baikai --full`, and `mori registry docs shinzui/baikai`. Verified guides are `mori://shinzui/baikai/docs/tools` and `mori://shinzui/baikai/docs/models-and-providers`. In project `mori://shinzui/baikai`, project-relative `baikai/src/Baikai/Model.hs` defines model identity and runtime headers/compatibility data; its artifact-level source URI is pending. No dependency bounds or pins change here. If implementation unexpectedly needs a dependency change, use Mori to discover source and verify the authoritative package registry release and upstream tag before choosing bounds.


## Plan of Work


### M1: Resolve explicit-model protocols once and preserve compatibility


Refactor construction in `shikumi-tools/src/Shikumi/Agent/ReAct.hs` so both start functions share validation and history creation, but `startSessionWithModel` resolves `protocol cfg` against its supplied model before creating the session. `startSession` continues resolving against `emptyModel`. Keep `resolveProtocolKind` and its supported-provider table as policy authority. Explicit `ProtocolNative` and `ProtocolPrompt` still override automatic policy, including deliberately forced native mode with a custom interpreter.

Separate configuration compatibility from initial resolution. For an existing session, explicit native or prompt configuration must equal the stored concrete protocol; automatic configuration accepts the stored valid native or prompt choice. Origin and protected-prefix validation remain enforced independently. Do not reconstruct protocol from an old origin, promote a restored prompt checkpoint to native, or rewrite assistant history. Version-1 checkpoints and pre-change checkpoints keep their stored protocol. An explicit conflicting choice fails before any model or tool call.

Express both rules through a type instead of more string comparison. Today the resolved protocol travels as the `Text` values `"native"` and `"prompt"`, and `resolveProtocolKind` returns the three-way `ToolProtocol`, so its callers need a wildcard arm for a `ProtocolAuto` that cannot occur. Add the private `PinnedProtocol` type and functions listed in Interfaces and Dependencies: one resolves a `ToolProtocol` against a `Model`, a pair converts to and from the stored `Text`, and one total function decides whether a configured `ToolProtocol` admits a pinned protocol. Both start functions and `checkSession` go through them. None of this is exported. `resolveProtocolKind` keeps its type and results and may be defined from the private resolver, so the supported-provider table has one reader. `sessionProtocol` remains the persisted `Text`.

Add regressions in `shikumi-tools/test/AgentHistorySpec.hs` and `shikumi-tools/test/ProtocolSpec.hs`. A credential-free first-party HTTP model plus `ProtocolAuto` must produce native tools and assistant/tool messages preserving call IDs. The native checkpoint must advance, continue, encode/decode, and advance again under the automatic configuration without a compatibility error. Cover CLI, custom, and third-party fallbacks, both explicit overrides, and an older prompt checkpoint whose origin identifies a native-capable model. Test matching `runRouting`/`routeLLM` identity and prove a mismatch fails before dispatch. Acceptance requires captured requests to establish selection and preserved history. Run focused tests and then the package suite.


### M2: Expose single-step results through one session engine


Add `SessionStep`, `SessionOutcome`, `stepCheckpoint`, `outcomeCheckpoint`, `advanceSessionStep`, and `runSessionOutcome` to `Shikumi.Agent.ReAct` as specified in Interfaces and Dependencies. Move execution into `advanceSessionStep`, taking rejection reasons directly from the rejection branch. An ordinary accepted exchange returns `ExchangeCompleted checkpoint`, including recoverable tool-error results. A rejected proposal returns `ProposalRejected reason checkpoint`, with the same correction text retained in audit history. Advancing on an already exhausted budget returns `IterationLimitReached original` without a model call. Negative and zero limits retain their effective zero-limit behavior. A valid final returns `FinalAccepted answer checkpoint`.

Implement `runSessionOutcome` as the driver over `advanceSessionStep`, using an exhaustive match with no wildcard arm. It continues after `ExchangeCompleted` and `ProposalRejected`, returns `SessionExhausted` for `IterationLimitReached`, and returns `SessionAnswered` for `FinalAccepted`. Exactly one arm produces `SessionExhausted`, so it means the iteration limit is spent by construction. The step that consumes the final iteration still reports what it did. The driver's next step then observes the spent budget without a model or tool call, so request and dispatch counts do not change, and the exchange or rejection remains in the audit. A step reports what it did, whereas a run reports where it stopped. Document and test this distinction. Advancing a finished session still raises the existing validation error until a new user turn is appended.

Implement `advanceSession` and `runSession` as `advanceSessionStep` and `runSessionOutcome` followed by private total projections to the unchanged `SessionResult`. Do not infer reasons by parsing diagnostic strings or rerun tools to determine a result. Provider failures, infrastructure exceptions, cancellation, incompatible checkpoints, and unsafe reasoning recovery keep their existing error paths. Step results and run outcomes describe one invocation; neither checkpoint JSON nor `HistoryEntry` needs a new field.

Verify all four step results across an ordinary exchange, a recoverable tool error, invalid final arguments, malformed calls, a mixed final/tool proposal, a valid final, and a zero budget. Verify that `runSessionOutcome` returns `SessionExhausted` after the final consumed iteration, that a rejected proposal followed by a valid final returns `SessionAnswered` within budget, and that a valid final on the last allowed iteration succeeds. Compare `advanceSession` and `runSession` with `advanceSessionStep` and `runSessionOutcome` against identical fresh scripts: answers, checkpoints, request order, dispatch counts, and proposal counts must agree. Check `stepCheckpoint` and `outcomeCheckpoint` against every constructor, and check that `fmap` changes only the answer. Existing run, compaction, and legacy ReAct regressions remain green with their expectations unedited. This milestone is independently accepted by focused AgentHistory tests and the package suite.


### M3: Add program constructors and a combined consumer example


Add `reactSession` and `reactSessionWithModel` in `shikumi-tools/src/Shikumi/Agent/ReAct.hs`, with the signatures below. Each embeds session start followed by `runSessionOutcome`; the explicit-model variant uses the corrected explicit-model start. Its output is a `SessionOutcome o`: `SessionAnswered answer checkpoint`, or `SessionExhausted checkpoint` when the iteration limit is spent. An exhausted outcome is a normal return of the embedded program, so `FMap` or composition can decide what follows. `FMap (fmap f)` transforms only the answer, and `outcomeCheckpoint` yields the value to persist in either case. Existing `react` and `reactWithTrajectory` retain extraction, output types, and trajectory semantics.

Extend `shikumi-tools/test/ReActSessionExample.hs` with a second exported example using `reactSessionWithModel` and `runProgram`, keeping the original continuation example callable. Use a credential-free first-party identity and `ProtocolAuto` so it exercises M1. A strict scripted interpreter returns one two-tool proposal and one final submission, failing on unexpected extra calls. Tool bodies stay within the rank-polymorphic LLM/error boundary; reuse the nested-call recording technique if observing dispatch. Compare the constructor run with direct start plus `runSessionOutcome` under equivalent scripts.

Run the same program with `maxIters = 1`. It must return `SessionExhausted checkpoint` after both tools have resolved. Encode/decode it, increase `maxIters`, and call `runSessionOutcome` to finish without redispatching either tool. This demonstrates budget extension without inserting a user turn. Separately prove that `continueSession` accepts new input and resets the per-user limit. Test the model-free constructor with a prompt script. Register example checks in `AgentHistorySpec.hs`; update Cabal and `Main.hs` only if a new test module is introduced.

Run the package suite and workspace build. Acceptance requires the public `runProgram` path, composition with a following `FMap (fmap f)` transformation, existing `ShapeEmbed` behavior, zero extraction calls, and equal direct-versus-program outcomes. The two-tool program is the early combined consumer proof before expanding documentation variants.


### M4: Document and validate the public contract


Update `docs/user/resumable-react-sessions.md` with the compiled program example, explicit-model automatic selection, pinned protocol on restoration, single-step results, run outcomes, and budget extension. Replace the blanket statement that session auto always selects prompt with the explicit-model versus model-free rule. Link the entry points from `docs/user/tools-and-agents.md` and the agent overview in `README.md`. Keep legacy extraction and session final submission accurately described.

Update `docs/capabilities/resumable-react-sessions.md` and `docs/capabilities/react-agents.md` where behavior changes, retaining stable capability IDs and following existing bundle index/log conventions. Add an unreleased entry to `shikumi-tools/CHANGELOG.md`. Update the module-level Haddock in `Shikumi.Agent.ReAct`, whose opening currently implies every agent extracts an answer. Give every new export and each constructor of `SessionStep` and `SessionOutcome` its own Haddock comment. Distill durable rules into ADR-6 and ADR-14, preserving stable IDs and recording meaningful timestamp changes with the local OKF log tooling. These documentation edits are implementation work; plan creation does not preemptively change accepted ADRs.

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

The combined example asserts its full typed fixture answer and two cumulative assistant exchanges. Its one-iteration variant returns `SessionExhausted` with a checkpoint whose audit holds both tool results. Restoration and budget extension finish with both original dispatch counts still equal to one. Use either existing weather or city fixtures, asserting complete typed values.


## Validation and Acceptance


The primary consumer proof runs `runProgram (reactSessionWithModel model signature registry defaultReActConfig) input` under a strict script. For a supported first-party HTTP identity, requests advertise native tools and retain original assistant/tool messages. The final value passes `Validatable`, and exactly two proposal responses are consumed. No extraction or protocol-discovery request is allowed. Nested tool-owned LLM calls used to record dispatch count separately from proposals.

The step proof feeds one valid ordinary exchange, one malformed proposal, one valid final, and one zero-budget session separately into `advanceSessionStep`. They return `ExchangeCompleted`, `ProposalRejected reason`, `FinalAccepted answer`, and `IterationLimitReached`, each with its checkpoint. The rejection reason agrees with the audit correction; zero budget produces zero model and tool calls and returns the checkpoint unchanged. `runSessionOutcome` continues through rejection if budget permits and returns `SessionExhausted` otherwise. A valid final on the last allowed iteration succeeds.

The persistence proof starts a native automatic session, records `call-A` and `call-B`, serializes/restores it, and continues under automatic configuration. Results remain paired with original IDs and neither tool repeats. An older prompt checkpoint stays prompt even when its origin is first-party HTTP. An explicitly conflicting protocol or incompatible routed model fails before dispatch. Immutable version-1 and version-2 round-trip regressions stay valid; step results and run outcomes never appear in checkpoint bytes.

The compatibility proof retains compilation of existing `SessionPaused checkpoint` and `SessionFinished answer checkpoint` matches. `SessionResult` gains no constructors or instances, and no existing test expectation changes. Legacy `react` retains extraction, while new constructors use final submission. Ordinary tool errors stay model-visible. Infrastructure failures and provider refusals remain failures rather than pauses. Existing compaction, reasoning guards, context-window retry limits, and request-default behavior remain intact.

These checks establish local protocol selection, request construction, and session semantics. They do not establish new provider capabilities or exactly-once external effects. No new live provider test or performance benchmark is required for these API changes.


## Idempotence and Recovery


Required checks are repeatable and offline. Entry points are additive, allowing incremental adoption. No storage migration, checkpoint rewrite, or automatic promotion of existing prompt history is needed. Preserve original checkpoint bytes when diagnosing restore failures.

A returned checkpoint still contains a whole completed exchange. An infrastructure failure or crash during dispatch may leave external effects without a returned checkpoint. This plan adds no execution journal and must not retry uncertain side effects automatically. Increasing the iteration limit continues from the last returned checkpoint; appending a user turn is an explicit alternative with its documented budget reset. Error and cancellation paths retain current behavior.

Keep dependency bounds and current branch unchanged. Publication and changes to other repositories are separate tasks. Implementation commits follow Conventional Commits and include an `ExecPlan:` trailer naming this file. Record provenance and friction according to the exec-plan skill and triage implementation friction before completion.


## Interfaces and Dependencies


All new API belongs in `Shikumi.Agent.ReAct`, package `shikumi-tools`. The new exports are `SessionStep (..)`, `SessionOutcome (..)`, `stepCheckpoint`, `outcomeCheckpoint`, `advanceSessionStep`, `runSessionOutcome`, `reactSession`, and `reactSessionWithModel`. `Text` is `Data.Text.Text`; `ReActSession` is the existing opaque history type.

`SessionStep` is the result of one step and `SessionOutcome` is the result of a run. Their fields are strict and positional, and every constructor carries the resulting checkpoint. `SessionResult` is not changed.

```haskell
-- | What one 'advanceSessionStep' did. 'stepCheckpoint' projects the
-- checkpoint that every constructor carries.
data SessionStep o
  = -- | An ordinary proposal was accepted and all of its tool results are
    -- recorded, including recoverable tool errors. The task is not finished.
    ExchangeCompleted !ReActSession
  | -- | The response was rejected before any tool ran. The text is the
    -- correction stored in audit history and sent with the next request.
    ProposalRejected !Text !ReActSession
  | -- | The per-user-turn budget was already spent. Nothing was called and
    -- the checkpoint is returned unchanged.
    IterationLimitReached !ReActSession
  | -- | A final submission decoded and passed validation.
    FinalAccepted !o !ReActSession
  deriving stock (Eq, Show, Functor, Foldable, Traversable)

-- | Where one 'runSessionOutcome' stopped. 'outcomeCheckpoint' projects the
-- checkpoint that every constructor carries.
data SessionOutcome o
  = -- | A final submission was accepted.
    SessionAnswered !o !ReActSession
  | -- | The per-user-turn iteration limit was spent before a final
    -- submission. The checkpoint is complete and resumable.
    SessionExhausted !ReActSession
  deriving stock (Eq, Show, Functor, Foldable, Traversable)

-- | The checkpoint to persist, whatever the step did.
stepCheckpoint :: SessionStep o -> ReActSession

-- | The checkpoint to persist, wherever the run stopped.
outcomeCheckpoint :: SessionOutcome o -> ReActSession
```

Expose the step and run operations and the two program constructors. `i` is fixed by the signature even though advancement receives no new input. The explicit `forall` on the step is needed because its body uses `Proxy @o`.

```haskell
advanceSessionStep ::
  forall i o es.
  (ToSchema o, FromModel o, Validatable o, LLM :> es, Error ShikumiError :> es) =>
  Signature i o ->
  ToolRegistry ->
  ReActConfig ->
  ReActSession ->
  Eff es (SessionStep o)

runSessionOutcome ::
  (ToSchema o, FromModel o, Validatable o, LLM :> es, Error ShikumiError :> es) =>
  Signature i o ->
  ToolRegistry ->
  ReActConfig ->
  ReActSession ->
  Eff es (SessionOutcome o)

reactSession ::
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  Signature i o ->
  ToolRegistry ->
  ReActConfig ->
  Program i (SessionOutcome o)

reactSessionWithModel ::
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  Model ->
  Signature i o ->
  ToolRegistry ->
  ReActConfig ->
  Program i (SessionOutcome o)
```

`runSessionOutcome` is the driver below. Its match is exhaustive, so adding a constructor to `SessionStep` later is a compile error here instead of a silent fall-through.

```haskell
runSessionOutcome sig reg cfg s =
  advanceSessionStep sig reg cfg s >>= \case
    ExchangeCompleted next -> runSessionOutcome sig reg cfg next
    ProposalRejected _ next -> runSessionOutcome sig reg cfg next
    IterationLimitReached next -> pure (SessionExhausted next)
    FinalAccepted answer next -> pure (SessionAnswered answer next)
```

`advanceSession` and `runSession` keep their signatures and results. Each is the new operation followed by one of these private total projections to `SessionResult`:

```haskell
stepResult :: SessionStep o -> SessionResult o
stepResult = \case
  ExchangeCompleted s -> SessionPaused s
  ProposalRejected _ s -> SessionPaused s
  IterationLimitReached s -> SessionPaused s
  FinalAccepted answer s -> SessionFinished answer s

outcomeResult :: SessionOutcome o -> SessionResult o
outcomeResult = \case
  SessionAnswered answer s -> SessionFinished answer s
  SessionExhausted s -> SessionPaused s
```

The program constructors use the existing start operations followed by `runSessionOutcome` inside `embed`. A consumer handles two cases and persists the checkpoint without matching:

```haskell
outcome <- runProgram (reactSessionWithModel model signature registry config) input
let bytes = encode (encodeSession (outcomeCheckpoint outcome))
case outcome of
  SessionAnswered answer _ -> useAnswer answer
  SessionExhausted checkpoint -> extendLimitOrContinue checkpoint
```

`useAnswer` and `extendLimitOrContinue` stand for application code. After exhaustion the application either raises `maxIters` and calls `runSessionOutcome` again, or appends a user turn with `continueSession`.

`ExchangeCompleted` means every ordinary tool result is recorded, not that the task is finished. `ProposalRejected` means the response is audit-only and its correction enters the request view. `IterationLimitReached` means the budget was already spent when the step was requested, so the step called nothing. `FinalAccepted` is the only step that yields an answer. `SessionExhausted` is not a failure: it holds a complete checkpoint that can be resumed. A future stop reason for a run is added as a new `SessionOutcome` constructor, not as a field on an existing one. Finished state and cumulative/per-user counters remain session properties. No new `ReActConfig` field, `Program` node, effect, provider policy, or checkpoint version is needed.

The pinned protocol used by M1 is private to `Shikumi.Agent.ReAct` and is not exported:

```haskell
data PinnedProtocol = PinnedNative | PinnedPrompt
  deriving stock (Eq, Show)

-- | Resolve a configured selection against a model. Reads the provider table.
pinProtocol :: ToolProtocol -> Model -> PinnedProtocol

-- | The persisted form, "native" or "prompt", and its inverse.
pinnedProtocolText :: PinnedProtocol -> Text
parsePinnedProtocol :: Text -> Maybe PinnedProtocol

-- | 'ProtocolAuto' admits either pinned protocol; an explicit selection
-- admits only its own.
protocolAdmits :: ToolProtocol -> PinnedProtocol -> Bool
```

The prerequisites are the completed [plan 54](54-add-structured-resumable-react-history.md), [plan 59](59-guard-reasoning-state-across-session-compaction-and-model-changes.md), and [plan 67](67-enforce-typed-output-schemas-on-cli-providers.md). There is no pending cross-plan prerequisite or external API work. Use already-declared dependency versions and canonical Mori URIs for durable cross-repository references.

Revision note, 2026-11-04: An API review for idiomatic Haskell replaced the shared `SessionOutcome` and `SessionPauseReason` types and the two `Detailed` operations. A run can pause only on budget exhaustion, so a single step now returns a flat four-constructor `SessionStep` from `advanceSessionStep`, while `runSession` and the program constructors return the existing `SessionResult`. The revision also added `Functor`, `Foldable`, and `Traversable` to both result types, total checkpoint projections, strict fields, and a private closed type for the pinned protocol. M1, M2, M3, acceptance, and Interfaces were updated to match.

Revision note, 2026-11-04: At the user's direction, a dedicated run-level type replaced the reuse of `SessionResult` described in the previous note. `runSessionOutcome` and both program constructors return a flat `SessionOutcome` with `SessionAnswered` and `SessionExhausted`, so a later stop reason can be added as a constructor. `SessionResult`, `advanceSession`, and `runSession` are untouched and become projections. The instances and `resultCheckpoint` that the previous note added to `SessionResult` were withdrawn in favor of `outcomeCheckpoint`.
