---
id: 35
slug: combinator-and-budget-semantics-cleanup
title: "Combinator and Budget Semantics Cleanup"
kind: exec-plan
created_at: 2026-07-02T03:30:15Z
intention: "intention_01kwjfe4dhetqa7m7g3n6zq03a"
master_plan: "docs/masterplans/5-core-runtime-correctness-and-wire-fidelity.md"
---

# Combinator and Budget Semantics Cleanup

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan closes the tail of MEDIUM-LOW correctness findings from the production-readiness
review of the core `shikumi` package: places where the API's documentation and its behavior
disagree, or where an exported function can crash a program at runtime. Concretely, after
this plan: `majorityVoteBy` actually varies sampling temperature per sample as its
`TempSchedule` argument promises (today the schedule is silently ignored) and
`majorityVote`'s stale docstring is fixed; the budget's `tryReserve` no longer pretends to
reserve — it is renamed to what it does (optimistic admission), its worst-case overshoot
under concurrency is documented and pinned by a test; and the partial-function tail is
closed — `modal` and `chain` can no longer crash on empty input (their emptiness becomes a
compile error via `NonEmpty`), a malformed numeric bound in a `Constrained` field surfaces
as a typed `ValidationFailure` instead of a pure `error` crash, `TempSpread` can no longer
send negative temperatures to a provider, and a failed advice-generation call inside
`refine` no longer throws away a perfectly good best-so-far answer.

Each item is small; together they make the combinator and resilience surface honest before
production use. Everything is provable offline.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-03): `MajorityVote` constructor carries its reducer; `majorityVote`/`majorityVoteBy` rebuilt on it; `modal`/`sampleTemps` total via `NonEmpty`; downstream pattern matches updated (`shikumi`, `shikumi-trace`, `shikumi-compile`; also `Refine.hs` consumes `sampleTemps` via `NE.toList`)
- [x] M1 (2026-07-03): routed-temperature test for `majorityVoteBy` added; params-exposed-once test added; stale `majorityVote` docstring fixed
- [x] M2 (2026-07-03): `tryReserve` renamed to `admitCall` with honest docs; concurrent overshoot test added (barrier stub keeps four calls in flight)
- [x] M3 (2026-07-03): `chain` takes `NonEmpty` (done with M1's NonEmpty work); `parseBound` total (schema keyword dropped + decode-time `ValidationFailure` on malformed bounds); `spreadTemps` clamped to `[0, 2]` (done with M1); `refine` survives advice-call failure with best-so-far
- [x] Full matrix green (2026-07-03): `cabal build all && cabal test all` EXIT 0; CHANGELOG entry added


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Extra `sampleTemps` consumer beyond the plan's enumerated blast radius:
  `shikumi/src/Shikumi/Refine.hs` calls `sampleTemps` in two places
  (`bestOfN` and `multiChainComparison`) and treats the result as a plain list. With
  `sampleTemps` now returning `NonEmpty`, both sites were adapted with `NE.toList`
  (the reducer/loop logic is unchanged). Found by `cabal build all`.
- Test-side blast radius the plan did not enumerate: `shikumi/test/RefineStub.hs`
  (uses `modal` on a list → wrapped in `NE.fromList`) and `shikumi/test/CombinatorSpec.hs`
  (two `chain [..]` call sites → `chain (a :| [..])`). Found by `cabal build all`.
- `head` as a `majorityVoteBy` reducer in the routing test triggered `-Wx-partial`
  (partial `Prelude.head`); replaced with `NE.head . NE.fromList` to keep the build
  warning-clean.
- Pre-existing, out-of-scope warnings surfaced by the full rebuild (not caused by
  this plan, both in other master plans' packages): `shikumi-cache-postgres`
  (`Postgres.hs`, unused import/binding — master plan 7) and `shikumi-eval`
  (`EvaluateSpec.hs:27` unused import — master plan 6). Left untouched.


## Decision Log

- Decision: Fix `majorityVoteBy` by generalizing the `MajorityVote` GADT constructor to
  carry its reducer — `MajorityVote :: Int -> TempSchedule -> (NonEmpty o -> o) ->
  Program i o -> Program i o` (the `Eq o` constraint moves out of the constructor onto the
  `majorityVote` smart constructor, which passes `modal`).
  Rationale: the alternative implementations all fail a requirement. Keeping
  `majorityVoteBy = Ensemble (replicate k p) reducer` cannot ever apply per-sample
  temperatures (`Ensemble` has no temperature channel) and also mis-exposes k duplicate
  copies of the sub-program's `Params` to the optimizer. Wrapping each replica in an
  `embed` that stamps a temperature would apply the schedule but hide the sub-program's
  `Params` from `paramsTraversal` entirely. Carrying the reducer keeps exactly one
  parameter set visible (matching `majorityVote`'s existing behavior), lets both executors
  reuse the existing `sampleTemps`/`withSampleTemp` machinery, and leaves `ProgramShape`
  unchanged (the reducer is opaque and omitted, exactly like `Ensemble`'s). The cost is an
  arity change at every `MajorityVote` pattern-match site; the full site list is embedded
  in the Plan of Work. Consequence to document: a program built with `majorityVoteBy`
  changes its parameter count from k×|p| to |p|, so parameter vectors saved from old
  `majorityVoteBy` programs no longer load (`ParamCountMismatch`) — acceptable pre-1.0,
  noted in the CHANGELOG.
  Date: 2026-07-01

- Decision: Budget: keep the optimistic no-reservation semantics and rename
  `tryReserve` to `admitCall`, rather than implementing true reservation.
  Rationale: a real reservation needs a pre-call cost estimate, and baikai exposes no
  pricing/streaming cost preview (the `Shikumi.LLM.Budget` module header already concedes
  this); inventing an estimate would trade an honest, documented overshoot for a
  false-precision guarantee. The honest contract — "a call is admitted while the running
  total is under the ceiling; N concurrent calls admitted together can overshoot by up to
  N-1 times the largest single-call cost; the next call after the ceiling is reached is
  refused" — is renamed, documented, and pinned by a concurrency test.
  Date: 2026-07-01

- Decision: Totality style: emptiness that is a programmer error becomes a compile-time
  `NonEmpty` argument (`modal`, `sampleTemps` internally, `chain`); malformedness that only
  manifests at decode/render time (`parseBound`'s bound `Symbol`) becomes a deterministic
  runtime `ValidationFailure` at the decode site plus a silently-omitted schema keyword,
  because a type-level numeric parse of arbitrary `Symbol`s is not practical in GHC today.
  `TempFixed` user-supplied temperatures are passed through unclamped (explicit user
  choice); only `TempSpread`'s derived fan-out is clamped to `[0, 2]` (the widest range a
  mainstream provider accepts; OpenAI 0-2, Anthropic 0-1 — per-provider narrowing is the
  router's future concern, out of scope here).
  Date: 2026-07-01

- Decision: `refine`'s advice-generation failure (the LM call that turns a low reward into
  textual advice) is non-fatal: the loop keeps the previous advice (if any) and continues
  the remaining attempts; the `failCount` error budget is not consumed (it guards
  inner-program failures, and the advice call is auxiliary).
  Rationale: `refine`'s contract is "returns the best output seen across all attempts";
  aborting on an auxiliary call's failure while holding a valid best-so-far output violates
  that contract for no benefit.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

All three milestones delivered; the combinator and resilience surface is now honest.
`majorityVoteBy` applies its `TempSchedule` (routed test proves three distinct
temperatures) and exposes the sub-program's `Params` once (pinned test), via a
`MajorityVote` constructor that carries its reducer — threaded through every
pattern-match site in `shikumi`, `shikumi-trace`, and `shikumi-compile`. The
partial-function tail is closed: `modal`/`sampleTemps`/`chain` are total through
`NonEmpty`, `TempSpread` is clamped to `[0, 2]`, a malformed `Constrained` numeric
bound omits its schema keyword and fails decode with a located `ValidationFailure`
(no process crash), and `refine` survives a failed advice call with its best-so-far.
The budget gate is renamed `admitCall` with its optimistic overshoot documented and
pinned by a concurrency test. `cabal build all && cabal test all` is green (the only
remaining warnings are pre-existing, in other master plans' packages).

Deviations/discoveries recorded in Surprises: two extra `sampleTemps` consumers in
`Refine.hs`, two extra test-side call sites, and a `-Wx-partial` from `head`. The
plan's suggested commit split was adjusted: `chain` and the `spreadTemps` clamp
landed in the M1 commit rather than M3, because they were architecturally coupled to
the same `NonEmpty`/`sampleTemps` totality change (M3's commit is `parseBound` +
`refine` advice). No behavioral gaps versus the plan's seven acceptance criteria.


## Context and Orientation

This is a cabal multi-package Haskell repo built with GHC 9.12.4 inside the Nix dev shell:
run `nix develop .#ghc9124` from the repository root before any `cabal` command. All tests
are hermetic. Most edits land in the core `shikumi/` package; the `MajorityVote` arity
change also touches `shikumi-trace/` and `shikumi-compile/` pattern matches.

The pieces, with today's exact behavior:

MajorityVote. The `Program` GADT (`shikumi/src/Shikumi/Program.hs:182-222`) has
`MajorityVote :: (Eq o) => Int -> TempSchedule -> Program i o -> Program i o`: sample a
sub-program K times, return the modal (most frequent) output. Both executors apply the
`TempSchedule` — a per-sample temperature plan (`TempFixed` explicit list / `TempSpread
base spread` even fan-out, lines 150-169) — by stamping each sample's temperature onto the
request metadata (`sampleTemps`/`withSampleTemp`, lines 344-371), which the router turns
into `Options.temperature` on the wire. The surface combinators live in
`shikumi/src/Shikumi/Combinator.hs`: `majorityVote` (line 153-154) builds the constructor;
`majorityVoteBy` (lines 159-160) — for outputs that are not usefully `Eq`, taking a custom
`[o] -> o` reducer — is instead defined as
`majorityVoteBy k _sched reducer p = Ensemble (replicate (max 1 k) p) reducer`: the
`TempSchedule` is bound to `_sched` and ignored, so all K samples run at the provider
default temperature and (being `Ensemble` members) the sub-program's `Params` are exposed
K times to the optimizer instead of once. `majorityVote`'s docstring (lines 150-152) still
says the schedule is "carried and serialized but not yet applied to the wire", which has
been false since routing landed (see the correct story on `TempSchedule`,
Program.hs:150-161). `modal` (Program.hs:399-407) is exported ("Execution internals") and
crashes on `[]`: `pickBest [] = error "Shikumi.Program.modal: empty sample list"`.

Every `MajorityVote` pattern-match site in the repo (the arity-change blast radius):
`shikumi/src/Shikumi/Program.hs` lines 269-270 and 293-294 (executors), 443
(`paramsTraversal`), 481 (`nodeFieldsIndexed`), 504 (`nodeInstructionsIndexed`), 544-546
(`mapParamsAt`), 613 (`programShape`), 665-667 (`setProgramParams`);
`shikumi/src/Shikumi/Stream.hs:230`; `shikumi-trace/src/Shikumi/Trace/Program.hs:180-182`
(re-implements the vote with `modal`/`sampleTemps`/`withSampleTemp` imported from
`Shikumi.Program`); `shikumi-trace/src/Shikumi/Trace/Node.hs:97`;
`shikumi-compile/src/Shikumi/Compile/RAG.hs:88`;
`shikumi-compile/src/Shikumi/Compile/ChainOfThought.hs:76`. `ShapeMajorityVote` consumers
(`shikumi-optimize/src/Shikumi/Optimize/Propose/Summarize.hs:89`,
`shikumi-okf/src/Shikumi/Okf/Render.hs:82`) are unaffected — the shape type does not
change.

Budget. `Shikumi.LLM.Budget` (`shikumi/src/Shikumi/LLM/Budget.hs`) is a running US-dollar
ceiling. `tryReserve` (lines 42-47) reserves nothing: it atomically reads the spent total
and returns `spent < cap`. The resilient interpreter (`shikumi/src/Shikumi/LLM.hs:219-222`,
`withBudget`) calls it before each call and records actual cost after success — so N
concurrent calls that all start under the cap are all admitted and all charged; nothing
prevents overshoot, and nothing in the name or docs says so.

Partial-function tail. `chain` (`shikumi/src/Shikumi/Combinator.hs:85-87`) is
`chain [] = error "Shikumi.Combinator.chain: empty stage list"`. `parseBound`
(`shikumi/src/Shikumi/Schema.hs:392-395`) reflects the type-level bound `Symbol` of a
`MinVal`/`MaxVal` field constraint (e.g. `Constrained '[MinVal "0"] Int`) into a
`Scientific`, and calls `error` on an unparseable symbol (e.g. `MinVal "abc"`) — a runtime
crash triggered the first time the schema is derived or a value is checked. `spreadTemps`
(`shikumi/src/Shikumi/Program.hs:352-357`) fans K temperatures across
`[base-spread, base+spread]` with no clamping — `TempSpread 0.1 0.5` yields `-0.4`, which
providers reject. In `shikumi/src/Shikumi/Refine.hs`, `refineWith` (lines 226-252) loops
attempts, keeps the best output by reward, and on a sub-threshold attempt calls
`generateAdvice` (line 247) — an LM call — with no error handling: if it throws, the whole
`refine` aborts even when `best'` holds a returnable output (the module's `tryShikumi`
helper, used at line 231 for the inner program, shows the intended pattern).

Test infrastructure to reuse: `shikumi/test/RoutingSpec.hs` (capturing stub + router; its
temperature tests at lines 145-172 are the model for the new `majorityVoteBy` test),
`shikumi/test/CombinatorSpec.hs` (scripted-stub combinator tests; `majorityVoteBy` case at
line 268, `chain` case at line 173), `shikumi/test/ResilienceSpec.hs` +
`shikumi/test/StubProvider.hs` (`costStubRegistry` serves fixed-cost responses;
`concurrencyStubRegistry` instruments concurrency), `shikumi/test/ConstraintSpec.hs`
(EP-26 `Constrained` fields), `shikumi/test/RefineSpec.hs` + `shikumi/test/RefineStub.hs`.

Coordination: EP-32/EP-34 also edit `shikumi/src/Shikumi/Stream.hs` and
`shikumi/src/Shikumi/Program.hs` (master plan integration point 2); this plan's edits
there are disjoint from theirs (constructor/temperature regions) and rebase mechanically.


## Plan of Work

Milestone 1 — an honest MajorityVote family. Scope: the GADT constructor, both executors,
the traversals, the two surface combinators, and every pattern-match site listed in
Context. At the end, `majorityVoteBy` sends K distinct temperatures to the wire under
routing, `modal` cannot crash, and the docs match behavior.

In `shikumi/src/Shikumi/Program.hs`:

- Change the constructor (line 208) to
  `MajorityVote :: Int -> TempSchedule -> (NonEmpty o -> o) -> Program i o -> Program i o`
  and update its haddock (the reducer is opaque to traversal/serialization, like
  `Ensemble`'s; `majorityVote` passes `modal`). Import `Data.List.NonEmpty (NonEmpty (..))`
  qualified as needed.
- Make `sampleTemps` total and non-empty: signature becomes
  `sampleTemps :: Int -> TempSchedule -> NonEmpty (Maybe Double)` (clamp
  `k' = max 1 k` inside, moving the `max 1 k` out of the executors). Make `modal` total:
  `modal :: (Eq o) => NonEmpty o -> o`, deleting the `pickBest [] = error …` line (the
  fold seeds from the head). Both are exported "execution internals" — their consumers are
  enumerated below.
- Executors (lines 269-270 and 293-294) become
  `reduce <$> traverse (\mt -> withSampleTemp mt (run p i)) (sampleTemps k sched)` with the
  matched reducer (`traverse` over `NonEmpty` yields `NonEmpty o`;
  `mapConcurrently` in the concurrent executor is `Traversable`-polymorphic and accepts
  `NonEmpty` unchanged).
- Mechanically thread the extra field through `paramsTraversal` (443),
  `nodeFieldsIndexed` (481), `nodeInstructionsIndexed` (504), `mapParamsAt` (544-546),
  `programShape` (613 — `ShapeMajorityVote` keeps only `Int` and `TempSchedule`; the
  reducer is omitted like `Ensemble`'s), `setProgramParams` (665-667).

In `shikumi/src/Shikumi/Combinator.hs`:

- `majorityVote :: (Eq o) => Int -> TempSchedule -> Program i o -> Program i o` becomes
  `majorityVote k sched = MajorityVote k sched modal` (import `modal` from
  `Shikumi.Program`; it is already exported). Rewrite the stale docstring (lines 150-152):
  the schedule is live — each sample's temperature is stamped and realized by the router.
- `majorityVoteBy :: Int -> TempSchedule -> ([o] -> o) -> Program i o -> Program i o`
  (public signature unchanged, so existing callers compile) becomes
  `majorityVoteBy k sched reducer = MajorityVote k sched (reducer . NE.toList)`. Update its
  haddock: it now applies the schedule and exposes the sub-program's `Params` once (not K
  times).

Downstream pattern matches (arity only, plus the two substantive ones):
`shikumi/src/Shikumi/Stream.hs:230` (`MajorityVote {}` or a 4-hole wildcard — it already
falls to `blockingNode`); `shikumi-trace/src/Shikumi/Trace/Program.hs:180-182` — use the
carried reducer instead of `modal` so traced runs agree with untraced ones:
`reduce <$> traverse (\mt -> withSampleTemp mt (go (StepMajorityVote : prefix) p i)) (sampleTemps k sched)`;
`shikumi-trace/src/Shikumi/Trace/Node.hs:97` (`MajorityVote _ _ _ p`);
`shikumi-compile/src/Shikumi/Compile/RAG.hs:88` and
`shikumi-compile/src/Shikumi/Compile/ChainOfThought.hs:76`
(`MajorityVote k sched r p -> MajorityVote k sched r (go p)` — carry the reducer through).
Let `cabal build all` find anything the list missed and record it in Surprises &
Discoveries.

Tests. In `shikumi/test/RoutingSpec.hs`, clone `spreadSetsDistinctTemps` (lines 145-156)
for `majorityVoteBy`: route
`majorityVoteBy 3 (TempSpread 0.5 0.4) pickFirst (predict topicToOutline)` (any total
reducer, e.g. `head`-like via pattern match on the non-empty list) and assert three
captured temperatures `[0.1, 0.5, 0.9]` after rounding. Before the fix this fails with
zero captured temperatures (the schedule was ignored). In `shikumi/test/CombinatorSpec.hs`
the existing `majorityVoteBy` reducer case (line 268) must keep passing; add an assertion
that `length (foldParams (majorityVoteBy 3 sched1 concatCells cellP)) == 1` to pin the
corrected params exposure (before: 3). All existing MajorityVote/temperature tests
(`RoutingSpec`, `CombinatorSpec`, trace specs) must stay green.

Milestone 2 — honest budget admission. Scope: `Shikumi.LLM.Budget`, its one caller, and a
concurrency test. At the end the name, docs, and a test agree on what the gate does.

In `shikumi/src/Shikumi/LLM/Budget.hs`: rename `tryReserve` to `admitCall` (update the
export list; no deprecated alias — the survey found exactly one caller). Rewrite its
haddock and the module header's "enforced before a call by an optimistic `tryReserve`
check" sentence to the honest contract: admission, not reservation; the running total is
compared to the ceiling and nothing is held; with N calls in flight concurrently the total
may overshoot the ceiling by up to the sum of their costs; once the recorded total reaches
the ceiling every subsequent admission is refused. In `shikumi/src/Shikumi/LLM.hs`: update
the import (line 79) and the call in `withBudget` (line 221); extend `withBudget`'s and
`LLMConfig.budget`'s haddocks with the same contract.

Test, in `shikumi/test/ResilienceSpec.hs` (model: the existing budget case at lines 71-80
and the concurrency case at 81+): build a budget with a cap equal to one call's cost using
`newBudget` and `costStubRegistry`; run four `complete` calls concurrently (via
`Effectful.Concurrent.Async.mapConcurrently` inside `runLLMResilient` with the budget set —
the calls must overlap, so gate them on a shared `TVar` barrier or reuse
`concurrencyStubRegistry`'s instrumentation if it can carry cost; choose the simplest
arrangement that makes all four pass `admitCall` before any `recordCost` lands and note it
in the test comment). Assert: all four concurrent calls succeed (documented overshoot),
`spentUSD` afterwards exceeds the cap, and a fifth sequential call fails with
`BudgetExceeded`. This is a pin of documented semantics, not a fix of them — it will also
pass before the rename; its purpose is to freeze the contract the rename documents.

Milestone 3 — the partial-function tail. Scope: four independent fixes, each with a test
that fails before and passes after (except where noted).

`chain`. In `shikumi/src/Shikumi/Combinator.hs:85-87`: change to
`chain :: NonEmpty (Program a a) -> Program a a`, `chain ps = foldr1 (>>>) (NE.toList ps)`
(import `Data.List.NonEmpty`); delete the `error` clause and the "programmer error"
haddock paragraph — emptiness is now unrepresentable. Update the one in-repo caller
(`shikumi/test/CombinatorSpec.hs:173` area) and survey for others:
`grep -rn "chain " --include='*.hs' shikumi* | grep -v dist-newstyle`. This is a breaking
signature change; mark the commit `!` and add a CHANGELOG migration line
(`chain [a, b, c]` becomes `chain (a :| [b, c])`).

`parseBound`. In `shikumi/src/Shikumi/Schema.hs:392-395`: change to
`parseBound :: forall s. (KnownSymbol s) => Proxy s -> Maybe Scientific` (drop the
`error`). Update the four use sites in the `MinVal`/`MaxVal` `ReflectConstraints`
instances (lines 353-363): `constraintSchema` applies the keyword only when the bound
parses (`maybe id withMinimum (parseBound (Proxy @s))`); `checkConstraints` returns
`Left ("invalid numeric bound symbol: " <> T.pack (symbolVal (Proxy @s)))` when it does
not, otherwise compares as today. Result: a malformed bound can no longer crash the
process — schema derivation silently omits the keyword and every decode of that field
fails with a located `ValidationFailure` naming the bad symbol. Test in
`shikumi/test/ConstraintSpec.hs`: a fixture with `Constrained '[MinVal "abc"] Int`; assert
(a) `deriveSchema` contains no `"minimum"` for that field and (b) decoding any value
yields `Left (ValidationFailure …)` mentioning `"abc"`. Before the fix, (a)/(b) crash with
`error "Shikumi.Schema: invalid numeric bound symbol abc"`.

`spreadTemps`. In `shikumi/src/Shikumi/Program.hs:352-357`: clamp every generated value —
`clampTemp t = max 0 (min 2 t)` applied to each element (and to the single-sample `[base]`).
Haddock: derived temperatures are clamped to `[0, 2]`; `TempFixed` values are the user's
explicit choice and pass through unclamped. Test in `shikumi/test/ProgramSpec.hs` or
`CombinatorSpec.hs`: `sampleTemps 3 (TempSpread 0.1 0.5)` contains no negative value and
still centers on `0.1`; routed variant optional. Before the fix the lowest sample is
`Just (-0.4)`.

`refine` advice failure. In `shikumi/src/Shikumi/Refine.hs`, replace line 247's
`adv <- generateAdvice r threshold` with a guarded version using the module's existing
`tryShikumi` helper:

```haskell
advE <- tryShikumi (generateAdvice r threshold)
let mAdvice' = either (const mAdvice) Just advE
go (k + 1) best' lastErr mAdvice' budget
```

— on failure the loop continues with the previous advice (or none) and `failCount` is
untouched (per the Decision Log). Haddock the behavior on `refineWith`. Test in
`shikumi/test/RefineSpec.hs` using the `RefineStub` scripting: attempt 1 returns a
sub-threshold output, the advice call is scripted to fail (e.g. an unparseable advice
response), attempt 2 returns sub-threshold again; assert `refine` returns the best-so-far
output. Before the fix it returns the advice call's error.

Finish with a CHANGELOG entry covering: `majorityVoteBy` now applies its schedule and
exposes params once (saved param vectors for such programs need re-saving), `chain` takes
`NonEmpty`, `modal`/`sampleTemps` take/return `NonEmpty`, `tryReserve` renamed
`admitCall`, `TempSpread` clamping, `Constrained` malformed-bound behavior, `refine`
advice resilience.


## Concrete Steps

All commands run from the repository root (`/Users/shinzui/Keikaku/bokuno/shikumi`),
inside the dev shell (GHC 9.12.4 is required and only the shell provides it):

```bash
nix develop .#ghc9124
cabal build shikumi
cabal test shikumi          # or: just test-one shikumi
```

M1 touches three packages — use the full build as the pattern-match oracle after the
constructor change:

```bash
cabal build all
```

Expected before the downstream fixes: errors like

```text
shikumi-trace/src/Shikumi/Trace/Program.hs:180:16: error: [GHC-83865]
    • The constructor ‘MajorityVote’ should have 4 arguments, but has been given 3
```

Write each milestone's failing test first. Expected pre-fix output for the M1 routing
test:

```text
  majorityVoteBy spread sets distinct per-sample temperatures: FAIL
    expected: 3
     but got: 0
```

and for the M3 refine test:

```text
  advice-call failure returns best-so-far: FAIL
    expected: Right (Sentence ...)
     but got: Left (...)
```

Finish with the full matrix:

```bash
cabal build all && cabal test all
```

Every commit uses a conventional-commit subject and MUST carry these trailers:

```text
MasterPlan: docs/masterplans/5-core-runtime-correctness-and-wire-fidelity.md
ExecPlan: docs/plans/35-combinator-and-budget-semantics-cleanup.md
Intention: intention_01kwjfe4dhetqa7m7g3n6zq03a
```

Suggested split: `feat(program)!: MajorityVote carries its reducer; majorityVoteBy applies
its TempSchedule`, `refactor(budget): rename tryReserve to admitCall and document
admission semantics`, `fix(combinator)!: close the partial-function tail (chain,
parseBound, spreadTemps, refine advice)`.


## Validation and Acceptance

Acceptance is behavioral, all offline:

1. `majorityVoteBy 3 (TempSpread 0.5 0.4) reducer p` under `runRouting … routeLLM` sends
   three requests with temperatures `0.1 / 0.5 / 0.9` (fails before with none set), and
   `foldParams` sees the sub-program's params once (before: three times). The custom
   reducer still folds the samples (existing CombinatorSpec case green).
2. With a budget cap of one call's cost, four overlapping calls are all admitted and
   charged (overshoot pinned), and the next call is refused with `BudgetExceeded`; the
   symbol `tryReserve` no longer exists
   (`grep -rn "tryReserve" --include='*.hs' shikumi* | grep -v dist-newstyle` is empty).
3. `chain` on an empty list is a compile error, not a runtime crash; `modal` cannot be
   applied to `[]` (its argument is `NonEmpty`).
4. A `Constrained '[MinVal "abc"] Int` field derives a schema without `"minimum"` and
   every decode of it returns `Left (ValidationFailure …)` naming `abc` — no `error` call
   (before: process crash on first schema derivation).
5. `sampleTemps 3 (TempSpread 0.1 0.5)` contains no temperature outside `[0, 2]` (before:
   `-0.4`).
6. `refine` whose advice call fails returns the best sub-threshold output seen (before:
   the advice error aborts the run).
7. `cabal build all && cabal test all` green, including `shikumi-trace` and
   `shikumi-compile` suites (their MajorityVote behavior — traced spans, program rewrites —
   is unchanged apart from the carried reducer).


## Idempotence and Recovery

All steps are source edits plus hermetic tests; safe to re-run. M1 is the only cross-
package change: land it as one commit so no intermediate tree has mismatched constructor
arities. If M1 must be rolled back after later milestones land, it is independent of M2/M3
(different files/functions except the shared `Program.hs`, where M1 touches the
constructor/executors and M3 touches only `spreadTemps`). The parameter-count consequence
for saved `majorityVoteBy` param vectors is data-compatibility, not code: recovery is
re-saving the vector from the rebuilt program (`programParams`), noted in the CHANGELOG.


## Interfaces and Dependencies

End-state signatures (full module paths):

- `Shikumi.Program`:
  `MajorityVote :: Int -> TempSchedule -> (NonEmpty o -> o) -> Program i o -> Program i o`
  (GADT constructor, exported pattern);
  `modal :: (Eq o) => NonEmpty o -> o`;
  `sampleTemps :: Int -> TempSchedule -> NonEmpty (Maybe Double)`;
  `spreadTemps` stays internal, clamped; `ProgramShape`/`ShapeMajorityVote` unchanged.
- `Shikumi.Combinator`:
  `majorityVote :: (Eq o) => Int -> TempSchedule -> Program i o -> Program i o` (unchanged
  signature, new definition);
  `majorityVoteBy :: Int -> TempSchedule -> ([o] -> o) -> Program i o -> Program i o`
  (unchanged signature, schedule now applied);
  `chain :: NonEmpty (Program a a) -> Program a a` (breaking).
- `Shikumi.LLM.Budget`: `admitCall :: Budget -> IO Bool` replaces `tryReserve`;
  `newBudget`/`recordCost`/`spentUSD` unchanged.
- `Shikumi.Schema`: `parseBound :: (KnownSymbol s) => Proxy s -> Maybe Scientific`
  (internal); `ReflectConstraints` instances for `MinVal`/`MaxVal` adopt the
  omit-keyword/fail-decode behavior. Exported names unchanged.
- `Shikumi.Refine`: `refine`/`refineWith` signatures unchanged; advice failure is
  non-fatal.

Dependencies: `base`'s `Data.List.NonEmpty` (no new packages); `effectful`'s
`mapConcurrently` (already `Traversable`-polymorphic). Known consumers of the changed
internals, to update in the same commit: `shikumi-trace` (`Trace/Program.hs`,
`Trace/Node.hs` — uses `modal`, `sampleTemps`, `withSampleTemp`, and matches
`MajorityVote`), `shikumi-compile` (`RAG.hs`, `ChainOfThought.hs`). Coordination with
EP-32/EP-34 on `Program.hs`/`Stream.hs` per master plan integration point 2 (disjoint
regions; rebase mechanically).
