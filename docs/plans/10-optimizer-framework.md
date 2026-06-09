---
id: 10
slug: optimizer-framework
title: "Optimizer framework"
kind: exec-plan
created_at: 2026-06-08T02:44:17Z
intention: "intention_01ktjgkp10ef79vpwz1cmajek9"
master_plan: "docs/masterplans/1-shikumi-typed-lm-programming-framework.md"
---

# Optimizer framework

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi (仕組み — "the mechanism") is a Haskell framework for writing language-model (LM)
programs as ordinary, well-typed software instead of hand-written prompt strings. A
*program* in shikumi is a value of type `Program i o`: a typed description of an LM
computation that turns an input record of type `i` into an output record of type `o`. A
program contains, at each of its LM-calling nodes, two *parameters* that we are free to
change without changing what the program means: an **instruction** (a short natural-language
string telling the model what to do) and a list of **demonstrations** (worked
input/output examples, also called "few-shot demos", that are pasted into the prompt to
show the model the desired behaviour). A program written by a human is usually
*underspecified*: the instruction is vague and there are no demonstrations, so the model
performs poorly.

This ExecPlan delivers the **optimizer framework**: the part of shikumi that *automatically
improves a program*. In the DSPy framework (Stanford's "programming, not prompting"
library, the inspiration for shikumi) the equivalent component is called a *teleprompter* or
*optimizer*. An optimizer is, fundamentally, a **search procedure**: it repeatedly proposes
new values for the instruction and demonstration parameters, *scores* each candidate by
running the program over a dataset and measuring quality with a metric, and returns the
best-scoring program it found. Crucially, an optimizer changes only parameters, never the
program's structure or types, so the optimized program is the same typed function — just a
better-behaved one.

After this change a user can write a deliberately weak program — for example a single
`predict` node with the empty instruction `""` and no demos that is supposed to classify
the sentiment of a sentence — hand it a small labelled training set and a metric, call

```haskell
better <- optimize (bootstrapFewShot teacher defaultBudget) trainset exactMatch weak
```

and get back a `CompiledProgram` (a program plus a frozen set of node parameters, defined
by the sibling plan `docs/plans/9-compiler-layer.md`) that, when evaluated on a *held-out*
dataset it never saw during the search, scores **strictly higher** than the original weak
program. That measurable, held-out improvement — produced fully offline against a stub LM
in the test suite — is the user-visible behaviour this plan enables and the thing the
acceptance test asserts.

This plan provides four optimizers, each a different search strategy:

1. **Labeled few-shot** (`labeledFewShot`): pick the best `k` already-labelled examples
   from the training set and attach them as demonstrations. No LM calls beyond scoring; the
   simplest baseline.
2. **Bootstrap few-shot** (`bootstrapFewShot`): run a *teacher* program (often a stronger or
   chain-of-thought version of the program being optimized) over the training set, capture
   the *execution trace* of each run (the recorded inputs and outputs of every internal LM
   node), keep the traces of the examples the metric judged correct, and attach those
   captured input/output pairs as demonstrations to the *student* program's nodes. This
   "bootstraps" high-quality demos from the program's own successful behaviour.
3. **Instruction search** (`instructionSearch`, a MIPRO/COPRO-style optimizer): use a small
   shikumi program to *propose* several candidate instruction strings for each node via an
   LM, evaluate each, and keep the best instruction per node, all under an explicit call
   budget.
4. **Ensemble search** (`ensembleSearch`): run an inner optimizer several times to produce
   several complementary candidate programs, then combine them into one program using the
   `Ensemble` combinator (defined by the sibling plan
   `docs/plans/5-module-combinators-and-control-flow.md`), which runs all members and
   aggregates their answers (e.g. by majority vote).

All search is plumbed explicitly through the `effectful` effect system (see "Context and
Orientation"): there is no global mutable state; candidate programs are threaded as ordinary
values through pure folds, and only the *scoring* step performs effects (LM calls). Because
shikumi's caching layer (`docs/plans/6-caching-subsystem.md`) memoizes LM calls by request
content, re-evaluating overlapping candidates is cheap, which is what makes search
affordable.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M0 (spike): `shikumi-optimize` package scaffolded; `Optimizer` type and the
      `optimize` driver compile against the **real** sibling types; a no-op optimizer
      round-trips a program through `optimize`. **Done (2026-06-09).** `cabal test
      shikumi-optimize` green (1 test); `cabal build all` green.
- [x] M1: `labeledFewShot` implemented; candidate demo-set search; unit test shows the
      chosen demo set is the highest-scoring of those tried. **Done (2026-06-09).**
      Candidate sets are the deterministic size-@k@ combinations of the training demos
      (`labeledCandidateSets`, exported for the test); the test recomputes every candidate's
      score and asserts the chosen set attains the (non-trivial) maximum. Shared plumbing
      (`selectBest`/`scoreOn`/`freezeProgram`) lives in `Shikumi.Optimize.Search` to break the
      `Shikumi.Optimize` ⇄ optimizer-module import cycle.
- [x] M2: `bootstrapFewShot` implemented; demos recovered at the **program-I/O level**
      (`recoverDemo`) rather than per-node from the EP-7 trace (see Decision Log — the
      delivered trace lacks node correlation); test shows bootstrapped demos are attached only
      for metric-passing teacher runs. **Done (2026-06-09).**
- [x] M3: `instructionSearch` implemented with an LM-backed proposal program
      (`proposeInstruction`) and a budgeted coordinate-ascent proposal/selection loop; tests
      show the best-scoring proposed instruction is selected per node and the raw-LM-call
      budget bound is respected (counting stub). **Done (2026-06-09).** `fieldSummary` is
      static (EP-4 exposes no per-node signature accessor).
- [ ] M4: `ensembleSearch` implemented over the `Ensemble` combinator; test shows the
      ensemble scores at least as high as its best member.
- [ ] M5 (acceptance): end-to-end test optimizes a deliberately-underspecified program on a
      tiny dataset and asserts the returned `CompiledProgram` scores **strictly higher** on a
      held-out set than the input program; runs fully offline against the stub LM.
- [ ] Living sections (Decision Log, Surprises, Outcomes) kept current at each milestone.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **The delivered sibling APIs differ from this plan's pre-authoring sketch; adapted at
  M0 (2026-06-09).** Three concrete divergences, all reconciled by adapting call sites while
  keeping EP-10's public surface stable (as the plan's Interfaces section permits):
  (a) **Node addressing is by integer index, not `NodePath`.** EP-4 ships no
  `NodePath`/`programNodePaths`/`nodeParams`/`setNodeParams`/`nodeSignature`/`SomeSignature`.
  The real parameter interface is `foldParams :: Program i o -> [Params]` and
  `mapParamsAt :: Int -> (Params -> Params) -> Program i o -> Program i o` (plus `mapParams`
  for "all nodes"). So a node is addressed by its 0-based index in `foldParams` order;
  `instructionSearch`'s coordinate ascent iterates `[0 .. n-1]` where `n = length (foldParams
  prog)`.
  (b) **The `evaluate` effect row is wider than `(LLM :> es)`.** EP-8's
  `evaluate`/`evaluatePure` require `(LLM, Concurrent, Error ShikumiError, IOE) :> es`, so
  `Optimizer`'s rank-2 `runOptimizer`, `optimize`, and `scoreOn` all carry that exact row.
  `reportScore` is spelled `aggregateScore :: Report -> Double`.
  (c) **`CompiledProgram` is EP-9's `newtype`** with accessor `compiledProgram`; "freeze a
  program" is just its constructor (`freezeProgram = CompiledProgram`). EP-9's `fewShotTyped
  :: (ToJSON i, ToJSON o) => [(i, o)] -> Compiler` and `zeroShot` already do the
  demo/instruction parameter writes the optimizers need, so demo construction requires
  `(ToJSON i, ToJSON o)` on the demo-building optimizers.


## Decision Log

Record every decision made while working on the plan.

- Decision: An `Optimizer` is represented as a *record of functions* (an explicit strategy
  object), not a typeclass.
  Rationale: the four optimizers differ in what extra inputs they carry (a teacher program,
  a budget, an inner optimizer for ensembling) but share one driver signature. A record
  whose central field is `runOptimizer :: ... -> Eff es (CompiledProgram i o)` lets each
  smart constructor (`labeledFewShot`, `bootstrapFewShot`, …) close over its own extra
  configuration while presenting a uniform interface to `optimize`. A typeclass would force
  the extra configuration into associated types or a fundep, adding ceremony for no benefit
  and making it impossible to build an optimizer at runtime from CLI flags (which EP-12
  needs).
  Date: 2026-06-07.

- Decision (trace-to-demo recovery): To bootstrap a demonstration for an internal LM node,
  recover that node's *actual input record and output record* from the execution trace tree
  produced by the tracing layer (`docs/plans/7-hierarchical-tracing-observability-and-replay.md`),
  matching trace nodes to program nodes by a stable *node path* (the position of the node in
  the program's structure), and decode the recorded request/response back into the node's
  typed `i`/`o` via the same schema machinery the program used to make the call.
  Rationale: a demonstration *is* an input/output pair for a specific node; the trace already
  records exactly the inputs sent and outputs received per node, so recovering demos from the
  trace avoids re-running nodes and guarantees the demo is a faithful record of behaviour the
  program actually produced. Matching by node path (rather than by object identity, which
  Haskell does not offer for values) is the only stable correspondence between the trace tree
  and the program tree. See "Plan of Work — Milestone M2" for the exact recovery algorithm.
  Date: 2026-06-07.

- Decision (M2 impl, 2026-06-09): **Recover demos at the program-I/O level, not per-node from
  the trace.** Superseding the trace-to-demo decision above for this delivery: the delivered
  EP-7 (`Shikumi.Trace`) records LM-call spans by opaque `SpanId` carrying the *canonical
  wire request* and the *raw response JSON*, but ships **no** `NodePath`↔program-node
  correlation and **no** `runProgramTraced`; EP-4 likewise addresses nodes by integer index,
  not `NodePath`. So there is no faithful way to map a trace span back to a specific `Predict`
  node nor to reconstruct a node's *typed input* from a rendered prompt. Instead
  `bootstrapFewShot` runs the teacher with `runProgram`, and `recoverDemo i o = Demo (toJSON
  i) (toJSON o)` pairs the example's input with the teacher's produced output; kept demos
  (metric-passing only) attach to every node via `withDemos`. Rationale: this is faithful to
  bootstrap's user-visible behaviour for the single-module programs the acceptance test uses
  (and to DSPy's multi-module default of sharing demos across nodes), keeps `shikumi-optimize`
  off the `shikumi-trace` dependency, and the recovered demo is verified round-trippable
  through `fromModel` (M2 test (a)). Per-internal-node demo recovery is deferred until EP-7/EP-4
  expose a node-correlated trace. The drop of `shikumi-trace`/`runProgramTraced` from this
  plan's dependencies is the only interface change; the public optimizer surface is unchanged.

- Decision (instruction-proposal design): Instruction proposals are generated by a small
  *shikumi program* (`proposeInstruction :: Program ProposeIn ProposeOut`), not by ad-hoc
  string formatting against the raw LM. The proposer's input record carries the node's
  current instruction, the field names/descriptions of the node's signature, and a few
  example inputs from the trainset; its output record carries a single proposed instruction
  string. We generate `n` proposals per node by calling the proposer `n` times (the stub LM
  in tests returns a deterministic, scored set).
  Rationale: reusing a shikumi `Program` for the proposer means the proposer is itself
  typed, cached, traced, and testable with the same stub-LM machinery as everything else —
  no special-case prompt strings. It also dogfoods the framework: the optimizer is written
  in the framework it optimizes.
  Date: 2026-06-07.

- Decision (search budget): Every optimizer that issues LM calls takes an explicit
  `Budget { maxLmCalls :: Int, maxCandidates :: Int }`. The driver counts candidate
  evaluations and proposer calls; when a bound would be exceeded the search stops and returns
  the best candidate found *so far* (it never silently produces an unscored program).
  Rationale: LM search is open-ended and, in production, costs money; a hard, explicit bound
  makes cost predictable and makes tests deterministic (the test budget is tiny). Returning
  the best-so-far rather than erroring matches the "always return a usable program" contract
  that EP-12's `optimize` CLI subcommand relies on.
  Date: 2026-06-07.

- Decision (search-state plumbing): Search state (the set of scored candidates, the running
  call count, the best-so-far) is threaded explicitly as an ordinary value through a pure
  fold; the only effectful step is scoring a candidate (which calls `evaluate` from
  `docs/plans/8-evaluation-framework.md`). No `State`/`IORef`/global config is used to hold
  candidates.
  Rationale: the MasterPlan mandates "no global mutable state — thread candidate programs
  explicitly". A pure fold over candidates with an effectful scoring function is the simplest
  encoding, keeps the search reproducible, and makes the search trivially testable by
  swapping in a pure scorer.
  Date: 2026-06-07.

- Decision: Reuse, do not redefine, the integration types owned by sibling plans:
  `Program i o` and the parameter-traversal interface from
  `docs/plans/4-typed-program-representation-and-core-modules.md`; `Dataset`/`Example`/
  `Prediction`/`Metric`/`Report`/`evaluate` from `docs/plans/8-evaluation-framework.md`;
  `CompiledProgram i o` from `docs/plans/9-compiler-layer.md`; the trace tree from
  `docs/plans/7-hierarchical-tracing-observability-and-replay.md`; the cache effect from
  `docs/plans/6-caching-subsystem.md`.
  Rationale: these are the MasterPlan's integration points #4, #5, #6, and #7. Redefining
  them would fork the framework. This plan consumes them and adds only the search layer.
  Date: 2026-06-07.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**The repository.** Shikumi lives at the repo root (the directory containing
`cabal.project`). It is a multi-package Haskell project: each subdirectory under the root
(for example `shikumi/`, `shikumi-eval/`, `shikumi-compile/`) is a separate Cabal package
with its own `.cabal` file, and `cabal.project` lists them all. This plan adds a new package
`shikumi-optimize/`. Build everything with `cabal build all` and run all tests with
`cabal test all`, both from the repo root. The project uses GHC's `GHC2024` language
edition (a bundle of modern default extensions); follow the style of the existing packages.

**The dependency it sits on.** Shikumi is built on top of *baikai*, a separate Haskell
library (at `/Users/shinzui/Keikaku/bokuno/baikai`) that owns the provider/transport layer
(sending requests to OpenAI/Anthropic/etc. and getting responses). You do **not** interact
with baikai directly in this plan; you only ever go through shikumi's own layers. To find
baikai's source if you ever need it, the user's environment provides a tool called `mori`
(`mori registry show shinzui/baikai --full`); never search `/nix/store` or `/`.

**`effectful`, in plain terms.** Shikumi uses the `effectful` library to track, *in a
function's type*, which capabilities (called *effects*) that function may use. You will see
types like `Eff es a`, read as "a computation in the effect stack `es` that produces an
`a`". The notation `(LLM :> es)` is a constraint meaning "the effect stack `es` includes the
`LLM` effect", i.e. this function is allowed to make LM calls. Effects are *interpreted* by
handler functions (defined in other plans) that say what the effect actually does. For this
plan, the only effects you need to mention in signatures are `LLM` (to make LM calls during
search) and whatever the consumed functions (`evaluate`, `runProgram`) require; you compose
them by listing them in the constraint, e.g. `(LLM :> es) =>`. The key consequence:
**there is no global mutable variable** for "the current candidate program" — you pass
candidates around as plain function arguments and return values.

**Integration point #4 — `Program i o` and parameter traversal (owner:
`docs/plans/4-typed-program-representation-and-core-modules.md`).** A `Program i o` is a
GADT (a data type whose constructors are individually typed) describing an LM computation
from input record `i` to output record `o`. Its leaf constructor is `Predict signature
params`, where `params` holds the *optimizable parameters* of that node: its instruction
string and its list of demonstrations. EP-4 exposes a *parameter-traversal interface* so
that code in this plan can read and rewrite the parameters of every node without runtime
reflection. This plan **consumes** that interface and must not redefine `Program`. The
specific operations this plan relies on EP-4 to provide are spelled out, by name and
signature, under "Interfaces and Dependencies"; treat them as a contract. In short you can
(a) enumerate every node's *path* (a stable identifier for the node's position in the
program tree), (b) read a node's current `Params`, and (c) produce a new program with a
node's `Params` replaced. You also have `runProgram :: (LLM :> es) => Program i o -> i ->
Eff es o` to execute a program.

**`Params`, instructions, and demonstrations.** EP-4 defines the per-node parameter record.
For this plan's purposes it carries at least an instruction string and a list of
demonstrations. A *demonstration* (demo) is a stored input/output pair for *that node's*
signature — i.e. a value pairing the node's input record with the node's output record —
which the adapter renders into the prompt as a worked example. EP-4/EP-3 own the exact demo
type; this plan refers to it as `Demo` and uses EP-4's `Params`-rewriting operations to
attach demos. Because demos are typed per node, attaching a demo to a node requires that the
demo's input/output types match that node's signature; the trace-recovery step (M2) is where
we obtain correctly-typed demos.

**Integration point #5 — the evaluation data model (owner:
`docs/plans/8-evaluation-framework.md`).** That plan defines: `Example i o` (one labelled
data point — an input plus its expected output, with input fields marked); `Dataset i o` (a
collection of `Example i o`); `Prediction o` (a program's produced output, possibly with
multiple samples); `Metric o` (a function scoring a prediction against an expected output,
yielding a number in `[0,1]` where higher is better — `1.0` for a perfect match);
`Report` (the aggregate result of evaluating a program: an overall score plus per-example
detail); and the driver
`evaluate :: (LLM :> es) => Program i o -> Dataset i o -> Metric o -> Eff es Report`,
plus `reportScore :: Report -> Double` returning the aggregate score. This plan **consumes**
all of these and must not redefine them. (`exactMatch :: Eq o => Metric o`, a built-in
metric returning `1.0` when the prediction equals the expected output and `0.0` otherwise,
is also provided by EP-8 and used in the tests below.)

**Integration point #6 — `CompiledProgram i o` (owner:
`docs/plans/9-compiler-layer.md`).** That plan defines `CompiledProgram i o` as a `Program i
o` together with a frozen set of node parameters, plus the operations to build one from a
program with rewritten parameters and to run it. This plan **consumes** it: `optimize`
returns a `CompiledProgram i o`. The specific operations relied upon (constructing a
`CompiledProgram` from a `Program` whose parameters have been rewritten, and extracting the
underlying `Program` to evaluate it) are named under "Interfaces and Dependencies".

**Integration point #7 — the trace tree and cache (owners:
`docs/plans/7-hierarchical-tracing-observability-and-replay.md` and
`docs/plans/6-caching-subsystem.md`).** EP-7's *trace tree* is a hierarchical record of one
program run: a tree of nodes, each recording the LM request sent and response received at
one program node, identified by the same *node path* used by EP-4's traversal. This plan
reads the trace tree to recover demos (M2). EP-6's *cache* memoizes LM calls by request
content; running the same candidate twice, or two candidates that share sub-computations,
costs at most one real LM call. This plan does not configure the cache; it simply benefits
from it being in the effect stack during scoring.

**What "stub LM" means for tests.** All four sibling layers (EP-4, EP-6, EP-7, EP-8) are
designed to run against a *stub* (mock) interpreter of the `LLM` effect that returns
canned, deterministic responses instead of calling a real provider — this is how the whole
framework is tested offline. This plan's tests run inside that stub so that search is
deterministic and free. The stub used here is defined in this package's test suite (see
"Plan of Work — Milestone M0") and returns outputs that depend deterministically on the
input and on the node's current instruction/demos, so that *changing parameters changes the
score* — which is exactly what lets an optimizer demonstrably improve a program offline.


## Plan of Work

All new code lives in a new package `shikumi-optimize/` with modules under `Shikumi.Optimize.*`.
Create the package skeleton in M0 and grow it milestone by milestone. The reader edits only
files inside `shikumi-optimize/` plus the single line in `cabal.project` that registers the
package; no other package is modified by this plan.

The work is six milestones. M0 de-risks the integration surface (the four sibling types this
plan consumes). M1–M4 each add one optimizer with its own test. M5 is the end-to-end
acceptance test that proves measurable, held-out improvement.

### Milestone M0 — Package scaffold, `Optimizer` type, `optimize` driver, no-op spike

Scope: stand up the package and the central abstraction, and prove the integration surface
compiles, before writing any real search. At the end of this milestone the package builds,
exports `Optimizer`, `Budget`, and `optimize`, and a test drives a *no-op optimizer* (one
that returns its input program compiled unchanged) through `optimize` and gets a
`CompiledProgram` back.

Create `shikumi-optimize/shikumi-optimize.cabal` declaring a library exposing
`Shikumi.Optimize`, `Shikumi.Optimize.Types`, and (later) one module per optimizer, plus a
test-suite `shikumi-optimize-test`. Depend on the sibling packages `shikumi` (core,
providing `Program`, `LLM`, the parameter traversal), `shikumi-eval`, `shikumi-compile`,
`shikumi-trace`, `shikumi-cache`, and on `effectful`, `text`, `containers`, `vector`. Add the
package directory to `cabal.project`.

In `Shikumi.Optimize.Types` define the strategy record and the budget:

```haskell
-- | An optimizer is a search strategy that, given a training dataset, a metric, and a
-- starting program, searches for better node parameters and returns a compiled program.
-- It is a record of functions so that each smart constructor can close over its own extra
-- configuration (teacher, budget, inner optimizer) while sharing one driver signature.
newtype Optimizer i o = Optimizer
  { runOptimizer
      :: forall es. (LLM :> es)
      => Dataset i o          -- ^ training set the search is allowed to fit to
      -> Metric o             -- ^ how candidates are scored
      -> Program i o          -- ^ the starting (student) program
      -> Eff es (CompiledProgram i o)
  }

-- | A hard, explicit bound on search cost. The driver counts evaluations and proposer
-- calls and stops (returning the best candidate found so far) before any bound is exceeded.
data Budget = Budget
  { maxLmCalls    :: !Int   -- ^ ceiling on LM calls the optimizer may make (proposals + scoring)
  , maxCandidates :: !Int   -- ^ ceiling on candidate programs scored
  } deriving (Eq, Show)

defaultBudget :: Budget
defaultBudget = Budget { maxLmCalls = 200, maxCandidates = 32 }
```

In `Shikumi.Optimize` define the public driver as a thin wrapper that simply runs the
strategy (the per-optimizer logic lives in the strategy; the driver exists so the public API
is one stable function and so EP-12's CLI calls one name):

```haskell
optimize
  :: (LLM :> es)
  => Optimizer i o -> Dataset i o -> Metric o -> Program i o
  -> Eff es (CompiledProgram i o)
optimize opt train metric prog = runOptimizer opt train metric prog
```

Also define the shared, *pure* search-state plumbing that every real optimizer reuses (this
is the "thread candidates explicitly" mechanism the Decision Log mandates). Provide a
helper that, given a list of candidate programs and an effectful scorer, evaluates each
under the budget and returns the highest-scoring one together with its score:

```haskell
-- | A scored candidate. Threaded as a plain value; no mutable state.
data Scored a = Scored { candidate :: a, score :: !Double }

-- | Score every candidate (left to right) with the effectful scorer, stopping once the
-- candidate budget is hit, and return the best by score (ties: earliest wins). The scorer
-- is the ONLY effectful part; the selection is a pure fold over the results.
selectBest
  :: (LLM :> es)
  => Budget
  -> (cand -> Eff es Double)   -- ^ scorer (will call `evaluate`)
  -> [cand]                    -- ^ candidates, threaded explicitly
  -> Eff es (Maybe (Scored cand))
```

`selectBest` `take`s `maxCandidates` from the list, maps the scorer over them collecting
`Scored` values, then folds to the maximum by `score` (earliest on ties). The fold is pure;
only the per-candidate scorer touches the effect stack. This is the canonical place to read
to understand "search-state plumbing".

Define the standard scorer all optimizers use, built on EP-8's `evaluate`:

```haskell
-- | Score a candidate program against a dataset+metric: run `evaluate`, take the aggregate.
scoreOn :: (LLM :> es) => Dataset i o -> Metric o -> Program i o -> Eff es Double
scoreOn ds m p = reportScore <$> evaluate p ds m
```

Finally, in the test suite create `shikumi-optimize/test/StubLM.hs` providing
`runStubLM :: Eff (LLM : es) a -> Eff es a`, a pure interpreter of the `LLM` effect that
produces deterministic responses. The stub must make a program's score depend on its
parameters, so define it to reflect, in its canned output, both the input and the node's
current instruction/demos (for example: the stub answers a sentiment-classification node
correctly only when the node's demos include an example with the same label, or when the
instruction contains a keyword — the precise rule is the test author's choice, but it must
be *monotone enough* that better parameters yield better scores). Document the exact stub
rule in a comment so the determinism is auditable.

Verification: `cabal build all` succeeds. A test `noopOptimizer` (constructed inline as
`Optimizer (\_ _ p -> compileUnchanged p)`, where `compileUnchanged` is EP-9's "wrap a
program as a compiled program without changing parameters" operation) run through
`optimize` returns a `CompiledProgram` whose extracted program equals the input. Acceptance:
`cabal test shikumi-optimize-test` passes the M0 test group.

### Milestone M1 — Labeled few-shot demo selection

Scope: the simplest real optimizer. Add `Shikumi.Optimize.LabeledFewShot` exporting

```haskell
labeledFewShot :: Int -> Optimizer i o   -- ^ argument: k, the number of demos to attach
```

Algorithm, in prose. The training `Dataset i o` is a list of labelled `Example i o`. Each
example's input/expected-output pair *is* a candidate demonstration for the program's single
top-level node (M1 handles the single-`Predict` case; multi-node programs attach the same
demo set to every `Predict` node, which is the DSPy default). The search:

1. Convert each training example into a `Demo` (an input/output pair typed to the node's
   signature) using EP-8's accessor for an example's input and expected output and EP-4's
   `Demo` constructor.
2. Form several *candidate demo sets*, each of size `k`, by taking sliding/`k`-sized
   selections from the (optionally shuffled-by-a-fixed-seed) list of demos. To keep tests
   deterministic and offline, selection uses a fixed pseudo-random permutation seeded by a
   constant, and the number of candidate sets is bounded by `maxCandidates`. (DSPy's
   `LabeledFewShot` samples; we enumerate a bounded, seeded set so the result is
   reproducible.)
3. For each candidate demo set, produce a candidate program by using EP-4's parameter
   traversal to set every node's demos to that set (instruction unchanged), then score it
   with `scoreOn` over the *training* set.
4. Use `selectBest` to pick the highest-scoring candidate, then return it as a
   `CompiledProgram` via EP-9's "freeze this program's current parameters into a compiled
   program" operation.

Search-state note: the candidate demo sets are an ordinary `[[Demo]]` value; the chosen set
is just the `candidate` field of the winning `Scored`. No mutation.

Verification: a unit test builds three candidate demo sets where, under the stub LM, exactly
one yields a perfect training score and the others do not, and asserts that
`runOptimizer (labeledFewShot k) train exactMatch prog` returns a compiled program whose
attached demos equal the winning set. Acceptance: `cabal test shikumi-optimize-test` passes
the M1 group, demonstrating that the *chosen* demo set is the highest-scoring of those
tried (not merely "some demos were attached").

### Milestone M2 — Trace-to-demo recovery and bootstrap few-shot

Scope: the centerpiece. Add `Shikumi.Optimize.Bootstrap` exporting

```haskell
bootstrapFewShot
  :: Program i o    -- ^ teacher program (may be a stronger/CoT variant; may equal the student)
  -> Budget
  -> Optimizer i o  -- ^ optimizes the STUDENT program passed to `optimize`
```

First implement **trace-to-demo recovery** as its own function so it is independently
testable:

```haskell
-- | Given one run's trace tree and the program that produced it, recover, for every
-- internal Predict node, the (input, output) pair that node actually processed, keyed by
-- the node's stable path. The result is a map from node path to that node's recovered Demo.
recoverDemos :: Program i o -> TraceTree -> Map NodePath Demo
```

Recovery algorithm, precisely. EP-7's `TraceTree` is a tree of trace nodes, each carrying
(a) the *node path* identifying which program node produced it (the same `NodePath` EP-4's
traversal assigns), (b) the raw LM *request* sent at that node, and (c) the raw LM
*response* received. EP-4's parameter traversal gives, for each `NodePath`, the `Signature`
of the program node at that path (a `Predict` node's signature knows the node's input and
output record types and how to decode them). To recover a node's demo:

1. Walk the program with EP-4's traversal to build a map `NodePath -> SomeSignature`
   (a signature whose types are existentially carried so the map is homogeneous; recovery
   re-establishes the concrete types per node when decoding).
2. Walk the trace tree; for each trace node, look up the program signature at the same
   `NodePath`. Decode the trace node's recorded *request* back into that node's input record
   using the signature's input decoder (the request was produced from that input by the
   adapter, so the adapter's inverse — provided by EP-3 via the signature — recovers it; if
   the trace stores the structured input directly, decode that instead, which is the
   preferred path and what the tests use), and decode the recorded *response* into the
   node's output record using the signature's output decoder.
3. Pair the recovered input and output into a `Demo` for that node and insert it under the
   node's `NodePath`.

If decoding fails for a node (e.g. a malformed response), that node is simply omitted from
the map — recovery is total and never throws; a missing node just yields no bootstrapped
demo there.

Now `bootstrapFewShot teacher budget` is the optimizer:

1. For each training `Example i o`, run the *teacher* program on the example's input with
   tracing enabled to obtain both the prediction and the run's `TraceTree`. (EP-7 provides a
   "run a program and also return its trace tree" operation; this plan names it
   `runProgramTraced`. Each such run counts against `maxLmCalls`.)
2. Score the teacher's prediction for that example with the metric. **Keep** the example's
   recovered demos only if the metric judged the prediction *correct* (score `== 1.0` for a
   boolean-style metric, or `>= passThreshold` for a graded one; `passThreshold` defaults to
   `1.0` and is a field of `bootstrapFewShot`'s configuration). This is the "keep traces
   where the metric passes" rule.
3. Accumulate, per `NodePath`, the list of recovered demos across all kept examples (so each
   node collects demos from every training example the teacher got right). Cap each node's
   demo list at `maxBootstrappedDemos` (default 4) by taking the first that many, so prompts
   stay bounded.
4. Build the student program by using EP-4's parameter traversal to set each node's demos to
   that node's accumulated bootstrapped list (instruction unchanged), and return it as a
   `CompiledProgram` via EP-9.

Note on student vs teacher node correspondence: bootstrap assumes the teacher and student
share the same node structure (same `NodePath`s) — the common case where the teacher is the
student wrapped in chain-of-thought or simply the student itself with a stronger stub LM.
The plan documents this assumption; if a node path exists in the student but not in the
recovered map, that node keeps its original (empty) demos.

Search-state note: the per-node demo accumulation is a `Map NodePath [Demo]` folded over the
list of (kept) training examples — a pure fold; the only effects are the traced teacher runs
and the per-example metric scoring.

Verification: two tests. (a) A `recoverDemos` unit test feeds a hand-built `TraceTree` (one
node, a known recorded input/output) and asserts the recovered `Demo` equals the expected
input/output pair. (b) A `bootstrapFewShot` test where, under the stub LM, the teacher gets
two of three training examples "right" and one "wrong"; assert that exactly the two correct
examples' input/output pairs appear as demos on the student node and the wrong one does not.
Acceptance: `cabal test shikumi-optimize-test` passes the M2 group, demonstrating per-node
recovery from the trace and the metric-pass filter.

### Milestone M3 — Instruction search (MIPRO/COPRO-style)

Scope: search over *instruction strings* using an LM proposer, per node, under budget. Add
`Shikumi.Optimize.Instruction` exporting

```haskell
instructionSearch :: Int -> Budget -> Optimizer i o   -- ^ Int = proposals per node
```

The proposer is a small shikumi program defined in the same module:

```haskell
data ProposeIn  = ProposeIn  { currentInstruction :: Text, fieldSummary :: Text, examples :: Text }
data ProposeOut = ProposeOut { proposedInstruction :: Text }
proposeInstruction :: Program ProposeIn ProposeOut
```

`proposeInstruction` is an ordinary `predict`-style program (built with EP-4's `predict`)
whose signature's instruction tells the model to write a better instruction for a task,
given the current instruction, a summary of the task's input/output fields, and a few
example inputs. Because it is a shikumi program it is cached and traced like everything else,
and in tests the stub LM returns deterministic proposals.

Proposal + selection loop, in prose:

1. Enumerate the student's nodes via EP-4's traversal (each is a `NodePath` with a current
   `Params`).
2. For each node, build a `ProposeIn` from the node's current instruction, a textual summary
   of its signature's fields (names + descriptions, from EP-3 via the signature), and a
   handful of stringified training inputs. Call `runProgram proposeInstruction propIn`
   `proposalsPerNode` times to get that many candidate instructions; each call counts
   against `maxLmCalls`. Always include the *current* instruction as a candidate too, so the
   search can never do worse than the starting point for that node.
3. For each candidate instruction at that node, form a candidate program by rewriting only
   that node's instruction (other nodes unchanged), and score it with `scoreOn` over the
   training set. Use `selectBest` to pick the node's best instruction. Keep that instruction
   in the program and move to the next node (a greedy, coordinate-ascent search: optimize one
   node at a time, holding the others fixed — this is the COPRO strategy and keeps the
   candidate count linear in nodes × proposals rather than exponential).
4. Stop early and return the best-so-far if `maxLmCalls` or `maxCandidates` would be
   exceeded. Return the final program (all nodes' chosen instructions) as a
   `CompiledProgram` via EP-9.

Budget bound, explicit: total LM calls ≤ (number of nodes) × (`proposalsPerNode` proposer
calls + (`proposalsPerNode` + 1) scoring evaluations × dataset size), capped by
`maxLmCalls`; total candidates scored ≤ (number of nodes) × (`proposalsPerNode` + 1), capped
by `maxCandidates`. The driver checks the running counts before each call and halts at the
ceiling.

Search-state note: the program under construction is threaded explicitly through the
coordinate-ascent fold over nodes — `foldl'`-style, each step taking the current best program
and returning the program with one more node's instruction fixed. No mutation.

Verification: a test where, under the stub LM, the proposer offers (deterministically) one
instruction containing a "magic" keyword that makes the stub answer correctly and others
that do not; assert that `instructionSearch` selects the magic instruction for the node and
that the recorded LM-call count does not exceed the budget (instrument the stub to count
calls and assert the count ≤ `maxLmCalls`). Acceptance: `cabal test shikumi-optimize-test`
passes the M3 group, demonstrating best-instruction selection per node and budget
enforcement.

### Milestone M4 — Ensemble search

Scope: produce several complementary programs and combine them. Add
`Shikumi.Optimize.Ensemble` exporting

```haskell
ensembleSearch :: Int -> Optimizer i o -> Optimizer i o   -- ^ Int = ensemble size; inner optimizer to vary
```

Algorithm: run the inner optimizer `size` times, each time on a different *bootstrap sample*
of the training set (sampling the dataset with a different fixed seed per member, the
classic bagging trick that makes members complementary), collecting `size` candidate
programs. Combine them into one program with the `Ensemble` combinator from
`docs/plans/5-module-combinators-and-control-flow.md` — `ensemble :: [Program i o] ->
Program i o` — which runs all members on the input and aggregates their outputs (the default
aggregation is majority vote for `Eq o`, provided by EP-5). Return the ensemble program as a
`CompiledProgram` via EP-9. If the inner optimizer already returns `CompiledProgram`s,
extract each member's underlying `Program` with EP-9's accessor before building the ensemble.

Search-state note: the list of member programs is threaded explicitly; building the ensemble
is a pure combination of those values.

Verification: a test where the inner optimizer is a stub that returns two members which each
answer half of a held-out set correctly but disagree such that majority vote (with a third
tie-breaking member or a deterministic tie rule) is correct more often than either member;
assert `reportScore` of the ensemble on the held-out set is `>=` the best member's score.
Acceptance: `cabal test shikumi-optimize-test` passes the M4 group.

### Milestone M5 — End-to-end acceptance: measurable held-out improvement

Scope: the single test that proves the whole point. Add `shikumi-optimize/test/Acceptance.hs`.

Construct a *deliberately-underspecified* program: a single `predict` node over a tiny
sentiment task (`data Sentence = Sentence { text :: Text }`, `data Label = Label { sentiment
:: Text }`), with an empty instruction and no demos. Build a tiny `trainset` (say 6 labelled
examples) and a *disjoint* `heldout` set (say 4 labelled examples the optimizer never sees).
Use `exactMatch` as the metric and `runStubLM` as the LM interpreter. The stub must be
written so the empty/no-demo program scores poorly and a bootstrapped/demo-rich program
scores well on *both* sets (the stub generalizes — its answer rule depends on the demos and
input, not on memorizing specific trainset items).

The test:

1. Compute `before <- runStubLM (scoreOn heldout exactMatch underspecified)`.
2. Compute `after <- runStubLM $ do
       cp <- optimize (bootstrapFewShot teacher defaultBudget) trainset exactMatch underspecified
       scoreOn heldout exactMatch (compiledProgram cp)`
   where `compiledProgram` is EP-9's accessor extracting the runnable `Program` from a
   `CompiledProgram`, and `teacher` is the underspecified program run under a stronger stub
   rule (or simply the same program — the stub is configured so the teacher succeeds on
   enough trainset items to produce useful demos).
3. Assert `after > before` **strictly** (use `assertBool ("expected " <> show after <> " > "
   <> show before) (after > before)`), and additionally assert `after >= someFloor` (e.g.
   `>= 0.75`) so the test fails loudly if a future change silently makes the optimizer a
   no-op while still nudging the score by an epsilon.

Run the same assertion for at least one other optimizer (`labeledFewShot k` and/or
`instructionSearch`) to show the improvement is not specific to one strategy.

Acceptance: `cabal test shikumi-optimize-test` — the acceptance group fails on the
underspecified program (before-score is low) and passes after optimization (after-score
strictly higher on the held-out set). This is the behaviour the Purpose section promises.


## Concrete Steps

Run all commands from the repository root (the directory containing `cabal.project`).

Scaffold the package (M0):

```bash
mkdir -p shikumi-optimize/src/Shikumi/Optimize shikumi-optimize/test
$EDITOR shikumi-optimize/shikumi-optimize.cabal      # library + test-suite as described in M0
$EDITOR cabal.project                                # add: packages: ... shikumi-optimize/
$EDITOR shikumi-optimize/src/Shikumi/Optimize/Types.hs
$EDITOR shikumi-optimize/src/Shikumi/Optimize.hs
$EDITOR shikumi-optimize/test/StubLM.hs
$EDITOR shikumi-optimize/test/Main.hs                # test driver wiring the M0..M5 groups
```

Build and test after each milestone:

```bash
cabal build all
cabal test shikumi-optimize-test
```

Expected transcript shape once M5 lands (numbers will vary with your stub rule):

```text
shikumi-optimize-test
  M0 no-op optimizer round-trips:           OK
  M1 labeledFewShot picks best demo set:    OK
  M2 recoverDemos recovers node i/o:        OK
  M2 bootstrap keeps only passing demos:    OK
  M3 instructionSearch picks magic instr:   OK
  M3 instructionSearch respects budget:     OK
  M4 ensemble >= best member:               OK
  M5 acceptance: held-out improvement:      OK
      before=0.25  after=1.00  (strictly higher)

All N tests passed
```

If a milestone's test fails, the failure message names the milestone (e.g. the acceptance
assertion prints `expected 1.0 > 0.25`); fix the corresponding module and re-run. Because the
stub LM is pure and deterministic, results are reproducible run to run.


## Validation and Acceptance

The plan is accepted when `cabal test shikumi-optimize-test` passes all six milestone
groups, and specifically when the M5 acceptance test demonstrates **strictly higher
held-out score after optimization than before**. Phrased as observable behaviour: take a
sentiment program with an empty instruction and no demonstrations; on the four-example
held-out set it answers poorly (e.g. 1/4 correct, score 0.25). Call `optimize` with
`bootstrapFewShot` over the six-example training set under `exactMatch`. Run the returned
`CompiledProgram` on the *same* held-out set; it answers strictly better (e.g. 4/4, score
1.00). The assertion `after > before` is true and the test passes; with the underspecified
program left unoptimized it would fail, proving the optimizer is doing real work and not a
no-op. The supporting milestone tests prove each search strategy independently: that
labeled-few-shot returns the *highest-scoring* demo set tried (M1), that bootstrap recovers
per-node input/output from the trace and keeps only metric-passing demos (M2), that
instruction search selects the best proposed instruction per node within the LM-call budget
(M3), and that the ensemble scores at least as high as its best member (M4). All validation
runs offline against the deterministic stub LM, so it requires no API keys, no network, and
no cost, and is reproducible.


## Idempotence and Recovery

Every step is additive and safe to repeat. Re-running `cabal build all` and
`cabal test shikumi-optimize-test` is harmless. The only edit outside the new package
directory is adding one line to `cabal.project`; if that line is already present, leave it.
If a milestone's module does not yet compile, the earlier milestones' tests still build and
pass (the test driver in `test/Main.hs` should add each milestone's group as it lands, so a
partially-completed plan still produces a green suite for the finished milestones). Because
search state is threaded as plain values and the stub LM is pure, there is no persistent
state to corrupt and no cleanup to perform; deleting the `shikumi-optimize/` directory and
the `cabal.project` line fully reverts the plan.


## Interfaces and Dependencies

This package introduces (owns) the following, in `shikumi-optimize`:

- `Shikumi.Optimize.Types`: `data Optimizer i o` (with field `runOptimizer`), `data Budget`
  (`maxLmCalls`, `maxCandidates`), `defaultBudget :: Budget`, `data Scored a`.
- `Shikumi.Optimize`:
  `optimize :: (LLM :> es) => Optimizer i o -> Dataset i o -> Metric o -> Program i o -> Eff es (CompiledProgram i o)`;
  `selectBest :: (LLM :> es) => Budget -> (cand -> Eff es Double) -> [cand] -> Eff es (Maybe (Scored cand))`;
  `scoreOn :: (LLM :> es) => Dataset i o -> Metric o -> Program i o -> Eff es Double`.
- `Shikumi.Optimize.LabeledFewShot`: `labeledFewShot :: Int -> Optimizer i o`.
- `Shikumi.Optimize.Bootstrap`:
  `recoverDemos :: Program i o -> TraceTree -> Map NodePath Demo`;
  `bootstrapFewShot :: Program i o -> Budget -> Optimizer i o`.
- `Shikumi.Optimize.Instruction`:
  `data ProposeIn`, `data ProposeOut`, `proposeInstruction :: Program ProposeIn ProposeOut`,
  `instructionSearch :: Int -> Budget -> Optimizer i o`.
- `Shikumi.Optimize.Ensemble`: `ensembleSearch :: Int -> Optimizer i o -> Optimizer i o`.

This package **consumes** (and must NOT redefine) the following, owned by sibling plans.
Treat these signatures as the contract; if a sibling's final name differs slightly, adapt
the call sites but keep this plan's own public signatures stable.

- From `docs/plans/4-typed-program-representation-and-core-modules.md` (the `shikumi` core
  package): `data Program i o`; `runProgram :: (LLM :> es) => Program i o -> i -> Eff es o`;
  `predict` (smart constructor for a single `Predict` node); the per-node parameter type
  `Params` (carrying at least an instruction `Text` and demos `[Demo]`); the demo type
  `Demo` and a constructor pairing a node-typed input and output into a `Demo`; the
  parameter-traversal interface, which this plan uses as: `programNodePaths :: Program i o ->
  [NodePath]` (enumerate node paths), `nodeParams :: NodePath -> Program i o -> Maybe Params`
  (read a node's params), `setNodeParams :: NodePath -> Params -> Program i o -> Program i o`
  (rewrite a node's params, returning a new program), and `nodeSignature :: NodePath ->
  Program i o -> Maybe SomeSignature` (the node's signature for decoding). `NodePath` is
  EP-4's stable per-node identifier.
- From `docs/plans/8-evaluation-framework.md` (the `shikumi-eval` package): `Dataset i o`,
  `Example i o` (with accessors for an example's input and expected output), `Prediction o`,
  `Metric o`, `Report`, `reportScore :: Report -> Double`,
  `evaluate :: (LLM :> es) => Program i o -> Dataset i o -> Metric o -> Eff es Report`, and
  `exactMatch :: Eq o => Metric o`.
- From `docs/plans/9-compiler-layer.md` (the `shikumi-compile` package): `CompiledProgram i
  o`; an operation to build a `CompiledProgram` from a `Program` whose parameters have been
  rewritten (this plan calls it `freezeProgram :: Program i o -> CompiledProgram i o`, and
  `compileUnchanged` is `freezeProgram` applied to an unmodified program); and an accessor
  `compiledProgram :: CompiledProgram i o -> Program i o` extracting the runnable program.
- From `docs/plans/7-hierarchical-tracing-observability-and-replay.md` (the `shikumi-trace`
  package): `data TraceTree` (a tree of trace nodes, each carrying a `NodePath`, the LM
  request, and the LM response) and
  `runProgramTraced :: (LLM :> es) => Program i o -> i -> Eff es (o, TraceTree)` (run a
  program and also return its trace tree).
- From `docs/plans/6-caching-subsystem.md` (the `shikumi-cache` package): no direct API call
  — this plan benefits implicitly from the cache being in the effect stack during scoring,
  which makes repeated/overlapping candidate evaluations cheap. Tests may run with or without
  the cache interpreter installed; correctness does not depend on it.
- From `docs/plans/5-module-combinators-and-control-flow.md` (the `shikumi` core package):
  `ensemble :: [Program i o] -> Program i o` (combine programs, aggregating by majority vote
  for `Eq o`).
- The `LLM` effect (from `docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`):
  this plan only mentions it in constraints (`(LLM :> es)`); the test suite provides
  `runStubLM` to interpret it deterministically and offline.

External libraries: `effectful` (effect stack and `Eff`), `text` (`Text`), `containers`
(`Map`, `Data.Map.Strict`), `vector` (datasets, if EP-8 uses `Vector`). No new external
dependency is introduced beyond what the sibling packages already pull in.
