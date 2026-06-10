# Evaluation & optimization — under the covers

This is the payoff of the GADT deep embedding: because a `Program` is *data*, you can score it
against labeled examples, compile a prompting strategy into it, and let an optimizer **rewrite
its parameters** — then serialize the tuned result. This guide covers `shikumi-eval`,
`shikumi-compile`, and `shikumi-optimize`.

---

## Evaluation (`shikumi-eval`)

### The typed data model

Everything is typed by `i`/`o`, not the untyped bags DSPy uses.

```haskell
newtype Score          -- a Double clamped to [0,1]
data    Example i o    -- a labeled datum: input + expected output
data    Dataset i o    -- a list of examples
data    Prediction o   -- a program output: a primary result + a non-empty set of samples

example       :: i -> o -> Example i o
dataset       :: [Example i o] -> Dataset i o
mkScore       :: Double -> Score          -- clamps
boolScore     :: Bool -> Score            -- True → 1, False → 0
exactMatch    :: Eq o => Metric o
```

### Metrics

```haskell
type Metric  o    = o -> Prediction o -> Score              -- pure, deterministic, offline
type MetricM es o = o -> Prediction o -> Eff es Score        -- effectful (may call a model)
```

A `Metric o` scores a prediction against the expected output. Built-ins and combinators:

| Function | What it does |
|---|---|
| `exactMatch` | equality of expected vs. the primary output |
| `normalizedStringSimilarity (o -> Text)` | token-set + edit-distance blend |
| `customMetric f` | wrap any `o -> Prediction o -> Score` |
| `weightedMean [(w, m)]` | weighted average of metrics |
| `threshold t m` | convert a metric to pass/fail at `t` |
| `invert m` | `1 - score` |
| `liftMetric` | embed a pure metric as a `MetricM` |

LM-backed metrics live behind their own effects: `semanticSimilarity` (cosine over an
`Embedding` effect) and `modelJudge instruction (o -> Text)` (LLM-as-judge, needs `LLM` +
`Error`). The `Embedding` effect has two kinds of interpreter:

```haskell
-- Pure (deterministic; good for tests): supply a Text -> Vector Double table.
runEmbedding     :: (Text -> Vector Double) -> Eff (Embedding : es) a -> Eff es a

-- Real backend (Shikumi.Eval.Embedding): an OpenAI-compatible /v1/embeddings endpoint.
runEmbeddingLLM  :: (IOE :> es, Error ShikumiError :> es) => Eff (Embedding : es) a -> Eff es a
runEmbeddingWith :: (IOE :> es, Error ShikumiError :> es) => EmbeddingModel -> Eff (Embedding : es) a -> Eff es a
```

`runEmbeddingLLM` defaults to OpenAI's `text-embedding-3-small`; `runEmbeddingWith` takes an
explicit `Baikai.Embedding.EmbeddingModel` (a bare model-id string + base URL + key source, no
chat-catalog entry). So `semanticSimilarity` runs end-to-end against a real provider — two
meaning-close strings score higher than two distant ones — while a pure `runEmbedding` table
keeps unit tests hermetic. A transport failure surfaces as a typed `ProviderFailure`.

### Running an evaluation

```haskell
evaluate     :: (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es)
             => Dataset i o -> MetricM es o -> Program i o -> Eff es Report
evaluatePure :: (…same…) => Dataset i o -> Metric o -> Program i o -> Eff es Report
evaluateWith :: (…same…) => EvalConfig -> Dataset i o -> MetricM es o -> Program i o -> Eff es Report
```

The runner executes the program over every example with **bounded concurrency** (preserving
dataset order), scores each, and aggregates. Notice the effect row names *exactly* what
evaluation does — and carries **no `IOE`**: `Concurrent` (parallel examples), `Time`
(per-example latency via the monotonic clock), `Prim` (the usage/cost counters accumulated
across examples), and `LLM`/`Error` (running the program). This is the effects-as-constraints
design from [Effects & the runtime](./effects-and-runtime.md) made concrete.

### Failures don't abort the run

```haskell
data FailurePolicy = FailScore Score | FailAbort
defaultEvalConfig  -- 4-way concurrency, score failures as 0, 1 sample per example
```

A per-example error boundary catches a `ShikumiError` from the program (→ `ProgramError`) or a
metric error (→ `MetricError`); the `FailurePolicy` decides whether a failing example scores
zero (the default) or aborts. **A failing example scoring zero rather than aborting is what
lets an optimizer score many candidates and measure robustness.**

### The report

```haskell
data Report   -- aggregateScore, passCount, failCount, total, per-example results, usage, latency
renderReportText :: Report -> Text     -- deterministic, 4-decimal, CLI/golden-stable
```

`aggregateScore` is the arithmetic mean (0 if empty). `renderReportText` is stable enough to
diff in golden tests.

### Golden helpers

`goldenProgram` and `goldenReport` (in `Shikumi.Eval.Golden`) drop straight into a tasty test
tree. Each takes a rank-2 runner `forall a. Eff es a -> IO a` so *you* supply the LM (a stub or
a replay index); regenerate goldens with `--accept`.

```bash
cabal run jitsurei-evaluate     # evaluatePure over a Dataset, mixed believable report
```

---

## Compilation (`shikumi-compile`)

A **compiler** is a pure, type-agnostic rewrite of a program — it installs prompting strategy
into the nodes' parameters without running anything.

```haskell
newtype Compiler = Compiler { runCompiler :: forall i o. Program i o -> Program i o }
newtype CompiledProgram i o = CompiledProgram { compiledProgram :: Program i o }

compile     :: Compiler -> Program i o -> CompiledProgram i o          -- pure
runCompiled :: (LLM :> es, Error ShikumiError :> es) => CompiledProgram i o -> i -> Eff es o
identity    :: Compiler                                                 -- no-op (composition unit)
```

The shipped strategies:

| Compiler | Module | Effect on the program |
|---|---|---|
| `zeroShot instr` / `zeroShotClear` | `ZeroShot` | override every node's instruction (and clear demos) |
| `fewShot demos` / `fewShotTyped pairs` | `FewShot` | inject demos at every node (replace, for idempotence) |
| `chainOfThoughtCompiler` | `ChainOfThought` | structurally replace each `Predict` leaf with a CoT-augmented node |
| `rag retriever query` | `RAG` | prepend retrieved passages to every node's instruction (retrieved once at compile time) |

```haskell
let compiled = compile chainOfThoughtCompiler classify
```

Compilers reach nested nodes via `mapParams` / recursion over the GADT. Because each is a pure
`Program -> Program`, you can compose them — but mind that an existing `instructionOverride`
takes precedence, so apply CoT/RAG *before* zero-shot if you want both.

### Serialization

```haskell
encodeCompiled     :: CompiledProgram i o -> ByteString          -- ordered Params vector as JSON
decodeCompiledOnto :: Program i o -> ByteString -> Either String (CompiledProgram i o)
```

This saves/loads **parameter state only** (the `[Params]` in `foldParams` order), re-applying
it onto a structural template you reconstruct in code — exactly the
`programShape`/`setProgramParams` contract from
[Programs & combinators](./programs-and-combinators.md#programs-as-data-serialization). A node
count mismatch is a `Left`, never a silent corruption.

---

## Optimization (`shikumi-optimize`)

An **optimizer** searches for better node parameters (demos, instructions), scores candidates
by evaluation against a metric, and returns the best `CompiledProgram`.

```haskell
optimize :: (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es)
         => Optimizer i o -> Dataset i o -> Metric o -> Program i o -> Eff es (CompiledProgram i o)

newtype Optimizer i o = Optimizer { runOptimizer :: … -> Eff es (CompiledProgram i o) }

data Budget = Budget { maxLmCalls :: Int, maxCandidates :: Int }
defaultBudget = Budget { maxLmCalls = 200, maxCandidates = 32 }
```

`Budget` is a **hard, explicit** bound on search cost — optimizers stop before any bound is
exceeded, never silently producing an unscored program. The four shipped optimizers:

| Optimizer | Strategy |
|---|---|
| `labeledFewShot k` | Select the best size-`k` set of labeled demos from the training set. Candidate sets enumerated deterministically; no LM calls beyond scoring. |
| `bootstrapFewShot teacher budget` | Run a teacher program over the training set, keep the runs the metric judged correct, attach those input/output pairs as demos to the student. Tunable via `BootstrapConfig { passThreshold, maxBootstrappedDemos }` (default: only exactly-correct runs, ≤4 demos). |
| `instructionSearch n budget` | An LM *proposer* (itself an ordinary, traceable `Program`) suggests candidate instruction strings per node; greedy coordinate ascent keeps the best, holding others fixed. The current instruction is always a candidate, so a node never gets worse. |
| `ensembleSearch n inner` | Run an inner optimizer over `n` deterministic bootstrap resamples, then combine the candidates into one program via the `ensemble` combinator under a majority-vote reducer. |

```haskell
optimized <- optimize (bootstrapFewShot classify defaultBudget) trainset exactMatch classify

-- save the tuned state, reload it onto the structural template:
BL.writeFile "classify.json" (encodeCompiled optimized)
-- decodeCompiledOnto classify <$> BL.readFile "classify.json"
```

### Why this works without reflection

The optimizer's primitives are pure traversals over the GADT: `foldParams` reads each node's
parameters, `mapParamsAt n` rewrites node *n*, `scoreOn` runs `evaluate` and takes the
aggregate, and `selectBest budget scorer candidates` is a pure fold that stops at the budget.
Search is reproducible (deterministic candidate ordering and resampling) and testable (the
scorer is the only effectful part). No runtime reflection, no mutable module tree — just data.

```bash
cabal run jitsurei-optimize     # optimize, then serialize & reload
```

---

## How the layers compose

```
Dataset i o  +  Metric o
        │
        ▼
   optimize (Optimizer) ──uses──▶ evaluate ──uses──▶ runProgram (over each example)
        │                                                  │
        ▼                                                  ▼
  CompiledProgram i o  ──encodeCompiled──▶ JSON     LLM effect → resilient → Baikai → IO
        │
        └─ decodeCompiledOnto template ──▶ runCompiled ▶ typed o
```

Evaluation, compilation, and optimization all bottom out in the same `runProgram`/`LLM` stack
described in [Effects & the runtime](./effects-and-runtime.md) — which is why the CLI can run
all of them offline against the deterministic stub.
