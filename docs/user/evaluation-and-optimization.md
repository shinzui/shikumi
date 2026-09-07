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
data    Prediction o   -- primary result + non-empty samples + optional raw detail JSON

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
dataset order), scores each, and aggregates. If `numSamples > 1`, it runs the program that
many times for each example and builds a `Prediction` whose primary output is the first sample
and whose `samples` field contains every run. Notice the effect row names *exactly* what
evaluation does — and carries **no `IOE`**: `Concurrent` (parallel examples and optional
timeouts), `Time` (per-example latency via the monotonic clock), `Prim` (the usage/cost counters
accumulated across examples), and `LLM`/`Error` (running the program). This is the
effects-as-constraints design from [Effects & the runtime](./effects-and-runtime.md) made
concrete.

### Failures don't abort the run

```haskell
data FailurePolicy = FailScore Score | FailAbort

data EvalConfig = EvalConfig
  { concurrency      :: Int
  , failurePolicy    :: FailurePolicy
  , exampleTimeoutMs :: Maybe Int
  , numSamples       :: Int
  }

defaultEvalConfig  -- 4-way concurrency, no timeout, score failures as 0, 1 sample per example
```

A per-example error boundary catches a `ShikumiError` from the program (→ `ProgramError`) or a
metric error (→ `MetricError`); the `FailurePolicy` decides whether a failing example scores
zero (the default) or aborts. If `exampleTimeoutMs = Just n`, a timed-out example becomes
`TimedOut` under `FailScore`, or throws `Timeout "evaluate: example timed out"` under
`FailAbort`. **A failing example scoring zero rather than aborting is what lets an optimizer
score many candidates and measure robustness.**

### The report

```haskell
data Report   -- aggregateScore, passCount, failCount, total, per-example results, usage, latency
renderReportText :: Report -> Text     -- deterministic, 4-decimal, CLI/golden-stable
```

`aggregateScore` is the arithmetic mean (0 if empty). `passCount` counts only examples whose
score is exactly `1.0`, so partial-credit metrics should read quality from `aggregateScore`.
`failCount` counts examples with a `FailureReason`. Usage totals are accumulated by interposing
on `LLM` calls and summing response usage/cost, including terminal streaming events. The
reported latency is the **sum of per-example latencies**; under concurrent evaluation it can be
greater than wall-clock elapsed time. `renderReportText` is stable enough to diff in golden
tests.

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
encodeCompiled     :: CompiledProgram i o -> ByteString          -- shape + ordered Params as JSON
decodeCompiledOnto :: Program i o -> ByteString -> Either String (CompiledProgram i o)
```

This saves/loads **parameter state plus a structural fingerprint**: the JSON envelope carries
`programShape` and the `[Params]` in `foldParams` order. `decodeCompiledOnto` re-applies that
state onto a template you reconstruct in code and rejects a shape mismatch or node-count mismatch
as `Left`, never silent corruption. For structural compilers such as `chainOfThoughtCompiler`,
decode onto the same compiled shape, not the plain base program.

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
exceeded, never silently producing an unscored program. Every optimizer is an `Optimizer i o`,
invoked through the one `optimize` entry point, and returns V1's `CompiledProgram i o` — so they
all serialize and reload through the same `encodeCompiled`/`decodeCompiledOnto`. They group into
four families.

**Demo selection** — choose which few-shot examples each node shows:

| Optimizer | Strategy |
|---|---|
| `labeledFewShot k` | Select the best size-`k` set of labeled demos from the training set. Candidate sets enumerated deterministically; no LM calls beyond scoring. |
| `bootstrapFewShot teacher budget` | Run a teacher program over the training set, keep the runs the metric judged correct, recover each accepted predictor invocation as demos for the matching student node. Tunable via `BootstrapConfig { passThreshold, maxBootstrappedDemos }` (default: only exactly-correct runs, ≤4 demos). |
| `bootstrapRandomSearch teacher n budget` | Run `bootstrapFewShot` over `n` deterministic seeds (each shuffling the trainset and picking a random demo count) plus a zero-shot baseline, score each, keep the best. Best-of-N is a cheap, robust win over a single bootstrap run; reproducible via a seeded LCG. |
| `knnFewShot embedder k` | *Per input at run time*, attach the `k` training examples whose inputs are most semantically similar (cosine over an injected `Text -> Vector Double` embedder) as that call's demos — a geography question gets geography demos, an arithmetic one arithmetic demos, from one artifact. `knnFewShotCentroid` is a compile-time fallback that bakes the centroid-nearest demos once. |

**Instruction search** — rewrite each node's instruction string:

| Optimizer | Strategy |
|---|---|
| `instructionSearch n budget` | Greedy coordinate ascent: a *grounded proposer* suggests `n` instructions per node; keep the best, holding others fixed. The current instruction is always a candidate, so a node never gets worse. |
| `copro defaultCoproConfig` | COPRO — coordinate-ascent prompt optimization over several *rounds* (depth) of several candidates (breadth), feeding the scored attempt history forward so later rounds learn from what worked. The principled generalization of `instructionSearch`. |

**Joint search** — instructions *and* demos together:

| Optimizer | Strategy |
|---|---|
| `miprov2 Miprov2Light` | MIPROv2 — searches the *joint* per-node `(instruction × demoset)` grid (which `instructionSearch`'s single-axis greed cannot), screening candidates on cheap minibatches and confirming the best with a full evaluation. Light/Medium/Heavy presets, or `miprov2With` for an explicit `Miprov2Config`. |

**Reflective evolution** — improve by critique:

| Optimizer | Strategy |
|---|---|
| `gepa proposer feedbackMetric budget` | GEPA — captures a labeled whole-program critique (`FeedbackMetric o = o -> Prediction o -> (Score, Text)`), reflects using executed node evidence to propose a rewritten instruction, and keeps a **Pareto frontier** of candidates non-dominated across the per-example score vector. `reflectiveProposer` is the shipped default proposer. |

**Ensembling** — combine variants:

| Optimizer | Strategy |
|---|---|
| `ensembleSearch n inner` | Run an inner optimizer over `n` deterministic bootstrap resamples, then combine the candidates into one program via the `ensemble` combinator under a majority-vote reducer. |

The instruction-rewriting optimizers (`instructionSearch`, `copro`, `miprov2`) draw their
candidates from one shared **grounded proposer** (`Shikumi.Optimize.Propose`): the proposing LM
is fed a dataset summary, a pseudo-code summary of the program, each node's real input/output
field names, bootstrapped demos, the instruction history with scores, and a stylistic tip — each
signal-gatherer itself a typed `Program`, so "the optimizer is written in the framework it
optimizes." MIPROv2's joint search and GEPA's per-node reflection make MIPROv2 and GEPA the
heaviest, highest-ceiling optimizers; `labeledFewShot`/`bootstrapFewShot` are the cheapest.

```haskell
optimized <- optimize (bootstrapFewShot classify defaultBudget) trainset exactMatch classify
tuned     <- optimize (miprov2 Miprov2Light)        trainset exactMatch classify  -- joint search

-- save the tuned state, reload it onto the structural template:
BL.writeFile "classify.json" (encodeCompiled optimized)
-- decodeCompiledOnto classify <$> BL.readFile "classify.json"
```

### Bootstrap heterogeneous pipelines

Use `predictCaptured` for every predictor in a composite teacher and student.
It adds `ToJSON` and `ToSchema` requirements for both input and output, retaining
explicit wire encoders in the program template. Ordinary `predict` is unchanged;
a bare single predictor still supports the legacy outer input/output bootstrap.

For example, with record types `Question {question}`, `City {city}`, and
`Country {country}` and their JSON/schema/prompt instances:

```haskell
cityStage :: Program Question City
cityStage = predictCaptured (mkSignature "Extract the city from the question")

countryStage :: Program City Country
countryStage = predictCaptured (mkSignature "Resolve the city's country")

cityCountry :: Program Question Country
cityCountry = pipeline cityStage countryStage

-- The first recovered demo is Question -> City; the second is City -> Country.
optimized <- optimize (bootstrapFewShot cityCountry defaultBudget)
  trainset exactMatch cityCountry
```

`bootstrapNodeDemos` returns `(Map NodePath [Demo], BootstrapReport)` under a
shared budget meter. `withNodeDemos` installs these pools. Matching defaults to
equal program structure, structural paths, and input/output schema evidence.
For a differently structured teacher, set `nodeMapping` in
`defaultNodeBootstrapConfig` to explicit `(teacherPath, studentPath)` pairs.
Unknown paths and incompatible schemas fail before model calls. Multiple teacher
paths may feed one target only with `mergeTargetMappings = True`. Unmapped targets
receive an empty recovered pool. Each captured value must also decode using the
target predictor's `FromModel` instances; rejected custom encodings are reported
and never installed. `bootstrapDemosFor` supplies the legacy single-node adapter
when outer JSON instances are available.

`nodeBootstrapConfig` retains the existing threshold and per-node cap settings.
With no `nodeSeed`, recovery keeps the first accepted invocations until all mapped
nodes are full. With `nodeSeed = Just seed`, it collects within the available
budget and independently shuffles each target's pool using its stable path before
capping it. Equal seeds reproduce selection; different nodes can receive different
subsets. RandomSearch and MIPRO consume these node pools. MIPRO uses outer labeled
examples only for a bare single predictor.

Failed teacher examples and invocations from rejected retry/validation attempts
contribute no demonstrations. `runProgramObserved` retains their evidence for
inspection, using fresh storage per example. `Embed` is opaque: its execution
boundary can be reported, but hidden predictors cannot supply node demos.
Composite programs with uncaptured leaves fail with an actionable error.
`bootstrapKeptDemos` is restricted to the documented single-node outer-demo case.

Saved parameter formats are unchanged. Restore onto the capture-capable code
template to retain codecs. Public `Program` pattern matches must now also handle
`PredictCaptured`; compiler rewrites that change leaf types must adapt the codec.

> The CLI's `optimize` subcommand currently exposes `labeled-fewshot` and `bootstrap-fewshot`;
> the modern optimizers above are library-level (call `optimize` directly). The run-time
> `knnFewShot`/`knnDemos` form is a single `Embed` node, so — like a ReAct agent — it carries no
> `Params` and serializes as the empty vector; its per-input behaviour lives in the reconstructed
> template, not in saved bytes. See
> [Programs & combinators → Reward-driven self-refinement](./programs-and-combinators.md#reward-driven-self-refinement)
> for the inference-time modules (`bestOfN` / `refine` / `multiChainComparison`) that share this
> reward/critique vocabulary.

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

### Failure-aware GEPA feedback

For explicit node attribution, import `Shikumi.Optimize.Feedback` and use
`gepaWithFeedback config reflectiveProposer callback budget`. A `FeedbackCallback`
receives the expected output and `EvaluationEvidence`: the zero-based example index,
original `Either ShikumiError o`, ordered node observations, and provider-reported
execution token/cost totals. It can call a critic through the optimizer effect row.

For a two-predictor composition, a callback can target only its second predictor:

```haskell
import Shikumi.Optimize.Feedback
import Shikumi.Optimize.GEPA
import Shikumi.Trace.Node

-- The application supplies scoreAndCritique from its domain checks or critic LM.
callback = FeedbackCallback $ \expected evidence -> do
  (score, critiqueText) <- scoreAndCritique expected evidence
  pure FeedbackResult
    { overallScore = score
    , programCritique = Nothing
    , nodeCritiques =
        [ NodeFeedback (exampleIndex evidence) (NodePath [StepComposeR])
            Nothing critiqueText Caller
        ]
    }
```

Return no node critique when its target was not executed. Targets are checked
against actual observations and program paths; `Just ordinal` restricts a critique
to one invocation, while `Nothing` covers that node's invocations in the example.
Use `Model` provenance for model-generated critiques. Neither provenance asserts
human approval. A program-level critique is a separate optional `(Provenance, Text)`.
`LegacyProgram` is reserved for program attribution.

`captureEvidence config dataset callback program` returns one ordered
`(EvaluationEvidence, FeedbackResult, Maybe FailureReason)` per input. Output
failures default to score zero, retaining their original errors and positions.
Set `failureClassification = candidateFailurePolicy yourScore` to change that score,
or `const FailAbort` to abort with the original error. Provider failures and timeouts
abort by default; a caller may classify them explicitly. `BudgetExceeded` and host
cancellation always escape. Critic failures are labeled `MetricError`, distinct from
program failures. Ordinary `evaluateWith` retains its existing policies.

Reflection chooses deterministically among executed nodes with relevant critiques.
It sends local input/output fields (or structured values when codecs exist), error
status, invocation identity, retry rejection lineage, and only matching node
critiques. Failures and rejected attempts are prioritized. `includeProgramCritique`
adds a separately labeled program field; it defaults to false and the legacy `gepa`
wrapper enables it. `captureFeedback` remains available, projecting legacy program
critique once to the root log key with a `program (LegacyProgram)` label.

`critiqueCharacters` bounds each critique; `reflectionExamples` bounds invocation
samples, including retries; `reflectionCharacters` bounds the rendered feedback
and each other reflection field. Defaults are 2000, 4, and 8000. Negative bounds
fail before execution, zero critique allowance emits no critique, and zero reflection
allowance skips mutation. Truncation is marked within the character allowance.
`redactEvidence` transforms every reflection field before its final truncation and
before the proposer runs. Raw returned observations are not redacted.

Capture is sequential, Embed interiors stay opaque, and no JSON codec is required.
Search still uses the supplied optimization metric for candidate selection. Existing
budget reservations estimate student/proposer calls; arbitrary critic calls and retry
expansion are not yet strictly metered. Split-aware search, lifecycle reports, and
actual execution budgets belong to the next execution layer.

### Validated GEPA execution and objective reports

`optimizeWith controls (gepaWith config reflectiveProposer)` accepts the usual
training dataset, scalar metric, and student program. Import execution controls
from `Shikumi.Optimize.Execution`, report/objective types from
`Shikumi.Optimize.Report`, and feedback contracts from
`Shikumi.Optimize.Feedback`. It returns the compiled program and an
`OptimizationReport` whose JSON version is independent of compiled parameter state.

Build `config` with `defaultGEPAConfig (FeedbackCallback callback)`, then set
`validationDataset = Just validation`. Empty training or explicit validation is
an error. Omitting validation deliberately uses training-as-validation and labels
that mode in the report. Reflection sees only training evidence. A training
minibatch rejects proposals with no successful execution before full validation; a lower training score alone
does not disqualify a candidate that might generalize better. Validation inputs,
labels, critiques and traces never enter framework-generated reflection requests.
Caller programs and callbacks are trusted code, not sandboxed against data access.
Do not provide your protected final holdout to this optimizer.

`runLimits` contains `operationLimit`, `candidateLimit`, `evaluationConcurrency`,
and `deterministicSeed`. Zero budgets return an unscored baseline. Operation
admission is atomic before every Shikumi `Complete` or `Stream`, including retries,
proposers, critics and calls inside `Embed`; admitted failures consume their slot.
A separate exception-safe semaphore bounds active dispatches, while finite batches
bound concurrent candidate jobs. Examples within a candidate run sequentially.
`childrenPerGeneration` defaults to one; larger generations propose from one
frontier snapshot before concurrent evaluation, changing the adaptive search path.
Candidate IDs and report/frontier folds follow scheduling order. Concurrent model
responses and the race for the final operation slot are not reproducible merely
because the seed is fixed.

Each `ObjectiveSpec` declares its ID, unit, direction, aggregation (`Mean`, `Total`,
or `Worst`), missing-value policy (`Required` or a finite `Substitute`), and optional
bounds. `ObjectiveCallback` receives expected output plus `ExampleMeasurement`:
typed execution evidence, isolated execution-operation counts, provider usage, and
monotonic latency in seconds. The default adapts the scalar metric to `quality`.
Raw cost and latency values need not fit `Score`; declare a lower bound of zero
for nonnegative resources. Non-finite or required-missing values fail a candidate.
Bounds exclude candidates before Pareto selection. The primary objective, ordered
tie objectives, then creation order select one member of the non-dominated frontier.
Only candidates with every required validation position can win.

The session retains ordered candidate outcomes, admitted operations, separately
estimated work, objective values, frontier and selection reason. A budget stop
keeps the best completed eligible program; without one, it returns the student
explicitly unscored (`resultStatus = Just Unscored`). Opaque legacy results use
`resultStatus = Nothing` because their scoring state is unknown. Scored output
failures retain their scalar failure policy.
Typed infrastructure errors propagate; `runSearchSession` is the lower-level API
returning the original typed error alongside diagnostics for custom strategies.
`reserveCandidate`, `evaluateCandidate`, and `evaluateCandidates` are independent
of GEPA and accept evidence-preserving runners and metric callbacks.

`eventSink` receives metadata only: ordered `RunStarted`, `CandidateStarted`,
`CandidateEnded` with completed/failed/incomplete status, `BudgetStop`, and terminal
`RunFinished` records. Synchronous observer exceptions increment `observerFailures`
and do not change scores; cancellation propagates with cleanup bookkeeping.
Observers must avoid indefinitely blocking. `fromLegacyOptimizer` provides run-level
accounting and events for opaque strategies, explicitly marking candidate detail
unavailable. Existing `optimize` remains supported, and `gepa` retains its predicted
seed gate while using the configured execution core.

Run the fully offline demonstration:

```bash
nix develop .#ghc9124 -c cabal run shikumi-jitsurei:exe:jitsurei-gepa-objectives
```

It prints validation-selected candidate B, its objective frontier, actual operations
versus the cap, and termination status. The fixture's cost values are declared work
units. Operation limits do not count provider-internal transport retries separately
and are neither dollar limits nor sealed production-promotion evidence.
