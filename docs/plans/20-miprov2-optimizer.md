---
id: 20
slug: miprov2-optimizer
title: "MIPROv2 optimizer"
kind: exec-plan
created_at: 2026-06-09T22:35:41Z
intention: "intention_01ktq80q01emxtjfxzd3rw4tjs"
master_plan: "docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md"
---

# MIPROv2 optimizer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi is a Haskell framework for writing programs that call language models. A program is a
value of type `Program i o` (a tree of nodes; the `Predict` nodes are the ones that actually
call a model). Shikumi already ships four "optimizers" — search procedures that *automatically
improve* a program by rewriting each node's tunable parameters (its **instruction**, a short
piece of guidance text, and its **demonstrations**, a few worked input/output examples shown to
the model). The four are `labeledFewShot` (pick good demos from the training set),
`bootstrapFewShot` (harvest demos from a teacher's correct runs), `instructionSearch` (greedy
one-node-at-a-time search over LM-proposed instructions), and `ensembleSearch` (combine several
candidates by majority vote). They live in `shikumi-optimize/` and are invoked through one
stable entry point, `optimize`.

What is missing is the single most effective optimizer in modern DSPy: **MIPROv2**. Where
`instructionSearch` improves instructions *or* demos one node at a time and greedily,
MIPROv2 searches *both at once, across all nodes jointly*. It works in three phases. First it
**bootstraps** several candidate demonstration sets (running the program over the training set,
keeping demos from correct runs). Second it **proposes** several candidate instruction strings
for each node, using a *grounded* proposer that reads a summary of the dataset, a summary of the
program, the bootstrapped demos, and a "tip" (a short stylistic nudge) — this proposer is
delivered by `docs/plans/19-grounded-instruction-proposer.md`. Third it **searches** the grid of
"which instruction × which demo set, for each node" — a combinatorial space far too large to
enumerate — by running short, cheap evaluations on small random **minibatches** of the training
set, steering future trials toward the parameter choices that scored well, and periodically
doing a full evaluation of the running best to confirm it.

After this change a Shikumi user can write:

```haskell
cp <- optimize (miprov2 Miprov2Light) trainset metric program
```

and get back a `CompiledProgram i o` — the *same* type every other optimizer returns, runnable
and serializable through the *same* `runCompiled` / `encodeCompiled` / `decodeCompiledOnto`
functions — whose held-out score is *higher* than the program started with, and higher than what
the existing `instructionSearch` achieves on the same task. You can see it working through a
hermetic test (no network, no API key, deterministic): a deliberately-underspecified sentiment
program that scores 0.0 on a held-out set it never sees during search scores 1.0 after
`miprov2`, and `miprov2` beats `instructionSearch` on a task constructed so that the *joint*
instruction-and-demo choice matters. The result round-trips through serialization unchanged.

This is **EP-20** in the master plan
`docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md`. It **hard-depends**
on EP-19 (`docs/plans/19-grounded-instruction-proposer.md`) for the grounded proposer, and
**soft-depends** on EP-16 (`docs/plans/16-node-correlated-tracing-and-feedback-channel.md`) for
recovering *per-node* demos; both are referenced by path and a fallback is provided so this plan
can be implemented and tested even if EP-16 has not yet landed.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M0: New module `Shikumi.Optimize.MIPRO` created in `shikumi-optimize/src/`, registered in
      the cabal file, re-exported from `Shikumi.Optimize`; `Miprov2Config`, the auto presets
      (`Miprov2Light`/`Medium`/`Heavy`), and a stub `miprov2` that type-checks and returns
      `freezeProgram student` unchanged (so the package builds before any phase logic exists).
- [ ] M1: Candidate generation — the bootstrap stage (per-node demo sets, via EP-16's
      `runProgramTraced` with the program-level fallback) and the propose stage (per-node
      instruction candidates, via EP-19's `proposeInstructions`). A unit test proving each node
      receives a non-trivial list of demo-set candidates and instruction candidates including the
      node's current instruction at index 0.
- [ ] M2: The minibatch trial search loop — the chosen surrogate (greedy-coordinate-with-
      minibatch-pruning, defined below) over the per-node `(instruction × demoset)` grid, honoring
      `Budget {maxLmCalls, maxCandidates}`. A unit test proving the loop stops before the budget is
      exceeded (call counter via `runStubLMCounting`) and that minibatch trials select the
      better-scoring parameter combination.
- [ ] M3: Full-eval selection → `CompiledProgram`; the held-out-lift acceptance test
      (`miprov2` lifts held-out score above before *and* above `instructionSearch`); the
      `encodeCompiled`/`decodeCompiledOnto` round-trip test.
- [ ] Final: `cabal test shikumi-optimize` and `cabal test all` green inside
      `nix develop .#ghc9124`; fourmolu-formatted; living sections updated; commit carries
      MasterPlan/ExecPlan/Intention trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Implement the Phase-3 search as **greedy coordinate descent with minibatch
  pruning**, not a literal port of DSPy's Optuna TPE sampler.
  Rationale: DSPy delegates Phase 3 to Optuna's `TPESampler` (Tree-structured Parzen Estimator),
  a Bayesian-optimization library with no Haskell equivalent in this repo's dependency set.
  Re-implementing a multivariate TPE is a large, separately-riskable effort that would dwarf this
  plan and add a stochastic component hostile to hermetic golden tests. The *essential, testable*
  behavior of MIPROv2's search is: (a) it searches the **joint** per-node `(instruction, demoset)`
  grid rather than one axis at a time; (b) it evaluates candidates **cheaply on minibatches** and
  only **fully evaluates** the running best periodically; (c) it **honors a budget**. Greedy
  coordinate descent over the joint grid, with each coordinate move *scored on a minibatch* and a
  full evaluation gating each accepted move, captures all three while remaining deterministic. It
  is a faithful-enough analog: it spends the budget on the same grid, with the same
  minibatch/full-eval split, and demonstrably lifts the held-out score above the V1
  `instructionSearch` baseline (the acceptance criterion). The plan documents the surrogate
  precisely and notes a later EP could swap in a TPE-lite without changing the public surface.
  Date: 2026-06-09.
- Decision: The output is V1's `CompiledProgram i o`, produced via `freezeProgram`, invoked
  through V1's `optimize`, and persisted with V1's `encodeCompiled`/`decodeCompiledOnto`. No
  parallel optimizer type, no parallel serialization surface.
  Rationale: MasterPlan integration point #4 mandates reusing V1's `Optimizer`/`optimize`/
  `CompiledProgram` unchanged; the CLI and golden tests depend on these being stable. Parameters
  live *on the nodes* (`Params` inside each `Predict`), so an optimizer that has rewritten a
  program's parameters simply wraps it with `freezeProgram` — there is nothing to serialize on
  the side.
  Date: 2026-06-09.
- Decision: Per-node demo recovery consumes EP-16's `runProgramTraced` + `programNodePaths`
  (master plan integration point #5), with a **program-level fallback** (`bootstrapFewShot`'s
  existing `recoverDemo` shape: attach the same recovered demo set to every node) used when EP-16
  has not landed. The fallback is selected by a single config flag and is documented as a faithful
  degradation, not a different algorithm.
  Rationale: EP-16 is a soft dependency; this plan must be implementable and hermetically testable
  today. The fallback reproduces exactly what V1's `bootstrapFewShot` already does
  (`shikumi-optimize/src/Shikumi/Optimize/Bootstrap.hs`), so it is a known-good baseline.
  Date: 2026-06-09.
- Decision: Instruction candidates come from EP-19's `proposeInstructions` surface (master plan
  integration point #2), with a small **fallback proposer** reusing V1's `proposeInstruction`
  program (`Shikumi.Optimize.Instruction.proposeInstruction`) when EP-19 has not landed.
  Rationale: EP-19 is a hard dependency for the *headline* (grounded) behavior, but to let this
  plan be built and tested in isolation we keep a degraded proposer that emits candidates via the
  same `variant:N` marker the existing stub LM already understands. The acceptance test that
  *beats* `instructionSearch` uses the same proposer both sides, so the win comes from the joint
  search, not from a richer proposer.
  Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of this repository. Read it fully before editing. All
paths are relative to the repository root `/Users/shinzui/Keikaku/bokuno/shikumi`.

### Where the optimizer code lives

The optimizer framework is the package `shikumi-optimize/`. Its cabal file is
`shikumi-optimize/shikumi-optimize.cabal`. The modules that matter:

  * `shikumi-optimize/src/Shikumi/Optimize/Types.hs` — defines the central types. **Read these
    verbatim; you build on them.**

    ```haskell
    newtype Optimizer i o = Optimizer
      { runOptimizer ::
          forall es.
          (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
          Dataset i o ->
          Metric o ->
          Program i o ->
          Eff es (CompiledProgram i o)
      }

    data Budget = Budget
      { maxLmCalls :: !Int,     -- ceiling on raw LM calls (proposals + scoring)
        maxCandidates :: !Int   -- ceiling on candidate programs scored
      }

    defaultBudget :: Budget
    defaultBudget = Budget {maxLmCalls = 200, maxCandidates = 32}

    data Scored a = Scored { candidate :: a, score :: !Double }
    ```

    An `Optimizer i o` is a record holding one rank-2 function (`runOptimizer`) — "rank-2" just
    means the function is polymorphic in the effect row `es`, so the same optimizer works under
    any concrete stack that provides those five effects. `miprov2` returns an `Optimizer i o`.

  * `shikumi-optimize/src/Shikumi/Optimize/Search.hs` — shared plumbing every optimizer reuses.
    **You will call `scoreOn` and `freezeProgram`.**

    ```haskell
    -- Score a program against a dataset + pure metric: returns the mean score in [0,1].
    -- Internally runs EP-8's evaluatePure, which costs one LM call per dataset example.
    scoreOn ::
      (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
      Dataset i o -> Metric o -> Program i o -> Eff es Double

    -- Wrap a finished program as compiled. Parameters live on the nodes, so there is
    -- nothing to "freeze" on the side — this is just the CompiledProgram constructor.
    freezeProgram :: Program i o -> CompiledProgram i o

    -- A pure selection fold: score each candidate (left to right, bounded by
    -- maxCandidates), return the best by score (ties: earliest wins).
    selectBest :: (Monad m) => Budget -> (cand -> m Double) -> [cand] -> m (Maybe (Scored cand))
    ```

  * `shikumi-optimize/src/Shikumi/Optimize/Bootstrap.hs` — V1's `bootstrapFewShot`. **You reuse
    its `recoverDemo` and its pattern.** The key pieces:

    ```haskell
    -- Pair a typed input/output as a JSON Demo the node's adapter decodes back.
    recoverDemo :: (ToJSON i, ToJSON o) => i -> o -> Demo
    recoverDemo i o = Demo {input = toJSON i, output = toJSON o}
    ```

    The module's own header documents that, lacking node-correlated traces, V1 recovers demos at
    the *whole-program input/output level* and attaches the same set to every node. That exact
    behavior is this plan's **fallback** for per-node demo recovery.

  * `shikumi-optimize/src/Shikumi/Optimize/Instruction.hs` — V1's `instructionSearch` and its
    proposer program. **The acceptance test compares against `instructionSearch`.** Its proposer:

    ```haskell
    data ProposeIn = ProposeIn
      { currentInstruction :: Text, fieldSummary :: Text, examples :: Text }
    newtype ProposeOut = ProposeOut { proposedInstruction :: Text }
    proposeInstruction :: Program ProposeIn ProposeOut
    ```

    `instructionSearch n budget` does greedy coordinate ascent: for each node, ask the proposer
    for `n` candidate instructions (the request embeds a `variant:N` marker), score each by
    running the whole program over the training set, keep the best, move to the next node. The
    *current* instruction is always a candidate so a node never degrades.

  * `shikumi-optimize/src/Shikumi/Optimize/LabeledFewShot.hs` — provides `withDemos`:

    ```haskell
    -- Attach a demo set to every node, leaving instructions untouched.
    withDemos :: [Demo] -> Program i o -> Program i o
    withDemos ds = mapParams (\ps -> ps {demos = ds})
    ```

  * `shikumi-optimize/src/Shikumi/Optimize.hs` — the public façade. It re-exports the four
    strategy modules and defines `optimize`. **You add `module Shikumi.Optimize.MIPRO` to its
    re-export list.**

### The program model you manipulate

`Program i o` is a GADT defined in `shikumi/src/Shikumi/Program.hs`. Each `Predict` node holds a
`Params` record:

```haskell
data Params = Params
  { instructionOverride :: !(Maybe Text),  -- the node's instruction (Nothing = signature default)
    demos :: ![Demo]                        -- the node's few-shot demonstrations
  }

data Demo = Demo { input :: !Value, output :: !Value }   -- JSON-encoded I/O pair
```

You edit these via the **parameter traversal** functions (also in `Shikumi.Program`), whose
left-to-right depth-first order over `Predict` nodes is the canonical node ordering every other
optimizer agrees on:

```haskell
foldParams      :: Program i o -> [Params]            -- read all nodes' Params, in order
mapParams       :: (Params -> Params) -> Program i o -> Program i o   -- edit every node
mapParamsAt     :: Int -> (Params -> Params) -> Program i o -> Program i o  -- edit node n
programParams   :: Program i o -> [Params]            -- = foldParams (alias kept for serialization)
setProgramParams :: [Params] -> Program i o -> Either ProgramShapeError (Program i o)
```

`length (foldParams p)` is the number of `Predict` nodes. To set node `k`'s instruction:
`mapParamsAt k (\ps -> ps {instructionOverride = Just instr}) p`. To set its demos:
`mapParamsAt k (\ps -> ps {demos = ds}) p`. Composite nodes (`Compose`, `FMap`, `Map`, etc.)
carry no `Params` and are skipped by the traversal.

### Serialization (consumed unchanged)

From `shikumi-compile/src/Shikumi/Compile/Serialize.hs`:

```haskell
encodeCompiled :: CompiledProgram i o -> ByteString          -- JSON array of Params, foldParams order
decodeCompiledOnto :: Program i o -> ByteString -> Either String (CompiledProgram i o)
```

`encodeCompiled` writes the `[Params]` vector; `decodeCompiledOnto template bytes` applies a saved
vector back onto a structurally-identical template program (failing with `Left` on a node-count
mismatch). The M3 round-trip test uses these directly: encode the `miprov2` result, decode it onto
the original `underspecified` template, confirm the decoded program scores the same.

### The grounded proposer this plan consumes (EP-19)

EP-19 (`docs/plans/19-grounded-instruction-proposer.md`) owns `proposeInstructions`. EP-19's file
is currently a skeleton, so this plan pins the **interface it relies on** and treats anything finer
as EP-19's to refine. The contract this plan consumes is:

```haskell
-- In Shikumi.Optimize.Propose (owned by EP-19): given the proposal signals and a target node
-- index, return a ranked list of candidate instruction strings for that node, best first.
proposeInstructions ::
  (LLM :> es, Error ShikumiError :> es) =>
  ProposeSignals i o ->   -- dataset summary, program summary, bootstrapped demos, tip, history
  Int ->                  -- target node index (foldParams order)
  Int ->                  -- N: how many candidates to return
  Eff es [Text]
```

`ProposeSignals i o` is EP-19's record bundling the dataset summary, the program/module
summaries, the bootstrapped demo sets, the per-node field metadata (recovered via EP-16's
`nodeFieldsIndexed`, master plan integration point #3), the prior instructions with their scores,
and a tip. EP-19 builds these signals from the same `Dataset`, `Metric`, and `Program` this
optimizer holds; this plan calls a single EP-19-provided constructor
`mkProposeSignals :: Dataset i o -> Program i o -> [[Demo]] -> ProposeSignals i o` (or equivalent;
exact name to be confirmed against EP-19 at integration time) to assemble them.

**Until EP-19 lands**, this plan ships a *fallback proposer* (`fallbackProposeInstructions`)
that reuses V1's `proposeInstruction` program directly: it emits `N` candidates by running
`proposeInstruction` with `variant:0 .. variant:(N-1)` markers, exactly as `instructionSearch`
does. The public `miprov2` surface is identical with either proposer; a config flag (or a
compile-time choice recorded in the Decision Log) selects which is wired. **The acceptance test
uses the fallback on both `miprov2` and `instructionSearch`, so the demonstrated win is from the
joint search, not from a richer proposer** — when EP-19 lands, the grounded proposer only widens
the margin.

### The per-node trace recovery this plan consumes (EP-16)

EP-16 (`docs/plans/16-node-correlated-tracing-and-feedback-channel.md`) provides:

```haskell
-- Run a program like runProgram, but tag each model-call span with the NodePath of the
-- issuing Predict node. NodePath order agrees with foldParams/mapParamsAt indexing.
runProgramTraced ::
  (LLM :> es, Trace :> es, Error ShikumiError :> es) => Program i o -> i -> Eff es o
programNodePaths   :: Program i o -> [NodePath]       -- k-th path = node mapParamsAt k edits
nodeFieldsIndexed  :: Program i o -> [NodeFields]     -- k-th = node k's input/output field names
```

This plan's **bootstrap stage** uses `runProgramTraced` to recover, for each `Predict` node, the
typed input/output that node saw on a *passing* example, so it can build a *per-node* demo set
(the thing V1 could not do). The mechanism: run the teacher under `runProgramTraced`, collect the
trace tree, and for each node path read the model-call span's recorded input/output, decode it
into a `Demo`, and attach it via `mapParamsAt k`. **Until EP-16 lands**, the fallback recovers a
*single program-level* demo per passing example (the program's input paired with its final output,
via `recoverDemo`) and attaches the same set to every node — V1's documented behavior. A config
flag selects which path is taken; the public surface is identical.

### The hermetic stub-LM pattern (how tests stay offline)

Tests never hit the network. The pattern (see `shikumi-optimize/test/StubLM.hs`) is a tiny
interpreter of the `LLM` effect that inspects the rendered request and answers by a rule that is
*monotone in parameter quality*, so that better parameters yield higher scores. The existing stub:

  * The task is binary sentiment: classify a `Sentence` into a `Label` (`"positive"`/`"negative"`).
    Ground truth `goldLabel`: a sentence with the word `good` is positive, `bad` is negative.
  * **With demos present** it does nearest-demo classification (echo the label of the demo sentence
    sharing the most words with the input). So better demo sets score higher — what labeled/bootstrap
    exploit.
  * **No demos but an instruction containing `RULE`** → apply `goldLabel` directly. So a good
    instruction unlocks correct answers — what instruction search exploits.
  * **No demos and no `RULE`** → answer the constant `"neutral"`, which never matches → score 0.
    This is the deliberately-underspecified "before" state.
  * A *proposer* request (recognized by its `proposedInstruction` output field) returns the
    candidate selected by the `variant:N` marker: variant 0 is the magic `RULE` instruction, others
    are bland.

The stub exposes `runStubLM` (plain) and `runStubLMCounting :: IORef Int -> ...` (counts every
completion, for budget tests). The whole stack is assembled as

```haskell
runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runStubLM act
```

(see `shikumi-optimize/test/AcceptanceSpec.hs`). This plan's tests follow this exact shape. To
make the *joint* search demonstrably beat `instructionSearch`, M3 **extends the stub** with a task
where the right answer needs *both* a good instruction *and* a good demo set simultaneously
(details in M3) — a regime greedy single-axis search handles poorly but joint search handles well.

### Terms defined

  * **Predictor / node** — a `Predict` node in the program; the only nodes with tunable `Params`.
  * **Instruction** — a node's guidance string (`Params.instructionOverride`).
  * **Demo / demonstration** — a worked input/output example (`Params.demos`), shown to the model.
  * **Demo set candidate** — one whole list of demos that *might* be attached to a node.
  * **Bootstrap** — generating demo-set candidates by running the program over the training set and
    keeping demos from runs the metric judged correct.
  * **Proposer** — the LM-backed component that suggests candidate instruction strings.
  * **Minibatch** — a small random subset of the training set used for a *cheap* evaluation during
    search (vs. a *full* evaluation over the whole set).
  * **Trial** — one search step: pick a candidate parameter combination, evaluate it (on a
    minibatch, usually), and record the score.
  * **Budget** — `Budget {maxLmCalls, maxCandidates}`; a hard ceiling the search must not exceed.
  * **Coordinate descent** — improving a multi-dimensional choice by optimizing one dimension at a
    time, holding the others fixed, and sweeping repeatedly. Our surrogate's backbone.


## Plan of Work

The work proceeds through four milestones (M0–M3), each independently verifiable. M0 lands the
module skeleton so the package keeps building; M1 builds the candidate generators; M2 builds the
budget-aware minibatch search; M3 wires selection, the acceptance lift, and serialization.

All new code lives in **one new module**, `Shikumi.Optimize.MIPRO`
(`shikumi-optimize/src/Shikumi/Optimize/MIPRO.hs`), re-exported from `Shikumi.Optimize`. Tests
live in a new spec `shikumi-optimize/test/Miprov2Spec.hs`, wired into
`shikumi-optimize/test/Main.hs` and the cabal `other-modules`.

### Milestone 0 — module skeleton, config, auto presets

**Scope.** Create `Shikumi.Optimize.MIPRO` with the public configuration type, the three auto
presets, and a `miprov2` that type-checks end-to-end but does no real work yet (it returns
`freezeProgram student`). Register the module and re-export it. At the end of M0 the package
builds and `optimize (miprov2 Miprov2Light) ...` compiles and runs (returning the program
unchanged).

**The config and presets.** Add to `Shikumi.Optimize.MIPRO`:

```haskell
-- | How aggressively to search. Mirrors DSPy's light/medium/heavy "auto" modes: each sets the
-- number of instruction candidates per node, the number of demo-set candidates, the minibatch
-- size, the number of trials, and how often a full evaluation runs. Heavier presets spend more
-- of the Budget for (usually) better results.
data Miprov2Auto = Miprov2Light | Miprov2Medium | Miprov2Heavy
  deriving stock (Eq, Show)

-- | The full, explicit configuration. The presets fill this in; advanced users can build one
-- directly. Field meanings:
data Miprov2Config = Miprov2Config
  { numInstructCandidates :: !Int,   -- instruction candidates proposed per node
    numDemoCandidates :: !Int,       -- demo-set candidates bootstrapped per node
    numTrials :: !Int,               -- minibatch trials the search performs
    minibatchSize :: !Int,           -- examples per minibatch evaluation
    fullEvalEvery :: !Int,           -- run a full eval of the running best every k trials
    maxBootstrappedDemos :: !Int,    -- cap on demos in one bootstrapped set (prompt-size guard)
    bootstrapThreshold :: !Double,   -- min metric score for a teacher run to contribute demos
    budget :: !Budget,               -- hard LM-call / candidate ceiling (V1's Budget)
    usePerNodeDemos :: !Bool,        -- True: use EP-16 trace recovery; False: program-level fallback
    useGroundedProposer :: !Bool     -- True: use EP-19; False: V1 fallback proposer
  }
  deriving stock (Eq, Show)

-- | Turn a preset into a concrete config. Values chosen to be small enough for hermetic tests
-- yet faithful to DSPy's ordering (heavier => more candidates, more trials).
miprov2Auto :: Miprov2Auto -> Miprov2Config
miprov2Auto Miprov2Light  = Miprov2Config 2 2 6  3 3 4 1.0 defaultBudget True True
miprov2Auto Miprov2Medium = Miprov2Config 3 3 12 5 4 4 1.0 defaultBudget True True
miprov2Auto Miprov2Heavy  = Miprov2Config 4 4 18 8 5 4 1.0 defaultBudget True True
```

(DSPy's real presets are `light={n:6,val:100}`, `medium={n:12,val:300}`, `heavy={n:18,val:1000}`,
with `num_trials = max(2·numVars·log2(n), 1.5·n)`. We scale these down for hermetic tests but
keep the monotonic ordering and the same knobs. The `numTrials` values above are the DSPy formula
evaluated for a single-predictor program at each `n`, rounded — record the exact arithmetic in a
comment.)

**The two convenience constructors.** A `Program i o` argument (the *teacher* for bootstrap) is
needed exactly as `bootstrapFewShot` needs one. Provide:

```haskell
-- | MIPROv2 with a preset. The teacher (whose successful runs seed bootstrapped demos) defaults
-- to the student itself, matching DSPy's default.
miprov2 :: (ToJSON i, ToJSON o) => Miprov2Auto -> Optimizer i o

-- | MIPROv2 with an explicit config and an explicit teacher program.
miprov2With :: (ToJSON i, ToJSON o) => Miprov2Config -> Program i o -> Optimizer i o
```

For M0, `miprov2With cfg teacher = Optimizer $ \_ _ student -> pure (freezeProgram student)` and
`miprov2 a = Optimizer $ \train m student -> runOptimizer (miprov2With (miprov2Auto a) student) train m student`.
(`ToJSON i, ToJSON o` are required because demo recovery serializes typed I/O into JSON `Demo`s,
exactly as `bootstrapFewShot` requires.)

**Wiring.** Add `Shikumi.Optimize.MIPRO` to `exposed-modules` in
`shikumi-optimize/shikumi-optimize.cabal`, and add `module Shikumi.Optimize.MIPRO` to the
re-export list and imports of `shikumi-optimize/src/Shikumi/Optimize.hs`.

**Acceptance.** `nix develop .#ghc9124 --command cabal build shikumi-optimize` succeeds, and a
trivial test (`miprov2 Miprov2Light` over the existing `StubLM` task returns a program that runs)
passes. The held-out score need not improve yet.

### Milestone 1 — candidate generation (bootstrap + propose)

**Scope.** Implement the two candidate generators MIPROv2's first two phases produce: for each
node, a list of **demo-set candidates** and a list of **instruction candidates**. At the end of
M1 these are exposed as internal functions with unit tests; the search loop (M2) consumes them.

**Phase 1 — bootstrap demo-set candidates.** DSPy bootstraps `num_fewshot_candidates` *sets* of
demos, each set built from a different random sample of teacher-passing runs. We mirror this
deterministically. Add:

```haskell
-- | For each node (foldParams order), a list of candidate demo sets. Index 0 of every node's
-- list is always the empty set (so "no demos" is always reachable, matching DSPy including the
-- default program as a baseline). The remaining sets are bootstrapped from teacher runs.
bootstrapDemoCandidates ::
  (ToJSON i, ToJSON o, LLM :> es, Trace :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Miprov2Config -> Program i o -> Dataset i o -> Metric o -> Program i o ->
  Eff es [[ [Demo] ]]   -- outer: per node; middle: candidate sets; inner: one demo set
```

The implementation:

  1. Take up to `maxLmCalls budget` training examples (bounding teacher runs by the budget, as
     `bootstrapFewShot` does).
  2. For each example, run the teacher and score it with the metric. If the score `>=
     bootstrapThreshold`, recover its demos:
       * **Per-node path (`usePerNodeDemos = True`, EP-16 present):** run the teacher under
         `runProgramTraced`, collect the trace, and for each node index `k` (via
         `programNodePaths`) read that node's model-call span's recorded typed input/output, build a
         `Demo` per node. This yields, per passing example, a tuple of one demo per node.
       * **Fallback path (`usePerNodeDemos = False`, or EP-16 absent):** run the teacher under
         plain `runProgram`, recover a single program-level `Demo` (`recoverDemo input finalOutput`),
         and replicate it across all nodes.
     Recovery is total: a teacher error yields no demo for that example (caught with `catchError`,
     as `bootstrapFewShot` does), never aborting the search.
  3. From the recovered per-example demos, form `numDemoCandidates` candidate *sets* per node by
     taking successive deterministic slices (e.g. set `j` is `take maxBootstrappedDemos (drop
     (j*stride) kept)`), so different candidates emphasize different examples. Prepend the empty
     set as candidate 0.

The `Trace` effect appears in the per-node path's row only; in the fallback path it is unused.
Because `Optimizer`'s row does **not** include `Trace`, the per-node path must discharge `Trace`
internally: wrap the traced teacher run in EP-16's `runTrace` (which needs only `Prim` and `Time`,
both already in the row) so `bootstrapDemoCandidates`'s *public* row stays the five `Optimizer`
effects. (Record in the Decision Log whether EP-16's `runProgramTraced` is invoked under a local
`runTrace`/`runCurrentNode` discharge here; the observable result — per-node demo sets — is the
same either way.)

**Phase 2 — propose instruction candidates.** For each node, produce `numInstructCandidates`
candidate instruction strings, with the node's *current* instruction guaranteed at index 0 (so a
node can never be forced to degrade — same guarantee `instructionSearch` gives). Add:

```haskell
-- | For each node (foldParams order), a list of candidate instructions, the node's current
-- instruction first. Uses EP-19's grounded proposer when useGroundedProposer; else the V1
-- fallback proposer.
proposeInstructionCandidates ::
  (LLM :> es, Error ShikumiError :> es) =>
  Miprov2Config -> Program i o -> Dataset i o -> [[ [Demo] ]] ->
  Eff es [[Text]]
```

  * **Grounded path:** build EP-19's `ProposeSignals` once (from the dataset, the program, and the
    bootstrapped demo candidates), then for each node `k` call
    `proposeInstructions signals k (numInstructCandidates - 1)` and prepend the node's current
    instruction.
  * **Fallback path:** for each node, run V1's `proposeInstruction` program with markers
    `variant:0 .. variant:(numInstructCandidates-2)` and prepend the current instruction —
    structurally identical to `instructionSearch`'s `genProposals`.

Each proposer call is one LM call; both paths thread and respect a running call count so the
proposal phase alone never exceeds `maxLmCalls budget` (stop early, returning fewer candidates,
exactly as `instructionSearch` does).

**Unit test (M1).** In `Miprov2Spec.hs`, add a `candidates` group that, under the stub LM on the
single-node `sentimentProg`: asserts `proposeInstructionCandidates` returns a one-element outer
list (one node) whose inner list has length `numInstructCandidates`, head equal to the node's
current instruction, and contains `ruleInstruction` (the magic candidate the stub's variant 0
emits); and asserts `bootstrapDemoCandidates` returns one node's worth of candidate sets, candidate
0 empty, at least one non-empty candidate whose demos decode back to training pairs.

**Acceptance.** `cabal test shikumi-optimize --test-options='-p candidates'` passes.

### Milestone 2 — the minibatch trial search loop (the surrogate)

**Scope.** Implement the Phase-3 search: a budget-aware loop that searches the joint per-node
`(instruction × demoset)` grid using minibatch evaluations, with periodic full evaluation of the
running best. At the end of M2 the loop is an internal function with a test proving it (a) honors
the budget and (b) selects the better joint combination.

**The surrogate, precisely.** We implement **greedy coordinate descent with minibatch pruning**
over the joint grid. Define a *parameter vector* as, for each node `k`, a pair of indices
`(iₖ, dₖ)` selecting `instructionCandidates[k][iₖ]` and `demoCandidates[k][dₖ]`. Applying a vector
to the student program means, for every node, `mapParamsAt k` setting both the instruction and the
demos to the selected candidates. The search:

  1. **Initialize** the vector to all-zeros `(0,0)` per node — i.e. each node's *current*
     instruction (index 0 by construction) and the *empty* demo set (candidate 0). Evaluate this
     baseline with a **full** `scoreOn` over the whole training set; record it as the running best
     `(bestVec, bestFullScore)`. (This mirrors DSPy seeding the study with the default program's
     full-eval score.)
  2. **Trial loop**, repeated up to `numTrials` times (and never past the budget):
       * Form the next *candidate vector* by a deterministic coordinate sweep: cycle through the
         `2·nNodes` coordinates (each node's instruction axis, then its demo axis); for the current
         coordinate, try each alternative index `1..len-1` (the non-current options), holding all
         other coordinates at the running-best vector. This enumerates one-coordinate moves away
         from the current best — the coordinate-descent neighborhood.
       * **Evaluate each neighbor on a fresh minibatch** (a deterministic size-`minibatchSize`
         sample of the training set; reuse `Ensemble.hs`'s LCG style for the sample indices so it
         is reproducible). Pick the neighbor with the best minibatch score as the trial's
         *proposal*.
       * Count budget: each minibatch evaluation costs `minibatchSize` LM calls; each full
         evaluation costs `datasetSize` LM calls; proposer/bootstrap calls from M1 already counted.
         **Before** any evaluation that would push the running LM-call total over `maxLmCalls
         budget`, or once `maxCandidates budget` candidate vectors have been scored, stop and skip
         to step 4 with the current best.
       * Every `fullEvalEvery` trials (and on the final trial), take the trial's proposal and
         **fully evaluate** it with `scoreOn` over the whole training set. If its full score beats
         `bestFullScore`, accept it: `bestVec := proposal`, `bestFullScore := its full score`. This
         is the "minibatch proposes, full eval confirms" gate that prevents a lucky minibatch from
         winning — DSPy's `_perform_full_evaluation` of the highest-mean program, adapted.
  3. (Implicit) Between full evals, the running best stays fixed; minibatch proposals only steer
     which coordinate move is tried next. Because each accepted move strictly improves the *full*
     score, the loop is monotone and terminates at a local optimum or the budget, whichever first.
  4. **Return** `bestVec` applied to the student.

Why this is a faithful-enough analog of MIPROv2's TPE search: it searches the *same joint grid*,
spends the budget on *minibatch trials with periodic full evals* in the *same proportion*
(`fullEvalEvery` ≈ DSPy's `minibatch_full_eval_steps`), and is gated by full evaluation of the
best-averaging candidate — the three behaviors the Decision Log identifies as essential. What it
gives up versus TPE is the probabilistic model that lets TPE *interpolate* between unobserved
combinations; greedy descent instead samples the neighborhood directly. For the discrete,
low-dimensional grids these hermetic tests use (and for most real Shikumi programs, which have a
handful of predictors), the difference is small, and a later EP can replace the neighbor-selection
step with a TPE-lite surrogate without touching the public surface.

**Budget semantics, stated exactly in terms of `Budget`.** `maxLmCalls` bounds the *total* raw LM
calls: bootstrap teacher runs (M1) + proposer calls (M1) + every minibatch evaluation
(`minibatchSize` calls each) + every full evaluation (`datasetSize` calls each). The loop threads
a running integer and refuses to start any evaluation whose cost would exceed the ceiling, then
returns the best found so far — so the recorded LM-call count never exceeds `maxLmCalls`.
`maxCandidates` bounds the number of *candidate vectors scored* (each minibatch-evaluated neighbor
and each full-evaluated proposal counts as one), the same "candidates scored" meter
`selectBest`/`labeledFewShot` use. When either ceiling is hit the search stops gracefully.

**Implementation function.**

```haskell
-- | The Phase-3 search. Given per-node instruction and demo candidates, search the joint grid and
-- return the best program found, honoring the Budget.
searchJoint ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Miprov2Config -> Dataset i o -> Metric o -> Program i o ->
  [[Text]] ->      -- per-node instruction candidates
  [[ [Demo] ]] ->  -- per-node demo-set candidates
  Eff es (Program i o)
```

**Unit test (M2).** Add a `search` group:

  * **Budget honored.** Run `searchJoint` with a tiny `maxLmCalls` under `runStubLMCounting`;
    assert the recorded completion count is `<= maxLmCalls`. (Same shape as the existing
    `InstructionSpec` budget test.)
  * **Joint selection.** On a constructed task (extend `StubLM` — see M3) where the correct answer
    needs *both* a `RULE` instruction *and* a covering demo set, assert `searchJoint` returns a
    vector that selects both, scoring higher than any single-axis choice. (This is the kernel of
    the M3 acceptance, isolated.)

**Acceptance.** `cabal test shikumi-optimize --test-options='-p search'` passes.

### Milestone 3 — selection → `CompiledProgram`, the held-out lift, and serialization round-trip

**Scope.** Wire M1 + M2 into the real `miprov2With`, then prove the headline: a held-out score
lift over both the unoptimized program and the V1 `instructionSearch` baseline, plus a
serialization round-trip. At the end of M3 the plan's purpose is demonstrably met.

**Wire `miprov2With`.** Replace M0's stub body with:

```haskell
miprov2With cfg teacher = Optimizer $ \train metric student -> do
  demoCands  <- bootstrapDemoCandidates cfg teacher train metric student
  instrCands <- proposeInstructionCandidates cfg student train demoCands
  best       <- searchJoint cfg train metric student instrCands demoCands
  pure (freezeProgram best)
```

**The stub extension for the joint-win task.** The existing single-node `sentimentProg` is too
easy: `instructionSearch` already drives it to 1.0 (the magic `RULE` instruction alone suffices),
so `miprov2` cannot *beat* it there. To show MIPROv2's distinctive strength — joint
instruction-and-demo search — M3 adds a second fixture to `StubLM.hs` (additively; the existing
fixtures and tests are untouched) whose stub rule rewards the *combination*:

  * A new richer task (e.g. a two-class task with an ambiguous lexicon) where the stub answers
    correctly **only when both** a `RULE`-bearing instruction is present **and** the demos cover
    the ambiguous class. With a `RULE` instruction but no covering demos, or covering demos but no
    `RULE`, the stub answers correctly on only *part* of the held-out set. This makes the held-out
    score a strictly increasing function of *jointly* getting both axes right — a regime where
    greedy single-axis `instructionSearch` plateaus below `miprov2`.
  * Concretely, model it so `instructionSearch` (which optimizes instructions only, demos
    untouched, or one axis greedily) reaches some `sBase < 1.0` on held-out, while `miprov2`
    (joint) reaches `> sBase` (ideally `1.0`). The fixture's rule and the held-out set are designed
    in the test so this inequality is deterministic under the stub.

This keeps the single-node `RULE`-only acceptance (in `AcceptanceSpec.hs`) valid and adds the
joint-win acceptance here.

**The acceptance test (M3).** Add an `acceptance` group to `Miprov2Spec.hs`:

```text
1. before      = scoreOn heldout metric underspecified            -- expect ~0.0
2. cpInstr      = optimize (instructionSearch 3 defaultBudget) train metric underspecified
   afterInstr   = scoreOn heldout metric (compiledProgram cpInstr)
3. cpMipro      = optimize (miprov2With cfg teacher) train metric underspecified
   afterMipro   = scoreOn heldout metric (compiledProgram cpMipro)
assert: before < 0.5
assert: afterMipro > before                 -- MIPROv2 lifts the held-out score
assert: afterMipro > afterInstr             -- ... above the V1 instructionSearch baseline
assert: afterMipro >= 0.75                  -- floor, so a future near-no-op fails loudly
```

For the *single-node* `sentimentProg` task this would tie (`instructionSearch` already hits 1.0),
so the acceptance uses the **richer joint-win fixture** above, where `afterMipro > afterInstr` is
strict and deterministic.

**The serialization round-trip test (M3).** Add a `serialize` group:

```text
cp        = optimize (miprov2With cfg teacher) train metric underspecified
bytes      = encodeCompiled cp
decoded    = decodeCompiledOnto underspecified bytes        -- Right (CompiledProgram ...)
assert: decoded is Right
assert: scoreOn heldout metric (compiledProgram decoded) == scoreOn heldout metric (compiledProgram cp)
```

This proves the `miprov2` output is an ordinary `CompiledProgram` that persists and reloads through
V1's serialization unchanged (master plan integration point #4) — encode the optimized parameters,
decode them onto the original template, and confirm the reloaded program scores identically.

**Acceptance.** `cabal test shikumi-optimize --test-options='-p Miprov2'` passes all three
Miprov2 groups (`candidates`, `search`, `acceptance`/`serialize`), and `cabal test all` is green.


## Concrete Steps

All commands run from the repository root inside the pinned toolchain. Enter it once:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124
```

Inside that shell, the build/test commands are:

```bash
cabal build shikumi-optimize
cabal test shikumi-optimize
cabal test all
```

Formatting uses fourmolu with two-space indentation; format every file you touch:

```bash
fourmolu -i shikumi-optimize/src/Shikumi/Optimize/MIPRO.hs \
            shikumi-optimize/src/Shikumi/Optimize.hs \
            shikumi-optimize/test/Miprov2Spec.hs \
            shikumi-optimize/test/StubLM.hs \
            shikumi-optimize/test/Main.hs
```

### Step-by-step

1. **M0.** Create `shikumi-optimize/src/Shikumi/Optimize/MIPRO.hs` with `Miprov2Auto`,
   `Miprov2Config`, `miprov2Auto`, `miprov2`, `miprov2With` (stub body returning
   `freezeProgram student`). Add `Shikumi.Optimize.MIPRO` to `exposed-modules` in
   `shikumi-optimize/shikumi-optimize.cabal`. Add the re-export and import to
   `shikumi-optimize/src/Shikumi/Optimize.hs`. Build:

   ```bash
   nix develop .#ghc9124 --command cabal build shikumi-optimize
   ```

2. **M1.** Implement `bootstrapDemoCandidates` and `proposeInstructionCandidates` (with the EP-16
   and EP-19 paths plus their fallbacks). Create `shikumi-optimize/test/Miprov2Spec.hs` with the
   `candidates` group; add `Miprov2Spec` to `other-modules` in the cabal test stanza and to the
   test tree in `shikumi-optimize/test/Main.hs`. Run:

   ```bash
   nix develop .#ghc9124 --command cabal test shikumi-optimize --test-options='-p candidates'
   ```

3. **M2.** Implement `searchJoint` (the surrogate). Add the `search` group to `Miprov2Spec.hs`.
   Run:

   ```bash
   nix develop .#ghc9124 --command cabal test shikumi-optimize --test-options='-p search'
   ```

4. **M3.** Replace M0's stub body of `miprov2With` with the real pipeline. Extend
   `shikumi-optimize/test/StubLM.hs` additively with the joint-win fixture. Add the `acceptance`
   and `serialize` groups to `Miprov2Spec.hs`. Run:

   ```bash
   nix develop .#ghc9124 --command cabal test shikumi-optimize --test-options='-p Miprov2'
   nix develop .#ghc9124 --command cabal test all
   ```

5. **Format, then commit** (only when the user asks to commit). Run the fourmolu command above,
   confirm `cabal test all` green, update this plan's Progress/Surprises/Decision Log.

Expected final test transcript (abridged):

```text
shikumi-optimize
  LabeledFewShot: OK
  Bootstrap: OK
  Instruction: OK
  Ensemble: OK
  Optimize: OK
  M5 acceptance: OK
  Miprov2
    candidates: OK
    search: OK
    acceptance: OK
    serialize: OK

All N tests passed
```


## Validation and Acceptance

The headline acceptance is observable and hermetic (no network, no API keys):

  * **Held-out lift over baseline.** On the joint-win fixture, a deliberately-underspecified
    program scores low on a *held-out* set it never sees during search (`before < 0.5`,
    typically 0.0). After `optimize (miprov2With cfg teacher) train metric program`, the returned
    `CompiledProgram` scores strictly higher on the same held-out set (`afterMipro > before`,
    `>= 0.75`), **and strictly higher than `instructionSearch`** on the same fixture
    (`afterMipro > afterInstr`). This is the concrete realization of master plan progress item
    "EP-20: Held-out score lift over the V1 instruction search baseline on a fixture task."

  * **Joint search actually searches jointly.** The M2 `search` test proves `searchJoint` selects a
    parameter vector setting *both* a node's instruction *and* its demos, scoring higher than any
    single-axis choice — the behavior that distinguishes MIPROv2 from `instructionSearch`.

  * **Budget honored.** The M2 budget test, under `runStubLMCounting`, proves the recorded LM-call
    count is `<= maxLmCalls budget` even with a tiny ceiling.

  * **Serialization round-trip.** The M3 `serialize` test proves the `miprov2` output is an
    ordinary `CompiledProgram` that `encodeCompiled`/`decodeCompiledOnto` persist and reload onto
    the original template with an identical held-out score — confirming integration point #4 (reuse
    V1's compiled/serialization surface unchanged).

Run the whole suite to confirm nothing regressed:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test shikumi-optimize
nix develop .#ghc9124 --command cabal test all
```

Success is every group reporting `OK`, including the existing
`LabeledFewShot`/`Bootstrap`/`Instruction`/`Ensemble`/`Optimize`/`M5 acceptance` groups (proving
the additive change did not break the existing optimizers or their acceptance) and the new
`Miprov2` groups.


## Idempotence and Recovery

Every step is additive and safe to repeat. Re-running `cabal build`/`cabal test` is idempotent.
The new code is one new module plus one new test spec and an *additive* extension to `StubLM.hs`
(new fixtures alongside the existing ones); nothing existing is removed or rewritten, so existing
tests keep passing throughout. If M1's EP-19/EP-16 integration cannot be completed because those
plans have not landed, set `useGroundedProposer = False` and `usePerNodeDemos = False` in the
presets to take the documented fallbacks (V1 `proposeInstruction` and program-level demo recovery)
— the package still builds and the acceptance still holds (the win comes from the joint search, not
the richer signals), and the grounded/per-node paths can be wired in a follow-up once EP-19/EP-16
are merged. If the surrogate fails to beat `instructionSearch` on a too-easy fixture, the fix is in
the *fixture* (make the stub reward the joint combination more sharply), not the algorithm — record
the fixture change in the Decision Log. If a partially edited module fails to compile, the failure
is local to `Shikumi.Optimize.MIPRO`; revert that file to M0's stub body and re-add logic
incrementally.


## Interfaces and Dependencies

Libraries/modules used and why:

  * `shikumi-optimize` (this package) — home of the new module. Reuses `Optimizer`, `Budget`,
    `Scored`, `defaultBudget` (`Shikumi.Optimize.Types`); `scoreOn`, `freezeProgram`, `selectBest`
    (`Shikumi.Optimize.Search`); `recoverDemo` (`Shikumi.Optimize.Bootstrap`); `withDemos`
    (`Shikumi.Optimize.LabeledFewShot`); `proposeInstruction`/`ProposeIn`/`ProposeOut` for the
    fallback proposer (`Shikumi.Optimize.Instruction`).
  * `shikumi` (`Shikumi.Program`) — `Program`, `Params (..)`, `Demo (..)`, `foldParams`,
    `mapParamsAt`, `runProgram`, and (for the per-node path) `nodeFieldsIndexed`.
  * `shikumi-eval` (`Shikumi.Eval`) — `Dataset`, `Metric`, `Example (..)`, `datasetExamples`,
    `datasetSize`, `dataset`, `prediction`, `unScore`, `exactMatch` (tests).
  * `shikumi-compile` (`Shikumi.Compile.Types`, `Shikumi.Compile.Serialize`) — `CompiledProgram`,
    `compiledProgram`, `encodeCompiled`, `decodeCompiledOnto` (consumed unchanged; the serialization
    round-trip test).
  * `shikumi-trace` (`Shikumi.Trace`, `Shikumi.Trace.Node`) — **only on the per-node demo path**:
    `runProgramTraced`, `programNodePaths`, `runTrace`, `TraceTree`, `Span`/`SpanAttrs` (to read
    each node's recorded I/O). EP-16-owned; behind the `usePerNodeDemos` flag with a fallback, so
    this dependency is *optional* and the package builds without EP-16.
  * EP-19's proposer module (`Shikumi.Optimize.Propose` or as EP-19 names it) —
    `proposeInstructions`, `ProposeSignals`, `mkProposeSignals` (or equivalents); behind the
    `useGroundedProposer` flag with a V1 fallback, so optional until EP-19 lands.
  * `effectful` — the effect system; `Concurrent`, `Error`, `Prim`, `Time`, `LLM` are the row.
  * `aeson` — `ToJSON` for demo recovery (`recoverDemo` serializes typed I/O to JSON `Demo`s).
  * `tasty`/`tasty-hunit` — tests; `lens`/`generic-lens`/`baikai` — the stub-LM fixtures (already
    in the test stanza).

Signatures that must exist at the end of each milestone (full module paths):

End of **M0** (`Shikumi.Optimize.MIPRO` in `shikumi-optimize/src/Shikumi/Optimize/MIPRO.hs`,
re-exported from `Shikumi.Optimize`):

```haskell
data Miprov2Auto = Miprov2Light | Miprov2Medium | Miprov2Heavy
data Miprov2Config = Miprov2Config { {- 10 fields above -} }
miprov2Auto :: Miprov2Auto -> Miprov2Config
miprov2     :: (ToJSON i, ToJSON o) => Miprov2Auto -> Optimizer i o
miprov2With :: (ToJSON i, ToJSON o) => Miprov2Config -> Program i o -> Optimizer i o
```

End of **M1** (internal to `Shikumi.Optimize.MIPRO`, exported for tests):

```haskell
bootstrapDemoCandidates ::
  (ToJSON i, ToJSON o, LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Miprov2Config -> Program i o -> Dataset i o -> Metric o -> Program i o -> Eff es [[[Demo]]]
proposeInstructionCandidates ::
  (LLM :> es, Error ShikumiError :> es) =>
  Miprov2Config -> Program i o -> Dataset i o -> [[[Demo]]] -> Eff es [[Text]]
```

End of **M2**:

```haskell
searchJoint ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Miprov2Config -> Dataset i o -> Metric o -> Program i o -> [[Text]] -> [[[Demo]]] ->
  Eff es (Program i o)
```

End of **M3**: `miprov2With` has its real body (the M3 pipeline above) and all `Miprov2Spec`
groups pass; `encodeCompiled`/`decodeCompiledOnto` round-trip green.

Build/test facts: all builds and tests run inside `nix develop .#ghc9124` (GHC 9.12.4);
`cabal test shikumi-optimize` runs this package's suite and `cabal test all` runs the workspace;
formatting is fourmolu with two-space indentation; tests are hermetic via the stub `LLM`
interpreter in `shikumi-optimize/test/StubLM.hs`. Commits carry `MasterPlan:`, `ExecPlan:`, and
`Intention:` trailers (intention `intention_01ktq80q01emxtjfxzd3rw4tjs`). Sibling plans are
referenced by path only: `docs/plans/19-grounded-instruction-proposer.md` (hard dep) and
`docs/plans/16-node-correlated-tracing-and-feedback-channel.md` (soft dep).
