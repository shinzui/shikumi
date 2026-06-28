---
id: 29
slug: in-run-working-context-overflow-compaction
title: "In-run working-context overflow compaction"
kind: exec-plan
created_at: 2026-06-27T16:24:02Z
intention: "intention_01kw4y7rzmev8t61r5jaw2zgf1"
---

# In-run working-context overflow compaction

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today a long-running agent in shikumi can crash mid-task. The ReAct agent loop
(`Shikumi.Agent.ReAct.reactLoop`) appends one `Step` per turn to a growing list and
re-renders the entire history into the prompt on every turn. A run with many tool
calls — exactly the kind of open-ended work the agent stack is meant to do — keeps
growing that prompt until it exceeds the model's context window. When that happens the
provider rejects the request and the whole run dies with a `ProviderFailure`. The agent
loses all its progress at the worst possible moment: deep into a task.

After this change, a long agent run no longer dies when it approaches the window. Two
things become true that were not true before:

1. **Proactive compaction.** While the run is still healthy, the loop watches the actual
   token count reported by the provider after each turn. When the working context grows
   past a safety threshold (the model's context window minus a reserve), the loop folds
   the *older* steps into a short summary and keeps the *most recent* steps verbatim,
   then continues. The agent keeps going instead of marching off the cliff.

2. **Reactive recovery.** If the window is blown anyway — for example the very first turn
   is already too large, or the provider's accounting differs from ours — a context-overflow
   error from the provider is caught, the history is compacted, and the turn is retried
   once instead of aborting the run.

You can see it working by running an agent against a deliberately tiny context window with
a scripted model (no network needed): a run that previously errored now completes, its
recorded trajectory shows a synthetic "summary" step standing in for the folded-away
history, and the last few real steps are still present verbatim.

This is the one agent-infrastructure gap that the durable-workflow runtime does not help
with, because it happens *inside a single turn*, not across steps. The fix needs no new
durable infrastructure: it reuses token/model metadata that `baikai` already computes and
a summarize-then-replace pattern that `kioku` already uses for cross-session memory.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add `ContextWindowExceeded` to `Shikumi.Error.ShikumiError`; map baikai's
      `ContextOverflow` category to it in `fromBaikaiError`; keep `isTransient` returning
      `False` for it. Unit test the mapping.
- [ ] M1: Create `Shikumi.Compaction` with `CompactionConfig`,
      `defaultCompactionConfig`, and `usageExceedsWindow`. Unit-test the threshold around
      the boundary.
- [ ] M2: Implement `compactTail` (generic summarize-tail) in `Shikumi.Compaction`.
      Unit-test that older items fold into one summary item and the recent tail is preserved
      verbatim.
- [ ] M3: Thread `CompactionConfig` into `ReActConfig`; wire the proactive trigger into
      `reactLoop`. Acceptance test: agent on a tiny-window mock compacts and completes.
- [ ] M4: Add the reactive overflow-recovery path (catch `ContextWindowExceeded`, compact,
      retry once). Acceptance test: mock that throws once then succeeds.
- [ ] M4: Extend the reactive recovery to the final `extract` completion (also an unguarded
      `complete _Model` site), with its own one-shot compact-then-retry.
- [ ] M5: Export the compaction surface for `shikigami` reuse; extend `MockLLM` with a
      usage/window-carrying response builder; document the feature.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Plan validated against the source tree (2026-06-28).** Every concrete claim was
  checked and holds: the `reactLoop`/`loop` quote is verbatim
  (`shikumi-tools/src/Shikumi/Agent/ReAct.hs:195-209`); `acc :: [Step]` is newest-first
  and reversed at the end; the loop dispatches `complete _Model ctx opts` and `_Model`'s
  `contextWindow` is `0` (`baikai/baikai/src/Baikai/Model.hs:145`), so reading the window
  off the response rather than `_Model` is necessary, not merely tidy. `Response` carries
  both `model :: Model` and `message :: AssistantPayload` with `usage`
  (`baikai/baikai/src/Baikai/Response.hs:33-48`), and `Shikumi.LLM` already uses the
  exact lens path the plan relies on (`resp ^. #message . #usage . #cost . #usd`,
  `Shikumi/LLM.hs:270`), so `resp ^. #message . #usage . #inputTokens` and
  `resp ^. #model . #contextWindow` are valid. `Usage.inputTokens :: Natural`
  (`Baikai/Usage.hs:24`). baikai's `ErrorCategory` has `ContextOverflow` and exports
  `bodyIndicatesOverflow` (`Baikai/Error.hs:51,196`); shikumi's `fromBaikaiError`
  catch-all currently maps it to `ProviderFailure` and `isTransient`'s catch-all returns
  `False` (`Shikumi/Error.hs:53,62`), so the planned constructor is non-transient by
  default with no extra wiring. `correctiveStep` already uses the `CallTool "" Null`
  sentinel (`ReAct.hs:227-234`). `Baikai` re-exports `Model` and `Usage` from the
  umbrella module. The `shikumi-tools` cabal stanzas (`exposed-modules`,
  `shikumi-tools-test` `other-modules`) are exactly as described, and the kioku
  reference symbols (`distillSessionL1`, `buildExtractInput`, `renderTurns`,
  `runExtraction`, `runConsolidation`, `applyCharacterBudgets`) all exist.

- **The reactive path depends on baikai actually *classifying* an overflow as
  `ContextOverflow`.** baikai only produces that category through
  `classifyHttpStatusWithBody`, which requires a 400/422 *and* a body containing one of
  the markers in `bodyIndicatesOverflow` (`Baikai/Error.hs:187-210`). A provider package
  that classifies a 400 by status alone (`classifyHttpStatus`) yields `InvalidRequest`,
  which `fromBaikaiError` maps to `SchemaMismatch` — *not* `ContextWindowExceeded` — so
  the M4 `catchError` would not fire. The proactive M3 trigger is therefore the primary
  defense; reactive recovery is a best-effort backstop that only engages when the
  provider surfaces the overflow precisely. This is recorded so the implementer does not
  assume reactive recovery is universal. See the Decision Log.

- **The final `extract` call is outside both the proactive and reactive guards.**
  `reactLoop`'s `extract` (`ReAct.hs:213-217`) issues its own `complete _Model ctx opts`
  over `renderExtract impl i traj` — the whole trajectory — and M3/M4 as originally
  written only touch the propose `complete` inside `loop`. Because `extract` renders the
  (already-compacted) returned trajectory, it is small in the common case, but a single
  oversized trajectory could still overflow at extract time. M4's scope is widened to
  cover it. See the Decision Log.

- **Under the default `maxIters = 6`, compaction never engages in practice.** This is the
  intended no-regression property, but it also means the default `ReActConfig` gains
  nothing from this feature: the per-turn threshold is only reached on long runs, which
  require raising `maxIters`. The M5 documentation must say so explicitly, otherwise the
  feature reads as dead-on-arrival under defaults.

- **Architectural-fit pass (2026-06-28): `complete _Model` is idiomatic, and routing is
  why the response is the right source of truth.** `runProgram` is deliberately
  model-agnostic — every node calls `complete placeholderModel ...` where
  `placeholderModel = _Model` (`shikumi/src/Shikumi/Program.hs:241-249`, used by
  `runPredict` at line 320), and `Shikumi.Routing`'s `routeLLM` overwrites that placeholder
  with the real ambient model below the stack on every outgoing call. So the ReAct loop
  calling `complete _Model` is not a defect; it is the convention. This *confirms* the
  plan's central decision: the loop cannot know its model up front, so the resolved model
  and usage must be read from the `Response` the router produced. One consequence to keep in
  mind: the threshold reads `contextWindow` from the *previous* turn's response, so a router
  that routes successive turns to models with different windows would lag by one turn —
  acceptable, since routing is normally stable within a run.

- **Architectural-fit pass (2026-06-28): the original `shikumi-tools` placement broke the
  shikigami reuse goal.** `shikigami-core`'s cabal depends on `shikumi`, `kioku`, and
  `baikai` but **not** `shikumi-tools` (verified: a repo-wide grep for `shikumi-tools` in
  shikigami is empty), and it currently imports only
  `Shikumi.Program (Program, embed)` — there is no message/skill loop to reuse `compactTail`
  yet. The generic primitive was therefore moved to core `shikumi` (`Shikumi.Compaction`)
  and the reuse goal reframed as readiness. See the Decision Log.


## Decision Log

Record every decision made while working on the plan.

- Decision: Read the context-window size and the running token count from the provider's
  `Response`, not from the loop's `_Model` constant.
  Rationale: `Shikumi.Agent.ReAct.reactLoop` calls `complete _Model ctx opts`, where
  `_Model` is baikai's blank default `Model` whose `contextWindow` is `0`. Triggering off
  `0` would fire compaction on every turn. The `Response` carries the *resolved* provider
  model (`resp ^. #model . #contextWindow`) and the real token usage
  (`resp ^. #message . #usage . #inputTokens`), so the trigger uses those.
  Date: 2026-06-27

- Decision: Reuse `kioku`'s L1 extract/summarize *approach* but do not depend on
  `kioku-core`.
  Rationale: `Kioku.Distill.L1.distillSessionL1` renders turns to text and issues an LLM
  summarize/consolidate call — exactly the pattern we want — but it is bound to Postgres,
  `keiro`, `kiroku`, pgvector and the `Memory`/`Store` effects, none of which an in-run
  agent loop should pull in. We replicate only the render-then-summarize call using
  shikumi's own `LLM` effect, mirroring L1's shape. See the Interfaces section.
  Date: 2026-06-27

- Decision: `keepRecent` is a *step count*, not a token budget, in the first version.
  Rationale: flue/eve preserve a `keepRecentTokens` window; doing the same precisely
  requires per-step tokenization we do not have cheaply in-loop. A step count is simple,
  deterministic, and adequate, since the proactive trigger already uses real token totals.
  A token-budgeted variant is noted as a future refinement.
  Date: 2026-06-27

- Decision: Defaults are `reserveTokens = 16384`, `keepRecent = 4`, `enabled = True`.
  Rationale: 16k of headroom comfortably covers one more rendered turn plus the model's
  output allowance on the small-context models in baikai's catalog (down to 64k). Keeping
  4 recent steps preserves enough immediate context to continue coherently while still
  shrinking long runs. With the default `maxIters = 6`, short runs never trigger
  compaction, so existing behavior is unchanged.
  Date: 2026-06-27

- Decision: The trigger lives inside `reactLoop`'s recursion, evaluated after each
  successful `complete` (proactive) and inside a `catchError` wrapper around `complete`
  (reactive).
  Rationale: that is the single point where both the freshly-grown step list and the
  provider's usage report are in scope.
  Date: 2026-06-27

- Decision: M4's reactive recovery also wraps the final `extract` completion, not only
  the propose completion inside `loop`.
  Rationale: validation found that `reactLoop`'s `extract`
  (`shikumi-tools/src/Shikumi/Agent/ReAct.hs:213-217`) issues its own
  `complete _Model ctx opts` over the entire trajectory, outside both guards. Leaving it
  unprotected means a long run could survive the loop and then die on the final answer —
  the exact failure this plan exists to prevent. The fix is cheap: reuse the same
  one-shot compact-then-retry combinator (forced compaction, since an overflow is known)
  for the `extract` call. The summary step it injects is still visible in the returned
  trajectory, keeping the behavior auditable.
  Date: 2026-06-28

- Decision: Accept that reactive recovery is a best-effort backstop and document its
  limit rather than trying to widen baikai's overflow classification.
  Rationale: `ContextWindowExceeded` is only produced when baikai categorizes the failure
  as `ContextOverflow`, which depends on a provider package calling
  `classifyHttpStatusWithBody` with a body that matches `bodyIndicatesOverflow`
  (`baikai/baikai/src/Baikai/Error.hs:187-210`). A provider that classifies by status
  alone surfaces `InvalidRequest`/`SchemaMismatch`, which the loop does not catch.
  Broadening this belongs in baikai, not in this plan; the proactive token-threshold
  trigger is the primary defense and does not depend on provider classification. The
  Validation section's negative control is kept honest about this boundary.
  Date: 2026-06-28

- Decision: Keep `defaultReActConfig`'s `maxIters = 6` unchanged, but call out in the M5
  docs that compaction only engages on longer runs (raise `maxIters`).
  Rationale: changing the default iteration cap is out of scope and would alter existing
  behavior. The honest framing is that the feature is opt-in via run length: short runs
  never cross the threshold (the no-regression guarantee), and operators who want
  compaction must run longer agents. Documenting this prevents the feature from looking
  inert under defaults.
  Date: 2026-06-28

- Decision: Place the generic compaction primitive (`CompactionConfig`, `compactTail`,
  `usageExceedsWindow`, `overflowThreshold`) in the **core `shikumi` library** as a new
  module `Shikumi.Compaction`, not in `shikumi-tools` as originally drafted. Only the
  ReAct-specific wiring (the `Step` renderer/injector and the `ReActConfig.compaction`
  field) stays in `shikumi-tools/Shikumi/Agent/ReAct.hs`.
  Rationale: the fit investigation found that `shikigami-core` — the intended second
  consumer — depends on the core `shikumi` library but **not** on `shikumi-tools`, so a
  primitive placed in `shikumi-tools` could never be imported by shikigami, defeating the
  stated reuse goal. The primitive's only dependencies (`LLM`, `ShikumiError`, baikai
  `Model`/`Usage`/`Context`) are all in core `shikumi`, so the move is clean and adds no new
  dependency. Chosen over (a) adding a `shikumi-tools` dependency to shikigami-core, which
  would drag the entire ReAct/tool catalog into the runtime for one function, and (b)
  dropping the reuse goal, which would forgo a genuine future benefit at no saving.
  User selected this option on 2026-06-28.
  Date: 2026-06-28

- Decision: Treat shikigami reuse as a *readiness* goal, not an integration delivered by
  this plan.
  Rationale: shikigami has no message/skill loop today (it uses only
  `Shikumi.Program (Program, embed)`), so there is no existing call site to wire. Keeping
  `compactTail` generic over the element type makes it ready for `a = Baikai.Message` when
  such a loop is built, without this plan touching shikigami. The M5 wording was corrected
  to claim readiness rather than an existing integration.
  Date: 2026-06-28


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of the repository. Read it before editing anything.

### What "in-run compaction" means, precisely

There are two completely different kinds of context compaction in this stack, and only one
of them is the subject of this plan. Confusing them is the main hazard here.

- **Cross-session compaction (already solved — out of scope).** `shinzui/kioku` is the
  agent-memory library. When an agent finishes a session, kioku distills the whole session
  into durable, reusable memories: raw turns (L0) are extracted and consolidated into atoms
  (L1, in `Kioku.Distill.L1.distillSessionL1`), then scenes (L2) and a persona (L3). It
  also budgets what it loads back with `Kioku.Recall.applyCharacterBudgets`. This compacts
  *across* sessions and writes to a database. It is a strength of the stack and **this plan
  does not touch it.**

- **In-run working-context compaction (missing — this plan).** A *single* agent run is an
  agentic loop that holds a live, in-memory list of messages/steps and feeds the whole list
  back to the model every turn. That live list is the "working context." On a long run it
  grows until it overflows the model's context window mid-loop, and the run crashes. Nothing
  in the stack compacts this live list *within* one run. That is the gap. The "context
  window" is the maximum number of tokens a model accepts in one request; baikai records it
  per model as `contextWindow`.

This distinction is recorded in the gap analysis at
`/Users/shinzui/Keikaku/bokuno/kikan/docs/architecture/evolution/agent-infrastructure-gaps.md`
(gap #5). That document explicitly notes: kioku already does cross-session compaction via
distillation; what is missing is in-run overflow compaction of one agentic loop's live
message list.

### The loop that overflows

The ReAct agent loop lives at
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-tools/src/Shikumi/Agent/ReAct.hs`.
"ReAct" means "Reason + Act": each turn the model emits a thought and either calls a tool
or declares it is finished; the runtime runs the tool and records the result as an
observation. The relevant data types are in that file:

- `Action = CallTool Text Value | Finish` — what the model decided.
- `Step { thought, action, observation }` — one recorded turn.
- `Trajectory { steps :: Vector Step, termination :: Termination }` — the whole run.

The loop itself is `reactLoop`, whose inner worker is:

```haskell
loop :: Int -> [Step] -> Eff es Trajectory
loop iter acc
  | iter >= maxIters cfg = pure (Trajectory (V.fromList (reverse acc)) (TerminatedMaxIters iter))
  | otherwise = do
      let (ctx, opts) = renderPropose impl i (soFar acc)
      resp <- complete _Model ctx opts
      case parsePropose impl resp of
        Left perr            -> loop (iter + 1) (correctiveStep perr : acc)
        Right (th, Finish)   -> pure (Trajectory (V.fromList (reverse (Step th Finish Nothing : acc))) TerminatedFinish)
        Right (th, CallTool nm args) -> do
          res <- runToolCall reg (mkToolCall nm args)
          let obs = either renderToolError id res
          loop (iter + 1) (Step th (CallTool nm args) (Just obs) : acc)
```

Two facts matter for this plan. First, `acc :: [Step]` is held **newest-first** (the loop
conses the new step onto the front and reverses at the end). Second, the entire history is
re-rendered into the prompt every turn: `renderPropose impl i (soFar acc)` builds a fresh
`Context` whose single user message contains `historyBlock`/`renderTrajectory acc`. So the
prompt grows monotonically with the number of steps — that is the overflow source.
`renderTrajectory :: Trajectory -> Text` is already exported from this module.

The loop calls `complete _Model ctx opts`, where `complete` is the `LLM` effect operation
from `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/LLM.hs`:

```haskell
complete :: (LLM :> es) => Model -> Context -> Options -> Eff es Response
```

The loop runs in the effect row `(LLM :> es, Error ShikumiError :> es, ...)`, so any new
code the loop calls may use exactly those two effects and nothing more.

### Where token counts and the window come from (baikai)

`baikai` is the provider/transport layer (source at `/Users/shinzui/Keikaku/bokuno/baikai`).
The pieces this plan reads:

- The per-model context window. `Baikai.Model.Model` has fields
  `contextWindow :: Natural` and `maxOutputTokens :: Natural`
  (`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Model.hs`). The generated catalog
  `Baikai.Models.Generated` shows real values, e.g. Claude Haiku 4.5 has
  `contextWindow = 200000`, and several smaller models go down to `64000`.
- The per-call token usage. `Baikai.Usage.Usage`
  (`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Usage.hs`) has
  `inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens :: Natural`.
- Both are reachable from a `Response`: `Baikai.Response.Response` carries
  `model :: Model` and `message :: AssistantPayload`, and `AssistantPayload` carries
  `usage :: Usage`. So after a completion, `resp ^. #model . #contextWindow` is the window
  and `resp ^. #message . #usage . #inputTokens` is how many prompt tokens that turn
  actually consumed — i.e. the true size of the working context as the provider measured it.

- The overflow error category. `Baikai.Error.ErrorCategory` includes a dedicated
  `ContextOverflow` constructor ("The request exceeded the model's context window or a
  related limit"), and baikai exposes `bodyIndicatesOverflow` to detect it in 400 bodies
  (`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Error.hs`). Today shikumi's
  `fromBaikaiError` does **not** have a dedicated case for it, so it falls through to
  `ProviderFailure`. We will give it its own shikumi error so the loop can recognize it.

### How errors flow in shikumi

`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Error.hs` defines the single
error vocabulary `ShikumiError` and `fromBaikaiError :: BaikaiError -> ShikumiError`. The
`LLM` effect's interpreters (`runLLM`, `runLLMResilient`) call `fromBaikaiError` to translate
provider failures, and consult `isTransient :: ShikumiError -> Bool` to decide what to
retry. A context overflow is *not* transient in the retry sense — retrying the identical
oversized request cannot help — so we keep `isTransient` returning `False` for it and handle
it explicitly in the loop by compacting first.

### The summarizer pattern we reuse (kioku L1)

`/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/Distill/L1.hs` shows the pattern
we copy in spirit: `buildExtractInput` renders turns to a single text blob
(`renderTurns`), then `runExtraction`/`runConsolidation` issue an LLM call that produces a
condensed result. We do the same minimal thing — render the older steps to text and ask the
model for a compact summary — but using shikumi's own `LLM` effect, without kioku's
persistence machinery. The budgeting idea (greedy accumulate, cap, truncate) mirrors
`Kioku.Recall.applyCharacterBudgets`
(`/Users/shinzui/Keikaku/bokuno/kioku/kioku-core/src/Kioku/Recall.hs`).

### Prior art (flue / eve)

The TypeScript reference frameworks at `/Users/shinzui/Keikaku/hub/agents/flue` and
`/Users/shinzui/Keikaku/hub/agents/eve` use the same shape we adopt: a threshold of
`contextWindow - reserveTokens`, summarize the older turns, and preserve a recent window.
We deliberately keep the same vocabulary (`reserveTokens`, a "keep recent" window) so the
behavior is familiar.

### Cross-plan dependencies

- **Reuses `shinzui/kioku` L1** (`Kioku.Distill.L1`) only as a *reference pattern* for the
  tail summarizer (render-then-summarize). Already exists; no code dependency is added.
- **Reuses `shinzui/baikai`** usage/model metadata (`Baikai.Usage`, `Baikai.Model`,
  `Baikai.Error.ContextOverflow`). Already exists and already a dependency of shikumi.
- **Adjacent shikumi plans, separate from this one:** plan 28,
  `docs/plans/28-built-in-agent-work-tools-and-toolenv-execution-seam.md` (the work-tool
  catalog and `ToolEnv` seam), and the future "MCP client adapter" plan (gap #6). Those add
  *tools*; this plan adds *compaction*. They share the same loop but do not depend on each
  other.
- **`shinzui/shikigami` (the declared-agent runtime) is a downstream *consumer*, not a
  dependency.** `shikigami-core` depends on the core `shikumi` library (and `kioku`,
  `baikai`) but **not** on `shikumi-tools`, and today it imports only
  `Shikumi.Program (Program, embed)` — it has no ReAct/message loop yet. This is the reason
  `Shikumi.Compaction` is placed in core `shikumi` rather than in `shikumi-tools`: putting
  the generic primitive in core is the only placement from which a future shikigami loop
  could import it. This plan does not modify shikigami.
- **Owns an extension of MasterPlan integration point #1** (the single `ShikumiError`
  vocabulary), which plan 1
  (`docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`) introduced and
  owns. Adding the `ContextWindowExceeded` constructor is the sanctioned way that vocabulary
  grows; this plan stays consistent with plan 1's `fromBaikaiError`/`isTransient` policy
  rather than inventing a parallel error path.


## Plan of Work

The work is five small, independently verifiable milestones. Milestones M1–M2 build and
test the compaction primitives in isolation (no loop changes), M3–M4 wire them into the
ReAct loop (proactive then reactive), and M5 exposes the surface for `shikigami` and
documents it. All edits are additive; the default configuration leaves short runs behaving
exactly as before.

### M1 — Token accounting, the overflow error, and the threshold

Scope: introduce the error vocabulary and the trigger predicate, with no behavior change to
the loop yet.

First, edit `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Error.hs`:

- Add a constructor `ContextWindowExceeded !Text` to `ShikumiError` (export list updates
  automatically since the type is exported with `(..)`).
- In `fromBaikaiError`, add a case mapping baikai's `ContextOverflow` category to
  `ContextWindowExceeded (message e)`. No import change is needed: `Shikumi.Error`
  already imports `Baikai.Error (BaikaiError (..), ErrorCategory (..))`
  (`shikumi/src/Shikumi/Error.hs:14`), so the `ContextOverflow` constructor is already in
  scope. Place the new case before the catch-all `_ -> ProviderFailure (message e)`,
  which currently swallows it.
- Leave `isTransient` returning `False` for `ContextWindowExceeded` (the catch-all `_`
  already does this; do not add it to the transient set).

Second, create a new module
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Compaction.hs` and
add it to `exposed-modules` in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/shikumi.cabal` (the *core* `shikumi`
library — alongside `Shikumi.Error`, `Shikumi.LLM`, etc., at `shikumi.cabal:34-40`).
It lives in core, not `shikumi-tools`, deliberately: the generic primitive depends only on
the `LLM` effect, `ShikumiError`, and baikai's `Model`/`Usage`/`Context`, all of which are
core, and placing it in core is what lets `shikigami` reuse it — `shikigami-core` depends on
`shikumi` but not on `shikumi-tools` (see the Decision Log and Cross-plan dependencies). In
M1 it contains only the configuration and the threshold predicate (the summarizer comes in
M2):

```haskell
module Shikumi.Compaction
  ( CompactionConfig (..),
    defaultCompactionConfig,
    overflowThreshold,
    usageExceedsWindow,
  ) where

import Baikai (Model, Usage)
import Control.Lens ((^.))
import Numeric.Natural (Natural)

data CompactionConfig = CompactionConfig
  { reserveTokens :: !Natural, -- headroom kept free below the window
    keepRecent    :: !Int,     -- number of most-recent steps preserved verbatim
    enabled       :: !Bool
  }
  deriving stock (Eq, Show)

defaultCompactionConfig :: CompactionConfig
defaultCompactionConfig =
  CompactionConfig { reserveTokens = 16384, keepRecent = 4, enabled = True }

-- | The token count at or above which we compact: the model's window minus the
-- reserve. Saturating subtraction (Natural) so a tiny window never underflows.
overflowThreshold :: CompactionConfig -> Model -> Natural
overflowThreshold cfg model =
  let w = model ^. #contextWindow
   in if w <= reserveTokens cfg then 0 else w - reserveTokens cfg

-- | Should we compact, given a turn's reported input-token usage?
usageExceedsWindow :: CompactionConfig -> Model -> Usage -> Bool
usageExceedsWindow cfg model usage =
  enabled cfg && (usage ^. #inputTokens) >= overflowThreshold cfg model
```

Verification: `cabal build shikumi` and `cabal build shikumi-tools` succeed. A unit test
(added in M5's harness work, but a minimal one can be added now) asserts
`usageExceedsWindow` flips at the boundary, e.g. with a model whose `contextWindow = 1000`
and `reserveTokens = 100`, usage `inputTokens = 899` is `False` and `900` is `True`.

### M2 — The tail summarizer

Scope: add the function that folds older items into a summary and keeps the recent tail —
generic over the element type so the ReAct loop can reuse it with `a = Step` and any future
message-list loop (e.g. a `shikigami` skill loop) can reuse it with `a = Baikai.Message`. No
such shikigami loop exists today (shikigami-core currently uses only
`Shikumi.Program (Program, embed)`); genericity is kept so the primitive is *ready* for that
reuse, not because a second caller exists yet. No loop integration yet.

Add to `Shikumi.Compaction`:

```haskell
-- | Fold the older portion of a chronological (oldest-first) list into a single
-- synthesized summary element, preserving the most recent 'keepRecent' elements
-- verbatim. The summary is produced by one LLM call over the rendered older items.
--
--   * @render@   : how to render one element to text for the summary prompt.
--   * @inject@   : how to build a synthetic "summary" element from the summary text
--                  (for Step: a Step whose observation carries the summary; for a
--                  Message: a system/user message carrying the summary).
--
-- Returns the list unchanged when there is nothing old enough to fold
-- (length <= keepRecent).
compactTail ::
  (LLM :> es, Error ShikumiError :> es) =>
  CompactionConfig ->
  Model ->                 -- model used for the summarize call
  (a -> Text) ->           -- render one element chronologically
  (Text -> a) ->           -- build the synthetic summary element
  [a] ->                   -- elements, OLDEST-first
  Eff es [a]               -- compacted elements, OLDEST-first
```

Implementation outline: split `xs` into `older = drop (length xs - keepRecent) ...`
(equivalently `older = take (n - keepRecent) xs`, `recent = drop (n - keepRecent) xs`); if
`older` is empty, return `xs` unchanged. Otherwise render `older` with `render`, build a
`Context` whose system prompt instructs a faithful, compact summary that preserves
decisions, tool results, open questions, and facts, and whose single user message is the
rendered blob, then `complete model ctx opts` and read the assistant text (reuse the same
text-extraction approach `responseText` uses in `ReAct.hs`). Build the synthetic element
with `inject summaryText` and return `inject summaryText : recent`.

Keep the summarize `Options` minimal (no tools, `ToolChoiceNone` is irrelevant since no
tools are attached). Construct the `Context` directly with baikai's `_Context`/`user`
builders so this module has no cyclic dependency on `Shikumi.Agent.ReAct`.

Verification: a unit test feeds, say, six string-like elements with `keepRecent = 2`, scripts
one summary `Response` in the mock, and asserts the result is `[summaryItem, e5, e6]` — i.e.
exactly one folded summary plus the two recent items verbatim, and that the summarize call
consumed one scripted response.

### M3 — Wire the proactive trigger into the ReAct loop

Scope: the loop now compacts itself when usage crosses the threshold, and short runs are
unchanged.

Edit `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-tools/src/Shikumi/Agent/ReAct.hs`:

- Import `Shikumi.Compaction (CompactionConfig, defaultCompactionConfig,
  usageExceedsWindow, compactTail)` and `Baikai (Usage)`.
- Add a field `compaction :: !CompactionConfig` to `ReActConfig`, and set it to
  `defaultCompactionConfig` in `defaultReActConfig`. (Additive record field; update the one
  literal.)
- In `loop`, after a successful `complete` that leads to a `CallTool` continuation, decide
  compaction *before recursing*. Concretely, replace the `CallTool` branch's recursion so
  that the new newest-first accumulator is run through a compaction helper keyed off the
  response's usage and model:

  ```haskell
  Right (th, CallTool nm args) -> do
    res <- runToolCall reg (mkToolCall nm args)
    let obs  = either renderToolError id res
        acc' = Step th (CallTool nm args) (Just obs) : acc
    acc'' <- compactAcc (resp ^. #model) (resp ^. #message . #usage) acc'
    loop (iter + 1) acc''
  ```

  where `compactAcc` is a local helper that, when
  `usageExceedsWindow (compaction cfg) model usage` holds, reverses the newest-first `acc`
  to chronological order, calls `compactTail (compaction cfg) _Model renderStepLine
  summaryStep`, and reverses back; otherwise returns `acc` unchanged. `renderStepLine ::
  Step -> Text` is a one-line renderer (reuse the per-step rendering already inside
  `renderTrajectory`), and `summaryStep :: Text -> Step` builds
  `Step { thought = "(compacted summary of earlier steps)", action = CallTool "" Null,
  observation = Just summaryText }` — the empty tool name is the same inert sentinel
  `correctiveStep` already uses, so it never dispatches and renders cleanly in history.

The summarize call uses `_Model` (the same constant the loop already completes against), so
the working context is summarized by the same model the agent runs on. The *threshold*
still reads the real window from `resp ^. #model`.

Verification (acceptance): an agent driven by a scripted mock whose responses report a
`contextWindow` of, say, `1000` and `inputTokens` climbing past `1000 - reserveTokens`
runs several tool turns, then finishes. Assert the run returns `Right` (it did not error),
the final `Trajectory` contains a step whose thought is the summary sentinel, and the last
`keepRecent` real steps are present verbatim after it.

### M4 — Reactive overflow recovery

Scope: even if the threshold is mis-estimated and the provider rejects a turn for overflow,
the loop recovers instead of dying.

Edit `reactLoop` so the `complete` call in `loop` is wrapped in a recovery combinator:

```haskell
resp <- completeRecover (renderPropose impl i (soFar acc)) acc
```

where `completeRecover :: (Context, Options) -> [Step] -> Eff es Response` runs
`complete _Model ctx opts` inside `catchError`; on `ContextWindowExceeded`, it compacts the
current `acc` (via the same `compactAcc` logic, but forced regardless of the usage estimate
since we *know* it overflowed), re-renders the propose context from the compacted history,
and retries `complete` exactly once. If the retry also throws, rethrow so the failure is
honest rather than looping forever. Use `Effectful.Error.Static.catchError` (already
available in the effect row).

Also wrap the final `extract` completion. `reactLoop`'s `extract`
(`shikumi-tools/src/Shikumi/Agent/ReAct.hs:213-217`) issues its own
`complete _Model ctx opts` over `renderExtract impl i traj` — the whole trajectory —
outside the `loop`, so without this it remains an unguarded overflow site (see Surprises &
Discoveries and the Decision Log). Apply the same one-shot recovery: on
`ContextWindowExceeded`, force-compact the trajectory's steps (reuse `compactTail` over
`steps traj`), rebuild the extract context from the compacted trajectory, and retry once;
rethrow on a second failure. The injected summary step remains visible in the returned
`Trajectory`, so the compaction stays auditable.

Caveat to keep honest: the reactive path only fires when baikai surfaces the overflow as
`ContextWindowExceeded`, which it does only when a provider package classifies the failure
as `ContextOverflow` (a 400/422 whose body matches `bodyIndicatesOverflow`). Providers that
classify by status alone surface `SchemaMismatch`, which is not caught here. The proactive
M3 trigger is the primary defense and does not depend on this classification.

Verification (acceptance): a mock interpreter that throws `ContextWindowExceeded` on its
first `Complete` and then serves a normal scripted response thereafter. The run completes,
and the trajectory shows the summary step (proof that a compaction happened before the
successful retry).

### M5 — Expose for shikigami, test harness, and docs

Scope: make the surface reusable and observable, and document it.

- Confirm `Shikumi.Compaction` is in the core `shikumi` library's `exposed-modules`
  (`shikumi/shikumi.cabal`) and that `CompactionConfig`, `defaultCompactionConfig`,
  `usageExceedsWindow`, `overflowThreshold`, and `compactTail` are all exported. Because the
  module is in core `shikumi`, a future `shikigami` message loop *can* import `compactTail`
  with `a = Baikai.Message` (rendering each message and injecting a summary `Message`) —
  `shikigami-core` already depends on `shikumi`. No such loop exists today, so this milestone
  only guarantees the surface is reachable and generic; it does not wire shikigami.
- Extend the test harness
  `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-tools/test/MockLLM.hs` with a response
  builder that sets `usage.inputTokens` and the response `model` (so tests can script a tiny
  window and rising usage), e.g.
  `mkUsageResponse :: Model -> Natural -> Text -> Response`, plus a throwing interpreter
  variant `runMockLLMThrowingOnce` (throws `ContextWindowExceeded` on the first `Complete`,
  then delegates to the scripted list) for the M4 test.
- Add a new spec module `CompactionSpec` to
  `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-tools/test/` and to `other-modules` in the
  `shikumi-tools-test` stanza of the cabal file, wired into
  `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-tools/test/Main.hs`.
- Document the feature briefly in shikumi's docs (a short subsection under the agents/tools
  documentation) describing the trigger, the defaults, and how to disable compaction
  (`compaction = defaultCompactionConfig { enabled = False }`). The docs must state plainly
  that compaction only engages on long runs: under the default `maxIters = 6` the per-turn
  threshold is never reached, so to benefit an operator must raise `maxIters` on the
  `ReActConfig`. They must also note that reactive overflow recovery is best-effort and
  depends on the provider surfacing a `ContextOverflow` (see M4's caveat); the proactive
  token-threshold trigger is the dependable path.

Verification: `cabal test shikumi-tools` runs `CompactionSpec` green alongside the existing
suites.


## Concrete Steps

All commands run from the shikumi repository root and **inside the dev shell**, because the
system `ghc` is the wrong compiler (the project pins GHC 9.12.4 via `nix develop`; the
system PATH ghc is 9.10.3 and will fail). Either prefix each command with
`nix develop -c` or enter the shell once with `nix develop` and drop the prefix.

Orientation — list the packages and confirm the loop file exists:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
cat cabal.project        # lists shikumi, shikumi-tools, ... and notes the dev shell
ls shikumi-tools/src/Shikumi/Agent/   # ReAct.hs present
```

M1 — after editing `shikumi/src/Shikumi/Error.hs` and creating
`shikumi/src/Shikumi/Compaction.hs` (and adding it to the cabal
`exposed-modules`):

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop -c cabal build shikumi
nix develop -c cabal build shikumi-tools
```

Expected (abbreviated):

```text
[ N of M] Compiling Shikumi.Error          ( ... )
[ N of M] Compiling Shikumi.Compaction ( ... )
Linking ...
```

M2–M5 — build and run the test suite after each milestone's edits:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop -c cabal build shikumi-tools
nix develop -c cabal test shikumi-tools
```

Expected when the new spec is in place (abbreviated tasty output):

```text
Compaction
  usageExceedsWindow flips at the boundary:        OK
  compactTail folds older steps, keeps recent:     OK
  agent on tiny window compacts and completes:     OK
  overflow error is caught, compacted, retried:    OK

All N tests passed
```

To run only the new spec while iterating, use the tasty pattern flag:

```bash
nix develop -c cabal test shikumi-tools --test-options='--pattern Compaction'
```

Sanity check that nothing else regressed — the existing ReAct/protocol specs must still
pass:

```bash
nix develop -c cabal test shikumi-tools --test-options='--pattern ReAct'
```


## Validation and Acceptance

The change is internal plumbing, so acceptance is phrased as observable loop behavior under
a deterministic, network-free mock model — no API keys or network required. The mock is the
existing `MockLLM` interpreter extended in M5.

1. **Threshold (unit).** With a `Model` whose `contextWindow = 1000` and
   `defaultCompactionConfig { reserveTokens = 100 }`, `usageExceedsWindow` is `False` for
   `inputTokens = 899` and `True` for `inputTokens = 900`. With `enabled = False` it is
   always `False`. Saturating: with `contextWindow = 50` and `reserveTokens = 100`,
   `overflowThreshold` is `0` and any usage triggers.

2. **Tail summarizer (unit).** Feed `compactTail` six elements with `keepRecent = 2` and one
   scripted summary response "S". The result has exactly three elements: the injected
   summary element carrying "S", then the original fifth and sixth elements unchanged. With
   `keepRecent >= 6` the input is returned untouched and no LLM call is made.

3. **Proactive compaction (acceptance).** Script a mock whose tool-call responses report a
   200-ish input-token usage that, by the third or fourth turn, climbs past
   `contextWindow - reserveTokens` on a tiny-window model (e.g. `contextWindow = 700`,
   `reserveTokens = 100`). Run `reactWithTrajectory` with a registry that has one tool and a
   high enough `maxIters` to reach the threshold. Before this change, a real provider would
   reject the oversized prompt; here we prove the loop *compacts and continues*: the run
   returns `Right (_, traj)`, `termination traj == TerminatedFinish`, the trajectory
   contains a step whose `thought == "(compacted summary of earlier steps)"`, and the last
   `keepRecent` real steps appear verbatim *after* that summary step (assert their `action`
   tool names and observations equal the most recent scripted turns).

4. **Reactive recovery (acceptance).** Use `runMockLLMThrowingOnce`: the first `Complete`
   throws `ContextWindowExceeded "context length exceeded"`; subsequent completions are
   served from the script. Run the same agent. The run returns `Right` (it did not abort
   with `Left (ContextWindowExceeded ...)`), and the trajectory shows the summary step,
   proving the loop compacted and retried rather than crashing. As a negative control,
   make the *retry* also throw and assert the run returns
   `Left (ContextWindowExceeded ...)` — recovery is bounded to one retry, not an infinite
   loop. Note the boundary this does *not* cover: recovery only triggers when baikai
   classifies the failure as `ContextOverflow` (mapped to `ContextWindowExceeded`); an
   overflow surfaced as `SchemaMismatch` (status-only 400 classification) is by design not
   caught here, which is why the proactive trigger in case 3 is the dependable defense.

5. **No regression (acceptance).** With `defaultReActConfig` (`maxIters = 6`,
   `keepRecent = 4`) and a normal large-window model, the existing `ReActSpec` and
   `ProtocolSpec` pass unchanged: short runs never cross the threshold, so no compaction
   occurs and trajectories are identical to before.

Success is the full `shikumi-tools` suite passing with the new `Compaction` group green and
all pre-existing groups still green.


## Idempotence and Recovery

All source edits are additive and safe to re-apply: adding a constructor to `ShikumiError`,
adding a module, adding a record field with a default, and wrapping an existing call in a
recovery combinator. Re-running the build/test commands is non-destructive; there is no
migration, no database, and no on-disk state. If a build fails midway, fix the named file
and re-run `cabal build` — cabal recompiles only what changed.

The runtime behavior is itself idempotent and bounded. Proactive compaction only fires when
usage crosses the threshold and always leaves the `keepRecent` tail intact, so re-entering
the loop after a compaction simply continues from the smaller history. Reactive recovery is
bounded to a single retry per turn: if the compacted, retried request still overflows, the
loop rethrows `ContextWindowExceeded` rather than looping forever — an honest failure the
caller can surface. Compaction never deletes the live `Trajectory` returned to the caller of
a *finished* run; it only shrinks the *in-flight* prompt history, and it records a visible
summary step so the compaction is auditable in the returned trajectory.

To disable the behavior entirely (e.g. to reproduce pre-change behavior), set
`compaction = defaultCompactionConfig { enabled = False }` in the `ReActConfig`; the
threshold predicate then always returns `False` and the reactive path will rethrow the
overflow unchanged.


## Interfaces and Dependencies

Libraries used and why:

- `shinzui/baikai` (already a dependency): provides `Baikai.Model.Model.contextWindow ::
  Natural`, `Baikai.Usage.Usage.inputTokens :: Natural`, and the
  `Baikai.Error.ErrorCategory.ContextOverflow` constructor with `bodyIndicatesOverflow`.
  These give the trigger its window size, its running token count, and the error to recover
  from.
- `shinzui/shikumi` (this repo, `shikumi` package): the `LLM` effect
  (`Shikumi.LLM.complete`) for the summarize call and the `ShikumiError` vocabulary
  (`Shikumi.Error`). The new `Shikumi.Compaction` module is added to *this* core library
  (not `shikumi-tools`) so that downstream consumers such as `shikigami` — which depend on
  `shikumi` but not `shikumi-tools` — can reuse `compactTail`. Its dependencies (`LLM`,
  `ShikumiError`, baikai `Model`/`Usage`/`Context`) are all already in core `shikumi`.
- `shinzui/kioku` L1 (`Kioku.Distill.L1`): **reference only** for the render-then-summarize
  pattern; not linked.

Module and signature contract that must exist at the end of each milestone:

End of M1 —
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Error.hs`:

```haskell
data ShikumiError
  = ...
  | ContextWindowExceeded !Text   -- NEW: prompt exceeded the model's context window

fromBaikaiError :: BaikaiError -> ShikumiError   -- now maps ContextOverflow -> ContextWindowExceeded
isTransient :: ShikumiError -> Bool              -- returns False for ContextWindowExceeded
```

`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Compaction.hs`:

```haskell
data CompactionConfig = CompactionConfig
  { reserveTokens :: !Natural
  , keepRecent    :: !Int
  , enabled       :: !Bool
  }

defaultCompactionConfig :: CompactionConfig          -- reserveTokens=16384, keepRecent=4, enabled=True
overflowThreshold       :: CompactionConfig -> Model -> Natural
usageExceedsWindow      :: CompactionConfig -> Model -> Usage -> Bool
```

End of M2 — same module additionally exports:

```haskell
compactTail ::
  (LLM :> es, Error ShikumiError :> es) =>
  CompactionConfig -> Model -> (a -> Text) -> (Text -> a) -> [a] -> Eff es [a]
```

End of M3 —
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-tools/src/Shikumi/Agent/ReAct.hs`:

```haskell
data ReActConfig = ReActConfig
  { maxIters   :: !Int
  , protocol   :: !ToolProtocol
  , compaction :: !CompactionConfig   -- NEW
  }

defaultReActConfig :: ReActConfig     -- compaction = defaultCompactionConfig
```

with the proactive trigger applied inside `reactLoop`'s `loop` after each successful
`complete`, keyed off `resp ^. #model` (window) and `resp ^. #message . #usage` (token
count), folding via `compactTail` with `_Model` as the summarizer model and a `Step`
renderer/injector.

End of M4 — `reactLoop` wraps `complete` in a one-shot recovery on `ContextWindowExceeded`
(compact-then-retry-once via `Effectful.Error.Static.catchError`).

End of M5 — `MockLLM` gains `mkUsageResponse :: Model -> Natural -> Text -> Response` and a
throwing interpreter; `CompactionSpec` is wired into the `shikumi-tools-test` suite
(`other-modules` in `shikumi-tools/shikumi-tools.cabal` and imported in `test/Main.hs` —
the spec stays in shikumi-tools-test because it needs the ReAct loop and the existing
`MockLLM`, and that suite already depends on core `shikumi`, so it can import
`Shikumi.Compaction` for the pure threshold/`compactTail` unit tests too).
`Shikumi.Compaction` is listed in the **core `shikumi` library's** `exposed-modules`
(`shikumi/shikumi.cabal`), so a future `shikigami` message loop can import `compactTail`
with `a = Baikai.Message` (shikigami-core depends on `shikumi`, not `shikumi-tools`).

Effect-row note: every new loop-facing function uses exactly the row the loop already runs
in — `(LLM :> es, Error ShikumiError :> es)` — and nothing wider. The summarizer needs no
`IOE`; it goes through the `LLM` effect like the rest of the loop, so it remains testable
under the network-free `MockLLM` interpreter.


## Revision Notes

### 2026-06-28 — Validation pass

The plan was validated end-to-end against the working tree before any implementation. The
result was overwhelmingly positive: every file path, function name, record field, lens
path, the verbatim `reactLoop` quote, the `_Model.contextWindow = 0` premise, baikai's
`ContextOverflow`/`bodyIndicatesOverflow` surface, `Usage.inputTokens`, the
`MockLLM` builder set, the cabal stanzas, and the kioku reference symbols all check out
exactly (see the new Surprises & Discoveries entry for the file/line evidence). No claim
had to be corrected.

Three substantive gaps were surfaced and folded into the plan rather than left implicit:

1. **The final `extract` completion was outside both guards.** `reactLoop`'s `extract`
   issues its own `complete _Model` over the whole trajectory. M4's scope, the Progress
   list, the Decision Log, and the Interfaces contract were updated so reactive recovery
   also wraps `extract`. *Why:* otherwise a long run could survive the loop and still die
   on the final answer — exactly the failure this plan exists to prevent.

2. **Reactive recovery is provider-classification-dependent.** `ContextWindowExceeded`
   only appears when baikai categorizes the failure as `ContextOverflow`
   (`classifyHttpStatusWithBody` + a matching body); a status-only 400 becomes
   `SchemaMismatch` and is not caught. This boundary is now stated in M4, in the
   Validation negative control, and in the Decision Log, with the proactive trigger named
   as the dependable defense. *Why:* readers must not assume the `catchError` is a
   universal safety net.

3. **Compaction is inert under the default `maxIters = 6`.** This is the intended
   no-regression property, but it also means the default config gains nothing; an operator
   must raise `maxIters` to benefit. M5's documentation step and the Decision Log now say
   so explicitly. *Why:* prevents the feature from reading as dead-on-arrival.

One wording tidy: M1 no longer instructs adding an import for `ContextOverflow` — it is
already in scope via `Shikumi.Error`'s existing `ErrorCategory (..)` import; the new case
simply precedes the catch-all.

### 2026-06-28 — Architectural-fit pass

A second pass asked not "do the symbols exist" but "does the design fit shikumi's
architecture." Findings:

The design fits well on the axes that matter most. The `complete _Model` pattern the plan
builds on is shikumi's deliberate model-agnostic convention — `runProgram` always passes
the `_Model` placeholder and `Shikumi.Routing` overwrites it with the real model below the
stack (`Program.hs:241-249`), which is precisely *why* the plan's decision to read the
window and usage from the `Response` is correct. The effect-row discipline
(`LLM` + `Error ShikumiError`, no `IOE`) matches integration point #4, the `ShikumiError`
extension is the sanctioned growth of integration point #1 (owned by plan 1), and the
config/test idioms match existing code.

One design change resulted, decided with the user:

- **The generic compaction primitive moves from `shikumi-tools` to the core `shikumi`
  library** (`Shikumi.Compaction`), with only the ReAct-specific wiring left in
  `shikumi-tools`. The fit investigation found that `shikigami-core` — the plan's intended
  second consumer — depends on `shikumi` but not `shikumi-tools`, so the original placement
  made the M5 reuse goal impossible. The primitive's dependencies are all in core, so the
  move is clean. This rippled through M1, M2, M5, the Interfaces contract, the Concrete
  Steps, the Cross-plan dependencies list, the Progress list, and the Decision Log.

Two honesty corrections also resulted: the shikigami reuse goal is reframed as *readiness*
(shikigami has no message loop today), and the `ShikumiError` change now explicitly notes it
extends plan 1's integration-point-#1 vocabulary rather than standing alone.
