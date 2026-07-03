---
id: 37
slug: enforce-the-optimizer-budget-contract
title: "Enforce the Optimizer Budget Contract"
kind: exec-plan
created_at: 2026-07-02T03:30:15Z
intention: "intention_01kwjfeaf8e86bvx2arbh7nk2c"
master_plan: "docs/masterplans/6-optimizer-and-evaluation-correctness.md"
---

# Enforce the Optimizer Budget Contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

shikumi's optimizers search for better prompt parameters by making language-model (LM)
calls: proposer calls that generate candidate instructions, teacher runs that generate
candidate demonstrations, and scoring evaluations that run a candidate program over a
training dataset. LM calls cost real money, so the framework exposes a `Budget` type
(`shikumi-optimize/src/Shikumi/Optimize/Types.hs:74-80`) whose documentation
(lines 69–73) promises: optimizers "count the calls they make … and stop — returning
the best candidate found so far — before any bound is exceeded, so they never silently
produce an unscored program and never blow a cost ceiling."

Today only three code paths honor that promise (`instructionSearch`, `copro`, and
MIPROv2's phase-3 `searchJoint`), and even those under-count multi-node programs (they
charge one call per dataset example, but a program with N `Predict` nodes makes N calls
per example). Everything else violates the contract outright: `selectBest` enforces only
the candidate ceiling and lets scoring calls run unbounded; `labeledFewShot` hardcodes
`defaultBudget` and accepts no budget at all; MIPROv2's phases 1–2 (teacher runs over
the whole trainset, proposer calls) spend without counting; GEPA spends a whole-dataset
seed evaluation before its first budget check; `bootstrapFewShotWith` charges a
multi-node teacher run as one call; `bootstrapRandomSearchWith` hands each inner
bootstrap the full budget independently and never counts its own scoring; and
`ensembleSearch` has no budget whatsoever. A user who sets `maxLmCalls = 200` can spend
thousands of calls.

After this change there is one enforcement seam — a `BudgetMeter` threaded through the
shared scoring plumbing in `Shikumi.Optimize.Search` — every shipped optimizer routes
its spending through it, the `Budget` haddock states the accounting model honestly
(including exactly where the count is an estimate rather than an exact tally), and a
budget test exists for every optimizer, each run under a counting stub LM that verifies
the real number of LM calls stays within the promised bound.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-07-03: M1: `BudgetMeter` seam (`newBudgetMeter`, `tryCharge`, `meteredScore`,
      `selectBestMetered`, `withLmCallCount`) in Search.hs with unit tests
- [x] 2026-07-03: M2: rewire `instructionSearch`, `copro`, and `searchJoint` onto the meter
      (replacing their hand-rolled counters), with the per-candidate cost corrected to
      `datasetSize × nodes`
- [x] 2026-07-03: M3: `labeledFewShotWith` (budget-parameterized) + metered scoring; back-compat
      `labeledFewShot`
- [x] 2026-07-03: M4: MIPROv2 phases 1–2 metered (teacher runs, proposer calls) sharing one meter
      with phase 3
- [x] 2026-07-03: M5: GEPA seed-evaluation gate
- [x] 2026-07-03: M6: bootstrap per-teacher-run accounting; random search shares one meter across
      inner bootstraps and its own scoring
- [x] 2026-07-03: M7: `ensembleSearchWith` with exact call counting between members
- [x] 2026-07-03: M8: rewrite the `Budget` haddock (Types.hs) to the honest accounting model;
      per-optimizer budget tests under the counting stubs; `cabal test all` green


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-03: M3's labelled-few-shot budget test uses the existing 4-example fixture
  rather than creating a separate 6-example fixture. Under the old unbudgeted
  `labeledFewShot 2` path this fixture scores all 6 size-2 demo sets, which is 24
  LM completions. The new `labeledFewShotWith (Budget { maxLmCalls = 6,
  maxCandidates = 100 }) 2` test stops after one 4-call scoring evaluation and
  asserts the actual counter is `<= 6`.

- 2026-07-03: M4's tiny-budget MIPROv2 test uses `maxLmCalls = 4` on the 4-example
  joint fixture. Before this milestone, the run necessarily spent 4 teacher calls,
  5 proposer calls, and at least a 4-call baseline search evaluation, so it could
  not satisfy the bound. With one shared meter, the test observes only work that
  fits the shared ceiling and asserts the actual counter is `<= 4`.

- 2026-07-03: M5's GEPA seed-gate test uses `maxLmCalls = 1` on a 2-example,
  single-node fixture. The seed evaluation costs 2 predicted completions, so the
  optimizer now returns the student before evaluation; `withLmCallCount` observes
  exactly 0 LM calls.

- 2026-07-03: M6's bootstrap regression uses a 4-example trainset, a two-node
  teacher, and `maxLmCalls = 6`. The old prefix-by-example accounting would run all
  4 examples and spend 8 actual completions; `bootstrapKeptDemos` now gates each
  teacher run at cost 2 and the test asserts actual calls are `<= 6`. The random
  search regression uses 5 seeds with `maxLmCalls = 20`; the previous implementation
  handed a full budget to each inner bootstrap and then scored candidates on top,
  while the new implementation shares one meter across seed demo recovery and final
  scoring and asserts actual calls are `<= 20`.

- 2026-07-03: M7's ensemble test sets `maxLmCalls = 1` around
  `ensembleSearchWith ... 5 (labeledFewShot 1)`. The first member spends 4 actual
  completions, so the documented between-member enforcement returns a one-member
  ensemble and stops before launching members 2-5; the test asserts both the
  one-member shape and the exact 4-call spend.

- 2026-07-03: M8 added the final coverage gaps: `knnFewShot` and
  `knnFewShotCentroid` are asserted to make exactly 0 optimizer-time LM calls, and
  the `miprov2 Miprov2Light` wrapper is counted against `defaultBudget`. The full
  optimize matrix is 69 tests, and `cabal test all` passed after the docs/test
  updates.


## Decision Log

- Decision: One enforcement seam — a `BudgetMeter` (two `IORef` counters behind the
  already-required `Prim` effect, plus the `Budget`) with `tryCharge`/`meteredScore`
  helpers in `Shikumi.Optimize.Search` — instead of eight per-optimizer counter
  threads.
  Rationale: The existing three counters are already divergent copies of one idea; five
  more copies would guarantee future drift. A meter travels as a value, needs no effect
  beyond `Prim` (already in the `Optimizer` rank-2 row), and gives tests a single
  behavior to characterize. This was the review's recommendation.
  Date: 2026-07-01 (source: production-readiness code review)

- Decision: Primary accounting is predicted-cost gating (charge
  `datasetSize × max 1 (predictNodeCount candidate)` per scoring evaluation,
  `max 1 (predictNodeCount teacher)` per teacher run, `4 + numCandidates` per grounded
  proposer call — the proposer's documented exact cost), not post-hoc exact counting.
  Exact counting via an LLM-effect `interpose` is used only where the spender is opaque
  (`ensembleSearch`'s inner optimizer).
  Rationale: The contract says "stop before any bound is exceeded", which requires
  knowing a spend's cost before making it; the predicted cost is exact for programs
  without `Retry`/`RetryWhen`/`MajorityVote`/`Embed` wrappers and a documented lower
  bound otherwise. Rebuilding every optimizer around post-hoc counting would change
  semantics (overshoot then stop) and churn every existing budget test.
  Date: 2026-07-01

- Decision: Degenerate budgets (too small to score even one candidate, e.g. GEPA with
  `maxLmCalls < datasetSize`) return the input program unscored, and the `Budget`
  haddock says so explicitly, replacing the current "never silently produce an unscored
  program" phrasing.
  Rationale: When nothing can be scored, the input is the only never-worse answer;
  erroring would make small budgets a footgun. Honesty in the doc beats an
  unimplementable absolute.
  Date: 2026-07-01

- Decision: Keep every existing public optimizer signature; add `-With` variants where
  a budget parameter was missing (`labeledFewShotWith`, `ensembleSearchWith`), with the
  old names delegating to the new ones under `defaultBudget`.
  Rationale: `labeledFewShot` and `ensembleSearch` have callers in `shikumi-cli`,
  `shikumi-jitsurei`, and tests; a compatible surface keeps this plan mergeable without
  cross-package churn. `ensembleSearch` gaining a default cap is a behavior change and
  is documented as such in its haddock.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-07-03: EP-37 is complete. The optimizer package now has one shared
  `BudgetMeter` seam for predicted LM-call and candidate accounting; every shipped
  optimizer either routes spending through it or, for `ensembleSearchWith`, counts
  opaque inner optimizers exactly between members. The public API stays compatible:
  existing names still work, and explicit-budget variants were added where they were
  missing (`labeledFewShotWith`, `ensembleSearchWith`). The `Budget` haddock now
  states the implemented accounting model, including predicted-cost lower bounds for
  wrappers, one-member ensemble overshoot, and the degenerate-budget return of the
  input program. Validation passed with `cabal test shikumi-optimize-test` and
  `cabal test all`.


## Context and Orientation

This section assumes no prior repository knowledge.

The workspace is a cabal multi-package project; this plan works almost entirely inside
`shikumi-optimize`. Key concepts:

- A `Program i o` (core package `shikumi`, `shikumi/src/Shikumi/Program.hs`) is a tree
  of `Predict` nodes; `foldParams p` lists one `Params` per `Predict` node, so
  `length (foldParams p)` is the node count. Running a program makes (at least) one LM
  call per `Predict` node; `Retry`/`MajorityVote`/`Embed` wrappers can make more.
- An `Optimizer i o` (`shikumi-optimize/src/Shikumi/Optimize/Types.hs:56-67`) is a
  newtype over a rank-2 driver
  `Dataset i o -> Metric o -> Program i o -> Eff es (CompiledProgram i o)` whose effect
  row is `(LLM, Concurrent, Error ShikumiError, Time, Prim)`. `Prim` provides `IORef`s
  (`Effectful.Prim.IORef`), which is what the meter uses — no row change is needed.
- `Budget { maxLmCalls :: Int, maxCandidates :: Int }` (Types.hs:74-80) with
  `defaultBudget = Budget 200 32`. Its haddock (lines 69–73) is the contract this plan
  makes true.
- `Shikumi.Optimize.Search` (`shikumi-optimize/src/Shikumi/Optimize/Search.hs`) is the
  shared plumbing: `scoreOn ds m p` runs one full evaluation (one LM call per example
  per node) and returns the aggregate; `selectBest` (lines 38–55) folds a scorer over
  candidates but enforces only `maxCandidates` (line 47) — its scoring calls are
  unbounded. Note: plan 36 (`docs/plans/36-fix-optimizer-instruction-seeding.md`,
  sequenced before this plan) adds `effectiveInstructionAt`/`setNodeInstrIfNew` here;
  build on the file as it stands after that plan.

The violations, by file (verified against the current tree):

- `Search.hs:46-48` — `selectBest` takes only `maxCandidates` candidates; each scoring
  call (a full-dataset evaluation) is uncounted against `maxLmCalls`.
- `LabeledFewShot.hs:30` — `labeledFewShot` passes the hardcoded `defaultBudget` to
  `selectBest`; there is no budget parameter, and scoring calls are uncounted (see
  above).
- `MIPRO.hs:163-172` — phase 1 runs the teacher over every training example with no
  counting; `MIPRO.hs:195-212` — phase 2 makes one grounded-proposer call per node
  (`4 + numCandidates` LM calls each, per `Propose/Grounded.hs:95-96`) uncounted. Only
  phase 3 (`searchJoint`, lines 244–275) threads a counter.
- `GEPA.hs:223` — `seedRpt <- evaluatePure train metric student` spends `datasetSize`
  calls before the loop's first budget check (the loop then starts at `calls = n`,
  line 252, so the spend is retro-counted but never pre-gated).
- `Bootstrap.hs:76-77` — `take (max 0 (maxLmCalls budget)) (datasetExamples train)`
  counts each teacher run as exactly one call; a multi-node teacher under-counts by a
  factor of its node count.
- `RandomSearch.hs:79-90` — each seed's inner `bootstrapFewShotWith … budget` receives
  the full budget independently (line 83), and the final `selectBest budget (scoreOn …)`
  (line 87) adds uncounted scoring on top; worst case ≈
  `numCandidates × maxLmCalls + (numCandidates + 1) × datasetSize`.
- `Ensemble.hs:27-34` — `ensembleSearch size inner` runs the inner optimizer `size`
  times with no budget of its own; total spend is `size ×` whatever the inner optimizer
  spends.

Test infrastructure you will reuse: `shikumi-optimize/test/StubLM.hs` provides
`runStubLMCounting` and `runJointStubLMCounting` (an `IORef Int` incremented on every
`Complete`), which measure the *actual* number of LM calls an optimizer makes — the
ground truth every budget test asserts against. Existing budget tests (grep for
`maxLmCalls` under `shikumi-optimize/test/`) cover `instructionSearch`, `copro`, and
MIPROv2 phase 3 only.

Build/test: from the repository root, `nix develop .#ghc9124`, then
`cabal test shikumi-optimize` (or `just test-one shikumi-optimize`).


## Plan of Work

### Milestone 1 — the BudgetMeter seam

Scope: the shared enforcement mechanism, fully unit-tested, plus the exact-counting
interpose helper. Nothing else changes yet.

In `shikumi-optimize/src/Shikumi/Optimize/Search.hs`, add (and export):

```haskell
-- | Mutable spend-tracking for one optimizer run: the budget plus two counters
-- (predicted LM calls charged, candidates scored) behind the ambient 'Prim'
-- effect. Created once per 'runOptimizer' invocation and threaded as a value.
data BudgetMeter = BudgetMeter
  { meterBudget :: !Budget,
    meterCalls :: !(IORef Int),
    meterCands :: !(IORef Int)
  }

newBudgetMeter :: (Prim :> es) => Budget -> Eff es BudgetMeter

-- | Charge @n@ predicted LM calls if and only if they fit under 'maxLmCalls';
-- returns 'False' (charging nothing) when they would not. @n <= 0@ charges
-- nothing and succeeds.
tryCharge :: (Prim :> es) => BudgetMeter -> Int -> Eff es Bool

-- | The predicted LM-call cost of scoring @p@ over @ds@ once: one call per
-- example per Predict node. Exact for plain predict/compose programs; a lower
-- bound under Retry/MajorityVote/Embed wrappers (see the 'Budget' haddock).
scoringCost :: Dataset i o -> Program i o -> Int
scoringCost ds p = datasetSize ds * max 1 (length (foldParams p))

-- | Score one candidate program under the meter: 'Nothing' (nothing spent, no
-- evaluation run) when either the candidate ceiling is reached or the predicted
-- scoring cost does not fit; otherwise charge, bump the candidate count, and
-- return 'Just' the aggregate score.
meteredScore ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  BudgetMeter -> Dataset i o -> Metric o -> Program i o -> Eff es (Maybe Double)

-- | 'selectBest' under a meter: walks candidates in order, stops at the first
-- 'Nothing' from the scorer, returns the best scored so far.
selectBestMetered ::
  BudgetMeter -> (cand -> Eff es (Maybe Double)) -> [cand] -> Eff es (Maybe (Scored cand))

-- | Run an action while counting every LLM operation ('Complete' and 'Stream'
-- alike) via 'interpose' — the exact tally, used where a spender is opaque
-- (ensemble members) and by tests.
withLmCallCount :: (LLM :> es, Prim :> es) => Eff es a -> Eff es (a, Int)
```

Implementation notes: `tryCharge` must be a single `atomicModifyIORef'` (read-check-add
in one step) so concurrent scoring inside one evaluation cannot race the counter;
`selectBestMetered` is `selectBest` minus the `take` (the meter's candidate counter
replaces it) — keep tie-breaking "earliest wins" identical (strict `>`);
`withLmCallCount` mirrors the shape of `Shikumi.Eval.Usage.withUsageTotals`
(`interpose`, forward the operation, bump the ref). New imports: `Effectful.Prim.IORef`
(`IORef`, `newIORef`, `readIORef`, `atomicModifyIORef'`), `Effectful.Dispatch.Dynamic
(interpose)`, `Shikumi.LLM (LLM (..), complete, stream)`, `Shikumi.Eval (datasetSize)`.

Unit tests in `shikumi-optimize/test/SearchSpec.hs` (created by plan 36; extend it):
`tryCharge` refuses an over-budget charge and leaves the counter unchanged;
`meteredScore` returns `Nothing` without invoking the LM when the cost does not fit
(assert via `runStubLMCounting` that the counter stayed 0); `selectBestMetered` stops
at the ceiling and still returns the best-so-far; `withLmCallCount` counts a known
number of `runProgram` invocations.

### Milestone 2 — rewire the three existing counters

Scope: `instructionSearch` (`Instruction.hs`), `copro` (`COPRO.hs`), and `searchJoint`
(`MIPRO.hs`) drop their hand-threaded `calls` integers and use one `BudgetMeter`
created at the top of their drivers. Behavioral deltas, both intended: the
per-candidate scoring cost becomes `scoringCost train candidate` (was `datasetSize` —
the multi-node under-count fixed), and candidate ceilings previously enforced only in
COPRO's `scoreNew` become uniform via `meteredScore`. Proposer spends keep their
documented predicted cost (`proposerCost = 4 + numProposals`), now spent through
`tryCharge` (skip the proposer and fall back to `[currentInstruction]` when it does not
fit — the same fallback the code has today). Update each module's Budget paragraph in
its haddock. `searchJoint` keeps its exported signature; internally it constructs its
meter from `budget cfg` — when M4 lands, `miprov2With` will instead pass a shared meter
through an internal `searchJointWith :: BudgetMeter -> …` and the exported `searchJoint`
becomes a thin wrapper that makes a fresh meter.

Existing budget tests must stay green with unchanged constants where the fixture
programs are single-node (cost model identical there). Add one new test: a two-node
program (plan 36's `sentimentPipeline` from `StubLM.hs`) under `runStubLMCounting` with
`maxLmCalls = k`; assert the counted calls are `<= k` — before this milestone the
per-example charge of 1 instead of 2 lets the real count reach nearly `2k`.

### Milestone 3 — labeledFewShot

Scope: budget parameterization plus metered scoring. In
`shikumi-optimize/src/Shikumi/Optimize/LabeledFewShot.hs` add
`labeledFewShotWith :: (ToJSON i, ToJSON o) => Budget -> Int -> Optimizer i o` whose
driver creates a meter and calls
`selectBestMetered meter (\ds -> meteredScore meter train metric (withDemos ds prog))
(labeledCandidateSets k train)`; redefine
`labeledFewShot k = labeledFewShotWith defaultBudget k` (line 27–33 today). Export the
new name from `LabeledFewShot.hs` and from the umbrella `Shikumi.Optimize` module
(check its export list in `shikumi-optimize/src/Shikumi/Optimize.hs`). Callers
(`shikumi-cli/src/Shikumi/Cli/Example.hs:76`, `shikumi-jitsurei/app/Optimize.hs:50`,
tests) compile unchanged.

Test: `labeledFewShotWith (Budget { maxLmCalls = 8, maxCandidates = 100 }) 2` over the
6-example trainset under `runStubLMCounting` — scoring one candidate costs 6, so
exactly one candidate is scored; assert counted calls `<= 8`. Before this milestone the
same search scores up to 32 candidates (~192 calls); write the test first and record
the failing count.

### Milestone 4 — MIPROv2 phases 1–2

Scope: all three phases share one meter. In `MIPRO.hs`, `miprov2With` creates the meter
from `budget cfg` and passes it to all three phase functions (change their internal
signatures; keep the exported names working by giving each exported phase function a
fresh-meter wrapper, since they are exported for tests). Phase 1
(`bootstrapDemoCandidates`): before each teacher run, `tryCharge meter (max 1 (length
(foldParams teacher)))`; on `False`, stop iterating examples and build candidate sets
from whatever was kept so far (possibly none — the labelled set needs no LM calls and
is always available). Phase 2 (`proposeInstructionCandidates`): per node,
`tryCharge meter (4 + max 0 (numInstructCandidates cfg - 1))`; on `False`, that node's
candidate list is just `[currentInstruction]` (after plan 36: the node's effective
instruction). Phase 3: as rewired in M2, consuming the same meter, so the whole run
shares one ceiling.

Test: `miprov2With` with a tiny budget (e.g. `maxLmCalls = datasetSize trainset`, just
the baseline evaluation) under `runJointStubLMCounting`: assert counted calls
`<= maxLmCalls + smallSlack` where `smallSlack = 0` for the single-node fixture; and a
generous-budget run asserting counted calls `<= maxLmCalls` while the search still
reaches the joint optimum (the existing `Miprov2Spec` improvement assertions must stay
green). Before this milestone the tiny-budget run still spends phase-1 teacher runs and
phase-2 proposer calls (observable: counter far above `maxLmCalls`).

### Milestone 5 — GEPA's seed evaluation

Scope: pre-gate the seed spend. In `GEPA.hs` (line 223 area), before
`seedRpt <- evaluatePure train metric student`, check the seed cost against the budget:
if `scoringCost train student > maxLmCalls budget`, return `freezeProgram student`
immediately (the degenerate-budget rule from the Decision Log; note it in the `gepa`
haddock). Otherwise create a meter, charge the seed cost, and convert the loop's manual
`calls`/`stepCost` arithmetic to `tryCharge` (a full step costs
`2 * scoringCost train student + 1`; keep the existing structure, just spend through
the meter). Test: `gepa … (Budget { maxLmCalls = 1, maxCandidates = 4 })` over a
2-example dataset under `runStubLMCounting` returns the student with a counted call
total of 0 — before this milestone it spends the 2-call seed evaluation first.

### Milestone 6 — bootstrap and random search

Scope: per-node teacher accounting and one shared meter for the whole random search.
In `Bootstrap.hs`, change `bootstrapFewShotWith` to create a meter and gate each
teacher run with `tryCharge meter (max 1 (length (foldParams teacher)))` instead of the
`take (maxLmCalls budget)` prefix (lines 76–77); extract the demo-collection loop as

```haskell
bootstrapKeptDemos ::
  (ToJSON i, ToJSON o, LLM :> es, Error ShikumiError :> es, Prim :> es) =>
  BootstrapConfig -> BudgetMeter -> Program i o -> Dataset i o -> Metric o -> Eff es [Demo]
```

exported so random search can reuse it under its own meter. In `RandomSearch.hs`,
`bootstrapRandomSearchWith` creates one meter from its `Budget` and uses it for
everything: each seed's demos come from `bootstrapKeptDemos cfg' meter teacher
(shuffle seed train) metric` (no more full-budget inner optimizers — drop the
`runOptimizer opt …` construction at lines 82–84 in favor of
`withDemos <$> bootstrapKeptDemos …` applied to the student), and final selection goes
through `selectBestMetered meter (meteredScore meter train metric) cands` with the
zero-shot student still first. Document in both haddocks that the budget now covers
teacher runs and scoring jointly.

Tests: (a) bootstrap with a two-node teacher (`sentimentPipeline`) and
`maxLmCalls = 6` over a 6-example trainset under `runStubLMCounting`: counted calls
`<= 6` (before: 12 — each of 6 teacher runs makes 2 calls); (b)
`bootstrapRandomSearchWith` with `numCandidates = 5` and `maxLmCalls = 20` under
`runStubLMCounting`: counted calls `<= 20` (before: hundreds); assert it still returns
a program scoring `>=` the zero-shot baseline (the existing RandomSearchSpec
assertions stay green).

### Milestone 7 — ensemble

Scope: a budgeted ensemble variant with exact counting. In `Ensemble.hs` add
`ensembleSearchWith :: (Eq o) => Budget -> Int -> Optimizer i o -> Optimizer i o`:
run members sequentially, wrapping each
`runOptimizer inner (resample seed train) metric student` in `withLmCallCount`; keep a
running exact total; before launching each member after the first, stop if the total
has reached `maxLmCalls budget` (members already built are kept; at least one member
always runs so the ensemble is never empty). Redefine
`ensembleSearch size inner = ensembleSearchWith defaultBudget size inner` and document
the granularity honestly in the haddock: the bound is enforced between members — a
single member's spend is not interrupted, so the total may overshoot by at most one
member's cost, and with the default budget an `ensembleSearch` that previously spent
`size × inner` now stops early. Export `ensembleSearchWith` from the module and from
`Shikumi.Optimize`.

Test: `ensembleSearchWith (Budget { maxLmCalls = 1, maxCandidates = 32 }) 5
(labeledFewShot 1)` under `runStubLMCounting`: exactly one member runs (inspect the
returned `Ensemble` member count the way `EnsembleSpec.hs:85-86` already does), and
counted calls equal one member's spend; before this milestone five members always run.

### Milestone 8 — honest docs and the full budget matrix

Scope: make the contract text true and the test coverage complete. Rewrite the `Budget`
haddock in `Types.hs` (lines 69–73) to state: (1) the accounting unit is *predicted LM
completions* — one per example per `Predict` node for a scoring evaluation, one per
`Predict` node for a teacher run, `4 + N` for a grounded proposer call; (2) wrappers
that re-invoke the LM (`Retry`, `RetryWhen`, `MajorityVote`, `Embed` bodies such as
ReAct agents) make the prediction a lower bound, and `ensembleSearchWith` enforces its
bound between members with up to one member's overshoot; (3) a budget too small to
score a single candidate returns the input program unscored. Mirror the relevant
sentence in each optimizer's haddock. Finally, ensure the budget test matrix covers
every exported optimizer (instructionSearch, copro, miprov2/miprov2With,
gepa, labeledFewShot/labeledFewShotWith, bootstrapFewShot/With,
bootstrapRandomSearch/With, ensembleSearch/With, knnFewShot — the last makes zero LM
calls at optimize time; assert exactly that with the counting stub) and run
`cabal test all`.


## Concrete Steps

All commands from the repository root, inside the dev shell:

```bash
cd /path/to/shikumi
nix develop .#ghc9124
cabal build shikumi-optimize
cabal test shikumi-optimize          # or: just test-one shikumi-optimize
```

Write each milestone's budget test first, run it, and record the observed (violating)
call count in Surprises & Discoveries; then implement and re-run. Expected shape of a
failing-before run (M3 example):

```text
    budget
      labeledFewShot respects maxLmCalls: FAIL
        expected <= 8 LM calls, counted 186
```

After each green milestone, commit with a Conventional Commits subject and these exact
trailers on every commit:

```text
fix(optimize): meter labeledFewShot scoring against the budget

MasterPlan: docs/masterplans/6-optimizer-and-evaluation-correctness.md
ExecPlan: docs/plans/37-enforce-the-optimizer-budget-contract.md
Intention: intention_01kwjfeaf8e86bvx2arbh7nk2c
```

Because `shikumi-cli` and `shikumi-jitsurei` import `labeledFewShot`/`ensembleSearch`,
finish with:

```bash
cabal build all
cabal test all
```


## Validation and Acceptance

Accepted when:

1. For every exported optimizer there is a test that runs it under `runStubLMCounting`
   (or `runJointStubLMCounting`) with an explicit small `Budget` and asserts the
   counter — the *actual* number of `Complete` calls — is `<=` the documented bound
   (`maxLmCalls`, plus the documented one-member slack only for
   `ensembleSearchWith`). Each such test demonstrably failed before its milestone
   (record at least the M3, M4, and M6 failing counts in Surprises & Discoveries).
2. All pre-existing improvement/acceptance tests in `shikumi-optimize/test` still pass
   with unchanged score floors — enforcement must not be achieved by preventing the
   optimizers from searching under normal budgets (`defaultBudget` is generous for the
   fixture sizes).
3. The `Budget` haddock in `Types.hs` describes exactly the implemented model,
   including the estimate-versus-exact distinction and the degenerate-budget rule; no
   optimizer haddock still claims an unimplemented guarantee.
4. `cabal test all` inside `nix develop .#ghc9124` passes.


## Idempotence and Recovery

All steps are source edits plus deterministic test runs (the counting stubs are
IORef-based and offline); everything can be re-run safely. Milestones are ordered so
the seam (M1) is purely additive — if a rewiring milestone (M2–M7) misbehaves, revert
just that module (`git checkout -- shikumi-optimize/src/Shikumi/Optimize/<X>.hs`) and
its tests without touching the seam. One risk to watch: `tryCharge` must remain a
single atomic read-modify-write; if a test shows counter drift under `evaluatePure`'s
4-way concurrency, that invariant was broken — fix the atomicity rather than loosening
the assertion. Prefer forward-fixing commits (same trailers) over history rewrites.


## Interfaces and Dependencies

No new external dependencies (`effectful`'s `Prim`/`interpose` are already in use in
this workspace — see `Shikumi.Eval.Usage`). End-state public surface, all in
`shikumi-optimize`:

- `Shikumi.Optimize.Search`: adds `BudgetMeter`, `newBudgetMeter :: (Prim :> es) =>
  Budget -> Eff es BudgetMeter`, `tryCharge :: (Prim :> es) => BudgetMeter -> Int ->
  Eff es Bool`, `scoringCost :: Dataset i o -> Program i o -> Int`, `meteredScore`,
  `selectBestMetered`, `withLmCallCount :: (LLM :> es, Prim :> es) => Eff es a ->
  Eff es (a, Int)`. `selectBest`/`scoreOn` remain (deprecable later; do not delete —
  external code may use them).
- `Shikumi.Optimize.LabeledFewShot`: adds `labeledFewShotWith :: (ToJSON i, ToJSON o)
  => Budget -> Int -> Optimizer i o`; `labeledFewShot` unchanged in type.
- `Shikumi.Optimize.Bootstrap`: adds `bootstrapKeptDemos` (signature in M6);
  `bootstrapFewShot`/`bootstrapFewShotWith` unchanged in type.
- `Shikumi.Optimize.Ensemble`: adds `ensembleSearchWith :: (Eq o) => Budget -> Int ->
  Optimizer i o -> Optimizer i o`; `ensembleSearch` unchanged in type (now capped by
  `defaultBudget` — documented behavior change).
- `Shikumi.Optimize.MIPRO`, `Shikumi.Optimize.GEPA`, `Shikumi.Optimize.Instruction`,
  `Shikumi.Optimize.COPRO`: internal changes; exported types unchanged.
- `Shikumi.Optimize` (umbrella): re-export the new `-With` names and the meter seam.

Sequencing (from the master plan): this plan soft-depends on plan 36
(`docs/plans/36-fix-optimizer-instruction-seeding.md`) — implement on top of its landed
Search.hs helpers, StubLM fixtures (`sentimentPipeline`), and candidate semantics; do
not reintroduce `fromMaybe "" . instructionAt` reads while refactoring.
