---
id: 18
slug: reward-driven-self-refinement-modules
title: "Reward-driven self-refinement modules"
kind: exec-plan
created_at: 2026-06-09T22:35:41Z
intention: "intention_01ktq80q01emxtjfxzd3rw4tjs"
master_plan: "docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md"
---

# Reward-driven self-refinement modules

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi is a Haskell framework for writing typed language-model (LM) programs. You build a
value of type `Program i o` — a tree of "predict" nodes (each one LM call with a typed input
`i` and typed output `o`) and combinators — and you run it with `runProgram program input`,
which issues the LM calls and decodes the replies back into the typed `o`. Today Shikumi can
*re-run* a program for robustness (the `Retry`, `MajorityVote`, and `Validate` combinators in
`shikumi/src/Shikumi/Combinator.hs`), but it cannot **steer those re-runs by how good the
answer is**. There is no notion of a *reward* — a score you assign to an output — and no way
to keep the best-scoring sample, or to feed a written critique of a bad answer back into the
next attempt.

After this change a Shikumi user can wrap any `Program i o` in one of three new
**self-refinement modules**, each of which is itself an ordinary `Program i o` (so it runs
under the unchanged `runProgram` and composes with every existing combinator):

- **`bestOfN`** — run the inner program `N` times, varying the sampling temperature per
  attempt, score each output with a user-supplied reward function, and return the
  highest-scoring output (short-circuiting early if one clears a pass threshold).
- **`refine`** — run the inner program; if its output scores below the threshold, turn the
  reward into a short textual critique ("advice") and feed that advice into the next attempt,
  up to `N` attempts, returning the best output seen.
- **`multiChainComparison`** — run `M` independent reasoning attempts, then make one final LM
  call that is shown all `M` candidate answers and asked to synthesize a single corrected
  consensus answer.

The user-visible payoff, stated as the MasterPlan's headline Progress item, is: **a
reward-driven module demonstrably improves a deliberately-weak program's score.** You will see
this in a hermetic test (no network, no API key) where a stub LM is scripted so that a
single-shot run scores poorly, but the same program wrapped in `bestOfN` / `refine` returns a
better-scoring answer — and the test asserts the score went up.

These modules share the **reward vocabulary** that this plan *owns* (it is integration point
#1 of the parent MasterPlan, `docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md`):
a `Reward o` type and the three smart constructors. A later plan (EP-22, GEPA, at
`docs/plans/22-gepa-reflective-optimizer.md`) reuses this same reward vocabulary for its
reflective feedback and must not define a parallel one.

One mechanism this plan depends on is **per-sample temperature**. `bestOfN` and
`multiChainComparison` want each attempt sampled at a different temperature so the attempts
actually differ. The ability to set a per-sample temperature *on the wire* is delivered by a
sibling plan, EP-14 (`docs/plans/14-ambient-model-routing-and-live-native-structured-output.md`),
which makes Shikumi's existing `TempSchedule` mechanism live. This plan is written so that the
modules are **fully demonstrable with a hermetic stub LM before any live provider exists**: the
stub inspects the request it receives (including its requested temperature) and answers
deterministically, so we can prove the loops behave correctly without a network.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **M1 — reward vocabulary + `bestOfN`.** (2026-06-09) `Shikumi.Reward` module exists
  (`Reward o`, `mkReward`, `boolReward`); threshold is a plain `Double` argument. `bestOfN` is a
  smart constructor producing a `Program i o` built from an `Embed` node; hermetic tests show
  `bestOfN` returns the highest-reward scripted sample (all 3 attempts run), short-circuits on a
  pass (stops after 2), and propagates the error when every attempt throws.
- [x] **M2 — `refine`.** (2026-06-09) `refine`/`refineWith` smart constructors producing a
  `Program i o` (an `Embed` node) that, on a sub-threshold output, derive textual advice from the
  reward (via a typed `AdviceIn -> AdviceOut` `predict` node) and thread it into the next attempt;
  hermetic test shows it climbs from a failing (`bad`) to a passing (`good`) output and the final
  reward strictly exceeds the single-shot reward.
- [x] **M3 — `multiChainComparison`.** (2026-06-09) `multiChainComparison` smart constructor
  producing a `Program i o2`, plus `MultiChainInput`/`multiChainSig`; hermetic test shows it runs
  `M` reasoning attempts and the final synthesis call sees all `M` "Student Attempt" candidates and
  returns the modal consensus.
- [x] **M4 — composition + acceptance.** (2026-06-09) Tests nest a module inside `mapP 2 (...)`
  and `bestOfN ... >>> validate ...`, run under both `runProgram` and `runProgramConc` with
  identical results, and assert `programShape == ShapeEmbed`, `foldParams == []`,
  `setProgramParams [] == Right`. The MasterPlan acceptance test "reward-driven retry demonstrably
  improves a deliberately-weak program's score" passes (single-shot 0.2 → wrapped 0.9).
- [x] MasterPlan Progress checkboxes for EP-18 ticked; Decision Log / Surprises updated.
  (2026-06-09)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Per-attempt temperature needs the router installed to actually reach the wire — and that is
  the right hermetic seam.** `bestOfN`/`multiChainComparison` use the *exported*
  `Shikumi.Program.withSampleTemp` (no `Eq o` constraint, unlike `MajorityVote 1 (TempFixed [t])`,
  which the plan suggested but which would have forced an `Eq o` constraint the public signatures
  do not carry). `withSampleTemp` only *stamps* the temperature onto the private metadata channel;
  it becomes a real `Options.temperature` only once `routeLLM . runRouting model` (EP-14) is
  installed below the stub. So the EP-18 tests install the production router over the stub exactly
  as `RoutingSpec` does, and the stub reads `o ^. #temperature`. This means EP-18's headline
  behaviour is *already live* against the merged EP-14 substrate — not merely stub-demonstrable.
- **Advice is injected by rewriting the outgoing request, not via a metadata key.** The plan
  floated stamping advice on an `Options.metadata` key; but unknown metadata keys do not reach the
  model's prompt on a real provider. `withAdvice` instead `interpose`s on the `LLM` effect and
  appends "Hint from a previous attempt: <advice>" to the request's *system prompt*, so the advice
  is visible to both the hermetic stub and a real model. Recorded in the Decision Log below.
- **`refine`'s advice generator carries only the reward and threshold, not the input.** Because
  `refine :: Int -> Double -> Reward o -> Program i o -> Program i o` is deliberately
  constraint-free on `i`, the wrapper cannot render the opaque input. `AdviceIn` therefore carries
  the achieved reward and the target threshold (as `Text`); the advice is whole-program, the honest
  analogue given the wrapper sees the inner program as an opaque `Embed` body.


## Decision Log

Record every decision made while working on the plan.

- Decision: **Own a dedicated `Reward o = o -> Double` (wrapped in a `newtype`) in the base
  `shikumi` package, rather than reusing `shikumi-eval`'s `Metric o = o -> Prediction o ->
  Score`.**
  Rationale: the three modules must be first-class `Program i o` values, and `Program` lives in
  the base `shikumi` package (`shikumi/src/Shikumi/Program.hs`). `Score`, `Prediction`, and
  `Metric` live in `shikumi-eval` (`shikumi-eval/src/Shikumi/Eval/Types.hs` and
  `.../Metric.hs`), which *depends on* `shikumi` — the dependency only points one way
  (verified: `shikumi-eval.cabal` lists `shikumi`; `shikumi.cabal` does not list
  `shikumi-eval`). Reusing `Metric` would force `shikumi` to depend on `shikumi-eval`, an
  inversion that would create a dependency cycle. A reward at inference time also only ever
  sees the *one* output it is scoring (not a held-out expected value and not a multi-sample
  `Prediction`), so the simpler `o -> Double` shape is the honest one. The two vocabularies are
  reconciled by a one-line adapter shown below so a user who already has an `exactMatch`-style
  metric can derive a `Reward` from it.
  Date: 2026-06-09.
- Decision: **Build all three modules from the existing `Embed` constructor, not from new
  `Program` GADT constructors.**
  Rationale: the parameter-count invariant in `shikumi/src/Shikumi/Program.hs` is "a program's
  parameter count equals its number of `Predict` nodes"; every composite node carries no
  `Params`. A self-refinement module's inner program already contributes its own `Predict`
  nodes; the wrapper itself holds no optimizable parameters of its own. `Embed` is exactly the
  closure-carrying leaf that already satisfies this — it carries no `Params` (it is a traversal
  leaf), has the structural shape `ShapeEmbed`, and runs under `runProgram`'s exact effect row.
  This is the same pattern V1's ReAct agent uses (`react` is an `Embed` node). Choosing `Embed`
  means **no edit to `paramsTraversal`, `programShape`, `setProgramParams`, `runProgram`, or
  `runProgramConc`**, and the V1 compilers/optimizers/serialization pass these modules through
  unchanged. (The cost, accepted: the inner program's per-node `Params` are *not* exposed to
  the optimizer through the wrapper, because `Embed`'s body is an opaque closure — identical to
  how ReAct's inner predictors are invisible. This is acceptable for inference-time modules
  whose job is selection/retry, not parameter tuning.)
  Date: 2026-06-09.
- Decision: **Per-sample temperature is requested via the same `TempSchedule` / `Options.temperature`
  channel EP-14 makes live, and the modules degrade gracefully to identical-temperature
  sampling when EP-14 is not yet merged.**
  Rationale: EP-14 (`docs/plans/14-ambient-model-routing-and-live-native-structured-output.md`)
  resolves temperature by having `runProgram`'s render step stamp the requested temperature
  onto `Options.metadata`, which a model-aware router below the stack translates onto
  `Options.temperature` on the real wire. Since the self-refinement modules are `Embed` nodes
  that call `runProgram` on their inner program, they cannot reach into the inner program's
  render step directly. Instead each attempt that wants a distinct temperature wraps its inner
  program in the existing `MajorityVote 1 (TempFixed [t])`-style schedule carrier OR, more
  directly, threads the temperature through the same metadata key EP-14 defines. Until EP-14
  lands, the hermetic stub honours the temperature carried in the request (so tests pass), and
  against a real provider every attempt is sampled identically (correct but less diverse). This
  keeps EP-18 demonstrable now and automatically "lights up" when EP-14 merges.
  Date: 2026-06-09.
- Decision: **Default `failCount` (the number of tolerated inner-program errors before the
  module gives up and rethrows) equals `N`.**
  Rationale: mirrors DSPy's `BestOfN`/`Refine`, where `fail_count` defaults to `N`. A module
  should tolerate as many failures as it has attempts, but no more, so a program that always
  throws surfaces its error rather than silently returning nothing.
  Date: 2026-06-09.
- Decision: **Use the exported `Shikumi.Program.withSampleTemp` to vary per-attempt temperature,
  not a `MajorityVote 1 (TempFixed [t])` wrapper.** Rationale: `MajorityVote` carries an `Eq o`
  constraint that `bestOfN`/`multiChainComparison`'s public signatures do not; `withSampleTemp ::
  (LLM :> es) => Maybe Double -> Eff es a -> Eff es a` stamps the temperature with no such
  constraint and is already the mechanism `MajorityVote` itself uses internally. Implemented; the
  hermetic tests install the EP-14 router so the stamp becomes a real `Options.temperature`.
  Date: 2026-06-09.
- Decision: **Inject `refine` advice by `interpose`-ing on the `LLM` effect to append a hint to
  the system prompt, rather than via an `Options.metadata` key.** Rationale: a private metadata key
  would be stub-readable but invisible to a real provider's prompt; rewriting the outgoing
  `Context.systemPrompt` works for both. `withAdvice` is scoped via `interpose` so it affects only
  the advice-bearing attempt. Date: 2026-06-09.
- Decision: **Add `bestOfNWith`/`refineWith` (explicit `failCount`/`TempSchedule`) and a
  `multiChainSig` helper.** Rationale: the plan flagged the `With` variants as optional; they cost
  nothing and make the budget/schedule explicit for callers. `multiChainSig` is needed because the
  synthesis input `MultiChainInput i o` is not `Generic` (its `attempts` field is polymorphic in
  `o`), so `mkSignature` cannot build its signature — `multiChainSig` constructs it directly with
  the output-field metadata derived from `o2`. Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Completed 2026-06-09.** All four milestones landed. Delivered:

- `shikumi/src/Shikumi/Reward.hs` — the owned reward vocabulary (`Reward o`, `mkReward`,
  `boolReward`) in the base `shikumi` package, as integration point #1 requires.
- `shikumi/src/Shikumi/Refine.hs` — `bestOfN`/`bestOfNWith`, `refine`/`refineWith`,
  `multiChainComparison` (+ `MultiChainInput`/`multiChainSig`), all built from the existing
  `Embed` leaf with **no new `Program` GADT constructor** — so `paramsTraversal`, `programShape`,
  `setProgramParams`, `runProgram`, and `runProgramConc` are untouched and the modules pass
  through V1 serialization as `ShapeEmbed`.
- `shikumi/test/RefineStub.hs` + `shikumi/test/RefineSpec.hs` — 8 hermetic tests, wired into
  `shikumi/test/Main.hs` and the cabal suite.

The headline purpose is met: the acceptance test shows a deliberately-weak classify program
scoring **0.2 single-shot vs 0.9 wrapped in `bestOfN`** under a deterministic stub, and `refine`
climbs `bad → good` (0.0 → 1.0) via advice. `cabal test shikumi` is 94/94 green and `cabal test
all` passes every workspace suite, confirming the additive change regressed nothing.

Gaps / accepted limitations (unchanged from the plan): the inner program's per-node `Params` are
invisible to an optimizer *through* these wrappers (the `Embed` body is opaque) — acceptable for
inference-time selection/retry modules and identical to how ReAct already behaves. EP-22 (GEPA)
reuses `Shikumi.Reward` directly and must not define a parallel reward type.


## Context and Orientation

This section assumes you have never seen this repository. Read it fully before editing.

### Where things live

Shikumi is a multi-package Cabal project rooted at `/Users/shinzui/Keikaku/bokuno/shikumi`,
with a sibling transport library `baikai` at `/Users/shinzui/Keikaku/bokuno/baikai`. The
package you will edit is `shikumi/` (the runtime substrate). Its library modules live under
`shikumi/src/Shikumi/`; its tests live under `shikumi/test/`. The library's exposed-modules
list and the test suite's other-modules list both live in `shikumi/shikumi.cabal`; you will add
entries to both.

You will create one new library module, `shikumi/src/Shikumi/Refine.hs`, exposing the three
smart constructors and the reward vocabulary (or split the reward type into its own
`shikumi/src/Shikumi/Reward.hs` — see "Interfaces and Dependencies" for the exact split). You
will create one new test module, `shikumi/test/RefineSpec.hs`, and wire it into the test
suite's `other-modules` and into the test runner `shikumi/test/Main.hs`.

### The `Program` model (read `shikumi/src/Shikumi/Program.hs`)

A `Program i o` is a GADT (a typed tree). The constructors that matter to this plan are:

```haskell
data Program i o where
  Predict :: (...) => Signature i o -> Params -> Program i o
  Compose :: Program a b -> Program b c -> Program a c
  FMap    :: (o -> o') -> Program i o -> Program i o'
  Embed   :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o
  -- plus Map, Parallel, Retry, RetryWhen, Validate, MajorityVote, Ensemble
```

Three things you can do with any `Program`:

1. **Run it.** `runProgram :: (LLM :> es, Error ShikumiError :> es) => Program i o -> i -> Eff es o`
   interprets the tree, issuing LM calls. There is also `runProgramConc`, which adds a
   `Concurrent :> es` constraint and runs independent sub-programs concurrently; its observable
   results match `runProgram`. **You must not change the row of `runProgram`** — every
   downstream consumer inherits it (this is integration point #4 of the foundation MasterPlan).
2. **Rewrite its parameters as data.** `paramsTraversal` / `foldParams` / `mapParams` /
   `mapParamsAt` read and replace each node's optimizable `Params` (an instruction override
   plus few-shot demos). The invariant: **the number of `Params` equals the number of `Predict`
   nodes**; every composite node (`Compose`, `FMap`, `Embed`, …) carries no `Params`.
3. **Serialize it.** `programShape :: Program i o -> ProgramShape` captures the closure-free
   structure; `programParams` / `setProgramParams` move the JSON parameter vector on and off a
   structurally identical template.

**The constructor rule.** The dossier and `Program.hs` are explicit: *if* you add a new GADT
constructor, it is a compile error until you pattern-match it in `runProgram`, `runProgramConc`,
`paramsTraversal`, `mapParamsAt`, `programShape`, `setProgramParams`, and add a new `Shape*`
constructor. This plan deliberately **adds no new constructor**; it builds on the existing
`Embed`, so none of those functions change. (The alternative — new constructors — is spelled out
in "Interfaces and Dependencies" under "Rejected: new constructors", including the full list of
edits it would force, so a future contributor understands why we avoided it.)

### The `Embed` constructor (the keystone of this plan)

`Embed` lifts an opaque effectful step into a program node:

```haskell
Embed :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o

embed :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o
embed = Embed
```

Its body is constrained to **exactly `runProgram`'s effect row** (`LLM` + `Error ShikumiError`),
so an `Embed` node runs under the ordinary executors without widening any constraint. Crucially,
**inside an `Embed` body you may call `runProgram` recursively** on a sub-program, because
`runProgram` requires exactly the row the body already provides. This is how V1's ReAct agent is
built (its loop is one `Embed` node, per the dossier section H.4), and it is how all three
self-refinement modules are built here: each module's `Embed` body runs the inner program one or
more times and combines the results.

`Embed`'s structural treatment is already correct for our purposes:
`paramsTraversal _ (Embed f) = pure (Embed f)` (a leaf — no params), `programShape (Embed _) =
ShapeEmbed`, and both `setProgramParams` and `mapParamsAt` pass it through untouched. So a
self-refinement module contributes **zero** to the program's parameter count, exactly like
`FMap`.

### The reward vocabulary you own

A **reward** is a function that scores a single output. We define, in the base `shikumi`
package:

```haskell
newtype Reward o = Reward { runReward :: o -> Double }
```

A reward returns a plain `Double` (by convention in `[0, 1]`, but not clamped — higher is
better, and `bestOfN` only ever compares rewards, so any totally-ordered range works). We use a
bare `Double` rather than `shikumi-eval`'s `Score` to avoid the dependency inversion described
in the Decision Log. For callers who already have a `shikumi-eval` `Metric`, a one-line adapter
(in `shikumi-eval`, not here) recovers a `Reward`:

```haskell
-- lives in shikumi-eval, where both Metric and Reward are in scope; shown for orientation only
rewardFromMetric :: o -> Metric o -> Reward o
rewardFromMetric expected m = mkReward (\o -> unScore (m expected (prediction o)))
```

A **threshold** is the reward value at or above which an output is "good enough" and the loop
short-circuits. We represent it as a plain `Double` argument to each smart constructor.

### What DSPy does (mirrored here in our own words)

Read these only if you want the algorithmic background; this plan restates each loop precisely.

- **BestOfN.** Run the module up to `N` times, each with a different "rollout id" and a fixed
  sampling temperature (DSPy uses `temperature = 1.0`). After each run, compute the reward.
  Keep the best-scoring run. If a run's reward reaches the threshold, stop early and return it.
  A `fail_count` caps how many *exceptions* are tolerated before the error is re-raised.
- **Refine.** Like BestOfN, but on a sub-threshold run it additionally builds a structured
  *feedback* object — DSPy calls it "advice" — by asking an LM to look at the program's
  inputs, trajectory, outputs, the reward code, the target threshold, and the achieved reward,
  then write concrete advice per module. On the next attempt that advice is injected as an extra
  hint input field. It returns the best run seen across all attempts.
- **MultiChainComparison.** Build `M` independent reasoning attempts (each a candidate answer
  with its rationale). Then make one final LM call whose signature has been extended with `M`
  extra input fields — one per attempt, each rendered as "Student Attempt #k" — and a prepended
  output field asking for "accurate reasoning" that holistically compares the attempts and
  produces a single corrected answer. The final call returns that consensus.

### The hermetic stub LM pattern (read `shikumi/test/StubProvider.hs` and `shikumi-optimize/test/StubLM.hs`)

Tests run with **no network and no API key**. There are two established ways to supply a fake
LM, and this plan uses the second:

1. A fake *baikai provider* in an isolated `ProviderRegistry` whose `complete` returns scripted
   text (`shikumi/test/StubProvider.hs`). This exercises the real adapter/parse path.
2. A direct *`LLM`-effect interpreter* that inspects the rendered request and answers by a rule
   (`shikumi-optimize/test/StubLM.hs`'s `runStubLM`). This is the pattern we copy: it reads the
   request `Context` (system prompt + messages), and returns a fallback-style
   `[[ ## field ## ]]` body so the adapter decodes it into a typed output. It lets the same fake
   model answer *differently depending on the request*, which is exactly what we need to make a
   "weak single shot, better after refinement" scenario deterministic.

The key knobs the stub reads, all already demonstrated in `StubLM.hs`:

- It reads the last user message text to recover the typed input (`lastUserText`,
  `parseSentence`).
- It reads the system prompt to detect whether a magic instruction is present
  (`instructionHasRule`).
- It emits a `[[ ## field ## ]]` marker body that the fallback adapter parses (`markerBody`).

For this plan we add two new behaviours to a *local copy* of that stub (in
`shikumi/test/RefineSpec.hs`, or a small shared `shikumi/test/RefineStub.hs`):

- **It reads `Options.temperature` (or the EP-14 metadata key carrying it)** so the test can
  prove different attempts request different temperatures and so the stub can return a
  better answer at a higher temperature, modelling "more sampling finds a better answer."
- **It reads an injected advice/hint field** (for `refine`) so the test can prove that the
  second attempt, which carries advice, yields a passing answer where the first did not.


## Plan of Work

The work is four milestones. M1 establishes the reward vocabulary and the simplest module
(`bestOfN`); M2 and M3 add the other two modules; M4 proves composition and lands the
MasterPlan acceptance scenario. Each milestone is independently verifiable with a hermetic stub
LM and ends with a runnable test.

All edits are additive: one new library module (`Shikumi.Refine`, optionally with a separate
`Shikumi.Reward`), additions to `shikumi/shikumi.cabal`, and new test modules. No existing
function signature changes; in particular `runProgram`'s row is untouched.


### Milestone 1 — reward vocabulary and `bestOfN`

**Scope.** Introduce the owned reward vocabulary and the first module. At the end of M1 a user
can write `bestOfN n threshold reward innerProgram :: Program i o`, run it with `runProgram`,
and get back the highest-reward output of `n` sampled runs (short-circuiting when one reaches
the threshold).

**What will exist that did not before.** A module `Shikumi.Reward` exporting:

```haskell
newtype Reward o = Reward { runReward :: o -> Double }

mkReward   :: (o -> Double) -> Reward o
boolReward :: (o -> Bool) -> Reward o      -- True -> 1.0, False -> 0.0
```

and `bestOfN` in `Shikumi.Refine`:

```haskell
bestOfN :: Int -> Double -> Reward o -> Program i o -> Program i o
```

**The `bestOfN` loop (precise).** `bestOfN n threshold reward inner` is `embed body`, where
`body i` runs `inner` on `i` up to `max 1 n` times. Maintain `(bestOutput, bestReward)`,
initialised empty. For attempt index `k` from `0`:

1. Choose this attempt's temperature `t_k` from a spread schedule (see "per-sample temperature"
   below). Run the inner program at temperature `t_k`: `o <- runInnerAt t_k inner i`.
2. Compute `r = runReward reward o`.
3. If `r` is greater than `bestReward` (or there is no best yet), set `(bestOutput, bestReward)
   = (o, r)`.
4. If `r >= threshold`, stop and return `o` immediately (short-circuit on a pass).
5. Otherwise continue to the next attempt.

After the loop, return `bestOutput`. If every attempt threw an error, the `failCount` budget
(default `n`) governs whether the error is swallowed-and-retried or rethrown: each caught error
decrements the budget; when it would go negative the error propagates (`throwError`). If at
least one attempt succeeded, errors from other attempts are ignored and the best success is
returned. The reward function itself is pure (`o -> Double`), so scoring never throws.

**Per-sample temperature.** The desire is that attempt `k` is sampled at a distinct temperature
so the `n` runs genuinely differ. We reuse Shikumi's existing `TempSchedule` (defined in
`shikumi/src/Shikumi/Program.hs`): `bestOfN` derives `n` temperatures from a default spread
(`TempSpread 0.7 0.6`, i.e. centred at 0.7, fanning out by 0.6, the same convention
`MajorityVote` uses), then runs each attempt as the inner program wrapped to carry that single
temperature. Concretely, "run the inner program at temperature `t`" is implemented by wrapping
`inner` in a one-sample temperature carrier and running it: `runProgram (MajorityVote 1
(TempFixed [t]) inner) i`. EP-14 (`docs/plans/14-ambient-model-routing-and-live-native-structured-output.md`)
is the plan that makes `MajorityVote`'s `TempSchedule` actually set `Options.temperature` on
the wire; until EP-14 lands the schedule is carried but inert against a real provider (every
attempt is sampled identically — correct, just less diverse), and the **hermetic stub honours
the requested temperature directly** so M1's test is fully deterministic now. Record in the
Surprises section if, when EP-14 merges, the metadata key it uses differs from a literal
`Options.temperature` so the wrapper can be adjusted in one place.

**Commands.** Build and test inside the dev shell:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal build shikumi
nix develop .#ghc9124 --command cabal test shikumi
```

**Acceptance.** A new test in `shikumi/test/RefineSpec.hs` installs a stub LM that scripts a
known reward per attempt — for example, attempt 0 returns an output the reward scores `0.2`,
attempt 1 returns one scored `0.9`, attempt 2 one scored `0.5`. Running
`bestOfN 3 1.0 reward inner` returns the `0.9` output (the maximum), and the stub's call counter
shows all 3 attempts ran (no early stop, since none reached `1.0`). A second case scripts an
attempt that reaches the threshold early (e.g. attempt 1 scores `1.0`) and asserts the call
counter shows the loop stopped after attempt 1. A third case scripts every attempt to throw and
asserts the error propagates after the `failCount` budget is exhausted.


### Milestone 2 — `refine`

**Scope.** Add the feedback-driven module. At the end of M2 a user can write
`refine n threshold reward inner :: Program i o`; on a sub-threshold output it derives textual
advice from the reward and feeds it into the next attempt.

**What will exist that did not before.** `refine` in `Shikumi.Refine`:

```haskell
refine :: Int -> Double -> Reward o -> Program i o -> Program i o
```

**The `refine` loop (precise).** `refine n threshold reward inner` is `embed body`. `body i`
maintains `(bestOutput, bestReward)` and an optional `advice :: Maybe Text`, initialised to
`Nothing`. For attempt `k` from `0` to `n - 1`:

1. Run the inner program on `i`, threading the current `advice` (if any) as an extra textual
   hint. Threading advice into a typed `Program i o` is the one subtlety: the inner program's
   `i` does not have an "advice" field. We resolve this with a **hint-carrying wrapper** that is
   itself an `Embed`: the body, when `advice = Just txt`, augments the request the inner program
   makes by appending the advice to the rendered prompt. Because the inner program renders
   inside `runProgram`, the clean seam is the same `Options.metadata` channel EP-14 introduces:
   `refine` stamps a private metadata key (`"shikumi.refine.advice"`) carrying the advice text,
   and the adapter/stub reads it and appends "Hint from a previous attempt: <advice>" to the
   prompt. (If EP-14's metadata seam is not yet available when M2 is implemented, fall back to
   wrapping `inner` so that, for the advice-bearing attempt, the body prepends a synthetic
   advice turn — document whichever path is taken in the Decision Log. The hermetic stub reads
   the advice from the request either way.)
2. Compute `r = runReward reward o`, update `(bestOutput, bestReward)` as in `bestOfN`.
3. If `r >= threshold`, return `o` immediately.
4. If this was the last attempt (`k == n - 1`), stop and return `bestOutput`.
5. Otherwise, **generate advice for the next attempt.** Build a small typed advice-generating
   `Program` (a single `Predict` over a signature `AdviceIn -> AdviceOut`, where `AdviceIn`
   carries the rendered input, the achieved reward, and the target threshold, and `AdviceOut`
   carries a single `advice` text field). Run it via `runProgram` to get the advice text, store
   it in `advice`, and continue. This mirrors DSPy's `OfferFeedback` predictor but is scoped to
   the single inner program rather than a multi-module program (Shikumi's inner program is
   opaque inside the `Embed`, so we cannot enumerate its sub-modules; we give whole-program
   advice, which is the honest analogue given the dossier's "no per-node correlation" gap, J.3).

Errors are governed by the same `failCount` budget as `bestOfN`.

**Acceptance.** A test scripts the stub so that **without advice** the inner program returns a
failing output (reward `0.0`) and **with the advice present in the request** it returns a
passing output (reward `1.0`). The advice-generator stub returns a fixed advice string. Running
`refine 2 1.0 reward inner` returns the passing output, and the stub's recorded requests show:
attempt 0 had no advice and scored `0.0`; attempt 1 carried the advice string and scored `1.0`.
The final returned reward is strictly greater than a single-shot run's reward — proving
feedback improved the result.


### Milestone 3 — `multiChainComparison`

**Scope.** Add the consensus-synthesis module. At the end of M3 a user can write
`multiChainComparison m inner synthSig :: Program i o2`, which runs `m` reasoning attempts and
synthesizes one corrected answer.

**What will exist that did not before.** `multiChainComparison` in `Shikumi.Refine`. Because
the synthesis step needs to *show* the candidates to a fresh LM call, its signature differs from
the inner program's, so the type is:

```haskell
multiChainComparison ::
  (FromModel i, FromModel o2, ToSchema o2, Validatable o2, ToPrompt i, ToPrompt o2) =>
  Int ->                                  -- M, the number of reasoning attempts
  Program i (WithReasoning o) ->          -- the reasoning program (produces rationale + answer)
  Signature (MultiChainInput i o) o2 ->   -- the synthesis signature
  Program i o2
```

Here `WithReasoning o` is the existing chain-of-thought wrapper from `shikumi/src/Shikumi/Module.hs`
(`data WithReasoning o = WithReasoning { reasoning :: Text, value :: o }`), which a
`chainOfThoughtRaw` node produces. `MultiChainInput i o` is a new small record this plan
defines, carrying the original input plus the `M` candidate `(reasoning, answer)` attempts:

```haskell
data MultiChainInput i o = MultiChainInput
  { original :: i
  , attempts :: [WithReasoning o]     -- length M; each rendered as "Student Attempt #k"
  }
```

with hand-written `ToPrompt`/`ToSchema`/`FromModel` instances (the `attempts` field is
polymorphic in `o`, so it cannot be `Generic`-derived for the same reason `WithReasoning`'s
instances are hand-written — see `Shikumi.Module`).

**The `multiChainComparison` loop (precise).** `multiChainComparison m reasoner synthSig` is
`embed body`. `body i`:

1. Runs the reasoning program `m` times on `i`, each at a distinct temperature (same spread
   mechanism as `bestOfN`), collecting `attempts :: [WithReasoning o]` of length `m`. If fewer
   than `m` attempts succeed, the synthesis proceeds with however many succeeded (but at least
   one; if none succeed, the last error propagates).
2. Builds `MultiChainInput i o { original = i, attempts = attempts }`.
3. Runs a single `Predict synthSig`-backed program on that input. The synthesis signature's
   instruction asks the model to compare the attempts and produce one corrected answer; its
   `ToPrompt` renders each attempt as `"Student Attempt #k: «I tried to <reasoning>; my answer
   is <answer>»"` (mirroring DSPy's rendering). Returns the synthesized `o2`.

**Acceptance.** A test scripts the reasoning stub to return `m` distinct candidate answers
(e.g. for `m = 3`: "Paris", "Brussels", "Brussels") and scripts the synthesis stub so that its
response is a deterministic function of the candidates it is shown — for example it returns the
modal candidate ("Brussels"). The test asserts the final output is "Brussels" and that the
synthesis request's rendered prompt contained all three "Student Attempt" lines (so we know the
candidates were actually passed through). This proves the consensus call saw and used all `M`
attempts.


### Milestone 4 — composition and the MasterPlan acceptance scenario

**Scope.** Prove the modules are genuinely first-class composable `Program`s and land the
headline acceptance test.

**What will exist that did not before.** Tests demonstrating:

1. **Nesting inside a combinator.** `mapP 2 (bestOfN 3 1.0 reward inner)` type-checks and runs
   (a `bestOfN` module is mapped over a list); `bestOfN 3 1.0 reward inner >>> validate ok
   "reason" downstream` type-checks and runs (a module feeds a validator). Run both under
   `runProgram` *and* `runProgramConc` and assert identical results.
2. **Structural transparency.** For `p = bestOfN 3 1.0 reward inner`, assert
   `programShape p == ShapeEmbed`, `foldParams p == []` (the wrapper holds no params), and
   `setProgramParams [] p` is `Right`. This confirms the modules satisfy the parameter-count
   invariant and pass through serialization untouched — the whole reason we chose `Embed`.
3. **The MasterPlan acceptance scenario** — "reward-driven retry demonstrably improves a
   deliberately-weak program's score." Reuse the sentiment-classification fixture pattern from
   `shikumi-optimize/test/StubLM.hs` (a deliberately-underspecified program that scores poorly
   single-shot). Script the stub so that a single-shot `runProgram inner i` produces a low-reward
   answer, but `bestOfN`/`refine` around the same `inner` produce a high-reward answer (because a
   later attempt — higher temperature for `bestOfN`, advice-bearing for `refine` — yields the
   correct label). The test computes the reward of the single-shot output and the reward of the
   wrapped output and asserts `wrappedReward > singleShotReward`. This is the exact Progress line
   the MasterPlan tracks.

**Commands.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test shikumi
nix develop .#ghc9124 --command cabal test all
```

**Acceptance.** `cabal test shikumi` passes, including the three M4 assertions, and the
acceptance scenario prints a visible improvement (single-shot reward strictly below the wrapped
reward). `cabal test all` stays green (no other package regressed, since all edits are additive
and no shared signature changed).


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` inside the dev
shell. The dev shell pins GHC 9.12.4:

```bash
nix develop .#ghc9124
```

Inside that shell:

1. **Create `shikumi/src/Shikumi/Reward.hs`** exporting `Reward (..)`, `mkReward`, `boolReward`.
   (Alternatively define `Reward` at the top of `Shikumi.Refine`; a separate module is cleaner
   because EP-22 imports the reward vocabulary without pulling in the modules.)

2. **Create `shikumi/src/Shikumi/Refine.hs`** exporting `bestOfN`, `refine`,
   `multiChainComparison`, `MultiChainInput (..)`, and re-exporting the reward vocabulary. Each
   smart constructor returns a `Program i o` built with `embed`. Inside each `embed` body, call
   `runProgram` recursively on the inner program(s). Define the small advice and synthesis
   helper signatures/records here.

3. **Register both modules** in `shikumi/shikumi.cabal` under the library's `exposed-modules`
   (add `Shikumi.Reward` and `Shikumi.Refine`).

4. **Create `shikumi/test/RefineSpec.hs`** (and optionally `shikumi/test/RefineStub.hs` for the
   shared scripted stub). Model the stub on `shikumi-optimize/test/StubLM.hs`'s `runStubLM`:
   `interpret` the `LLM` effect, read the request `Context`, branch on whether the request is a
   reasoning call, an advice call, or a synthesis call (recognise each by an output-field name in
   the system prompt, exactly as `StubLM`'s `isProposer` does), and return a `markerBody`
   response. Add the temperature-reading and advice-reading behaviours described in M1/M2.

5. **Wire the test module** into `shikumi/shikumi.cabal`'s test-suite `other-modules` (add
   `RefineSpec` and `RefineStub` if used) and into `shikumi/test/Main.hs` (add the spec to the
   test tree, matching the existing pattern there).

6. **Build and test** after each milestone:

```bash
nix develop .#ghc9124 --command cabal build shikumi
nix develop .#ghc9124 --command cabal test shikumi
```

Expected final transcript (illustrative — exact wording depends on the test names you choose):

```text
shikumi-test
  Refine
    bestOfN returns the highest-reward sample:        OK
    bestOfN short-circuits on a passing threshold:    OK
    bestOfN exhausts failCount then rethrows:         OK
    refine climbs from failing to passing via advice: OK
    multiChainComparison synthesizes the consensus:   OK
    module nests inside mapP and >>> :                OK
    module is structurally transparent (ShapeEmbed):  OK
    reward-driven retry improves a weak program:      OK

All N tests passed
```

7. **Format** with fourmolu (2-space indentation, the repo standard):

```bash
nix develop .#ghc9124 --command fourmolu -i shikumi/src/Shikumi/Refine.hs shikumi/src/Shikumi/Reward.hs shikumi/test/RefineSpec.hs
```

8. **Commit** with the trailers every commit in this repo carries:

```text
feat(shikumi): reward-driven self-refinement modules (bestOfN, refine, multiChainComparison)

MasterPlan: docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md
ExecPlan: docs/plans/18-reward-driven-self-refinement-modules.md
Intention: intention_01ktq80q01emxtjfxzd3rw4tjs
```

Commit at each milestone boundary, not only at the end.


## Validation and Acceptance

Every milestone is validated by a hermetic test that runs with no network and no API key, using
a scripted stub `LLM` interpreter. The acceptance criteria, restated as observable behaviour:

- **M1.** With a stub that scores attempt outputs `[0.2, 0.9, 0.5]`, `runProgram (bestOfN 3 1.0
  reward inner) i` returns the `0.9`-scored output; with a stub where attempt 1 scores `1.0`,
  the loop stops after 2 attempts (asserted via a call counter, the `runStubLMCounting` pattern);
  with a stub that always throws, the error propagates after the `failCount` budget.
- **M2.** With a stub that returns a failing output when no advice is in the request and a
  passing output when the advice string is present, `runProgram (refine 2 1.0 reward inner) i`
  returns the passing output and the final reward strictly exceeds the single-shot reward.
- **M3.** With a reasoning stub returning `m` distinct candidates and a synthesis stub returning
  their modal value, `runProgram (multiChainComparison m reasoner synthSig) i` returns the modal
  candidate, and the synthesis request's rendered prompt contains all `m` "Student Attempt"
  lines.
- **M4.** `mapP` and `>>>` compositions of a module run under both `runProgram` and
  `runProgramConc` with identical results; `programShape p == ShapeEmbed`, `foldParams p == []`,
  `setProgramParams [] p == Right p`; and the acceptance scenario shows `wrappedReward >
  singleShotReward`.

Run the full suite to confirm no regression:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test all
```

Beyond compilation, the proof of effectiveness is the M4 acceptance assertion: a program that
scores low single-shot scores higher once wrapped in a reward-driven module, demonstrated with a
deterministic stub so the improvement is reproducible.


## Idempotence and Recovery

All steps are additive and safe to repeat. Creating the modules and tests is idempotent (rerun
the editor; the files converge to the same content). Re-running `cabal build`/`cabal test` is
safe. If a build fails because a new module was added to the library but not to the cabal
`exposed-modules` (or a test module not to `other-modules`/`Main.hs`), the error names the
missing module; add it and rebuild. If a test is flaky, it is a bug in the stub or the loop —
the stub is fully deterministic by construction (it reads only the request and returns scripted
text), so any nondeterminism indicates the loop is not threading temperature/advice the way the
stub expects; fix the threading rather than weakening the assertion. No step is destructive; no
migration or data change is involved. To roll back, delete the two new library modules and the
test module and revert the three cabal edits and the `Main.hs` edit; nothing else references
them.


## Interfaces and Dependencies

### New modules and their exact surface (end-state)

In the base `shikumi` package (`shikumi/src/Shikumi/`):

```haskell
-- Shikumi.Reward
newtype Reward o = Reward { runReward :: o -> Double }
mkReward   :: (o -> Double) -> Reward o
boolReward :: (o -> Bool) -> Reward o          -- True -> 1.0, False -> 0.0

-- Shikumi.Refine (re-exports Shikumi.Reward)
bestOfN ::
  Int ->                 -- N attempts (>= 1; clamped with max 1)
  Double ->              -- pass threshold (reward >= this short-circuits)
  Reward o ->
  Program i o ->
  Program i o

refine ::
  Int ->                 -- N attempts
  Double ->              -- pass threshold
  Reward o ->
  Program i o ->
  Program i o

multiChainComparison ::
  (FromModel i, FromModel o2, ToSchema o2, Validatable o2, ToPrompt i, ToPrompt o2) =>
  Int ->                                 -- M reasoning attempts
  Program i (WithReasoning o) ->         -- reasoning program (chainOfThoughtRaw-shaped)
  Signature (MultiChainInput i o) o2 ->  -- synthesis signature
  Program i o2

data MultiChainInput i o = MultiChainInput
  { original :: i
  , attempts :: [WithReasoning o]
  }
-- hand-written ToPrompt/ToSchema/FromModel (attempts is polymorphic in o)
```

Optional convenience constructors to consider (decide during M1; record in Decision Log):
`bestOfNWith` / `refineWith` taking an explicit `TempSchedule` and an explicit `failCount`,
with `bestOfN`/`refine` defaulting to `TempSpread 0.7 0.6` and `failCount = N`.

### Dependencies this plan consumes

- **`Shikumi.Program`** (`shikumi/src/Shikumi/Program.hs`): `Program`, `embed`/`Embed`,
  `runProgram`, `TempSchedule (..)`, `MajorityVote` (used to carry a per-attempt temperature),
  `programShape`/`ShapeEmbed`, `foldParams`, `setProgramParams` (for the M4 transparency
  assertions). Unchanged by this plan.
- **`Shikumi.Module`** (`shikumi/src/Shikumi/Module.hs`): `WithReasoning (..)`,
  `chainOfThoughtRaw` (the reasoning program for `multiChainComparison`), `predict` (for the
  advice generator and synthesis nodes). Unchanged.
- **`Shikumi.Signature`**, **`Shikumi.Schema`**, **`Shikumi.Adapter`**: the `Signature`,
  `ToSchema`/`FromModel`/`Validatable`/`ToPrompt` classes for the advice and synthesis records.
  Unchanged.
- **`Shikumi.LLM`** / **`Shikumi.Error`**: the `LLM` effect and `ShikumiError` for the `Embed`
  bodies' effect row. Unchanged.
- **EP-14** (`docs/plans/14-ambient-model-routing-and-live-native-structured-output.md`): the
  per-sample temperature wire mechanism. Hard dependency for the *live* behaviour; the modules
  are demonstrable with the stub before EP-14 lands (see Decision Log entry 3).

### Reconciliation with the `shikumi-eval` reward shape (for consumers)

`shikumi-eval` (`shikumi-eval/src/Shikumi/Eval/Metric.hs`) keeps its `Metric o = o -> Prediction
o -> Score`. A caller who already has a metric and an expected value derives a `Reward` with the
one-line adapter shown in "Context and Orientation" (`rewardFromMetric`), which belongs in
`shikumi-eval` (where both types are in scope) and is *not* part of this plan's base-package
surface. This plan owns the reward vocabulary (MasterPlan integration point #1); EP-22 (GEPA)
imports `Shikumi.Reward` and must not define a parallel reward type.

### Rejected: new `Program` GADT constructors

We considered adding `BestOfN`, `Refine`, and `MultiChainComparison` as first-class GADT
constructors (analogous to `MajorityVote`). We rejected this because it would require, for
*each* new constructor: a clause in `runProgram` and `runProgramConc`; a clause in
`paramsTraversal` (and the threading in `mapParamsAt` and `setProgramParams`); a new `Shape*`
constructor in `ProgramShape` with `ToJSON`/`FromJSON`; and a clause in `programShape`. It would
also raise a hard question — should the inner program's `Params` be exposed through the wrapper
(changing the parameter-count invariant) or hidden? Building on `Embed` sidesteps all of this:
the wrapper carries no params (invariant preserved), serializes as `ShapeEmbed`, and runs under
the existing executors with zero edits to `Program.hs`. The only thing `Embed` gives up — making
the inner program's nodes invisible to the optimizer through the wrapper — is acceptable for
inference-time self-correction modules and matches how V1's ReAct agent already behaves. If a
future need arises to optimize *through* one of these modules, that is a separate plan that would
revisit the constructor decision; this plan records the rejected design here so that future plan
has the full edit list in hand.
