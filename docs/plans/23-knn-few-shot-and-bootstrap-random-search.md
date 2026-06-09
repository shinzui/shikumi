---
id: 23
slug: knn-few-shot-and-bootstrap-random-search
title: "KNN few-shot and bootstrap random search"
kind: exec-plan
created_at: 2026-06-09T22:35:41Z
intention: "intention_01ktq80q01emxtjfxzd3rw4tjs"
master_plan: "docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md"
---

# KNN few-shot and bootstrap random search

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi (`/Users/shinzui/Keikaku/bokuno/shikumi`) is a typed framework for programming
language models in Haskell. You write a program once as a value of type `Program i o` (a
typed function from a structured input `i` to a structured output `o`), and an *optimizer*
improves that program's *parameters* — its instructions and its few-shot *demonstrations* (a
"demo" is an example input/output pair shown to the model in the prompt so it learns the task
by imitation) — without changing the program's structure or types. After optimizing, you get
back a `CompiledProgram i o` you can run, save to disk, and reload.

Shikumi already ships four optimizers (in the package `shikumi-optimize`): `labeledFewShot`
(pick the best fixed set of training examples as demos), `bootstrapFewShot` (run the program
on the training set, keep the runs the metric judged correct, and reuse those as demos),
`instructionSearch` (rewrite each node's instruction), and `ensembleSearch` (combine several
optimized variants by majority vote). This plan adds the two **demo-selection** optimizers
that the modern DSPy framework (the Python project Shikumi mirrors) added and that Shikumi is
still missing:

1. **`knnFewShot`** — *k-nearest-neighbour few-shot*. Instead of choosing one fixed demo set
   for the whole program, it picks, **for each input the program is run on**, the `k` training
   examples whose inputs are most *semantically similar* to that input, and shows those as the
   demos. "Semantically similar" means: turn each text into a dense numeric vector (an
   *embedding*) with an embedding model, and measure the angle between vectors — close
   meanings point in close directions. This is the faithful, run-time variant. A compile-time
   fallback (`knnFewShotCentroid`) picks the demos nearest the *centre* of the training set
   once, at optimize time, for callers who cannot supply a run-time embedder.

2. **`bootstrapRandomSearch`** — *bootstrap few-shot with random search* (DSPy's
   `BootstrapFewShotWithRandomSearch`). It runs the existing `bootstrapFewShot` several times
   with different random demo subsets and sizes (one per random *seed*), scores each resulting
   program on a held-out set, and keeps the single best-scoring one. Random search over
   bootstrap seeds reliably beats a single bootstrap run because a single run's demo set is an
   arbitrary slice of the successful teacher runs; trying several and keeping the best is a
   cheap, robust win.

**What you can do after this change that you could not before.** You can call
`optimize (knnFewShot embedder 3) trainset metric program` and get a compiled program that, at
run time, attaches the three training examples nearest the *current* input as its demos — so a
geography question gets geography demos and an arithmetic question gets arithmetic demos, from
one optimized artifact. And you can call `optimize (bootstrapRandomSearch teacher 8 budget)
trainset metric program` and get back the best of eight bootstrap variants, which on a fixture
task scores **at least as high** as a single `bootstrapFewShot` run on the same held-out set.

**How you see it working (hermetically, no network).** Both optimizers are exercised by tests
that use a *stub embedder* (a pure `Text -> Vector Double` function with a known geometry, so
"close" strings really do embed near each other and "far" strings far apart) and a *stub
language model* (a deterministic fake `LLM` interpreter that returns canned answers). The KNN
test asserts that, under that known stub geometry, the optimizer attaches exactly the
input-nearest training examples as demos. The random-search test asserts the best-of-N
held-out score is greater than or equal to a single bootstrap's on the same fixture. No API
key, no network, fully reproducible.

This plan **hard-depends on EP-15** (`docs/plans/15-embedding-backend-over-baikai.md`), which
makes Shikumi's `Embedding` effect real: it ships `runEmbeddingWith` / `runEmbeddingLLM`
(interpreters that drive an OpenAI-compatible embeddings endpoint through baikai) and the pure
`runEmbedding` / `runEmbeddingBy` test interpreters. This plan consumes that effect — it never
re-implements embeddings. See integration point #6 of the parent master plan
(`docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md`).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `Shikumi.Optimize.KNN` module with `knnFewShot` (run-time, `Embed`-node form) and
      `knnDemos`/`knnFewShotCentroid` (compile-time fallback); selects nearest demos by
      embedding cosine similarity; re-exported from `Shikumi.Optimize`.
- [ ] M1: Hermetic test `KNNSpec` proving, under a known stub-embedder geometry, that the
      attached demos are the input-nearest training examples (run-time form) and the
      centroid-nearest training examples (compile-time fallback).
- [ ] M2: `Shikumi.Optimize.RandomSearch` module with `bootstrapRandomSearch` reusing V1's
      `bootstrapFewShot`/`bootstrapFewShotWith` over deterministic seeds, keeping the best by
      held-out score; re-exported from `Shikumi.Optimize`.
- [ ] M2: Hermetic test `RandomSearchSpec` proving the best-of-N held-out score is `>=` a
      single bootstrap run on a fixture, with a stub LM and pure metric.
- [ ] M3: Acceptance — held-out lift assertions for both optimizers; `encodeCompiled` /
      `decodeCompiledOnto` round-trip for both compiled outputs (documenting how the run-time
      `Embed`-based KNN serializes — it carries no `Params`, like `react`).
- [ ] Master-plan registry row for EP-23 flipped to In Progress / Complete and the EP-23
      progress bullet in the parent master plan checked off.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet — fill in during implementation.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Resolve the "KNN is run-time, but `CompiledProgram` bakes demos at compile time"
  tension by offering **both** forms, leading with a faithful **run-time `Embed`-node form**
  (`knnFewShot`, built on `knnDemos`) and providing a **compile-time centroid fallback**
  (`knnFewShotCentroid`).
  Rationale: DSPy's `KNNFewShot` selects demos *per input at forward time* (see
  `/tmp/dspy/dspy/predict/knn.py` and `/tmp/dspy/dspy/teleprompt/knn_fewshot.py`): it embeds
  every training input once at construction, then at each call embeds the current input and
  returns the `k` nearest training examples as that call's demos. Shikumi's `CompiledProgram`
  ordinarily bakes one fixed demo set onto every node at optimize time, which cannot express
  "demos depend on the input". The faithful analog is therefore a program node that performs
  the nearest-neighbour lookup *and* the prediction at run time — exactly what Shikumi's
  `Embed` constructor is for. `Embed` is how V1's `react` agent is a first-class composable
  `Program` (an opaque effectful node carrying no `Params`); KNN is the same shape. The
  centroid fallback exists for callers who want a plain baked `Params` artifact (e.g. to ship
  one fixed demo set) and cannot run an embedder at execution time.
  Date: 2026-06-09.
- Decision: The run-time KNN node receives its embedder as a **pure injected closure**
  `embedder :: Text -> Vector Double`, captured into the `Embed` body, rather than the
  `Embedding` *effect*.
  Rationale (load-bearing — read carefully): Shikumi's `Embed` constructor fixes its body's
  effect row to *exactly* `(LLM :> es, Error ShikumiError :> es)` (see
  `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Program.hs` lines 191–199), so an
  `Embed` body **cannot** call `embedText` — `Embedding` is not in its row, and widening that
  row would violate integration point #4 (the `runProgram` constraint must stay
  `(LLM, Error ShikumiError)`). The resolution: do all embedding-effect work *outside* the
  node, at optimize time, where the full evaluator row plus a discharged `Embedding`
  interpreter is available, and pass into the node a *pure* function from text to vector. The
  optimizer's caller supplies that pure embedder. For production use it is obtained by
  *closing over* EP-15's effect — e.g. the caller runs the trainset embeddings through
  `runEmbeddingWith` once, but the per-input run-time lookup needs a pure `Text -> Vector
  Double`; in practice the embedder closure is the same deterministic stub in tests and, for
  live use, a memoised/precomputed table or a synchronous wrapper. The public `knnFewShot`
  signature therefore takes `(Text -> Vector Double)`, matching the shape of EP-15's pure
  `runEmbedding` interpreter argument and its `runEmbeddingBy` seam, and keeping the node
  hermetic and serialization-safe. See "Context and Orientation" for the full justification
  and the live-embedder caveat recorded under Surprises during implementation.
  Date: 2026-06-09.
- Decision: `bootstrapRandomSearch` is a **wrapper over V1's `bootstrapFewShot`**, not a
  re-implementation of bootstrap.
  Rationale: integration point #4 of the parent master plan mandates reusing V1's optimizers;
  the dossier (section E.6 M2) and `Shikumi.Optimize.Bootstrap` already provide
  `bootstrapFewShot`/`bootstrapFewShotWith`. Random search only varies the *seed* (the random
  subset and size of demos) and keeps the best, exactly as DSPy's
  `BootstrapFewShotWithRandomSearch` (`/tmp/dspy/dspy/teleprompt/random_search.py`) wraps DSPy's
  `BootstrapFewShot`.
  Date: 2026-06-09.
- Decision: Randomness is a **deterministic linear-congruential (LCG) stream**, mirroring
  `Shikumi.Optimize.Ensemble`'s style, not a system RNG.
  Rationale: there is no ambient `Math.random` in this environment and the tests rely on
  reproducible candidate generation; `Shikumi.Optimize.Ensemble` already establishes the LCG
  (glibc constants) resampling idiom, so `bootstrapRandomSearch` reuses that exact style for a
  consistent, hermetic, reproducible search.
  Date: 2026-06-09.
- Decision: Place new code in `shikumi-optimize` as two new modules,
  `Shikumi.Optimize.KNN` and `Shikumi.Optimize.RandomSearch`, re-exported from
  `Shikumi.Optimize`. No parallel optimizer type or serialization surface.
  Rationale: integration point #4 — every optimizer is V1's `Optimizer i o`, invoked via V1's
  `optimize`, returning V1's `CompiledProgram i o`, persisted with V1's `encodeCompiled` /
  `decodeCompiledOnto`. The CLI and golden tests depend on these being stable.
  Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Read this section fully before editing. It assumes no prior knowledge of the repository.

### The package and where new code goes

All edits land in the package `shikumi-optimize`, rooted at
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize`. Its source modules live under
`shikumi-optimize/src/Shikumi/Optimize/` and its tests under `shikumi-optimize/test/`. You add
two new source modules — `Shikumi/Optimize/KNN.hs` and `Shikumi/Optimize/RandomSearch.hs` —
and two new test modules, register all four in `shikumi-optimize/shikumi-optimize.cabal`, and
re-export the two new optimizers from the façade `Shikumi/Optimize.hs`.

### The optimizer contract you must satisfy (verbatim from the dossier)

An optimizer is a value of this type, defined in
`shikumi-optimize/src/Shikumi/Optimize/Types.hs`:

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
```

In plain terms: an `Optimizer i o` wraps one function that, given a training `Dataset i o`, a
`Metric o` (a pure scorer `o -> Prediction o -> Score`), and a starting `Program i o`, runs in
the *evaluator effect row* and returns a `CompiledProgram i o`. The effect row — `(LLM,
Concurrent, Error ShikumiError, Time, Prim)` — is exactly what `evaluate`/`evaluatePure` needs
(scoring a candidate runs the program over the dataset). You never widen this row; in
particular you do **not** add `Embedding` to it (see the next subsection).

`optimize` (in `shikumi-optimize/src/Shikumi/Optimize.hs`) is the one public entry point:

```haskell
optimize ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  Optimizer i o -> Dataset i o -> Metric o -> Program i o -> Eff es (CompiledProgram i o)
optimize opt train metric prog = runOptimizer opt train metric prog
```

A `CompiledProgram i o` is, per the dossier (section F.1), a newtype wrapping a `Program i o`
whose nodes already hold their baked-in `Params`:

```haskell
newtype CompiledProgram i o = CompiledProgram { compiledProgram :: Program i o }
runCompiled :: (LLM :> es, Error ShikumiError :> es) => CompiledProgram i o -> i -> Eff es o
freezeProgram :: Program i o -> CompiledProgram i o    -- = CompiledProgram (Shikumi.Optimize.Search)
```

### The `Params`/`Demo` parameter model (verbatim from the dossier, section A.2)

```haskell
data Params = Params { instructionOverride :: !(Maybe Text), demos :: ![Demo] }
data Demo   = Demo   { input :: !Value, output :: !Value }            -- Value = aeson JSON
emptyParams :: Params
```

A node's demos are a list of JSON input/output pairs. The helper `withDemos :: [Demo] ->
Program i o -> Program i o` (in `Shikumi.Optimize.LabeledFewShot`,
`shikumi-optimize/src/Shikumi/Optimize/LabeledFewShot.hs`) attaches the same demo set to every
node via `mapParams (\ps -> ps { demos = ds })`. You reuse `withDemos` for the centroid
fallback. `mapParams` and `foldParams` are in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Program.hs` (dossier section A.5):
the parameter traversal visits **`Predict` nodes only**, left-to-right depth-first; composite
nodes (`Compose`, `FMap`, `Embed`) carry no `Params`.

### The `Embed` constructor — the heart of the run-time KNN design

From `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Program.hs` (lines 189–212):

```haskell
-- in the Program GADT:
Embed :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o

-- smart constructor:
embed :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o
embed = Embed
```

`Embed` lifts an opaque effectful step `i -> Eff es o` into a `Program i o`. Two facts drive
this plan's whole design:

1. **The body's effect row is fixed to `(LLM :> es, Error ShikumiError :> es)` and nothing
   more.** It is rank-2 quantified over `es` with that exact constraint. So inside an `Embed`
   body you can call `runProgram` on a sub-program, call the LLM, and throw a `ShikumiError` —
   but you **cannot** call `embedText` (the `Embedding` effect is not in the row). This is why
   the run-time KNN node receives a *pure* embedder closure, not the effect (see Decision Log).
   Widening the row is forbidden: integration point #4 says `runProgram`'s constraint stays
   `(LLM, Error ShikumiError)`, and `Embed` is precisely the constructor that lets a program
   stay runnable under that constraint.

2. **An `Embed` node carries no `Params` and is opaque to the parameter traversal**, exactly
   like `FMap`. Its `ProgramShape` is `ShapeEmbed` (the body is omitted from the shape; dossier
   section A.6). This is how V1's `react` agent (dossier section H.4) is a composable,
   structurally-inspectable, serializable program: "the agent loop is one `Embed` node, so the
   agent is a real, composable `Program` … (it carries no `Params`, like `FMap`)." The run-time
   KNN program is the same shape — which dictates *how it serializes* (see M3 and the
   serialization note below).

### EP-15: the embeddings substrate this plan consumes

EP-15 (`docs/plans/15-embedding-backend-over-baikai.md`, a hard dependency) makes the
`Embedding` effect real. From that plan and the dossier (sections E.4, J.1), the effect lives
in `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-eval/src/Shikumi/Eval/Metric.hs`:

```haskell
data Embedding :: Effect where
  EmbedText :: Text -> Embedding m (Vector Double)
embedText    :: (Embedding :> es) => Text -> Eff es (Vector Double)
runEmbedding :: (Text -> Vector Double) -> Eff (Embedding : es) a -> Eff es a   -- pure interpreter
semanticSimilarity :: (Embedding :> es) => (o -> Text) -> MetricM es o          -- cosine, [-1,1]→[0,1]
```

EP-15 adds, in `shikumi-eval/src/Shikumi/Eval/Embedding.hs`, the real interpreters
`runEmbeddingWith :: EmbeddingModel -> ...` and `runEmbeddingLLM :: ...` (OpenAI-backed) and
the injectable seam `runEmbeddingBy :: ([Text] -> IO (Vector (Vector Double))) -> ...`. The key
observation this plan relies on: **the unit that turns text into a vector is, at its core, a
pure `Text -> Vector Double`** — that is exactly the argument shape of EP-15's pure
`runEmbedding`, and exactly what this plan injects into the KNN node. EP-15 establishes the
*hermetic stub stance*: tests use a deterministic stub embedder (close pairs embed near,
distant far). This plan mirrors that stance precisely.

`Vector Double` is `Data.Vector.Vector Double` from the `vector` package. **Cosine
similarity** of two vectors `a` and `b` is `dot(a,b) / (‖a‖·‖b‖)`; it lies in `[-1, 1]`, is `1`
for same-direction vectors and lower for divergent ones. KNN ranks training examples by cosine
similarity of their input-embedding to the query-embedding, highest first. (Shikumi's
`cosineScore` in `Shikumi.Eval.Metric` maps `[-1,1] → [0,1]`; for *ranking* you do not need the
remap — raw cosine, or even the dot product when comparing against one fixed query, gives the
same ordering — but defining a small `cosine` helper in the KNN module keeps the intent
explicit. DSPy ranks by the raw dot product, `np.dot(trainset_vectors, query)`, see
`/tmp/dspy/dspy/predict/knn.py`; cosine is dot normalised and is the safer default when
training-input norms differ.)

### What DSPy does, precisely, in this plan's own words

**`KNNFewShot` + `KNN`** (`/tmp/dspy/dspy/teleprompt/knn_fewshot.py`,
`/tmp/dspy/dspy/predict/knn.py`). At construction, `KNN` renders each training example's
*input fields* to a string and embeds all of them once, caching the `trainset_vectors`. At
forward (run) time, it renders the current input the same way, embeds it, computes the
similarity of the query vector against every cached training vector (`np.dot`), takes the `k`
highest (`argsort()[-k:][::-1]`), and returns those `k` training examples. `KNNFewShot.compile`
wraps the student so that, on each call, it (in DSPy) bootstraps few-shot demos from *those k
neighbours* and runs. The user-visible behaviour we mirror: **at run time, the demos are the k
training examples most similar to the current input.** This plan's run-time form simplifies
DSPy's per-call re-bootstrap to *directly attaching the k nearest training examples as demos*
(the labelled-demo path), which is the dominant, deterministic part of the behaviour and is
exactly what the acceptance test checks; the optional teacher re-bootstrap per input is left
out as a non-deterministic refinement (noted under Surprises if revisited).

**`BootstrapFewShotWithRandomSearch`** (`/tmp/dspy/dspy/teleprompt/random_search.py`). It
iterates over candidate "seeds": a couple of special seeds (zero-shot, labels-only,
unshuffled bootstrap) plus `num_candidate_programs` random seeds. For each random seed it
shuffles the trainset with that seed and picks a random demo count `size` between
`min_num_samples` and `max_num_samples`, then runs `BootstrapFewShot` with that size on the
shuffled set. Every candidate program is evaluated on a validation set; it keeps the
highest-scoring one. The user-visible behaviour we mirror: **try bootstrap several times with
different random demo subsets/sizes and keep the best-scoring program.** This plan implements
the core of that — a zero-shot/labels baseline candidate plus N seeded random bootstrap
candidates, each scored by `scoreOn` (the dossier's `evaluatePure`-backed scorer), keeping the
best with the existing `selectBest` fold.

### The siblings you reuse (all in `shikumi-optimize/src/Shikumi/Optimize/`)

- `Search.hs` — `selectBest :: Monad m => Budget -> (cand -> m Double) -> [cand] -> m (Maybe
  (Scored cand))` (pure selection fold, ties→earliest), `scoreOn :: ... => Dataset i o ->
  Metric o -> Program i o -> Eff es Double` (runs `evaluatePure`, takes `aggregateScore`), and
  `freezeProgram :: Program i o -> CompiledProgram i o`. `bootstrapRandomSearch` reuses all
  three.
- `Bootstrap.hs` — `bootstrapFewShot :: (ToJSON i, ToJSON o) => Program i o -> Budget ->
  Optimizer i o`, `bootstrapFewShotWith :: BootstrapConfig -> Program i o -> Budget ->
  Optimizer i o`, `BootstrapConfig { passThreshold, maxBootstrappedDemos }`,
  `defaultBootstrapConfig`. `bootstrapRandomSearch` calls `runOptimizer (bootstrapFewShotWith
  cfg teacher budget) (shuffle seed train) metric student` once per seed.
- `LabeledFewShot.hs` — `withDemos :: [Demo] -> Program i o -> Program i o`,
  `labeledCandidateSets`. The centroid fallback uses `withDemos`.
- `Ensemble.hs` — its deterministic `lcg :: Int -> [Int]` (glibc-constants linear-congruential
  stream) and `resample`/seeding style. `RandomSearch.hs` mirrors this for shuffling and for
  picking a per-seed demo count. (`lcg` is module-private in `Ensemble`; reproduce the same
  three-line function in `RandomSearch` — the dossier and the plan both note the LCG idiom is
  shared by copy, not by export, because `Ensemble` does not export it.)
- `Types.hs` — `Optimizer (..)`, `Budget (..)` (`maxLmCalls`, `maxCandidates`),
  `defaultBudget`, `Scored (..)`.

### The eval/dataset vocabulary (dossier section E.1)

```haskell
data Example i o = Example { input :: !i, expected :: !o }
newtype Dataset i o = Dataset [Example i o]
dataset         :: [Example i o] -> Dataset i o
datasetExamples :: Dataset i o -> [Example i o]
```

These come from `Shikumi.Eval` (`shikumi-eval`), already a dependency of `shikumi-optimize`.

### Build and test facts

The repo builds with GHC 9.12.4 from a Nix dev shell. From the repo root
`/Users/shinzui/Keikaku/bokuno/shikumi`, enter it with `nix develop .#ghc9124` (the system
`ghc` is 9.10.3 — the wrong compiler; do not use it). Build the package with `cabal build
shikumi-optimize`; run its tests with `cabal test shikumi-optimize`; run the whole suite with
`cabal test all`. Formatting is `fourmolu` with 2-space indentation, enforced by a pre-commit
hook; run `fourmolu --mode inplace $(git ls-files '*.hs')` before committing or the hook
reformats. Every commit carries `MasterPlan:`, `ExecPlan:`, and `Intention:` trailers (see the
commit templates in the milestones).


## Plan of Work

The work is three milestones. M1 delivers KNN demo selection (run-time and compile-time
forms). M2 delivers bootstrap random search. M3 ties both to held-out-lift acceptance and
serialization round-trips. Each milestone is independently verifiable with a hermetic test
(stub embedder + stub LM) and a precise acceptance assertion. M1 and M2 are independent of each
other and may be done in either order; M3 depends on both.


### Milestone M1 — KNN few-shot demo selection

**Scope.** Add `shikumi-optimize/src/Shikumi/Optimize/KNN.hs` exposing the run-time KNN form
`knnFewShot`, its underlying node builder `knnDemos`, the pure ranking helpers, and the
compile-time fallback `knnFewShotCentroid`. Re-export them from `Shikumi.Optimize`. Add a
hermetic test `KNNSpec` proving the attached demos are the input-nearest (run-time) and
centroid-nearest (fallback) training examples under a known stub-embedder geometry. At the end
of M1, a reader can construct a KNN-optimized program and observe, deterministically, which
demos it selects for a given input.

**The module surface (the contract M1 establishes):**

```haskell
module Shikumi.Optimize.KNN
  ( -- run-time form (the faithful analog)
    knnFewShot,
    knnDemos,
    -- compile-time fallback
    knnFewShotCentroid,
    -- pure helpers (exposed so tests can reproduce the ranking)
    cosine,
    nearestDemos,
    centroid,
  )
where

-- | Run-time KNN: returns an Optimizer whose compiled program is a single 'Embed'
-- node that, for each input, embeds the input with the injected pure embedder,
-- ranks the training examples by cosine similarity of their input-embedding to the
-- input's, attaches the k nearest as that run's demos, and runs the (frozen)
-- student under those demos.
knnFewShot ::
  (ToJSON i, ToJSON o, ToPrompt i) =>
  (Text -> Vector Double) ->   -- the injected pure embedder (EP-15's pure-embedder shape)
  Int ->                        -- k: number of neighbour demos
  Optimizer i o

-- | The Program node that performs the per-input KNN selection and runs the student.
-- Exposed (not just used by 'knnFewShot') so it composes like V1's 'react': it is a
-- plain @Program i o@ (an 'Embed' node) usable anywhere a Program is, and serializes
-- the same way 'react' does (no 'Params').
knnDemos ::
  (ToJSON i, ToJSON o, ToPrompt i) =>
  (Text -> Vector Double) ->
  Int ->
  Dataset i o ->               -- the training examples to select neighbours from
  Program i o ->               -- the student program demos are attached to
  Program i o

-- | Compile-time fallback: pick the k training examples nearest the centroid of all
-- training-input embeddings, bake them as a fixed demo set on every node (via
-- 'withDemos'), and freeze. A plain @Params@ artifact, no run-time embedder needed.
knnFewShotCentroid ::
  (ToJSON i, ToJSON o, ToPrompt i) =>
  (Text -> Vector Double) ->
  Int ->
  Optimizer i o

cosine       :: Vector Double -> Vector Double -> Double
nearestDemos :: (ToJSON i, ToJSON o, ToPrompt i)
             => (Text -> Vector Double) -> Int -> [Example i o] -> Text -> [Demo]
centroid     :: [Vector Double] -> Vector Double
```

**Files to create or edit (all under `/Users/shinzui/Keikaku/bokuno/shikumi`):**

1. **New module** `shikumi-optimize/src/Shikumi/Optimize/KNN.hs`. Implementation notes, in
   prose so a novice can write it:

   - **Rendering an input to text.** To embed an input you need a `Text` for it. Use the
     `ToPrompt` class (dossier section C.3): `toPrompt :: ToPrompt a => a -> Text` renders a
     structured value to its prompt text (the same rendering the adapter uses). So the text of
     a training example or a query input `i` is `toPrompt i`. This mirrors DSPy's `KNN`, which
     joins the example's input fields into a string before embedding
     (`/tmp/dspy/dspy/predict/knn.py`). Add `ToPrompt i` to the constraints (import from
     `Shikumi.Adapter`).

   - **`cosine a b`** = `dot a b / (norm a * norm b)`, where `dot = V.sum (V.zipWith (*) a b)`
     and `norm v = sqrt (dot v v)`. Guard the zero-norm degenerate case: if either norm is `0`,
     return `0` (no signal), matching `cosineScore`'s zero-length handling. Use
     `Data.Vector qualified as V`.

   - **`nearestDemos embedder k exs query`**: embed `query` once (`embedder query`); for each
     `Example i o` in `exs`, compute `cosine (embedder (toPrompt i)) qv`; sort the examples by
     that score *descending* (ties broken by original order — use a stable sort, e.g. sort on
     `Down score` with the original index as the tiebreak, so the result is deterministic);
     take the first `k`; turn each kept example into a `Demo {input = toJSON i, output = toJSON
     o}` (exactly how `LabeledFewShot.labeledCandidateSets` and `Bootstrap.recoverDemo` build a
     JSON `Demo`). Return that `[Demo]`. Precompute the training-input embeddings *outside* the
     per-query path where possible (embed each `toPrompt i` once and reuse), mirroring DSPy's
     cached `trainset_vectors` — but since the embedder is a pure function, even the naive
     re-embed is deterministic and correct; cache as an optimisation.

   - **`knnDemos embedder k train student`**: build the `Embed` node. The body, given an input
     `i`, computes `let ds = nearestDemos embedder k (datasetExamples train) (toPrompt i)` and
     runs `runProgram (withDemos ds student) i`. Concretely:

     ```haskell
     knnDemos embedder k train student =
       let exs = datasetExamples train
        in embed $ \i -> runProgram (withDemos (nearestDemos embedder k exs (toPrompt i)) student) i
     ```

     `embed` and `runProgram` are from `Shikumi.Program`; `withDemos` from
     `Shikumi.Optimize.LabeledFewShot`. The body's row is `(LLM, Error ShikumiError)` — which is
     all `runProgram` needs and all the `Embed` body permits. The embedder is captured as a
     pure closure, so no `Embedding` effect is required inside. This is the faithful run-time
     analog: demos depend on the input.

   - **`knnFewShot embedder k`**: an `Optimizer` that ignores the metric for *selection* (KNN
     does not search — it deterministically attaches neighbours) and returns
     `freezeProgram (knnDemos embedder k train student)`:

     ```haskell
     knnFewShot embedder k = Optimizer $ \train _metric student ->
       pure (freezeProgram (knnDemos embedder k train student))
     ```

     (It makes no LM calls itself and does not consult the metric — selection is by embedding
     geometry, not by held-out score. That matches DSPy's `KNNFewShot`, which selects
     neighbours, not the best of several. The metric is still in the signature because every
     `Optimizer` shares one driver type.)

   - **`knnFewShotCentroid embedder k`** (compile-time fallback): embed every training input
     (`embedder . toPrompt`), compute the `centroid` (component-wise mean) of those vectors,
     pick the `k` training examples nearest that centroid via `nearestDemos` applied to a
     synthetic "query at the centroid" — since `nearestDemos` takes a `Text` query, factor the
     ranking so the fallback can rank by cosine-to-a-vector directly (add a small internal
     `nearestDemosByVec :: (Text -> Vector Double) -> Int -> [Example i o] -> Vector Double ->
     [Demo]` that `nearestDemos` is defined in terms of). Bake the result with `withDemos` and
     freeze:

     ```haskell
     knnFewShotCentroid embedder k = Optimizer $ \train _metric student ->
       let exs = datasetExamples train
           c   = centroid [embedder (toPrompt i) | Example i _ <- exs]
           ds  = nearestDemosByVec embedder k exs c
        in pure (freezeProgram (withDemos ds student))
     ```

     `centroid vs = V.map (/ fromIntegral (length vs)) (foldl1 (V.zipWith (+)) vs)`, with the
     empty-list case returning an empty vector. This produces a plain baked-`Params` artifact
     (every node gets the same `k` centroid-nearest demos), serializable as ordinary `[Params]`
     — the natural fallback for callers who cannot run an embedder at execution time.

2. **Edit** `shikumi-optimize/src/Shikumi/Optimize.hs`: add `module Shikumi.Optimize.KNN` to
   the re-export list and `import Shikumi.Optimize.KNN`.

3. **Edit** `shikumi-optimize/shikumi-optimize.cabal`: add `Shikumi.Optimize.KNN` to the
   library `exposed-modules`. Add `vector` to the library `build-depends` if not already
   present (it is used for `Vector Double`); `aeson` (for `toJSON`) and the shikumi packages
   are already deps.

4. **New test** `shikumi-optimize/test/KNNSpec.hs`, registered in the test suite's
   `other-modules` in `shikumi-optimize/shikumi-optimize.cabal` and aggregated in the suite's
   `Main` (follow the existing pattern by which the other `*Spec` modules are aggregated —
   inspect `shikumi-optimize/test/Main.hs` or the existing spec files to match their harness,
   `hspec` or `tasty`). The test contains:

   - A **stub embedder** `stubEmbed :: Text -> Vector Double` with a known 2-D geometry. Pick a
     tiny fixture domain where similarity is obvious. For example, map inputs whose rendered
     text contains the word "france"/"paris"/"capital" to a vector near direction `[1, 0]`, and
     inputs about arithmetic ("plus", "sum", digits) to a vector near `[0, 1]`, with small
     per-string perturbations so distinct examples are distinguishable but stay in their
     cluster. Concretely, define `stubEmbed t` by inspecting `t` for marker substrings and
     returning e.g. `V.fromList [1, 0.1]`, `V.fromList [0.9, 0.2]`, `V.fromList [0.1, 1]`,
     `V.fromList [0.2, 0.9]` so the geography cluster and the arithmetic cluster are
     near-orthogonal. Verify by hand that the intended neighbours win under `cosine`.

   - A **training set** `train :: Dataset Q A` over a small fixture input type `Q` and output
     `A` (define minimal record types with `ToJSON`/`ToPrompt`/`FromModel`/`ToSchema` — or
     reuse a fixture type already present in the optimize test tree if one exists; check the
     existing specs first) containing, say, two geography examples and two arithmetic examples.

   - A test **`"knnDemos attaches the input-nearest training examples"`**: call `nearestDemos
     stubEmbed 2 (datasetExamples train) (toPrompt geographyQuery)` and assert the returned
     `[Demo]` are exactly the two geography examples (compare on `toJSON` of the expected
     inputs), in nearest-first order. Then do the symmetric assertion for an arithmetic query.
     This is the headline acceptance: **the chosen demos are the input-nearest training
     examples under the known stub geometry.**

   - A test **`"knnFewShotCentroid attaches the centroid-nearest examples"`**: with a training
     set deliberately skewed (e.g. three geography + one arithmetic, so the centroid sits in the
     geography cluster), assert `knnFewShotCentroid stubEmbed 2` bakes the two geography
     examples as demos on the student's single `Predict` node — inspect via `foldParams` /
     `programParams` (dossier A.5/A.6) on `compiledProgram` of the result and compare the
     node's `demos` to the expected JSON. This proves the compile-time fallback picks
     centroid-nearest neighbours and bakes them as `Params`.

   - A test **`"knnDemos selects per-input (run-time) demos"`** that runs the optimized program
     end-to-end under a **stub LM** and asserts the demos actually presented differ between a
     geography input and an arithmetic input. The cleanest hermetic way: make the stub LM a
     deterministic `LLM` interpreter that records (in a `Prim` `IORef`, or returns through the
     answer) the demos it saw in the rendered context, or — simpler — assert at the
     `nearestDemos` level for both inputs (already covered above) and additionally assert the
     `Embed`-wrapped program *runs* and returns the stub LM's canned answer for each input under
     `runProgram`, proving the node is a real runnable `Program`. (A full "inspect rendered
     demos through the LM" assertion is optional polish; the `nearestDemos` assertions are the
     load-bearing acceptance.)

**Commands (from `/Users/shinzui/Keikaku/bokuno/shikumi`):**

```bash
nix develop .#ghc9124
cabal build shikumi-optimize
cabal test shikumi-optimize
```

**Acceptance for M1.** `cabal test shikumi-optimize` is green and includes the `KNN` group.
The headline assertions pass: under the known stub geometry, `nearestDemos` returns the
input-nearest training examples (geography query → geography demos; arithmetic query →
arithmetic demos), and `knnFewShotCentroid` bakes the centroid-nearest examples as the node's
`Params`. Expected (abridged):

```text
KNN
  knnDemos attaches the input-nearest training examples: OK
  knnFewShotCentroid attaches the centroid-nearest examples: OK
  knnDemos selects per-input (run-time) demos: OK
```

**Commit (M1).**

```text
feat(shikumi-optimize): add knnFewShot/knnDemos embedding-similarity demo selection

MasterPlan: docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md
ExecPlan: docs/plans/23-knn-few-shot-and-bootstrap-random-search.md
Intention: intention_01ktq80q01emxtjfxzd3rw4tjs
```


### Milestone M2 — Bootstrap few-shot with random search

**Scope.** Add `shikumi-optimize/src/Shikumi/Optimize/RandomSearch.hs` exposing
`bootstrapRandomSearch`, a wrapper that runs V1's `bootstrapFewShot` over several deterministic
seeds (each shuffling the trainset and picking a random demo count), scores each candidate on
the dataset with `scoreOn`, and keeps the best via `selectBest`. Re-export from
`Shikumi.Optimize`. Add a hermetic test proving the best-of-N held-out score is `>=` a single
bootstrap run. At the end of M2, a reader can call `optimize (bootstrapRandomSearch teacher n
budget) train metric prog` and get the best of `n` bootstrap variants.

**The module surface (the contract M2 establishes):**

```haskell
module Shikumi.Optimize.RandomSearch
  ( bootstrapRandomSearch,
    bootstrapRandomSearchWith,
    RandomSearchConfig (..),
    defaultRandomSearchConfig,
  )
where

data RandomSearchConfig = RandomSearchConfig
  { minDemos :: !Int,   -- lower bound on the per-seed random demo count (default 1)
    maxDemos :: !Int,   -- upper bound on the per-seed random demo count (default 4)
    passThreshold :: !Double  -- bootstrap pass threshold forwarded to BootstrapConfig (default 1.0)
  }

defaultRandomSearchConfig :: RandomSearchConfig

-- | Run V1 bootstrap over @numCandidates@ random seeds plus a zero-shot baseline,
-- score each on the dataset, and keep the best-scoring CompiledProgram.
bootstrapRandomSearch ::
  (ToJSON i, ToJSON o) =>
  Program i o ->   -- teacher (may be the student itself)
  Int ->           -- numCandidates: number of random seeds to try
  Budget ->        -- forwarded to each bootstrap run; also bounds candidates scored
  Optimizer i o

bootstrapRandomSearchWith ::
  (ToJSON i, ToJSON o) =>
  RandomSearchConfig -> Program i o -> Int -> Budget -> Optimizer i o
```

**Files to create or edit (all under `/Users/shinzui/Keikaku/bokuno/shikumi`):**

1. **New module** `shikumi-optimize/src/Shikumi/Optimize/RandomSearch.hs`. Implementation
   notes:

   - **Deterministic randomness.** Reproduce the `lcg` stream from
     `Shikumi.Optimize.Ensemble` (it is module-private there, so copy the three-line definition;
     record in the Decision Log that it is duplicated by intent):

     ```haskell
     lcg :: Int -> [Int]
     lcg s0 = drop 1 (iterate step s0)
       where step s = (1103515245 * s + 12345) `mod` 2147483648
     ```

   - **Per-seed shuffle.** Use the LCG stream to shuffle a list deterministically (a
     Fisher–Yates-style permutation driven by `lcg seed`), or, more simply, reorder by sorting
     on an LCG-derived key per element — any deterministic seed-dependent reordering is fine, as
     DSPy's only requirement is that different seeds give different subsets. Mirror
     `Ensemble.resample`'s shape (it indexes `exs V.! (i \`mod\` m)` over the LCG stream); here
     you want a *permutation* (without replacement) so the bootstrap sees each example at most
     once. Define `shuffle :: Int -> Dataset i o -> Dataset i o` that returns `dataset` of the
     permuted examples.

   - **Per-seed demo count.** Pick `size` in `[minDemos .. maxDemos]` from the seed:
     `let size = minDemos cfg + (head (lcg seed) \`mod\` (maxDemos cfg - minDemos cfg + 1))`
     (guard `maxDemos >= minDemos`). This mirrors DSPy's `random.Random(seed).randint(min,
     max)`.

   - **One candidate per seed.** For each `seed <- [1 .. max 1 numCandidates]`, build a
     bootstrap optimizer with that seed's demo cap and run it on that seed's shuffled trainset:

     ```haskell
     candidateFor seed = do
       let cfg' = defaultBootstrapConfig { maxBootstrappedDemos = sizeFor seed,
                                           passThreshold = passThreshold cfg }
           opt  = bootstrapFewShotWith cfg' teacher budget
       compiledProgram <$> runOptimizer opt (shuffle seed train) metric student
     ```

     `bootstrapFewShotWith`, `defaultBootstrapConfig`, `BootstrapConfig (..)` are from
     `Shikumi.Optimize.Bootstrap`; `compiledProgram` unwraps the `CompiledProgram` (dossier
     F.1), exactly as `Ensemble.ensembleSearch` does.

   - **A zero-shot baseline candidate.** Mirroring DSPy's special seeds, also include the
     student with no demos (`student` itself, or `withDemos [] student`) as one candidate, so
     random search can never do *worse* than zero-shot. This is what makes the "best-of-N `>=`
     single bootstrap" inequality robust and is the cheap insurance DSPy's `seed == -3` provides.

   - **Score and keep the best.** Collect the candidate programs, then use `selectBest` over
     `scoreOn train metric` to pick the highest-scoring one (ties → earliest), and
     `freezeProgram` it:

     ```haskell
     bootstrapRandomSearchWith cfg teacher numCandidates budget =
       Optimizer $ \train metric student -> do
         let seeds = [1 .. max 1 numCandidates]
         cands <- (:) student <$> mapM (candidateFor train metric student) seeds  -- baseline + seeded
         best  <- selectBest budget (\p -> scoreOn train metric p) cands
         pure $ case best of
           Nothing -> freezeProgram student
           Just sc -> freezeProgram (candidate sc)
     ```

     `selectBest`, `scoreOn`, `freezeProgram` from `Shikumi.Optimize.Search`; `candidate`,
     `Scored (..)`, `Budget (..)` from `Shikumi.Optimize.Types`. Note `selectBest` already caps
     the number of candidates scored at `maxCandidates budget`, so the `Budget` bounds both the
     bootstrap LM calls (inside each candidate) and the number of candidates scored — no
     separate budget surface is introduced.

   - **`bootstrapRandomSearch teacher n budget = bootstrapRandomSearchWith
     defaultRandomSearchConfig teacher n budget`**, with `defaultRandomSearchConfig =
     RandomSearchConfig { minDemos = 1, maxDemos = 4, passThreshold = 1.0 }`.

2. **Edit** `shikumi-optimize/src/Shikumi/Optimize.hs`: add `module Shikumi.Optimize.RandomSearch`
   to the re-exports and `import Shikumi.Optimize.RandomSearch`.

3. **Edit** `shikumi-optimize/shikumi-optimize.cabal`: add `Shikumi.Optimize.RandomSearch` to
   the library `exposed-modules`.

4. **New test** `shikumi-optimize/test/RandomSearchSpec.hs`, registered and aggregated like
   `KNNSpec`. It contains:

   - A **stub LM** — a deterministic `LLM` interpreter returning canned structured answers for
     the fixture task — and a **pure metric** (`exactMatch` from `Shikumi.Eval`, dossier E.4)
     so scoring is deterministic. Mirror whatever stub-LM harness the existing optimize tests
     use (inspect `Bootstrap`/`LabeledFewShot` specs in `shikumi-optimize/test/` for the exact
     `runLLM`-stub idiom and the `runEff`/`runError`/`runConcurrent`/`runTime`/`runPrim`
     discharge stack the optimizer effect row needs).

   - A fixture where demos *help*: design the stub LM so that, on inputs not covered by a demo,
     it answers wrong, but when a matching demo is present in the prompt it answers right (the
     stub can key its answer on whether a relevant demo appears in the rendered context). This
     makes bootstrap (and thus random search) measurably improve the score, so the inequality is
     non-trivial.

   - A test **`"bootstrapRandomSearch held-out score >= single bootstrap"`**: compute
     `singleScore = scoreOn heldout metric (compiledProgram <$> optimize (bootstrapFewShot
     teacher budget) train metric student)` and `rsScore = scoreOn heldout metric
     (compiledProgram <$> optimize (bootstrapRandomSearch teacher 8 budget) train metric
     student)` — both under the same stub LM and the same held-out dataset — and assert `rsScore
     >= singleScore`. (Use a held-out split distinct from `train`, or, following DSPy's default
     of `valset = trainset`, evaluate on `train` itself; document which.) This is the headline
     acceptance: **random search never does worse than a single bootstrap, and on this fixture
     does at least as well.**

   - A determinism test **`"bootstrapRandomSearch is reproducible"`**: run it twice and assert
     the two compiled programs produce identical scores (the LCG seeding makes the search
     deterministic).

**Commands (from `/Users/shinzui/Keikaku/bokuno/shikumi`):**

```bash
nix develop .#ghc9124
cabal build shikumi-optimize
cabal test shikumi-optimize
```

**Acceptance for M2.** `cabal test shikumi-optimize` is green and includes the `RandomSearch`
group. `rsScore >= singleScore` holds on the fixture, and the search is reproducible.
Expected (abridged):

```text
RandomSearch
  bootstrapRandomSearch held-out score >= single bootstrap: OK
  bootstrapRandomSearch is reproducible: OK
```

**Commit (M2).**

```text
feat(shikumi-optimize): add bootstrapRandomSearch over V1 bootstrap seeds

MasterPlan: docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md
ExecPlan: docs/plans/23-knn-few-shot-and-bootstrap-random-search.md
Intention: intention_01ktq80q01emxtjfxzd3rw4tjs
```


### Milestone M3 — Held-out-lift acceptance and serialization round-trip

**Scope.** Tie both optimizers to the master plan's acceptance ("demonstrably lifting a fixture
program's held-out score offline") and prove the compiled outputs round-trip through V1's
serialization (`encodeCompiled` / `decodeCompiledOnto`, dossier F.3). The subtlety this
milestone resolves and documents: **how the run-time `Embed`-based KNN program serializes.** At
the end of M3, the reader can save and reload both compiled programs and observe that the
behaviour survives the round-trip (for the centroid/baked forms, the demos persist; for the
run-time `Embed` form, the serialization is the empty-`Params` vector and the *template* —
exactly like `react` — and the round-trip is shown to preserve behaviour because the template
is reconstructed in code).

**The serialization facts (verbatim from the dossier, section F.3):**

```haskell
encodeCompiled :: CompiledProgram i o -> ByteString
  -- JSON array of Params, in foldParams order
decodeCompiledOnto :: Program i o -> ByteString -> Either String (CompiledProgram i o)
  -- Applies saved [Params] back onto the template; Left on malformed JSON or node-count mismatch
```

And from the parameter-traversal facts (dossier A.5): `foldParams` visits **`Predict` nodes
only**; `Embed` nodes carry no `Params`. Therefore:

- **Centroid fallback (`knnFewShotCentroid`) and `bootstrapRandomSearch` outputs** are ordinary
  programs whose `Predict` nodes hold baked demos. `encodeCompiled` writes those demos;
  `decodeCompiledOnto template bytes` reapplies them onto a structurally identical template.
  Standard round-trip — the same one the existing optimizers' outputs use.

- **Run-time KNN output (`knnFewShot` / `knnDemos`)** is a *single `Embed` node*. It has **zero**
  `Predict` nodes at the top level (the student `Predict` is captured *inside* the `Embed`
  closure, invisible to the traversal). So `foldParams` returns `[]`, `encodeCompiled` writes
  `[]` (the empty JSON array), and `decodeCompiledOnto template "[]"` succeeds iff the template
  is also a zero-`Predict`-node program (an `Embed` node). This is **exactly how `react`
  serializes** (dossier H.4: "the agent loop is one `Embed` node … it carries no `Params`, like
  `FMap`"). The *template* — the `Embed` node with its embedder, `k`, trainset, and student
  closed over — is reconstructed in code (you call `knnDemos embedder k train student` again to
  rebuild it), and `decodeCompiledOnto` applies the empty parameter vector onto it. The
  embedder, the neighbour logic, and the demos-per-input behaviour live in the closure, not in
  serialized `Params`; they are restored by reconstructing the template, not by decoding bytes.
  This is the honest, documented consequence of choosing the faithful run-time form, and it
  matches V1's established stance for closure-carrying nodes (dossier J.4: "Program structure
  cannot be serialized; optimized programs are saved as `[Params]` + a structural template held
  in code").

**Files to edit:**

1. **Edit** `shikumi-optimize/test/KNNSpec.hs`: add a test
   **`"knnDemos compiled output round-trips (empty Params, like react)"`** that takes
   `compiled = freezeProgram (knnDemos embedder k train student)`, computes `bytes =
   encodeCompiled compiled`, asserts `bytes` decodes to the empty `Params` array (i.e. the
   program has no top-level `Predict` nodes), and asserts `decodeCompiledOnto (knnDemos embedder
   k train student) bytes` is `Right` and that the reloaded program, run under the stub LM on a
   geography and an arithmetic input, still selects the input-nearest demos (re-run the
   `nearestDemos` assertion, or run end-to-end and compare answers). Add a parallel test for
   `knnFewShotCentroid` asserting its baked `Params` (the centroid-nearest demos) survive
   `encodeCompiled` → `decodeCompiledOnto` onto the bare student template.

2. **Edit** `shikumi-optimize/test/RandomSearchSpec.hs`: add a test
   **`"bootstrapRandomSearch compiled output round-trips"`** that encodes the best compiled
   program, decodes it onto the bare student template, and asserts the reloaded program scores
   identically to the original on the held-out set (proving the baked demos persisted).

3. **Edit** the master plan `docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md`:
   flip EP-23's registry row status (to In Progress while working, Complete at the end) and
   check the EP-23 progress bullet ("EP-23: KNNFewShot (embedding-similarity demos) +
   BootstrapFewShotWithRandomSearch").

**Commands (from `/Users/shinzui/Keikaku/bokuno/shikumi`):**

```bash
nix develop .#ghc9124
cabal test shikumi-optimize
cabal test all
```

**Acceptance for M3.** `cabal test shikumi-optimize` and `cabal test all` are green. The
round-trip tests pass: the baked-demo outputs (`knnFewShotCentroid`, `bootstrapRandomSearch`)
reload with their demos intact and score identically; the run-time `Embed` KNN output encodes
to the empty `Params` array and reloads onto a reconstructed template with its per-input
selection behaviour preserved. Combined with M1's "demos are the input-nearest examples" and
M2's "best-of-N `>=` single bootstrap", the plan's headline behaviours are all demonstrated
hermetically. Expected (abridged):

```text
KNN
  knnDemos compiled output round-trips (empty Params, like react): OK
  knnFewShotCentroid baked demos round-trip: OK
RandomSearch
  bootstrapRandomSearch compiled output round-trips: OK
```

**Commit (M3).**

```text
test(shikumi-optimize): held-out lift + serialization round-trip for KNN and random search

MasterPlan: docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md
ExecPlan: docs/plans/23-knn-few-shot-and-bootstrap-random-search.md
Intention: intention_01ktq80q01emxtjfxzd3rw4tjs
```


## Concrete Steps

The exact command sequence, in order, with working directories. Update this section as work
proceeds (record actual output under the milestone where it was produced).

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124        # GHC 9.12.4 dev shell — the system ghc 9.10.3 is wrong

# --- M1: KNN demo selection ---
# create shikumi-optimize/src/Shikumi/Optimize/KNN.hs
# edit  shikumi-optimize/src/Shikumi/Optimize.hs (re-export)
# edit  shikumi-optimize/shikumi-optimize.cabal  (exposed-modules + vector dep + test other-modules)
# create shikumi-optimize/test/KNNSpec.hs ; aggregate it in the suite's Main
cabal build shikumi-optimize
cabal test shikumi-optimize  # KNN group green
fourmolu --mode inplace $(git ls-files '*.hs')
git add -A && git commit     # M1 message + trailers (see M1)

# --- M2: bootstrap random search ---
# create shikumi-optimize/src/Shikumi/Optimize/RandomSearch.hs
# edit  shikumi-optimize/src/Shikumi/Optimize.hs (re-export)
# edit  shikumi-optimize/shikumi-optimize.cabal  (exposed-modules + test other-modules)
# create shikumi-optimize/test/RandomSearchSpec.hs ; aggregate it
cabal build shikumi-optimize
cabal test shikumi-optimize  # RandomSearch group green
fourmolu --mode inplace $(git ls-files '*.hs')
git add -A && git commit     # M2 message + trailers

# --- M3: acceptance + serialization round-trip ---
# extend KNNSpec.hs and RandomSearchSpec.hs with the round-trip tests
cabal test shikumi-optimize
cabal test all               # whole suite stays green
fourmolu --mode inplace $(git ls-files '*.hs')
git add -A && git commit     # M3 message + trailers
# edit docs/masterplans/3-...md registry row + progress bullet ; commit
```


## Validation and Acceptance

The plan is accepted when all of the following hold, phrased as observable behaviour:

1. **KNN selects input-nearest demos (M1).** In `cabal test shikumi-optimize`, the `KNN` group
   passes: under a deterministic stub embedder with a known 2-D geometry, `nearestDemos`
   returns exactly the training examples nearest the query (geography query → the geography
   examples; arithmetic query → the arithmetic examples), in nearest-first order; and
   `knnFewShotCentroid` bakes the centroid-nearest examples as the node's `Params`. This proves
   embedding-similarity demo selection works and is deterministic.

2. **Random search never loses to a single bootstrap (M2).** In the same test run, the
   `RandomSearch` group passes: on a fixture where demos measurably help (a stub LM that answers
   right only when a relevant demo is in the prompt), the best-of-N held-out score from
   `bootstrapRandomSearch` is `>=` a single `bootstrapFewShot` run's on the same held-out set,
   and the search is reproducible across runs.

3. **Both compiled outputs round-trip through V1 serialization (M3).** The baked-demo outputs
   (`knnFewShotCentroid`, `bootstrapRandomSearch`) encode with `encodeCompiled`, reload with
   `decodeCompiledOnto` onto a bare student template, and score identically; the run-time
   `Embed`-based `knnDemos` output encodes to the empty `Params` array and reloads onto a
   reconstructed template, with its per-input demo-selection behaviour preserved — documented as
   the same serialization stance V1's `react` uses.

4. **The whole suite stays green (`cabal test all`).** The change is purely additive: two new
   modules re-exported from `Shikumi.Optimize`, two new test modules, no change to any existing
   optimizer, type, or serialization surface — every optimizer remains an `Optimizer i o`
   invoked via `optimize`, returning a `CompiledProgram i o`.

Success is the passing assertions above, not mere compilation: the KNN demo-choice assertion
and the random-search inequality are the behaviours a human verifies.


## Idempotence and Recovery

All steps are additive and safe to repeat. Re-running `cabal build` / `cabal test` is
idempotent. Creating the two new modules and two new test modules is a one-time additive change;
if a build fails partway (for example a missing `build-depends` or an unregistered test
`other-modules`), fix the cabal stanza and rebuild — nothing is destructive and there is no
migration or data change anywhere in this plan. The re-exports in `Shikumi.Optimize.hs` are
additive; if a name clashes with an existing re-export, qualify or rename in the new module
(the new names — `knnFewShot`, `knnDemos`, `knnFewShotCentroid`, `bootstrapRandomSearch`,
`bootstrapRandomSearchWith`, `RandomSearchConfig` — do not collide with any existing optimizer
name in the package).

If the run-time-vs-compile-time decision is ever revisited, the two forms are independent: you
can ship only the centroid fallback by not exporting `knnFewShot`/`knnDemos`, or vice versa,
without touching `bootstrapRandomSearch`. The serialization round-trip tests document exactly
what each form persists, so a future contributor can choose safely.

This plan **hard-depends on EP-15** (`docs/plans/15-embedding-backend-over-baikai.md`): it
consumes the `Embedding` substrate that EP-15 makes real. Because this plan injects a *pure*
`Text -> Vector Double` embedder (the shape of EP-15's `runEmbedding` argument) rather than the
`Embedding` effect, M1's hermetic tests can be written and pass against a stub embedder *before*
EP-15's live OpenAI backend lands — but the plan's headline *live* behaviour (real semantic
neighbours from a real embedding model) needs EP-15 Complete, exactly as the master plan's
cross-MasterPlan dependency note prescribes. Record under Surprises during implementation how a
*live* embedder closure is obtained from EP-15's effectful interpreter (e.g. precompute the
trainset table once through `runEmbeddingWith`, then close over a synchronous wrapper for the
per-input query embed), since the run-time node needs a pure function and EP-15's interpreter is
effectful.


## Interfaces and Dependencies

**Libraries and modules used, and why.**

- `Shikumi.Program` (`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Program.hs`):
  `embed`/`Embed` (the run-time KNN node), `runProgram` (run the student under selected demos),
  `Program`, `Demo (..)`, `Params (..)`, `mapParams`, `foldParams`. The `Embed` body's fixed
  `(LLM, Error ShikumiError)` row is the constraint that forces the pure-embedder design.
- `Shikumi.Adapter` (`ToPrompt`, `toPrompt`): renders a structured input to the `Text` that is
  embedded — mirroring DSPy's "join the input fields" before vectorizing.
- `Shikumi.Optimize.Search`: `selectBest`, `scoreOn`, `freezeProgram` — the shared search
  plumbing `bootstrapRandomSearch` reuses.
- `Shikumi.Optimize.Bootstrap`: `bootstrapFewShot`, `bootstrapFewShotWith`, `BootstrapConfig
  (..)`, `defaultBootstrapConfig` — V1 bootstrap, wrapped (not re-implemented) by random search.
- `Shikumi.Optimize.LabeledFewShot`: `withDemos` — attaches a demo set to every node (used by
  the KNN run-time body and the centroid fallback).
- `Shikumi.Optimize.Types`: `Optimizer (..)`, `Budget (..)`, `defaultBudget`, `Scored (..)`,
  `candidate`.
- `Shikumi.Compile.Types`: `CompiledProgram (..)` (and `compiledProgram` to unwrap).
- `Shikumi.Compile.Serialize` (M3 tests): `encodeCompiled`, `decodeCompiledOnto`.
- `Shikumi.Eval`: `Dataset`, `Example (..)`, `dataset`, `datasetExamples`, `Metric`,
  `exactMatch` (the pure metric the random-search test scores with).
- `Shikumi.Eval.Metric` (`Embedding` effect) and `Shikumi.Eval.Embedding`
  (`runEmbedding`/`runEmbeddingWith` from EP-15): the embeddings substrate this plan consumes.
  Note the production code injects a pure `Text -> Vector Double`; the effect interpreters are
  used by the *caller* to build that closure, not inside the optimizer.
- `Data.Vector` (`vector`): `Vector Double` and the cosine/centroid arithmetic.
- `Data.Aeson` (`aeson`): `toJSON` to build JSON `Demo`s.

**Signatures that must exist at the end of each milestone** (full module paths):

- End of M1, in `Shikumi.Optimize.KNN`:
  ```haskell
  knnFewShot         :: (ToJSON i, ToJSON o, ToPrompt i) => (Text -> Vector Double) -> Int -> Optimizer i o
  knnDemos           :: (ToJSON i, ToJSON o, ToPrompt i) => (Text -> Vector Double) -> Int -> Dataset i o -> Program i o -> Program i o
  knnFewShotCentroid :: (ToJSON i, ToJSON o, ToPrompt i) => (Text -> Vector Double) -> Int -> Optimizer i o
  cosine             :: Vector Double -> Vector Double -> Double
  nearestDemos       :: (ToJSON i, ToJSON o, ToPrompt i) => (Text -> Vector Double) -> Int -> [Example i o] -> Text -> [Demo]
  centroid           :: [Vector Double] -> Vector Double
  ```
  re-exported from `Shikumi.Optimize`.

- End of M2, in `Shikumi.Optimize.RandomSearch`:
  ```haskell
  bootstrapRandomSearch     :: (ToJSON i, ToJSON o) => Program i o -> Int -> Budget -> Optimizer i o
  bootstrapRandomSearchWith :: (ToJSON i, ToJSON o) => RandomSearchConfig -> Program i o -> Int -> Budget -> Optimizer i o
  data RandomSearchConfig = RandomSearchConfig { minDemos :: !Int, maxDemos :: !Int, passThreshold :: !Double }
  defaultRandomSearchConfig :: RandomSearchConfig
  ```
  re-exported from `Shikumi.Optimize`.

- End of M3: no new signatures — the existing `encodeCompiled` / `decodeCompiledOnto`
  (`Shikumi.Compile.Serialize`) are exercised by the new round-trip tests, and the master-plan
  registry/progress is updated.

**The unchanged V1 contract this plan honours.** Both optimizers are V1's `Optimizer i o`,
invoked through V1's `optimize`, returning V1's `CompiledProgram i o`, persisted with V1's
`encodeCompiled` / `decodeCompiledOnto`. No parallel optimizer type, no parallel serialization
surface, no widening of any effect row (in particular `Embedding` is never added to the
optimizer or `runProgram` row — the embedder enters as a pure injected closure). This is exactly
integration point #4 of the parent master plan
(`docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md`).
