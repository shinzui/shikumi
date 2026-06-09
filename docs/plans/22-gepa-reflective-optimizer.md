---
id: 22
slug: gepa-reflective-optimizer
title: "GEPA reflective optimizer"
kind: exec-plan
created_at: 2026-06-09T22:35:41Z
intention: "intention_01ktq80q01emxtjfxzd3rw4tjs"
master_plan: "docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md"
---

# GEPA reflective optimizer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi (the typed language-model-programming framework rooted at
`/Users/shinzui/Keikaku/bokuno/shikumi`) lets you build a language-model pipeline as a
value of type `Program i o` — a tree of nodes, some of which (`Predict` nodes) actually
call a language model with an *instruction* (a natural-language directive) and optional
*demonstrations* (worked input/output examples). Shikumi already ships several
*optimizers*: search procedures that automatically rewrite a program's per-node
instructions and demonstrations to make it score higher on a dataset, returning a
`CompiledProgram i o` you can run, save, and reload. The existing instruction optimizer
(`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/Instruction.hs`)
is *greedy coordinate ascent*: it walks node by node, asks a proposer for a few candidate
instructions, scores each, keeps the best, and moves on. It never looks at *why* a node
failed, and it keeps only a single running-best program.

This plan adds **GEPA** — short for *Genetic-Pareto*, a reflective evolutionary optimizer.
Where the greedy search is blind, GEPA is *reflective*: it runs the program while capturing,
for each individual node, a short natural-language **critique** ("feedback") describing how
that node performed on each example — for instance, "the answer was too vague; be more
specific about the date format." It then *reflects* on those critiques and proposes a
rewritten instruction for one selected node, using a small typed Shikumi program as the
proposer. Where the greedy search keeps one best program, GEPA keeps a **Pareto frontier**:
a set of *candidate programs* none of which is strictly worse than another across the
*per-example* score vector (one program may be best on example 3 while another is best on
example 7; both are kept). GEPA samples a *parent* program from this frontier, mutates one
of its nodes by reflection, scores the *child*, and folds the child back into the frontier —
repeating until a budget is spent. The frontier is what lets GEPA escape the local optima a
single-best greedy search gets stuck in.

After this change, a Shikumi user can write:

```haskell
compiled <- optimize (gepa reflectionProposer feedbackMetric defaultBudget) train metric student
```

and get back a `CompiledProgram i o` whose held-out score is *higher* than the starting
(deliberately weak) program's, achieved by reflective instruction evolution rather than blind
search. They can serialize it with `encodeCompiled` and reload it with `decodeCompiledOnto`
exactly like every other optimizer's output, because GEPA returns V1's `CompiledProgram i o`
and is invoked through V1's stable `optimize` entry point — there is no new optimizer type and
no parallel serialization surface.

You can see all of this working through a **hermetic** test (no network, no API keys, a
deterministic stub language model): build a deliberately-weak two-node program, run
`gepa` over a small fixture dataset under the stub, and observe that (a) the held-out
`aggregateScore` after optimization is strictly greater than before; (b) the Pareto frontier
contains at least one non-dominated candidate; and (c) a node whose captured feedback says
"be more specific" ends up carrying a mutated instruction — asserted by reading that node's
`Params` back out with `foldParams` and checking the instruction changed.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Feedback capture. Run the student under EP-16's `runProgramTraced` + `Feedback`,
      derive a per-node textual critique from a *feedback metric*, and accumulate it into a
      `FeedbackLog` keyed by `NodePath`. Hermetic test: a deliberately-weak node accumulates
      a non-empty critique whose `NodePath` matches that node's `foldParams` index.
- [ ] M2: Reflective mutation proposer. A typed Shikumi `Program ReflectIn ReflectOut` that,
      given a node's current instruction, its accumulated critiques, and the EP-19 program/
      dataset summaries, proposes a better instruction; apply it to a selected node via
      `mapParamsAt`. Hermetic test: a node whose critique says "be more specific" receives a
      mutated instruction, asserted via `foldParams`.
- [ ] M3: Pareto frontier + parent sampling + evolution loop honoring V1 `Budget`; return the
      best `CompiledProgram`. Hermetic acceptance: held-out `aggregateScore` strictly rises;
      the frontier has ≥1 non-dominated candidate; `encodeCompiled`/`decodeCompiledOnto`
      round-trips the result.
- [ ] Final: `Shikumi.Optimize.GEPA` + `Shikumi.Optimize.Pareto` added, re-exported from
      `Shikumi.Optimize`; `cabal test shikumi-optimize` and `cabal test all` green inside
      `nix develop .#ghc9124`; living sections updated; commit carries MasterPlan/ExecPlan/
      Intention trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: GEPA discharges the tracing, current-node, and feedback effects *internally*,
  inside its `runOptimizer` body, rather than widening the `Optimizer i o` effect row.
  Rationale: The `Optimizer i o` newtype
  (`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/Types.hs`)
  pins the rank-2 row to `(LLM, Concurrent, Error ShikumiError, Time, Prim)`. GEPA needs
  `Trace`, `CurrentNode`, and `Feedback` (from EP-16) only *transiently*, around each traced
  run; it interprets them with `runTrace`/`runCurrentNode`/`runFeedback` against the ambient
  `Prim`/`Time`/`LLM` already in the row, so the public optimizer surface is unchanged. This
  is exactly how the existing optimizers stay inside the pinned row while using extra local
  effects. Date: 2026-06-09.
- Decision: Reuse EP-18's reward/critique vocabulary; do **not** define a parallel reward
  type. GEPA's "feedback metric" is a function from an expected/predicted pair (and, where
  available, the node's captured sub-trace) to a `Score` *plus* a short critique `Text`,
  layered on V1's `Metric o = o -> Prediction o -> Score`
  (`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-eval/src/Shikumi/Eval/Metric.hs`).
  Rationale: MasterPlan integration point #1 forbids a parallel reward type; the critique is
  additive textual feedback on top of the existing scalar `Score`. Date: 2026-06-09.
- Decision: Keep GEPA's output strictly V1's `CompiledProgram i o`, invoked via `optimize`;
  the Pareto frontier is an *internal* bookkeeping structure, not part of the returned type.
  Rationale: MasterPlan integration point #4 mandates no parallel optimizer/serialization
  surface; the CLI and golden serialization tests depend on `CompiledProgram` being the only
  output. Date: 2026-06-09.
- Decision: A candidate is identified for the frontier by its full `[Params]` vector (the
  node parameters in `foldParams` order), and dominance is computed over the *per-example*
  score vector returned by `evaluatePure` (its `results :: [ExampleResult]`, each carrying a
  `score`). Rationale: `evaluatePure`'s `Report` already exposes per-example scores in dataset
  order, which is exactly the vector GEPA's Pareto frontier needs; `[Params]` + the structural
  template is the only serializable identity a `Program` has (its closures are opaque). Date:
  2026-06-09.
- Decision: Node (component) selection is round-robin (`stepNo `mod` nNodes`), the DSPy default
  selector; parent selection is the "pareto" strategy (sample from the frontier, biased toward
  candidates that win on more examples), driven by a pure, seeded LCG so the search is
  reproducible without IO. Rationale: round-robin and pareto-sampling are DSPy GEPA's defaults
  and are sufficient to demonstrate reflective evolution; a deterministic RNG keeps the
  hermetic test reproducible and matches the existing ensemble optimizer's PRNG approach. Date:
  2026-06-09.
- Decision: DSPy GEPA's optional *merge* step (combining two parent candidates) and its
  *multimodal* instruction proposer are out of scope. Rationale: the headline behavior —
  reflective per-node instruction evolution under a Pareto frontier with held-out lift — is
  fully demonstrable without them; merge adds search complexity with no bearing on the
  acceptance criteria, and multimodality belongs to a separate MasterPlan. They can be added
  later additively without changing GEPA's public `Optimizer i o` surface. Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section describes everything a newcomer needs. Read it fully before editing. It assumes
no prior knowledge of this repository.

### Define the terms

  * **`Program i o`** — Shikumi's pipeline value: a tree of nodes computing an output of type
    `o` from an input of type `i`. The node that calls a language model is `Predict`; it holds
    a *signature* (the typed task description) and a `Params` record (the optimizable
    instruction override and demonstrations). Defined in
    `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Program.hs`.
  * **Instruction** — the natural-language directive given to a `Predict` node. An optimizer
    rewrites it by setting `instructionOverride` inside that node's `Params`.
  * **Demonstration ("demo")** — a worked input/output example attached to a node to steer it.
  * **Optimizer** — a search procedure that rewrites instructions/demos and returns a
    `CompiledProgram i o`. Defined as the `Optimizer i o` newtype in
    `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/Types.hs`.
  * **`CompiledProgram i o`** — a thin wrapper around a finished `Program i o`, the output of
    every optimizer. From
    `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-compile/src/Shikumi/Compile/Types.hs`.
  * **`NodePath`** — EP-16's stable identifier for a node's structural position inside a
    `Program`. The *k*-th `NodePath` that `programNodePaths p` emits names the same node whose
    parameters are the *k*-th element of `foldParams p` and which `mapParamsAt k` edits. This
    is the bridge that lets GEPA tie a critique to a node and then mutate that node.
  * **Feedback / critique** — a short natural-language note about how one node performed on
    one example, keyed by that node's `NodePath`. Written during a run, read during a
    proposal step.
  * **Reflection** — reading a node's accumulated critiques and proposing a *better*
    instruction in response.
  * **Pareto frontier** — a set of candidate programs such that no candidate is *dominated*
    by another. Candidate *A* dominates candidate *B* when *A*'s per-example score is greater
    than or equal to *B*'s on every example and strictly greater on at least one. Keeping the
    frontier (rather than one global best) preserves candidates that are best on *some*
    examples even if not best on average, which is what gives reflective evolution room to
    explore.
  * **Hermetic test** — a test that runs entirely offline against a deterministic stub
    language model (a tiny interpreter of the `LLM` effect that returns canned responses),
    with no network and no API key.

### Where the code lives

Everything GEPA needs is already on disk; this plan adds two modules to one existing package.

  * `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/` — the optimizer package, where
    GEPA goes. The public surface is
    `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize.hs` (it
    re-exports every optimizer). The shared search plumbing —
    `selectBest`, `scoreOn`, `freezeProgram` — is in
    `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/Search.hs`.
    The optimizer types (`Optimizer`, `Budget`, `Scored`) are in
    `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/Types.hs`.
    The closest sibling to study for style is
    `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/Instruction.hs`
    (a proposer-driven optimizer whose proposer is itself a typed `Program`). The cabal file
    is
    `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/shikumi-optimize.cabal`; the test
    suite is under `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/test/`, with a
    shared stub LM in `test/StubLM.hs`.
  * `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-trace/` — the tracing package. EP-16
    (`/Users/shinzui/Keikaku/bokuno/shikumi/docs/plans/16-node-correlated-tracing-and-feedback-channel.md`)
    adds, inside this package, `runProgramTraced`, the `NodePath`/`NodeStep` types,
    `programNodePaths`, `nodeFields`, the `CurrentNode` effect, the `Feedback` effect with
    `attachFeedback`/`feedbackFor`/`runFeedback`/`emptyFeedback`/`FeedbackLog`, and the
    `SpanAttrs.nodePath` field. GEPA *consumes* all of these; it adds nothing here.
  * `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Program.hs` — the program GADT,
    the parameter traversal (`paramsTraversal`, `foldParams`, `mapParams`, `mapParamsAt`), the
    executors (`runProgram`, `runProgramConc`), and (added by EP-16) `nodeFieldsIndexed` /
    `NodeFields`.
  * `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-eval/` — the evaluation package:
    `Dataset`, `Example`, `Metric`, `Prediction`, `Report`, `evaluatePure`. GEPA reads
    per-example scores from `Report`'s `results` field.

### Cross-plan contracts this plan *consumes* (does not redefine)

GEPA hard-depends on **EP-16**
(`/Users/shinzui/Keikaku/bokuno/shikumi/docs/plans/16-node-correlated-tracing-and-feedback-channel.md`,
which is a complete, checked-in plan) and **EP-19**
(`/Users/shinzui/Keikaku/bokuno/shikumi/docs/plans/19-grounded-instruction-proposer.md`); it
soft-depends on **EP-18**
(`/Users/shinzui/Keikaku/bokuno/shikumi/docs/plans/18-reward-driven-self-refinement-modules.md`).
The exact signatures GEPA relies on, copied so this plan stands alone:

From EP-16 (in `shikumi-trace`, plus two accessors in `shikumi/Shikumi.Program`):

```haskell
-- Shikumi.Trace.Node (shikumi-trace)
data NodeStep
  = StepComposeL | StepComposeR | StepFMap | StepMap
  | StepParallelL | StepParallelR | StepRetry | StepRetryWhen
  | StepValidate | StepMajorityVote | StepEnsemble !Int
newtype NodePath = NodePath [NodeStep]
  deriving stock (Eq, Ord, Show, Generic)

-- | The k-th element names the same node whose Params is the k-th of foldParams
-- and which mapParamsAt k edits. This is EP-16 integration-point-#3's law.
programNodePaths :: Program i o -> [NodePath]

-- | Each Predict node's NodePath paired with its input/output field names.
nodeFields :: Program i o -> [(NodePath, NodeFields)]

-- Shikumi.Program (shikumi)
data NodeFields = NodeFields { inputFieldNames :: ![Text], outputFieldNames :: ![Text] }
nodeFieldsIndexed :: Program i o -> [NodeFields]   -- one per Predict, foldParams order

-- Shikumi.Trace.Node / Shikumi.Trace.Program (shikumi-trace): the current-node effect
data CurrentNode :: Effect
askNode        :: (CurrentNode :> es) => Eff es (Maybe NodePath)
localNode      :: (CurrentNode :> es) => NodePath -> Eff es a -> Eff es a
runCurrentNode :: Eff (CurrentNode : es) a -> Eff es a

-- | Additive entry point: runs a program like runProgram while opening a span per
-- node and tagging each model-call span with the issuing node's NodePath.
runProgramTraced ::
  (LLM :> es, Trace :> es, CurrentNode :> es, Error ShikumiError :> es) =>
  Program i o -> i -> Eff es o

-- Shikumi.Trace.Feedback (shikumi-trace): the per-node feedback channel
newtype FeedbackLog = FeedbackLog (Map NodePath [Text])
emptyFeedback  :: FeedbackLog
feedbackFor    :: NodePath -> FeedbackLog -> [Text]   -- critiques for a node, attach order
data Feedback :: Effect
attachFeedback :: (Feedback :> es) => NodePath -> Text -> Eff es ()
runFeedback    :: (Prim :> es) => Eff (Feedback : es) a -> Eff es (a, FeedbackLog)
```

EP-16 also notes its public `runProgramTraced` surface may be exposed with the `CurrentNode`
constraint already discharged internally (so callers see only
`(LLM, Trace, Error ShikumiError)`). GEPA must tolerate *either* surface; the Plan of Work
shows how (it discharges `CurrentNode` itself if the published signature still requires it,
and otherwise simply does not mention it). The observable behavior — model-call spans tagged
with node paths, and `feedbackFor path` returning the critiques attached to a node — is the
contract GEPA actually depends on.

From EP-19 (the grounded instruction proposer). EP-19's detailed body is still a skeleton at
the time of writing, so GEPA depends only on the **named artifacts** the MasterPlan integration
point #2 guarantees it will expose, and provides a documented fallback for each so GEPA can be
built and tested *before* EP-19 lands. The artifacts GEPA reuses:

  * A **dataset summary** — a short `Text` describing the training data — and a **program
    summary** — a short `Text` describing the program's structure/role. GEPA passes both into
    its reflective proposer as extra grounding context. EP-19 produces these via typed Shikumi
    programs (a dataset summarizer and a program describer). **Fallback if EP-19 is absent:**
    GEPA synthesizes a minimal dataset summary (the example count and the first input rendered
    via `ToPrompt`) and a minimal program summary (the node count and each node's field names
    from `nodeFields`) with a small pure helper, so the proposer always receives *some*
    grounding. When EP-19 lands, swap the helper for EP-19's summarizers; record the swap in
    the Decision Log.
  * **Per-node field names** via EP-16's `nodeFields` / `nodeFieldsIndexed` (which EP-19 also
    consumes). GEPA uses these directly; there is no fallback needed because they come from
    EP-16, not EP-19.

From EP-18 (reward-driven self-refinement, soft dependency). EP-18 owns the reward/critique
vocabulary. EP-18's body is also a skeleton at the time of writing, so GEPA does **not** import
a concrete reward type from it; instead GEPA expresses its feedback metric in terms of V1's
already-shipped `Metric o = o -> Prediction o -> Score` plus a critique `Text`, which is the
shape EP-18's reward functions are guaranteed (by MasterPlan integration point #1) to reduce
to. The Decision Log records that GEPA layers on `Metric`/`Score` rather than redefining a
reward type, satisfying the "do not redefine a parallel reward type" constraint. If EP-18
later exports a named `Reward o`/critique type that is *literally* GEPA's feedback-metric
shape, GEPA re-exports/aliases it rather than keeping a twin; record that in the Decision Log.

### The optimizer contract GEPA must satisfy, verbatim

From `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/Types.hs`:

```haskell
newtype Optimizer i o = Optimizer
  { runOptimizer ::
      forall es.
      (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
      Dataset i o -> Metric o -> Program i o -> Eff es (CompiledProgram i o)
  }

data Budget = Budget { maxLmCalls :: !Int, maxCandidates :: !Int }
defaultBudget :: Budget   -- Budget { maxLmCalls = 200, maxCandidates = 32 }

data Scored a = Scored { candidate :: a, score :: !Double }
```

`gepa :: ... -> Optimizer i o` therefore wraps a function of exactly this shape. Its row is
`(LLM, Concurrent, Error ShikumiError, Time, Prim)` — note it does **not** include `Trace`,
`CurrentNode`, or `Feedback`. GEPA introduces those locally and discharges them inside its own
body (see the Plan of Work), using the ambient `Prim`/`Time`/`LLM`.

From `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/Search.hs`,
the plumbing GEPA reuses unchanged:

```haskell
scoreOn ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Dataset i o -> Metric o -> Program i o -> Eff es Double   -- aggregateScore of evaluatePure
freezeProgram :: Program i o -> CompiledProgram i o
```

GEPA also calls `evaluatePure` *directly* (not just through `scoreOn`) when it needs the
*per-example* score vector for the Pareto frontier, reading `results :: [ExampleResult]` off
the `Report` (each `ExampleResult` carries `score :: Score`, in dataset order). From
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-eval/src/Shikumi/Eval/`:

```haskell
evaluatePure ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Dataset i o -> Metric o -> Program i o -> Eff es Report
data Report = Report { aggregateScore :: !Double, results :: ![ExampleResult], ... }
data ExampleResult = ExampleResult { index :: !Int, score :: !Score, ... }
unScore :: Score -> Double
```

From `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Program.hs`, the parameter
machinery GEPA uses to read and write node instructions:

```haskell
data Params = Params { instructionOverride :: !(Maybe Text), demos :: ![Demo] }
emptyParams :: Params
foldParams      :: Program i o -> [Params]                       -- node params, foldParams order
mapParamsAt     :: Int -> (Params -> Params) -> Program i o -> Program i o
programParams   :: Program i o -> [Params]
setProgramParams :: [Params] -> Program i o -> Either ProgramShapeError (Program i o)
```

From `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-compile/src/Shikumi/Compile/Serialize.hs`,
the serialization round-trip the acceptance test exercises:

```haskell
encodeCompiled     :: CompiledProgram i o -> ByteString               -- JSON array of Params
decodeCompiledOnto :: Program i o -> ByteString -> Either String (CompiledProgram i o)
```

### How DSPy's GEPA works (the algorithm GEPA reimplements natively)

DSPy's GEPA delegates the search to an external `gepa` Python package; this plan implements the
*same algorithm* natively in Haskell, described here in plain terms so the implementer needs no
external reading. DSPy's flow, distilled from
`/tmp/dspy/dspy/teleprompt/gepa/gepa.py`, `gepa_utils.py`, and `instruction_proposal.py`:

  1. **Seed candidate.** GEPA starts from the student program; the seed *candidate* is the map
     from each predictor (node) name to its current instruction string.

  2. **Feedback capture (per node).** To score a candidate, GEPA runs the program over a batch
     while capturing a full execution trace, then — for each node it is optimizing — extracts
     the *sub-trace* belonging to that node (the inputs the node saw and the output it
     produced) and calls a **feedback metric**. That metric returns a `score` *and* a textual
     `feedback` string specific to the node ("this trajectory got a score of X" is the trivial
     default when the metric supplies no richer critique). The feedback is keyed by node name.
     The set of (node inputs, node outputs, feedback) triples for a node is its *reflective
     dataset*.

  3. **Reflective mutation proposer.** To improve a node, GEPA hands its current instruction
     and its reflective dataset (the captured failures + critiques) to a *reflection language
     model* that proposes a *new* instruction explicitly addressing the critiques. In DSPy this
     is the `InstructionProposalSignature` — a structured prompt whose inputs are
     `current_instruction_doc` and `dataset_with_feedback`, and whose output is
     `new_instruction`. GEPA mutates exactly one node (or, with some selectors, a chosen set)
     per step.

  4. **Component (node) selection.** GEPA picks which node to mutate each round. The default
     strategy is *round-robin* (cycle through the nodes one at a time); other strategies select
     all nodes, or use the optimization state. GEPA also *skips* examples whose score is
     already perfect (no critique is useful there).

  5. **Pareto frontier + parent selection.** GEPA evaluates every candidate on a validation set
     and keeps the *per-validation-instance* scores (a vector, one score per example). It tracks
     a **Pareto frontier**: for each validation instance it remembers which candidates achieve
     the best score there, and the frontier is the union of those candidates. To take an
     evolution step it samples a **parent** from the frontier (the default
     `candidate_selection_strategy = "pareto"` samples stochastically among frontier members,
     biased toward those that win on more instances), reflects to produce a *child*, scores the
     child, and folds it back in — a new candidate that is non-dominated joins the frontier and
     can itself become a parent later. (DSPy also offers an optional *merge* step that combines
     two parents; this plan treats merge as out of scope — see Decision Log below — because the
     headline behavior, reflective evolution under a Pareto frontier, is fully demonstrable
     without it.)

  6. **Budget and result.** The loop runs until a *metric-call budget* is spent. The result is
     the best candidate by aggregate validation score, rebuilt into a program by overlaying each
     node's evolved instruction. When stats are tracked, the full frontier and lineage are
     exposed for inspection.

GEPA in Shikumi maps these one-to-one onto Shikumi's substrate: step 2's per-node trace and
feedback are EP-16's `runProgramTraced` + `Feedback` channel keyed by `NodePath`; step 3's
reflection proposer is a typed Shikumi `Program`; step 4's node selection iterates
`programNodePaths`; step 5's score vector is `evaluatePure`'s per-example `results`; step 6's
budget is V1's `Budget` (counting LM calls). The *merge* step (and the multimodal proposer in
`instruction_proposal.py`) are out of scope.


## Plan of Work

GEPA is built in three milestones, each independently verifiable with a hermetic test. The
work lands two new modules in `shikumi-optimize`:
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/GEPA.hs` (the
optimizer) and
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/Pareto.hs` (the
frontier helper). Both are re-exported from
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize.hs`. The package
gains a dependency on `shikumi-trace` (for EP-16's `runProgramTraced`/`Feedback`/`NodePath`),
which must be added to `shikumi-optimize.cabal`.

A note that shapes all three milestones: **the `gepa` smart constructor takes its
reflective proposer and feedback metric as explicit arguments** so the whole optimizer is
testable under a stub LM. Concretely:

```haskell
-- The reflective proposer is an ordinary typed Shikumi Program: given a node's current
-- instruction, its accumulated critiques, and grounding summaries, it returns a better
-- instruction. (Mirrors Shikumi.Optimize.Instruction's proposeInstruction, but reflective.)
data ReflectIn = ReflectIn
  { currentInstruction :: Text   -- the node's instruction today
  , feedback           :: Text   -- the node's accumulated critiques, joined
  , programSummary     :: Text   -- EP-19 program summary (or the fallback)
  , datasetSummary     :: Text   -- EP-19 dataset summary (or the fallback)
  , fieldSummary       :: Text   -- the node's input/output field names, from nodeFields
  }
  deriving stock (Generic, Show)
instance FromModel ReflectIn
instance ToPrompt  ReflectIn

newtype ReflectOut = ReflectOut { proposedInstruction :: Text }
  deriving stock (Generic, Show)
instance ToSchema ReflectOut
instance FromModel ReflectOut
instance ToPrompt  ReflectOut
instance Validatable ReflectOut

reflectiveProposer :: Program ReflectIn ReflectOut   -- a single predict node, shipped default

-- The feedback metric: like V1's Metric but also emits a short critique. It reuses
-- Score (EP-18's reward vocabulary reduces to this) and adds the critique Text.
type FeedbackMetric o = o -> Prediction o -> (Score, Text)

-- The public smart constructor.
gepa ::
  (ToPrompt i, ToPrompt o) =>
  Program ReflectIn ReflectOut ->   -- reflective proposer (default: reflectiveProposer)
  FeedbackMetric o ->               -- per-example score + critique
  Budget ->
  Optimizer i o
```

The `(ToPrompt i, ToPrompt o)` constraints let GEPA render the fallback dataset/program
summaries; if EP-19's summarizers are wired in, these can be relaxed. GEPA's body is the
`runOptimizer` function of the shape pinned by `Optimizer i o`.


### Milestone 1 — feedback capture

**Scope.** Build the machinery that runs the student program once per example under EP-16's
`runProgramTraced` while capturing a per-node critique into a `FeedbackLog`. At the end of M1,
a hermetic test builds a deliberately-weak two-node program, runs the M1 capture over a small
dataset under a stub LM, and asserts that a chosen node accumulates a non-empty critique whose
`NodePath` matches that node's `foldParams` index.

**What exists at the end of M1.** A private helper inside `Shikumi.Optimize.GEPA`:

```haskell
-- Run the program over the whole dataset under tracing, attaching, for each node and each
-- example, the critique the feedback metric produces. Returns the FeedbackLog (critiques
-- keyed by NodePath) alongside the per-example score vector (for the Pareto frontier in M3).
captureFeedback ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Dataset i o ->
  FeedbackMetric o ->
  Program i o ->
  Eff es (FeedbackLog, [Double])
```

**How it works, step by step.**

  1. Enumerate the node paths once: `let paths = programNodePaths prog`. The *k*-th path names
     the node at `foldParams` index *k*.

  2. For each `Example inp expd` in `datasetExamples ds`, run the program under tracing *and*
     feedback. The effect stack assembled *locally* (the key design point — these effects are
     not in the `Optimizer` row, so GEPA introduces and discharges them here against the ambient
     `Prim`/`Time`/`LLM`):

     ```haskell
     -- Inside captureFeedback, for one example:
     ((out, _tree), _fblog1) <-
       runFeedback                         -- introduces Feedback, returns (a, FeedbackLog)
         . fmap (\(a, t) -> (a, t))        -- (identity reshaping; runTrace returns (a, tree))
         . runTrace                        -- introduces Trace, returns (a, TraceTree)
         . runCurrentNode                  -- introduces CurrentNode (if not pre-discharged)
         $ tracedNodeLLM                   -- node-aware LM capture (EP-16)
         $ tracedLLM                       -- base LM capture (EP-16)
         $ runProgramTraced prog inp
     ```

     The precise stacking mirrors EP-16's own demonstration stack (see its Plan of Work, the
     `runEff . runPrim . runTime . runCurrentNode . runTrace . runKeyedLLM . tracedLLM .
     tracedNodeLLM $ runProgramTraced ...` shape). GEPA does *not* re-introduce `runPrim` /
     `runTime` / the base `LLM` interpreter — those are ambient (the `Optimizer` row already
     carries `Prim`, `Time`, `LLM`); GEPA only adds the `Trace`/`CurrentNode`/`Feedback`
     layers, which are discharged before control returns to the optimizer row. If EP-16's
     published `runProgramTraced` already discharges `CurrentNode` internally, drop the
     `runCurrentNode` line; the Decision Log records which surface was used.

  3. The captured output `out :: o` is the program's prediction. Compute the feedback metric:
     `let (sc, critique) = fm out (prediction out)`. Here `prediction :: o -> Prediction o`
     (from `Shikumi.Eval`) wraps a single output. The metric compares against `expd`
     (so the closure is really `fm expd`, matching `FeedbackMetric o = o -> Prediction o ->
     (Score, Text)` applied as `fm expd (prediction out)`).

  4. Attach the critique to **every node** by default, keyed by its `NodePath`: for each
     `path` in `paths`, `attachFeedback path critique`. This is the program-level feedback
     fallback DSPy uses when no node-specific critique is available — every node sees the same
     critique for this example. (M2 refines this: when EP-16's trace exposes a node's *own*
     sub-output, GEPA can compute a node-specific critique; the M1 baseline attaches the
     program-level critique to each node, which is sufficient for the headline behavior and is
     exactly DSPy's documented default. See the Decision Log entry GEPA writes during M1 about
     program-level vs. node-level feedback.)

     A subtlety: `attachFeedback` must run *inside* `runFeedback`'s scope, so the per-example
     `runFeedback` block must `attachFeedback` for each node *before* it returns, then GEPA
     merges that example's `FeedbackLog` into a running accumulator. Because `FeedbackLog` is a
     `Map NodePath [Text]` and critiques accumulate in attach order, the merge is a key-wise
     append (`Map.unionWith (<>)`).

  5. Collect the per-example scores `unScore sc` into the `[Double]` vector (dataset order),
     and accumulate the per-example `FeedbackLog`s into one `FeedbackLog`. Return both.

**Acceptance for M1.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test shikumi-optimize --test-options='-p gepa-feedback'
```

The `gepa-feedback` group builds a two-node chain (`predict sigA >>> predict sigB`, using
`Shikumi.Combinator.(>>>)` and `Shikumi.Module.predict`), a fixture dataset of a few examples,
and a feedback metric that returns `(scoreZero, "be more specific")` for the weak output. It
runs `captureFeedback` under the stub LM and asserts: `feedbackFor (programNodePaths prog !! 0)
log` is non-empty and contains `"be more specific"`, and the same for node 1; and the returned
`[Double]` has one entry per example. This proves per-node feedback capture works end to end
against the stub.


### Milestone 2 — the reflective mutation proposer

**Scope.** Add the typed reflective proposer program and the function that applies a proposed
instruction to a selected node via `mapParamsAt`. At the end of M2, a hermetic test shows that
a node whose captured critique says "be more specific" ends up carrying a *different*
instruction, asserted by reading `foldParams` before and after.

**What exists at the end of M2.**

  1. The `ReflectIn`/`ReflectOut` types and the default `reflectiveProposer :: Program
     ReflectIn ReflectOut` (a single `predict` node whose signature instruction is, in plain
     words: "You are improving the instruction for one node of a language-model pipeline. You
     are given the node's current instruction, textual feedback describing how it failed on
     several examples, a summary of the whole program, a summary of the dataset, and the node's
     input/output field names. Write a single improved instruction, addressing the feedback
     specifically, in the `proposedInstruction` field."). This mirrors
     `Shikumi.Optimize.Instruction.proposeInstruction` but takes the reflective `feedback`
     field, which is the whole point of GEPA.

  2. A private mutation helper:

     ```haskell
     -- Reflect on node idx's feedback and overwrite its instruction with the proposal.
     -- Returns the mutated program and the running LM-call count (one proposer call here).
     mutateNode ::
       (LLM :> es, Error ShikumiError :> es) =>
       Program ReflectIn ReflectOut ->   -- the reflective proposer
       Text ->                            -- program summary  (EP-19 or fallback)
       Text ->                            -- dataset summary  (EP-19 or fallback)
       [NodeFields] ->                    -- per-node field metadata (nodeFieldsIndexed)
       FeedbackLog ->                     -- accumulated critiques
       [NodePath] ->                      -- programNodePaths, to key the feedback
       Int ->                             -- the node index to mutate (foldParams order)
       Program i o ->
       Eff es (Program i o)
     ```

     `mutateNode` reads the current instruction at `idx` from `foldParams prog !! idx`
     (`instructionOverride`, defaulting to `""`), gathers that node's critiques with
     `feedbackFor (paths !! idx) log` (joined into one `Text` with newlines), builds the
     `fieldSummary` from `nodeFieldsIndexed prog !! idx` (e.g. "inputs: question; outputs:
     answer"), runs the reflective proposer with `runProgram reflectiveProposer (ReflectIn
     curInstr joinedFeedback programSummary datasetSummary fieldSummary)`, and writes the
     result back with `mapParamsAt idx (\ps -> ps { instructionOverride = Just proposed })`.

     If the node has *no* accumulated feedback (its `feedbackFor` is empty), `mutateNode`
     returns the program unchanged and reports zero LM calls — there is nothing to reflect on,
     so spending a proposer call would be wasted budget.

**Acceptance for M2.**

```bash
nix develop .#ghc9124 --command cabal test shikumi-optimize --test-options='-p gepa-mutate'
```

The `gepa-mutate` group builds the same two-node chain, runs M1's `captureFeedback` to get a
`FeedbackLog` in which node 0's critique is "be more specific", then calls `mutateNode` with a
stub LM whose reflective proposer deterministically returns an instruction containing the word
`"specific"` (the StubLM keys its response off the `feedback` field, as the existing
`InstructionSpec` stub does for `proposeInstruction`). It asserts that
`instructionOverride (foldParams mutated !! 0)` is `Just` a text *different from* the original
and that the mutation landed on **node 0 only** (node 1's `Params` is unchanged) — proving the
mutation reached the intended node via `mapParamsAt`/`foldParams`. This is the plan's required
"a node whose feedback says be more specific receives a mutated instruction; assert the
mutation reached the node via foldParams" observable.


### Milestone 3 — Pareto frontier, parent sampling, evolution loop, and the result

**Scope.** Add the Pareto-frontier bookkeeping (in `Shikumi.Optimize.Pareto`), the parent
sampler, and the evolution loop that ties M1 + M2 together under V1's `Budget`, returning the
best `CompiledProgram`. At the end of M3, the headline hermetic acceptance test shows held-out
lift, a non-empty non-dominated frontier, and an `encodeCompiled`/`decodeCompiledOnto`
round-trip.

**What exists at the end of M3 — `Shikumi.Optimize.Pareto`.** A small, pure, well-tested module
holding the frontier logic (no effects):

```haskell
module Shikumi.Optimize.Pareto
  ( Candidate (..)
  , dominates
  , paretoFrontier
  , sampleParent
  ) where

-- A candidate program identified by its node-parameter vector, carrying its per-example
-- score vector and its aggregate. The params vector + the structural template (held by the
-- loop) reconstitute the actual Program via setProgramParams; storing [Params] keeps a
-- candidate serializable and comparable.
data Candidate = Candidate
  { candParams      :: ![Params]   -- node params in foldParams order
  , candPerExample  :: ![Double]   -- per-example scores, dataset order
  , candAggregate   :: !Double     -- mean of candPerExample (the headline score)
  }
  deriving stock (Eq, Show)

-- A dominates B when A >= B on every example and A > B on at least one. Vectors are assumed
-- equal length (same dataset). Ties (equal vectors) are NOT domination, so equal candidates
-- coexist on the frontier and the earliest-inserted is preferred by the loop.
dominates :: Candidate -> Candidate -> Bool

-- The non-dominated subset: every candidate not dominated by any other. Deterministic
-- (preserves input order), so the frontier is reproducible.
paretoFrontier :: [Candidate] -> [Candidate]

-- Deterministically sample a parent from the frontier, biased toward candidates that achieve
-- the best score on more examples (the "pareto" selection strategy). Pure: takes an explicit
-- Int seed and returns the chosen candidate + the next seed, so the loop threads RNG state
-- with no IO. A simple, documented LCG (the glibc constants the ensemble optimizer already
-- uses) drives the choice; weighting is by the count of examples on which the candidate ties
-- the column-wise maximum.
sampleParent :: Int -> [Candidate] -> Maybe (Candidate, Int)
```

`paretoFrontier` and `sampleParent` are pure and get their own unit tests (a frontier of three
vectors where one is dominated; a sampler that, given a fixed seed, picks a specific frontier
member). Keeping this logic pure and effect-free is the V1 "thread candidates explicitly, no
global mutable state" discipline, and it makes the frontier trivially testable.

**What exists at the end of M3 — the evolution loop in `Shikumi.Optimize.GEPA`.** The `gepa`
smart constructor's body:

  1. **Summaries.** Compute `programSummary` and `datasetSummary` once (EP-19 summarizers if
     present, else the fallback helpers described in Context). Compute `paths =
     programNodePaths student`, `fields = nodeFieldsIndexed student`, `nNodes = length paths`.

  2. **Seed the frontier.** Evaluate the student with `evaluatePure ds metric student` to get
     its per-example vector and aggregate; wrap as the seed `Candidate` (its `candParams =
     foldParams student`). Initialize the frontier to `[seed]`. Note: `metric` here is V1's
     scalar `Metric o` passed to `runOptimizer` (used for *scoring*); the richer
     `FeedbackMetric o` passed to `gepa` is used for *critique capture* in step 4. The two are
     consistent by construction in tests (the scalar score is the `fst` of the feedback
     metric).

  3. **Budget accounting.** Thread a running `calls :: Int` (LM calls consumed) and a
     `candidatesScored :: Int`. Each full `evaluatePure` over a dataset of size `n` costs `n`
     LM calls (one per example, per the existing optimizers' accounting); each traced
     `captureFeedback` pass likewise costs `n`; each proposer call in `mutateNode` costs one.
     The loop stops before `calls + cost > maxLmCalls budget` or `candidatesScored >=
     maxCandidates budget`, returning the best candidate found so far — never exceeding either
     bound, exactly like `Shikumi.Optimize.Instruction`'s budget discipline.

  4. **One evolution step** (repeated until budget stops it):
     a. Sample a parent from the current frontier with `sampleParent seed frontier`; rebuild
        the parent program with `setProgramParams (candParams parent) student` (the student is
        the structural template; `Right prog` on success — a `Left` is impossible because every
        candidate's params came from a `foldParams`/`mapParamsAt` of this same template).
     b. Capture feedback for the parent: `(log, _) <- captureFeedback ds fbMetric parentProg`.
     c. Select the node to mutate this step by **round-robin**: `idx = stepNo `mod` nNodes`
        (the DSPy default component selector). Skip if that node has no feedback.
     d. Mutate: `child <- mutateNode reflectiveProposer programSummary datasetSummary fields
        log paths idx parentProg`.
     e. Score the child for the frontier: `rpt <- evaluatePure ds metric child`; build a
        `Candidate` from `foldParams child`, the per-example `map (unScore . score) (results
        rpt)`, and `aggregateScore rpt`.
     f. Insert the child and recompute `frontier' = paretoFrontier (child : frontier)`; bump
        `candidatesScored`; thread the next `seed`.

  5. **Result.** When the loop stops, pick the frontier candidate with the highest
     `candAggregate` (ties: earliest), rebuild it with `setProgramParams`, and return
     `freezeProgram` of it. This is V1's `CompiledProgram i o`. Because the seed candidate is
     always in the frontier, the returned program is *never worse on aggregate* than the
     student — GEPA can only improve or hold.

**Why held-out lift is observable under a stub.** The acceptance test arranges a stub LM where
the student's weak instruction yields a low score, the feedback metric emits a "be more
specific" critique, and the reflective proposer (keyed off that critique in the stub) emits an
instruction the stub LM then *answers correctly*. A separate held-out dataset (distinct
examples, same task) is scored with `scoreOn` before and after; the after-score is strictly
greater. This is the same "deliberately-weak program lifted offline" shape the existing
optimizer acceptance tests use (`test/AcceptanceSpec.hs`), adapted to reflective evolution.

**Acceptance for M3.**

```bash
nix develop .#ghc9124 --command cabal test shikumi-optimize --test-options='-p gepa'
```

The `gepa` groups (`gepa-pareto` for the pure frontier unit tests, `gepa-accept` for the
end-to-end) assert: `paretoFrontier` drops a dominated vector and keeps non-dominated ones;
`sampleParent` is deterministic for a fixed seed; the end-to-end held-out `aggregateScore`
after `optimize (gepa reflectiveProposer fbMetric budget) train metric student` is strictly
greater than before; the internal frontier (exposed to the test via a thin
test-only accessor or by re-deriving it from the returned program plus the dataset) has at
least one non-dominated member; and `decodeCompiledOnto student (encodeCompiled compiled)`
returns `Right c'` whose `foldParams` equals the compiled program's `foldParams` (the
round-trip preserves the evolved instructions). All offline, under the stub.


## Concrete Steps

All commands run from the repository root inside the pinned toolchain. Enter the shell once:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124
```

Inside that shell the build/test/format commands are:

```bash
cabal build shikumi-optimize
cabal test shikumi-optimize
cabal test all
fourmolu -i shikumi-optimize/src/Shikumi/Optimize/GEPA.hs \
            shikumi-optimize/src/Shikumi/Optimize/Pareto.hs \
            shikumi-optimize/src/Shikumi/Optimize.hs \
            shikumi-optimize/test/GepaSpec.hs
```

Fourmolu uses two-space indentation; format every file you touch.

### Step-by-step

1. **Cabal wiring.** In
   `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/shikumi-optimize.cabal`, add
   `Shikumi.Optimize.GEPA` and `Shikumi.Optimize.Pareto` to the library `exposed-modules`, add
   `shikumi-trace` to the library `build-depends`, and add a `GepaSpec` module plus (if needed)
   `shikumi-trace` to the test suite `other-modules`/`build-depends`. `shikumi-trace` already
   depends on `shikumi`, so there is no cycle: `shikumi-optimize` may depend on it.

2. **M1 — `Shikumi.Optimize.Pareto` is not needed yet; create `Shikumi.Optimize.GEPA`** with
   the `FeedbackMetric` type alias, the `ReflectIn`/`ReflectOut` types + instances, the default
   `reflectiveProposer`, and the `captureFeedback` helper (the traced/feedback capture stack
   above). Add the fallback `programSummary`/`datasetSummary` helpers. Do *not* wire the loop
   yet — M1 only needs `captureFeedback` to typecheck and run.

3. **M1 test.** Create
   `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/test/GepaSpec.hs` with a
   `gepa-feedback` group as described. Reuse `test/StubLM.hs`'s pattern for the stub `LLM`
   interpreter; key the stub's response off the rendered request so the weak node scores low.
   Register `GepaSpec` in the test suite's `other-modules` and add it to the tasty test tree in
   `test/Main.hs`.

4. **M2 — add `mutateNode`** to `Shikumi.Optimize.GEPA` and the `gepa-mutate` test group.

5. **M3 — create `Shikumi.Optimize.Pareto`** with `Candidate`/`dominates`/`paretoFrontier`/
   `sampleParent`; add the `gepa` smart constructor and its evolution loop to
   `Shikumi.Optimize.GEPA`; add the `gepa-pareto` and `gepa-accept` test groups. Re-export
   `Shikumi.Optimize.GEPA` and `Shikumi.Optimize.Pareto` from
   `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize.hs` (add two
   `module Shikumi.Optimize.GEPA`/`module Shikumi.Optimize.Pareto` lines to its export list and
   two imports).

6. **Format, build, test.** Run the fourmolu command, then `cabal build shikumi-optimize`,
   `cabal test shikumi-optimize`, and `cabal test all`. Update this plan's Progress,
   Surprises, and Decision Log. Commit with the trailers.

Expected final test transcript (abridged):

```text
shikumi-optimize
  labeled-few-shot: OK
  bootstrap: OK
  instruction: OK
  ensemble: OK
  acceptance: OK
  gepa-feedback: OK
  gepa-mutate: OK
  gepa-pareto: OK
  gepa-accept: OK

All N tests passed
```


## Validation and Acceptance

The headline acceptance is observable and hermetic (no network, no API keys), and proves the
change is effective beyond compilation:

  * **Held-out lift.** Build a deliberately-weak two-node program and a train/held-out split of
    a small fixture task. Under the stub LM, record `before <- scoreOn heldOut metric student`,
    then `compiled <- optimize (gepa reflectiveProposer fbMetric defaultBudget) train metric
    student`, then `after <- scoreOn heldOut metric (compiledProgram compiled)`. Assert
    `after > before`. This is the plan's primary observable: reflective evolution lifts the
    held-out score.

  * **Non-empty Pareto frontier.** Assert the internal frontier contains at least one
    non-dominated candidate (it always contains the seed, and the test arranges a child that is
    non-dominated, so the assertion is ≥ 1 and typically ≥ 2). The `gepa-pareto` unit tests
    independently prove `paretoFrontier` correctly drops a dominated vector.

  * **Mutation reached the node.** From M2's `gepa-mutate`, assert that the node whose feedback
    said "be more specific" carries a *changed* `instructionOverride` (read via `foldParams`)
    and that the sibling node is untouched — proving `mapParamsAt`/`feedbackFor`/`NodePath`
    correlation works.

  * **Serialization round-trip.** Assert `decodeCompiledOnto student (encodeCompiled compiled)`
    is `Right c'` and `foldParams (compiledProgram c') == foldParams (compiledProgram
    compiled)`, proving GEPA's output is a normal `CompiledProgram` that persists and reloads
    like every other optimizer's.

Run the package suite and the whole workspace to confirm nothing regressed:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test shikumi-optimize
nix develop .#ghc9124 --command cabal test all
```

Success is every group reporting `OK`, including the pre-existing optimizer groups (proving the
additive change broke nothing) and the new `gepa-*` groups.


## Idempotence and Recovery

Every step is additive and safe to repeat. Re-running `cabal build`/`cabal test` is
idempotent; the new modules and tests do not modify any existing file's behavior (they only
add `exposed-modules`, a `build-depends` entry, re-export lines, and a new test module). If a
partial edit fails to compile — e.g. the re-export lines are added before the modules exist —
the fix is local: complete the module, or comment out the re-export until the module builds.

The single cross-package risk is the EP-16 dependency surface: GEPA's `captureFeedback`
assumes EP-16 exposes `runProgramTraced`, the `Feedback` effect, and `programNodePaths` as
documented above. If EP-16's *published* `runProgramTraced` discharges `CurrentNode`
internally, GEPA drops its own `runCurrentNode` layer (one line) and records the choice in the
Decision Log; if it still requires `CurrentNode`, GEPA keeps the layer. Either way the
observable behavior is identical. If EP-16 is not yet merged, GEPA cannot build (it imports
`shikumi-trace`'s new surface); the recovery is to land EP-16 first, which is the declared hard
dependency.

The EP-19 dependency is soft: GEPA ships with fallback summary helpers, so it builds and its
acceptance test passes *without* EP-19. When EP-19 lands, swap the fallbacks for its
summarizers and re-run the suite; record the swap in the Decision Log. The EP-18 dependency is
soft and discharged at the type level (GEPA's `FeedbackMetric` reduces to `Score` + `Text`); no
import of EP-18 is required to build.


## Interfaces and Dependencies

Libraries, modules, and services used and why:

  * `effectful` — the effect system. GEPA introduces no new effect; it *interprets* EP-16's
    `Trace`/`CurrentNode`/`Feedback` effects locally with EP-16's
    `runTrace`/`runCurrentNode`/`runFeedback` against the ambient `Prim`/`Time`, and calls the
    ambient `LLM` through EP-16's `runProgramTraced` + `tracedLLM`/`tracedNodeLLM`.
  * `shikumi` (`Shikumi.Program`) — `Params`, `foldParams`, `mapParamsAt`, `programParams`,
    `setProgramParams`, `nodeFieldsIndexed`/`NodeFields`, and `runProgram` (for the reflective
    proposer). The program is the structural template a `Candidate`'s `[Params]` is overlaid
    onto.
  * `shikumi-trace` — **new dependency for this package.** EP-16's `runProgramTraced`,
    `NodePath`/`NodeStep`, `programNodePaths`, `nodeFields`, `CurrentNode`/`runCurrentNode`,
    and the `Feedback` channel (`FeedbackLog`, `attachFeedback`, `feedbackFor`, `runFeedback`,
    `emptyFeedback`).
  * `shikumi-eval` (`Shikumi.Eval`) — `Dataset`, `Example`, `Metric`, `Prediction`,
    `prediction`, `Score`, `unScore`, `scoreZero`/`scoreOne`/`mkScore`, `evaluatePure`,
    `Report` (`aggregateScore`, `results`), `ExampleResult` (`score`). The per-example `results`
    vector feeds the Pareto frontier.
  * `shikumi-compile` (`Shikumi.Compile.Types`, `Shikumi.Compile.Serialize`) —
    `CompiledProgram`, `compiledProgram`, `encodeCompiled`, `decodeCompiledOnto`. GEPA's output
    type and its persistence round-trip.
  * `shikumi-optimize` itself (`Shikumi.Optimize.Types`, `Shikumi.Optimize.Search`) —
    `Optimizer`, `Budget`, `Scored`, `scoreOn`, `freezeProgram`.
  * `containers` — `Map NodePath [Text]` is already EP-16's `FeedbackLog`; GEPA uses `Map`
    only to merge per-example logs (`Map.unionWith (<>)`).
  * `aeson` — `FromModel`/`ToSchema`/`ToPrompt` derivations for `ReflectIn`/`ReflectOut`
    (already the pattern in `Shikumi.Optimize.Instruction`).

Signatures that must exist at the end of each milestone (full module paths):

End of **M1** (`Shikumi.Optimize.GEPA` in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/GEPA.hs`):

```haskell
type FeedbackMetric o = o -> Prediction o -> (Score, Text)

data ReflectIn = ReflectIn
  { currentInstruction :: Text, feedback :: Text, programSummary :: Text
  , datasetSummary :: Text, fieldSummary :: Text }
newtype ReflectOut = ReflectOut { proposedInstruction :: Text }
reflectiveProposer :: Program ReflectIn ReflectOut

captureFeedback ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Dataset i o -> FeedbackMetric o -> Program i o -> Eff es (FeedbackLog, [Double])
```

End of **M2** (same module):

```haskell
mutateNode ::
  (LLM :> es, Error ShikumiError :> es) =>
  Program ReflectIn ReflectOut -> Text -> Text -> [NodeFields] ->
  FeedbackLog -> [NodePath] -> Int -> Program i o -> Eff es (Program i o)
```

End of **M3** (`Shikumi.Optimize.Pareto` in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/Pareto.hs`, and
`gepa` in `Shikumi.Optimize.GEPA`, re-exported from `Shikumi.Optimize`):

```haskell
data Candidate = Candidate
  { candParams :: ![Params], candPerExample :: ![Double], candAggregate :: !Double }
dominates      :: Candidate -> Candidate -> Bool
paretoFrontier :: [Candidate] -> [Candidate]
sampleParent   :: Int -> [Candidate] -> Maybe (Candidate, Int)

gepa ::
  (ToPrompt i, ToPrompt o) =>
  Program ReflectIn ReflectOut -> FeedbackMetric o -> Budget -> Optimizer i o
```

Build/test facts: all builds and tests run inside `nix develop .#ghc9124` (GHC 9.12.4);
`cabal test shikumi-optimize` runs this package's suite and `cabal test all` runs the
workspace; formatting is fourmolu with two-space indentation; tests are hermetic via a stub
`LLM` interpreter (the pattern already in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/test/StubLM.hs`). Commits carry
`MasterPlan:`, `ExecPlan:`, and `Intention:` trailers (intention
`intention_01ktq80q01emxtjfxzd3rw4tjs`).


## Note on this revision

This is the initial full authoring of EP-22 from its skeleton (the YAML frontmatter is
preserved verbatim). It was written after reading: the ExecPlan specification
(`.claude/skills/exec-plan/PLANS.md`); the integration dossier (`/tmp/shikumi-followup/
dossier.md`) for exact current signatures of `Optimizer`/`optimize`/`Budget`,
`scoreOn`/`selectBest`, `Metric`/`Report`, `foldParams`/`mapParamsAt`/`programParams`/
`setProgramParams`, `CompiledProgram`/`encodeCompiled`/`decodeCompiledOnto`, and the trace
substrate; the parent MasterPlan
(`docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md`) for integration
points #1 (reuse EP-18's reward vocabulary), #4 (reuse V1 `Optimizer`/`optimize`/
`CompiledProgram`), and #5 (consume EP-16's node-correlated traces + per-node feedback); the
hard-dependency plan EP-16
(`docs/plans/16-node-correlated-tracing-and-feedback-channel.md`) for the exact
`runProgramTraced`/`NodePath`/`Feedback`/`nodeFields` contract; the soft/hard-dependency
skeletons EP-19 and EP-18 (consumed by named artifact with documented fallbacks since their
bodies are not yet written); the existing optimizer sources under `shikumi-optimize/src/
Shikumi/Optimize/` for style and the `Search`/`Types` helpers; and DSPy's GEPA implementation
(`/tmp/dspy/dspy/teleprompt/gepa/`) for algorithmic fidelity (feedback capture, the reflective
mutation proposer, the Pareto-frontier bookkeeping with parent selection, and round-robin
component selection). The reason GEPA discharges `Trace`/`CurrentNode`/`Feedback` internally
rather than widening the optimizer row, the reason its output is strictly V1's
`CompiledProgram`, and the reason it reuses `Score` + critique `Text` rather than a parallel
reward type, are recorded in the Decision Log to honor the MasterPlan's integration contracts.
The merge step and multimodal proposer from DSPy's GEPA are explicitly out of scope: the
headline reflective-evolution-under-a-Pareto-frontier behavior is fully demonstrable without
them, and adding them would enlarge the plan past what the acceptance criteria require.
