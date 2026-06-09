---
id: 8
slug: evaluation-framework
title: "Evaluation framework"
kind: exec-plan
created_at: 2026-06-08T02:44:17Z
intention: "intention_01ktjgkp10ef79vpwz1cmajek9"
master_plan: "docs/masterplans/1-shikumi-typed-lm-programming-framework.md"
---

# Evaluation framework

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi (仕組み — "the mechanism behind how something works") is a Haskell framework for
building language-model (LM) programs as ordinary, well-typed software. A *program* in
shikumi is a value of type `Program i o`: it takes an input of Haskell record type `i`,
calls one or more language models, and returns a fully decoded output of Haskell record
type `o`. Programs are run inside an `effectful` effect stack (see the "effects" definition
below) by a function `runProgram :: (LLM :> es) => Program i o -> i -> Eff es o`, which is
delivered by a sibling plan at `docs/plans/4-typed-program-representation-and-core-modules.md`.

This plan delivers the **evaluation framework**: the ability to measure how good a program
is. After this change, a developer can write down a small **typed dataset** of example
inputs paired with their expected outputs, pick or write a **metric** that scores how close
a program's actual output is to the expected one, and call a single function `evaluate` to
run the program over every example, score each one, and receive a **report** summarising the
aggregate score, the latency, the token usage, the dollar cost, and a per-example breakdown
that shows exactly which examples passed, which failed, and why. This is the foundation on
which the optimizer (a sibling plan at `docs/plans/10-optimizer-framework.md`) later
performs its search: an optimizer is nothing more than a procedure that tries variations of
a program and keeps the variations that `evaluate` scores highest.

Concretely, after this plan a developer can do the following, and *see it work* with
`cabal test`:

1. Declare a dataset such as `myData :: Dataset Question Answer` holding a handful of
   `Example Question Answer` values, each carrying an input and the expected answer.
2. Build a program (for tests, a deterministic stub program backed by a mock LM that
   returns canned responses, so no network or API key is needed).
3. Choose a metric — for example `exactMatch` (output equals expected) or a custom metric
   written inline — and call
   `report <- evaluate myData exactMatch myProgram` inside the effect stack.
4. Inspect `report`: its `aggregateScore` field is the mean of the per-example scores, its
   `results` field lists every example with its individual score and any failure reason,
   and its `usage`/`cost`/`latencyMs` fields summarise resource consumption.

A second deliverable is **golden testing**: a helper `goldenProgram` that turns a program
plus a dataset into a `tasty` test (`tasty` is the standard Haskell test-runner library used
in this repository). A golden test pins a program's observable behaviour to a checked-in
"golden" file; the test fails if the program's behaviour changes. Combined with the trace
*replay* facility from the sibling plan at
`docs/plans/7-hierarchical-tracing-observability-and-replay.md`, golden tests run
deterministically and offline (replaying recorded model responses rather than calling a live
provider), so they are safe to run in continuous integration. The acceptance demonstration
for golden tests is a fail-before / pass-after sequence: a golden test passes, the program is
deliberately changed, the same test now fails, the golden file is regenerated, and the test
passes again.

This plan **owns** the evaluation data model — the types `Example`, `Prediction`, `Dataset`,
`Metric`, `Score`, and `Report`. These are integration point #5 in the master plan: the
optimizer plan (`docs/plans/10-optimizer-framework.md`) and the CLI plan
(`docs/plans/12-cli-and-developer-experience.md`) *consume* these types and must not
redefine them. This plan therefore takes care to define them cleanly and document them so
the consumers can rely on them.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `shikumi-eval` package scaffolded; `Shikumi.Eval.Types` defines `Score`,
      `Example`, `Prediction`, `Dataset`, plus smart constructors; builds with
      `cabal build shikumi-eval`. (2026-06-08)
- [x] M1: Unit tests for the data model and `Score` arithmetic pass under
      `cabal test shikumi-eval` (5 tests). (2026-06-08)
- [x] M2: `Shikumi.Eval.Metric` provides `Metric`/`MetricM`/`liftMetric`, `exactMatch`,
      `normalizedStringSimilarity` (token-set Jaccard + normalized Levenshtein),
      `customMetric`, and the combinators `weightedMean`/`threshold`/`invert`; pure-metric
      tests pass (16 tests total). (2026-06-08)
- [x] M3: `Shikumi.Eval.Report` defines `Report`, `ExampleResult`, `FailureReason`,
      `FailurePolicy`, `EvalConfig`/`defaultEvalConfig`, `UsageTotals` (Monoid), `mkReport`,
      and the deterministic `renderReportText`; aggregation + render are unit-tested with
      synthetic results (26 tests total). (2026-06-08)
- [x] M4: `Shikumi.Eval.Evaluate.evaluate`/`evaluatePure`/`evaluateWith` run a program over a
      dataset with bounded parallelism (`pooledForConcurrentlyN`) and per-example error
      handling; `Shikumi.Eval.Usage.withUsageTotals` accumulates usage by `interpose` on the
      `LLM` effect. `EvaluateSpec` (mock LM, no network): four-of-five exact match →
      `aggregateScore 0.8`; a program error → `FailScore scoreZero` while the run completes;
      `FailAbort` surfaces a `Left`. 29 tests total. (2026-06-08)
- [x] M5: LM-backed metrics `semanticSimilarity` (cosine over the new `Embedding` effect,
      with a pure `runEmbedding` interpreter) and `modelJudge` (LLM-as-grader running a tiny
      `JudgeInput -> Grade` predict program) are implemented and tested against mock
      interpreters (34 tests total). (2026-06-08)
- [x] M6: `Shikumi.Eval.Golden.goldenProgram`/`goldenReport` produce a `tasty` `TestTree`
      (built on `tasty-golden`'s `goldenVsString`, run under a caller-supplied rank-2 offline
      runner); the committed `shikumi-eval/test/golden/qa-program.golden` pins the transcript;
      the fail-before/pass-after demonstration is recorded below (35 tests total). (2026-06-08)
- [ ] M7: README/usage doc-comment example compiles via a doctest-style test; master-plan
      Progress row for EP-8 ticked.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: `Score` is a `newtype Score = Score Double` clamped to the closed interval
  `[0, 1]` at construction, exposed through a smart constructor `mkScore :: Double -> Score`
  that clamps out-of-range values, plus the convenience constructors `scoreZero`, `scoreOne`,
  and `boolScore :: Bool -> Score`.
  Rationale: DSPy (the Python framework shikumi ports ideas from) lets a metric return either
  a `bool` or a `float`, which forces every consumer to handle both. A single bounded
  `Double` unifies the two (a `Bool` metric maps `True -> 1`, `False -> 0`) and makes
  aggregation (mean) well-defined and comparable across metrics. Clamping at construction
  means downstream code (the optimizer) can assume `0 <= s <= 1` without re-checking. A
  *richer* record (e.g. carrying sub-scores) was rejected for the core type because it
  complicates `Ord`-based ranking in the optimizer; metrics that need structure can attach it
  via the `ExampleResult.detail :: Maybe Value` field instead. Date: 2026-06-07.
- Decision: Semantic similarity is offered in **two forms**: (a) `normalizedStringSimilarity`,
  a pure, dependency-free, offline metric based on a token-set Jaccard / normalized
  Levenshtein blend over case-folded, whitespace-collapsed text; and (b) `semanticSimilarity`,
  an embedding-based metric that requires an embedding capability and is therefore expressed
  as an `Eff`-returning metric (`MetricM`, see below).
  Rationale: the pure metric keeps the common case offline and deterministic (good for golden
  tests and CI); the embedding metric is the "real" semantic measure but unavoidably needs a
  model call, so it must live in the effectful metric variant. Date: 2026-06-07.
- Decision: There are **two metric type aliases**: a *pure* metric
  `type Metric o = o -> Prediction o -> Score` (expected output, then the program's
  prediction, yielding a score) and an *effectful* metric
  `type MetricM es o = o -> Prediction o -> Eff es Score` for metrics that must themselves
  call a model (embedding similarity, LLM-judge). A pure `Metric` lifts into `MetricM` via
  `liftMetric`. `evaluate` is defined over `MetricM` so it covers both; a convenience wrapper
  `evaluatePure` accepts a pure `Metric`.
  Rationale: forcing every metric to be effectful would pollute the type of trivial metrics
  like `exactMatch`; forcing every metric to be pure would make LLM-judge impossible. Two
  aliases with a lift is the smallest design that serves both, and keeps integration point #5
  honest (the optimizer can pass either). Date: 2026-06-07.
- Decision: Parallelism uses **bounded** concurrency via the `effectful` `Concurrent` effect
  and `Effectful.Concurrent.Async.pooledForConcurrentlyN`, with the worker count taken from
  `EvalConfig.concurrency` (default 4). Unbounded concurrency was rejected because it would
  hammer provider rate limits and blow budgets; sequential evaluation was rejected because
  datasets can be large and each example is I/O-bound on a model call.
  Rationale: `pooledForConcurrentlyN n` runs at most `n` actions at once and preserves input
  order in its result list, which is exactly the semantics we want (a bounded worker pool with
  a stable per-example ordering for the report). The dependency surfaces in `evaluate`'s
  constraint as `Concurrent :> es`. Date: 2026-06-07.
- Decision: A failing example does not abort the run. Each example is evaluated inside a
  per-example error boundary; on failure the example receives a configurable
  `FailurePolicy` outcome — by default `FailScore scoreZero` (record the failure, score it 0,
  continue). Alternatives `FailWith s` (use score `s`) and `FailAbort` (re-throw, ending the
  run) are provided.
  Rationale: in evaluation you almost always want to *measure* the failure rate rather than
  crash on the first bad example; scoring a failure as 0 makes the aggregate reflect
  robustness. `FailAbort` is retained for debugging. Date: 2026-06-07.
- Decision: `Prediction o` supports **multi-sample** completions: `Prediction o` carries a
  non-empty list of sampled outputs plus a designated primary output. This mirrors DSPy's
  `Completions` and lets majority-vote / ensemble metrics inspect all samples.
  Rationale: combinators in the sibling plan
  `docs/plans/5-module-combinators-and-control-flow.md` (`MajorityVote`, `Ensemble`) produce
  multiple candidate outputs; a metric that wants to reward agreement needs to see them. A
  single-output program simply yields a one-element `Prediction`. Date: 2026-06-07.
- Decision: Golden tests are built on `tasty-golden`'s `goldenVsString` and serialise a
  program's report (or a canonicalised transcript) to a stable textual form. Determinism is
  achieved by running `evaluate` under a *mock or replayed* LM interpreter, never a live one,
  inside the test.
  Rationale: `goldenVsString` is the smallest tasty-golden primitive that fits (golden file
  on disk vs. a produced `ByteString`); using a mock/replay interpreter removes network
  nondeterminism so the only thing that can change the golden output is a genuine change in
  program behaviour. Date: 2026-06-07.
- Decision (M4): the usage accumulator is the **local `interpose`** form, not a substrate
  hook. EP-1's `LLM` interpreters expose no usage-observing seam, but `LLM.complete` returns
  the full baikai `Response`, which already carries `Usage`/`Cost`. So
  `Shikumi.Eval.Usage.withUsageTotals` interposes on `LLM` (the same seam EP-6's `cachedLLM`
  and EP-7's `tracedLLM` use), reads usage straight off each response, and accumulates into a
  shared `IORef` with `atomicModifyIORef'` — which is safe under the bounded concurrency
  `evaluate` uses, because `pooledForConcurrentlyN` clones the env per worker but the handler
  closure still references the one ref. No local `UsageAccum` effect was needed; the public
  type of `evaluate` is unaffected and will not change if a substrate hook lands later.
  Date: 2026-06-08.
- Decision (M4): per-example latency is measured with `GHC.Clock.getMonotonicTimeNSec`
  (monotonic, `base`-only) around each example, rather than `Data.Time.Clock` wall time.
  Rationale: monotonic time is the correct primitive for elapsed-duration measurement and adds
  no dependency. Date: 2026-06-08.
- Decision (M5): `modelJudge`'s signature gains an `Error ShikumiError :> es` constraint
  beyond the plan's sketched `(LLM :> es)`, because it runs a real `JudgeInput -> Grade`
  predict program through `runProgram`, which threads `Error ShikumiError` (EP-4's finding):
  a decode failure of the grade throws a typed error that `evaluate`'s per-example boundary
  turns into a `MetricError`. The judge uses plain (unwrapped) record fields so the rendered
  prompt stays clean, and reuses EP-3's `Double` schema/decode support for the `grade` field.
  Date: 2026-06-08.
- Decision (M5): the `Embedding` effect (`embedText :: Text -> Eff es (Vector Double)`, with a
  pure `runEmbedding :: (Text -> Vector Double) -> ...` interpreter) is defined locally in
  `Shikumi.Eval.Metric` as the plan anticipated, since EP-1's `LLM` exposes no embedding
  operation. `semanticSimilarity` maps cosine from `[-1,1]` into `[0,1]` and returns
  `scoreZero` for a zero-norm vector. When a substrate embedding capability lands, the metric
  can switch interpreters without changing its type. Date: 2026-06-08.
- Decision (M4): `EvaluateSpec`'s aggregate-score case uses an **order-independent** mock (a
  constant LLM that always answers "yes", with a dataset of four "yes" + one "no" expecteds),
  so the 0.8 result holds under any concurrency; the failure-policy cases use a positional
  scripted mock under `concurrency = 1` so the injected `MockFail` lands on a known example.
  Rationale: `pooledForConcurrentlyN` does not order LLM calls across workers, so a positional
  script is only deterministic when single-threaded. Date: 2026-06-08.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section explains everything a newcomer needs, assuming only the current working tree.

**Where this sits in the repository.** The shikumi repository at
`/Users/shinzui/Keikaku/bokuno/shikumi` is a multi-package Haskell project. A root
`cabal.project` lists each package directory. The package that *this* plan creates is
`shikumi-eval`, living in a directory named `shikumi-eval/` at the repository root, with its
own `shikumi-eval.cabal` file. All modules this plan adds live under the `Shikumi.Eval.*`
namespace inside that package.

**effectful, the effect system (term of art).** The framework runs code in a monad
`Eff es a`, where `es` is a type-level list of *effects* (capabilities) the code is allowed
to use. The notation `LLM :> es` is a constraint meaning "the `LLM` effect is available in
the stack `es`". You do not need to understand effect internals to follow this plan; treat
`Eff es a` as "an IO-like computation that declares, in its type, which capabilities it uses"
and `(C :> es)` as "this code needs capability `C`". The relevant capabilities here are:

- `LLM` — the language-model call effect, owned by the substrate plan at
  `docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`. A program needs it
  to talk to a model.
- `Concurrent` — `effectful`'s built-in concurrency effect, from module
  `Effectful.Concurrent` / `Effectful.Concurrent.Async`. It provides
  `pooledForConcurrentlyN :: (Concurrent :> es) => Int -> (a -> Eff es b) -> [a] -> Eff es [b]`,
  which runs the per-element action over the list with **at most `n`** running at once and
  returns results in the original order. This is how `evaluate` parallelises the dataset.
- `Error ShikumiError` — `effectful`'s typed error effect carrying the shikumi error type
  `ShikumiError` defined by the substrate plan. `evaluate` catches per-example failures with
  `Effectful.Error.Static.runError`/`catchError` so one bad example does not abort the run.

**The `Program i o` type and `runProgram` (from a sibling plan).** Defined in module
`Shikumi.Program` by `docs/plans/4-typed-program-representation-and-core-modules.md`. It is a
*typed deep embedding* — a data type whose values *are* LM programs, runnable by
`runProgram :: (LLM :> es) => Program i o -> i -> Eff es o`. For this plan you only need:
the type constructor `Program i o`, the runner `runProgram`, and (for multi-sample metrics)
a runner that returns several samples. If the sibling plan exposes a sampling runner, this
plan uses it; otherwise this plan defines a thin local helper
`runProgramSamples :: (LLM :> es) => Int -> Program i o -> i -> Eff es (NonEmpty o)` that
calls `runProgram` `n` times (a model with temperature > 0 yields varied samples; a
deterministic stub yields identical samples, which is fine for tests). The plan does **not**
modify `Shikumi.Program`.

**baikai usage and cost accounting (transport-layer facts shikumi reuses).** shikumi sits on
top of *baikai* (the user's provider-abstraction library). Every model response carries a
`Usage` record with token counts and a `Cost` record with a dollar amount:

```haskell
-- From baikai (Baikai.Usage / Baikai.Cost), reproduced here for self-containment.
data Usage = Usage
  { inputTokens     :: !Natural
  , outputTokens    :: !Natural
  , cacheReadTokens :: !Natural
  , cacheWriteTokens :: !Natural
  , reasoningTokens :: !(Maybe Natural)
  , totalTokens     :: !Natural
  , cost            :: !Cost
  }

data Cost = Cost { usd :: !Rational, breakdown :: !CostBreakdown }
```

The `LLM` effect (substrate plan) is responsible for surfacing the per-call `Usage`/`Cost`
so they can be accumulated. This plan assumes the substrate plan exposes a way to *observe*
usage for a run — concretely, the substrate plan's `LLM` interpreter accumulates `Usage` into
a writer-like effect or a returned aggregate. If the substrate plan does not yet provide a
usage-accumulation hook, this plan introduces a **local, additive** accumulator: a small
`UsageAccum` effect (an `IORef (Usage` monoid`)` interpreter) defined in
`Shikumi.Eval.Usage`, wrapped around the LM interpreter only for the duration of `evaluate`,
and a `Monoid` instance for a `UsageTotals` summary (summing token fields, summing `usd`).
This keeps the plan self-contained even if the substrate hook lands later; when it lands, the
local accumulator can be swapped for it without changing `evaluate`'s public type. The
decision and the swap are recorded in the Decision Log when implementation reaches M4.

**tasty and tasty-golden (the test runner).** `tasty` provides `TestTree` (a tree of tests),
`testGroup :: String -> [TestTree] -> TestTree`, and `testCase :: String -> Assertion ->
TestTree` (from `Test.Tasty` and `Test.Tasty.HUnit`). `tasty-golden` provides
`goldenVsString :: TestName -> FilePath -> IO LBS.ByteString -> TestTree` (compare a produced
lazy `ByteString` against a checked-in golden file; regenerate the golden file with
`cabal test --test-options=--accept`). This plan's `goldenProgram` is built on
`goldenVsString`.

**DSPy concepts being ported (term-of-art definitions).** *Example*: in DSPy an example is an
untyped key/value bag where some keys are marked inputs and others are labels; shikumi types
it as `Example i o`. *Prediction*: in DSPy the output of running a module, again an untyped
bag, optionally holding several sampled `Completions`; shikumi types it as `Prediction o`.
*Metric*: a function `metric(example, prediction) -> bool | float`; shikumi types it as
`Metric o` / `MetricM es o` returning a bounded `Score`. *Evaluate*: run the program over a
devset, apply the metric, aggregate; shikumi's `evaluate` returns a `Report`.


## Plan of Work

The work proceeds in seven milestones. M1–M3 build the pure data model, metrics, and report
type (no model calls, fully unit-testable). M4 delivers `evaluate` with parallelism and error
handling against a mock LM. M5 adds the two LM-backed metrics. M6 delivers golden testing with
a fail-before/pass-after demonstration. M7 wires up documentation and ticks the master plan.

Throughout, every fenced code block is language-tagged, and every commit carries the three
trailers required by the repository:

```text
MasterPlan: docs/masterplans/1-shikumi-typed-lm-programming-framework.md
ExecPlan: docs/plans/8-evaluation-framework.md
Intention: intention_01ktjgkp10ef79vpwz1cmajek9
```


### Milestone 1 — Package scaffold and the typed data model

Scope: create the `shikumi-eval` package and the module `Shikumi.Eval.Types` holding the
owned data model (integration point #5). At the end of this milestone the package builds and
a unit-test suite exercises `Score` clamping, dataset construction, and `Prediction`
construction. No model calls are involved.

Create the directory `shikumi-eval/` at the repository root with `shikumi-eval.cabal`. The
cabal file declares a library exposing the `Shikumi.Eval.*` modules and a test suite. It
depends on `base`, `text`, `containers`, `vector`, `aeson` (for the `Value` escape hatch and
serialisation), `effectful` (for `Eff`/`Concurrent`/`Error`), the sibling core package
`shikumi` (for `Program`/`runProgram`/`ShikumiError` and the `LLM` effect), `tasty`,
`tasty-hunit`, and `tasty-golden`. A representative cabal file:

```cabal
cabal-version:      3.0
name:               shikumi-eval
version:            0.1.0.0
synopsis:           Typed evaluation framework for shikumi LM programs
build-type:         Simple

common warnings
  ghc-options: -Wall

library
  import:           warnings
  default-language: GHC2024
  hs-source-dirs:   src
  exposed-modules:
      Shikumi.Eval
      Shikumi.Eval.Types
      Shikumi.Eval.Metric
      Shikumi.Eval.Report
      Shikumi.Eval.Usage
      Shikumi.Eval.Evaluate
      Shikumi.Eval.Golden
  build-depends:
      base
    , text
    , containers
    , vector
    , aeson
    , effectful
    , shikumi
    , tasty
    , tasty-golden

test-suite shikumi-eval-test
  import:           warnings
  default-language: GHC2024
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test
  main-is:          Main.hs
  other-modules:
      TypesSpec
      MetricSpec
      ReportSpec
      EvaluateSpec
      GoldenSpec
  build-depends:
      base
    , text
    , containers
    , vector
    , aeson
    , bytestring
    , effectful
    , shikumi
    , shikumi-eval
    , tasty
    , tasty-hunit
    , tasty-golden
```

Add the line `packages: ... shikumi-eval` (alongside the other packages) to the repository
root `cabal.project`. If `cabal.project` does not yet exist (the substrate plan scaffolds it),
create a minimal one listing at least `shikumi` and `shikumi-eval` plus the
`source-repository-package` stanza for baikai as documented by the substrate plan; otherwise
just append `shikumi-eval`.

Author `shikumi-eval/src/Shikumi/Eval/Types.hs`. It must define exactly these types and
constructors (this is the integration contract other plans depend on):

```haskell
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveGeneric #-}
module Shikumi.Eval.Types
  ( -- * Scores
    Score (..)
  , mkScore
  , scoreZero
  , scoreOne
  , boolScore
  , unScore
    -- * Examples and datasets
  , Example (..)
  , example
  , Dataset (..)
  , dataset
  , datasetExamples
  , datasetSize
    -- * Predictions (program outputs)
  , Prediction (..)
  , prediction
  , predictionPrimary
  , predictionSamples
  ) where

import Data.Aeson (Value)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE

-- | A metric score, always in the closed interval [0, 1].
newtype Score = Score Double
  deriving stock (Eq, Ord, Show)

-- | Clamp any Double into [0, 1].
mkScore :: Double -> Score
mkScore d = Score (max 0 (min 1 d))

scoreZero, scoreOne :: Score
scoreZero = Score 0
scoreOne  = Score 1

boolScore :: Bool -> Score
boolScore True  = scoreOne
boolScore False = scoreZero

unScore :: Score -> Double
unScore (Score d) = d

-- | One labelled datum: an input of type @i@ and its expected output of type @o@.
data Example i o = Example
  { input    :: !i
  , expected :: !o
  }
  deriving stock (Eq, Show)

example :: i -> o -> Example i o
example = Example

-- | A typed evaluation dataset.
newtype Dataset i o = Dataset [Example i o]
  deriving stock (Eq, Show)

dataset :: [Example i o] -> Dataset i o
dataset = Dataset

datasetExamples :: Dataset i o -> [Example i o]
datasetExamples (Dataset xs) = xs

datasetSize :: Dataset i o -> Int
datasetSize (Dataset xs) = length xs

-- | A program's actual output for one example. Carries a primary output and the
--   non-empty set of sampled outputs (a single-output program yields one sample).
--   An optional raw JSON @detail@ lets adapters or judges attach structure.
data Prediction o = Prediction
  { primary :: !o
  , samples :: !(NonEmpty o)
  , detail  :: !(Maybe Value)
  }
  deriving stock (Eq, Show)

-- | Build a single-sample prediction.
prediction :: o -> Prediction o
prediction o = Prediction o (o :| []) Nothing

predictionPrimary :: Prediction o -> o
predictionPrimary = primary

predictionSamples :: Prediction o -> NonEmpty o
predictionSamples = samples
```

Author the test module `shikumi-eval/test/TypesSpec.hs` with `tasty-hunit` cases proving:
`mkScore 1.5 == scoreOne`, `mkScore (-0.2) == scoreZero`, `mkScore 0.5 == Score 0.5`;
`datasetSize (dataset [example 1 'a', example 2 'b']) == 2`; and
`predictionSamples (prediction "x") == ("x" :| [])`. Wire it into `test/Main.hs` as a
`testGroup`.

Verification: from the repository root run `cabal build shikumi-eval` then
`cabal test shikumi-eval`. The build succeeds and the `TypesSpec` group passes (expected
transcript shown in Concrete Steps).


### Milestone 2 — Pure metrics

Scope: module `Shikumi.Eval.Metric` providing the metric type aliases, the lift, the pure
built-in metrics, and metric combinators. At the end, pure-metric unit tests pass. No model
calls.

The metric aliases and the lift:

```haskell
module Shikumi.Eval.Metric
  ( Metric
  , MetricM
  , liftMetric
    -- * Built-in pure metrics
  , exactMatch
  , normalizedStringSimilarity
  , customMetric
    -- * Combinators
  , weightedMean
  , threshold
  , invert
  ) where

import Effectful (Eff)
import Shikumi.Eval.Types

-- | A pure metric: expected output, then the program's prediction, yields a score.
type Metric o = o -> Prediction o -> Score

-- | An effectful metric, for metrics that must call a model (embedding, judge).
type MetricM es o = o -> Prediction o -> Eff es Score

-- | Every pure metric is trivially an effectful one.
liftMetric :: Metric o -> MetricM es o
liftMetric m = \e p -> pure (m e p)
```

`exactMatch :: Eq o => Metric o` returns `boolScore (expected == primary pred)`.

`customMetric :: (o -> Prediction o -> Score) -> Metric o` is the escape hatch — it is
literally `id` at the type level, present so that user code reads `customMetric $ \e p -> ...`
and documents intent; this satisfies the "custom-metric escape hatch" requirement explicitly.

`normalizedStringSimilarity :: (o -> Text) -> Metric o` takes a projection from the output to
the text to compare (so it works on any record by pointing at the relevant field), and scores
the similarity between `proj expected` and `proj (primary pred)`. The similarity function is
pure and offline: case-fold both strings, collapse runs of whitespace to single spaces, trim,
then compute a blend of (a) token-set Jaccard similarity `|A ∩ B| / |A ∪ B|` over the
whitespace-split token sets and (b) a normalized character-level similarity
`1 - levenshtein a b / max(len a, len b)`. Return `mkScore ((jaccard + charSim) / 2)`. Define
`levenshtein :: Text -> Text -> Int` with the standard dynamic-programming row algorithm
(self-contained; do not pull a new dependency just for this). Identical strings score 1;
disjoint strings score near 0.

Combinators:

- `weightedMean :: [(Double, Metric o)] -> Metric o` — combine several metrics by a weighted
  average of their scores: `mkScore (sum (w_i * unScore (m_i e p)) / sum w_i)`. Empty list
  yields `const (const scoreZero)`.
- `threshold :: Double -> Metric o -> Metric o` — turn a graded metric into pass/fail:
  `boolScore (unScore (m e p) >= t)`.
- `invert :: Metric o -> Metric o` — `mkScore (1 - unScore (m e p))`, useful for "lower is
  better" wrapped metrics.

Author `shikumi-eval/test/MetricSpec.hs`: `exactMatch` on equal/unequal values;
`normalizedStringSimilarity id "the cat" "the cat" == scoreOne` (after building a
`Prediction`); a near-but-not-equal pair scores strictly between 0 and 1; `threshold 0.5`
turns a 0.7 metric into `scoreOne` and a 0.3 metric into `scoreZero`; `weightedMean` of two
constant metrics returns their weighted average.

Verification: `cabal test shikumi-eval` — the `MetricSpec` group passes.


### Milestone 3 — The Report type and aggregation

Scope: module `Shikumi.Eval.Report` defining `Report`, `ExampleResult`, `FailurePolicy`,
`EvalConfig`, the usage/cost summary type, and the pure aggregation function `mkReport`. At
the end, `mkReport` is unit-tested against synthetic per-example results. No model calls.

```haskell
{-# LANGUAGE DeriveGeneric #-}
module Shikumi.Eval.Report
  ( ExampleResult (..)
  , FailureReason (..)
  , FailurePolicy (..)
  , EvalConfig (..)
  , defaultEvalConfig
  , UsageTotals (..)
  , emptyUsageTotals
  , Report (..)
  , mkReport
  , renderReportText
  ) where

import Data.Text (Text)
import Numeric.Natural (Natural)
import Shikumi.Eval.Types (Score, unScore)

-- | The reason an example did not complete normally.
data FailureReason
  = ProgramError !Text   -- ^ runProgram threw a ShikumiError (rendered to Text)
  | MetricError !Text    -- ^ the metric itself failed (effectful metric error)
  | TimedOut
  deriving stock (Eq, Show)

-- | What to do when an example fails.
data FailurePolicy
  = FailScore !Score     -- ^ record the failure, assign this score, continue
  | FailAbort            -- ^ re-throw, ending the whole run
  deriving stock (Eq, Show)

-- | Per-example outcome retained in the report for failure analysis.
data ExampleResult = ExampleResult
  { index     :: !Int                 -- ^ position in the dataset (0-based)
  , score     :: !Score
  , failure   :: !(Maybe FailureReason)
  , latencyMs :: !Integer
  }
  deriving stock (Eq, Show)

-- | Summed token/cost usage across the run.
data UsageTotals = UsageTotals
  { totalInputTokens  :: !Natural
  , totalOutputTokens :: !Natural
  , totalTokens       :: !Natural
  , totalCostUsd      :: !Rational
  }
  deriving stock (Eq, Show)

emptyUsageTotals :: UsageTotals
emptyUsageTotals = UsageTotals 0 0 0 0

instance Semigroup UsageTotals where
  a <> b = UsageTotals
    (totalInputTokens a + totalInputTokens b)
    (totalOutputTokens a + totalOutputTokens b)
    (totalTokens a + totalTokens b)
    (totalCostUsd a + totalCostUsd b)

instance Monoid UsageTotals where
  mempty = emptyUsageTotals

-- | Knobs for an evaluation run.
data EvalConfig = EvalConfig
  { concurrency   :: !Int           -- ^ max examples evaluated at once (>=1)
  , failurePolicy :: !FailurePolicy
  , numSamples    :: !Int           -- ^ samples per example for multi-sample metrics (>=1)
  }
  deriving stock (Eq, Show)

defaultEvalConfig :: EvalConfig
defaultEvalConfig = EvalConfig
  { concurrency   = 4
  , failurePolicy = FailScore (toEnum 0 `seq` minBound `seq` undefined) -- replaced below
  , numSamples    = 1
  }
```

Note: the `defaultEvalConfig.failurePolicy` placeholder above must be implemented as
`FailScore scoreZero` (import `scoreZero` from `Shikumi.Eval.Types`); the placeholder is shown
only to flag that the default is "score failures 0, keep going". The real definition is:

```haskell
defaultEvalConfig :: EvalConfig
defaultEvalConfig = EvalConfig
  { concurrency   = 4
  , failurePolicy = FailScore scoreZero
  , numSamples    = 1
  }
```

The `Report` and its aggregator:

```haskell
data Report = Report
  { aggregateScore :: !Double          -- ^ mean of per-example scores, in [0,1]
  , passCount      :: !Int             -- ^ examples with score == 1.0
  , failCount      :: !Int             -- ^ examples with a 'FailureReason'
  , total          :: !Int
  , results        :: ![ExampleResult] -- ^ retained per-example, in dataset order
  , usage          :: !UsageTotals
  , totalLatencyMs :: !Integer
  }
  deriving stock (Eq, Show)

-- | Build a report from per-example results and the run's usage totals.
--   'aggregateScore' is the arithmetic mean of the per-example scores
--   (0 if there are no examples).
mkReport :: [ExampleResult] -> UsageTotals -> Report
mkReport rs u = Report
  { aggregateScore = if null rs then 0
                       else sum (map (unScore . score) rs) / fromIntegral (length rs)
  , passCount      = length (filter ((== 1.0) . unScore . score) rs)
  , failCount      = length (filter (maybe False (const True) . failure) rs)
  , total          = length rs
  , results        = rs
  , usage          = u
  , totalLatencyMs = sum (map latencyMs rs)
  }
```

`renderReportText :: Report -> Text` produces a stable, human-readable multi-line summary
(aggregate score to 4 decimals, pass/fail/total counts, total tokens, cost in USD, then one
line per failing example with its index and reason). This is reused by the CLI plan and by
golden tests, so it must be *deterministic* (fixed decimal formatting, examples in index
order). Document the exact format in a doc-comment with a sample so consumers can rely on it.

Author `shikumi-eval/test/ReportSpec.hs`: feed `mkReport` a handful of synthetic
`ExampleResult`s (some scoring 1, some 0.5, one with a `ProgramError` failure) and assert the
computed `aggregateScore`, `passCount`, `failCount`, and `total`; assert `UsageTotals`'s
`Monoid` sums correctly; assert `renderReportText` produces the documented format for a fixed
input (an inline golden-by-equality check).

Verification: `cabal test shikumi-eval` — the `ReportSpec` group passes.


### Milestone 4 — `evaluate` end-to-end with a mock LM

Scope: module `Shikumi.Eval.Evaluate` providing `evaluate` (and `evaluatePure`), running a
program over a dataset with bounded parallelism, per-example error handling, and usage/latency
accounting, returning a `Report`. The acceptance is an end-to-end test using a **mock LM**
interpreter so no network or API key is needed. This is the core deliverable.

First, the usage accumulator. Author `shikumi-eval/src/Shikumi/Eval/Usage.hs` providing a
function `withUsageTotals` that runs an `Eff` action while accumulating any model `Usage`
reported by the `LLM` effect's interpreter into a `UsageTotals`, returning both the action's
result and the totals. The precise wiring depends on the substrate plan's `LLM` interpreter:

- If the substrate plan
  (`docs/plans/1-shikumi-runtime-substrate-and-llm-effect-over-baikai.md`) exposes a
  usage-observing hook (for example a `Writer UsageTotals` effect, or a `runLLMWithUsage`
  interpreter that returns `(a, UsageTotals)`), `withUsageTotals` is a thin adapter over it.
- Otherwise, define a local `UsageAccum` effect with one operation
  `recordUsage :: Usage -> Eff es ()`, interpret it with an `IORef UsageTotals` via
  `Effectful.Dispatch.Dynamic.interpret`, and have `evaluate` wrap the program run so that
  the LM call path records usage. (If the substrate `LLM` interpreter cannot yet be hooked,
  the local accumulator simply reports zeros, and the per-example latency — measured directly
  with a monotonic clock around `runProgram` — is still populated. Record this state in the
  Decision Log when M4 is implemented and tighten it once the substrate hook lands.)

The public surface of `evaluate`:

```haskell
module Shikumi.Eval.Evaluate
  ( evaluate
  , evaluatePure
  , evaluateWith
  ) where

import Effectful (Eff, (:>), IOE)
import Effectful.Concurrent (Concurrent)
import Effectful.Error.Static (Error)
import Shikumi.Program (Program)               -- from the core 'shikumi' package
import Shikumi.Error (ShikumiError)            -- from the core 'shikumi' package
import Shikumi.LLM (LLM)                        -- from the core 'shikumi' package
import Shikumi.Eval.Types
import Shikumi.Eval.Metric (Metric, MetricM, liftMetric)
import Shikumi.Eval.Report

-- | Evaluate a program over a dataset with an effectful metric, using the
--   default configuration.
evaluate
  :: ( LLM :> es
     , Concurrent :> es
     , Error ShikumiError :> es
     , IOE :> es
     )
  => Dataset i o
  -> MetricM es o
  -> Program i o
  -> Eff es Report
evaluate = evaluateWith defaultEvalConfig

-- | Convenience for a pure metric.
evaluatePure
  :: ( LLM :> es
     , Concurrent :> es
     , Error ShikumiError :> es
     , IOE :> es
     )
  => Dataset i o
  -> Metric o
  -> Program i o
  -> Eff es Report
evaluatePure ds m = evaluate ds (liftMetric m)

-- | Evaluate with an explicit configuration.
evaluateWith
  :: ( LLM :> es
     , Concurrent :> es
     , Error ShikumiError :> es
     , IOE :> es
     )
  => EvalConfig
  -> Dataset i o
  -> MetricM es o
  -> Program i o
  -> Eff es Report
```

Implementation of `evaluateWith`:

1. Zip the dataset's examples with their 0-based index.
2. Run them with `pooledForConcurrentlyN (max 1 (concurrency cfg))` over the indexed list.
   For each `(ix, Example inp exp)`:
   a. Record a start time (monotonic clock via `IOE`).
   b. Build a `Prediction` by running the program. With `numSamples cfg == 1`, run
      `runProgram prog inp` once and wrap with `prediction`. With `numSamples > 1`, run it
      `n` times (or call the sibling sampling runner if available) and build a multi-sample
      `Prediction`.
   c. Apply the metric `m exp pred` to get a `Score`.
   d. Wrap steps (b)–(c) in `catchError` so a `ShikumiError` from `runProgram` (or a metric)
      becomes a `FailureReason`. On failure, consult `failurePolicy cfg`: `FailScore s`
      yields an `ExampleResult` with that score and a `Just` failure; `FailAbort` re-throws
      (`throwError`), aborting the pool. Record the elapsed time as `latencyMs`.
3. Collect the per-example `ExampleResult`s (already in dataset order thanks to
   `pooledForConcurrentlyN`), gather the run's `UsageTotals` (via `withUsageTotals` wrapping
   the whole pooled run, or zero if the substrate hook is absent), and return
   `mkReport results totals`.

Author `shikumi-eval/test/EvaluateSpec.hs`. It needs a **mock LM** and a **stub program**.
The mock LM is an interpreter for the `LLM` effect that returns canned responses without
network access. The exact constructor depends on the substrate plan; this test uses whatever
the substrate plan exposes for testing (e.g. `runLLMPure responses` or
`runLLMMock table`). If the substrate plan does not yet ship a test interpreter, this plan
provides a minimal one in the test module: an `interpret` over `LLM` that pattern-matches the
request and returns a fixed decoded value. The stub program is the simplest `Program i o`
the core plan offers (e.g. `predict @Sig`) wired to the mock, *or* — to keep this test
independent of the core program internals — a program whose behaviour the mock fully controls
so that for input `Example q a` the program returns exactly `a` for the "good" examples and a
wrong value for one "bad" example.

The test asserts: running `evaluatePure ds exactMatch prog` over a five-example dataset where
the mock answers four correctly and one incorrectly yields a `Report` with
`aggregateScore == 0.8`, `passCount == 4`, `failCount == 0` (a *wrong* answer is a pass/fail
of the metric, not a program *failure*), `total == 5`, and `results` of length 5 in order. A
second case forces `runProgram` to throw on one example (mock returns an error) and asserts
that with `defaultEvalConfig` (`FailScore scoreZero`) that example appears in `results` with
`failure == Just (ProgramError _)` and `score == scoreZero`, and the run completes; then with
`failurePolicy = FailAbort` the whole `evaluate` call surfaces the error
(`runError` returns `Left`).

Verification: `cabal test shikumi-eval` — `EvaluateSpec` passes; this is the plan's primary
acceptance (a `Report` with the expected aggregate score and per-example breakdown).


### Milestone 5 — LM-backed metrics: semantic similarity and model-judge

Scope: extend `Shikumi.Eval.Metric` with two `MetricM` metrics that call a model:
`semanticSimilarity` (embedding-based) and `modelJudge` (LLM-as-grader). Tested against a
mock LM.

`semanticSimilarity` needs an embedding capability. If the substrate `LLM` effect exposes an
embedding operation (`embed :: Text -> Eff es (Vector Double)`), use it; otherwise this plan
defines a tiny `Embedding` effect in `Shikumi.Eval.Metric` with one operation
`embedText :: Text -> Eff es (Vector Double)` and documents that its interpreter is provided
by the caller (the substrate or a mock). The metric:

```haskell
-- | Embedding-based semantic similarity: cosine similarity of the embeddings of
--   the projected expected and predicted text, mapped from [-1,1] into [0,1].
semanticSimilarity
  :: (Embedding :> es)
  => (o -> Text)            -- ^ project the output to comparable text
  -> MetricM es o
```

It embeds `proj expected` and `proj (primary pred)`, computes cosine similarity
`dot a b / (norm a * norm b)`, maps it via `mkScore ((cos + 1) / 2)`. Guard against
zero-norm vectors (return `scoreZero`).

`modelJudge` is itself a small shikumi program: it prompts a model to grade the prediction
against the expected output and return a score. Express it as an `LLM`-using metric:

```haskell
-- | LLM-as-judge: ask a model to grade the prediction against the expected output.
--   The grading rubric is supplied as text; the judge returns a score in [0,1].
modelJudge
  :: (LLM :> es)
  => Text                   -- ^ rubric / grading instruction
  -> (o -> Text)            -- ^ render an output for the judge to read
  -> MetricM es o
```

Internally it constructs a small judge program (or a direct `LLM` call) whose output is a
record with a single numeric `grade` field constrained to `[0,1]`, sends the rubric plus the
rendered expected and predicted texts, decodes the grade, and returns `mkScore grade`. Use
the structured-output path so the grade is parsed reliably; if decoding fails, surface a
`MetricError` (the per-example error boundary in `evaluate` turns it into a `FailureReason`).
Keep the judge program's signature minimal and documented inline.

Author `shikumi-eval/test/` cases (extend `MetricSpec.hs` or a new `MetricLMSpec.hs`):
`semanticSimilarity` against a mock `Embedding` interpreter that returns fixed vectors —
identical vectors score 1, orthogonal vectors score 0.5 (cosine 0 maps to 0.5), opposite
vectors score 0; `modelJudge` against a mock `LLM` that returns a fixed grade JSON, asserting
the returned `Score` equals the mocked grade. These run with no network access.

Verification: `cabal test shikumi-eval` — the LM-metric group passes.


### Milestone 6 — Golden program tests (fail-before / pass-after)

Scope: module `Shikumi.Eval.Golden` providing `goldenProgram`, integrating with `tasty`
via `tasty-golden`, so a program's behaviour is regression-tested deterministically and
offline. Acceptance is the documented fail-before/pass-after sequence.

```haskell
module Shikumi.Eval.Golden
  ( goldenProgram
  , goldenReport
  ) where

import Test.Tasty (TestTree)
import qualified Data.ByteString.Lazy as LBS

-- | Turn a program plus a dataset into a golden test. The test runs the program
--   over the dataset under the supplied (mock or replayed) interpreter, renders a
--   stable textual transcript, and compares it to the golden file at @path@.
--   Regenerate the golden file with: cabal test --test-options=--accept
goldenProgram
  :: TestName
  -> FilePath                       -- ^ golden file path
  -> (forall a. Eff es a -> IO a)   -- ^ how to run the effect stack (mock/replay)
  -> Dataset i o
  -> Program i o
  -> (o -> Text)                    -- ^ render an output line for the transcript
  -> TestTree

-- | Like 'goldenProgram' but compares the rendered 'Report' produced by 'evaluate'
--   with a given metric, rather than a raw transcript.
goldenReport
  :: TestName
  -> FilePath
  -> (forall a. Eff es a -> IO a)
  -> Dataset i o
  -> MetricM es o
  -> Program i o
  -> TestTree
```

`goldenProgram` runs the program over each example (under the provided interpreter, which the
caller wires to a mock LM or to the replay interpreter from
`docs/plans/7-hierarchical-tracing-observability-and-replay.md`), renders each output with the
supplied function into a deterministic transcript (one line per example, in dataset order,
each line `index\t<rendered output>`), encodes it as UTF-8 lazy `ByteString`, and hands that
to `goldenVsString name path`. `goldenReport` instead runs `evaluate`, renders the resulting
`Report` with `renderReportText`, and compares that. The `forall a. Eff es a -> IO a` runner
argument is how the caller supplies the offline interpreter; because it is a single rank-2
function the helper stays agnostic to the exact effect stack.

Why this is deterministic: the only inputs to the produced `ByteString` are the dataset (fixed
in the test source), the program (fixed), and the model responses — which the caller's runner
makes deterministic by replaying or mocking. Nothing else varies, so the golden file changes
only when program behaviour changes.

Author `shikumi-eval/test/GoldenSpec.hs` and a golden fixture directory
`shikumi-eval/test/golden/`. The spec builds a small dataset and a stub program (the same mock
machinery as M4), creates a `goldenProgram` test pointing at
`shikumi-eval/test/golden/stub-program.golden`, and adds it to the suite.

The fail-before/pass-after demonstration (record the transcript in Concrete Steps when run):

1. Run `cabal test shikumi-eval --test-options=--accept` once to generate
   `stub-program.golden` from the current program behaviour. Run `cabal test shikumi-eval`:
   the golden test passes.
2. Deliberately change the stub program's behaviour (e.g. make the mock return a different
   output for one example, simulating a regression). Run `cabal test shikumi-eval`: the
   golden test now **fails**, printing a diff between the recorded golden output and the new
   output.
3. Revert the change (or, if the change was intended, run with `--accept` to bless the new
   output). Run `cabal test shikumi-eval`: the golden test passes again.

Verification: the three-step sequence above behaves exactly as described; capture the failing
diff and the passing runs in Concrete Steps. The `.golden` file is committed.


### Milestone 7 — Documentation, top module, and master-plan wiring

Scope: a convenience re-export module `Shikumi.Eval` re-exporting `Types`, `Metric`,
`Report`, `Evaluate`, and `Golden`; a worked usage example in a doc-comment that is exercised
by a compiled test (so the documented example cannot rot); and ticking the EP-8 row in the
master plan's Progress section.

`Shikumi.Eval` re-exports the public surfaces so a user writes a single
`import Shikumi.Eval`. Add a top-of-module doc-comment showing the end-to-end usage from the
Purpose section (declare a `Dataset`, pick `exactMatch`, call `evaluate`, read the `Report`),
and back it with a test that constructs and runs that exact snippet under the mock so the
example is guaranteed to compile and run.

Update `docs/masterplans/1-shikumi-typed-lm-programming-framework.md`: tick the line
`- [ ] EP-8: Dataset/Metric/evaluate/Report + built-in metrics + golden tests` to `- [x]`
once all milestones land. (This is the only edit this plan makes outside `shikumi-eval/` and
this file.)

Verification: `cabal build shikumi-eval && cabal test shikumi-eval` all green; the master-plan
Progress row reflects completion.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` unless
noted. Replace `<editor>` with your editor.

Scaffold and build (M1):

```bash
mkdir -p shikumi-eval/src/Shikumi/Eval shikumi-eval/test/golden
# create shikumi-eval/shikumi-eval.cabal, src/Shikumi/Eval/Types.hs, test/Main.hs,
# test/TypesSpec.hs as specified above; add shikumi-eval to cabal.project
cabal build shikumi-eval
cabal test  shikumi-eval
```

Expected test transcript (shape; exact counts grow per milestone):

```text
shikumi-eval-test
  Types
    mkScore clamps high:   OK
    mkScore clamps low:    OK
    datasetSize:           OK
    prediction single:     OK

All 4 tests passed (0.00s)
```

End-to-end evaluate (M4) — expected assertions visible as passing cases:

```text
  Evaluate
    four-of-five exact match -> aggregateScore 0.8: OK
    program error -> FailScore scoreZero, run completes: OK
    FailAbort surfaces error: OK
```

Golden fail-before/pass-after (M6):

```bash
# 1. bless current behaviour
cabal test shikumi-eval --test-options=--accept
cabal test shikumi-eval        # golden test passes

# 2. introduce a regression in the stub program, then:
cabal test shikumi-eval        # golden test FAILS with a diff

# 3. revert (or re-accept), then:
cabal test shikumi-eval        # golden test passes again
```

Expected failing-diff shape in step 2:

```text
  Golden
    stub-program golden: FAIL
      Test output was different from 'test/golden/stub-program.golden'. It was:
      - 2	correct-answer
      + 2	regressed-answer
```

Actual M6 run (2026-06-08). The committed golden
`shikumi-eval/test/golden/qa-program.golden` is `0\tyes` / `1\tyes` (the constant mock
answers "yes" for both examples). Step 1 (`--accept`) created it and the clean run passed.
Step 2 changed the mock to answer `"regressed"`; the same test then failed:

```text
  Golden
    qa-program golden:                                   FAIL
      Test output was different from 'test/golden/qa-program.golden'. It was:
      0	regressed
      1	regressed

1 out of 35 tests failed (0.00s)
```

Step 3 reverted the mock to `"yes"`; the golden test passed again (`All 35 tests passed`).
This is the fail-before/pass-after acceptance.

Update the master plan Progress row (M7), then commit:

```bash
git add shikumi-eval docs/plans/8-evaluation-framework.md docs/masterplans/1-shikumi-typed-lm-programming-framework.md cabal.project
git commit -m "feat(eval): typed evaluation framework (datasets, metrics, evaluate, golden)"
```

(The commit body must carry the three trailers shown in Plan of Work.)


## Validation and Acceptance

The plan is accepted when all of the following are observable from the repository root:

1. `cabal build shikumi-eval` succeeds with `-Wall` and no errors.
2. `cabal test shikumi-eval` runs and every group passes: `Types`, `Metric`, `Report`,
   `Evaluate`, `Metric (LM)`, `Golden`, and the doc-example test.
3. The `Evaluate` group demonstrates the core behaviour with a mock LM and **no network**:
   a five-example dataset where the program answers four of five correctly yields a `Report`
   with `aggregateScore == 0.8`, `passCount == 4`, `total == 5`, and a `results` list of
   length five in dataset order; a program error on one example yields, under the default
   policy, an `ExampleResult` with `failure == Just (ProgramError _)` and `score == scoreZero`
   while the run completes; under `FailAbort` the error surfaces as a `Left` from `runError`.
4. The golden demonstration behaves as a fail-before/pass-after: with a checked-in
   `.golden` file the `Golden` group passes; after a deliberate program change the same test
   fails with a diff; after reverting or re-accepting it passes again.
5. The owned types `Score`, `Example`, `Prediction`, `Dataset`, `Metric`/`MetricM`, and
   `Report` are exported from `Shikumi.Eval` with the exact shapes in this plan, so the
   sibling plans `docs/plans/10-optimizer-framework.md` and
   `docs/plans/12-cli-and-developer-experience.md` can import them without redefining them.

All acceptance is behavioural (a `Report` you can inspect; a golden test that flips
fail→pass), not "a type was added".


## Idempotence and Recovery

Every step is additive and safe to repeat. `mkdir -p` and re-creating files are idempotent.
`cabal build`/`cabal test` are read-only with respect to source and can be run any number of
times. Re-running `cabal test --test-options=--accept` simply re-blesses the golden file to
the current behaviour; to recover a corrupted golden file, delete it and run with `--accept`
once to regenerate. If `cabal.project` already lists `shikumi-eval`, appending it again is the
only non-idempotent action — check first and only add if absent. No step is destructive; there
are no migrations. If the substrate plan's `LLM` test interpreter changes shape, only the test
modules (mock wiring) need updating, never the public `evaluate` type.


## Interfaces and Dependencies

Libraries used and why: `effectful` (the `Eff` monad, the `Concurrent` effect for bounded
parallelism via `pooledForConcurrentlyN`, the `Error` effect for per-example boundaries);
`tasty` + `tasty-hunit` (the unit-test suite) + `tasty-golden` (`goldenVsString` for golden
tests); `aeson` (the `Value` escape hatch on `Prediction.detail` and judge-grade decoding);
`text`, `containers`, `vector` (text handling, sets for Jaccard, embedding vectors). The
sibling core package `shikumi` supplies `Program`, `runProgram`, the `LLM` effect, and
`ShikumiError` — this plan depends on those but does not modify them.

Types and signatures that must exist at the end of each milestone (full module paths):

- M1 — `Shikumi.Eval.Types`: `newtype Score`, `mkScore`, `scoreZero`, `scoreOne`,
  `boolScore`, `unScore`; `data Example i o`, `example`; `newtype Dataset i o`, `dataset`,
  `datasetExamples`, `datasetSize`; `data Prediction o`, `prediction`, `predictionPrimary`,
  `predictionSamples`.
- M2 — `Shikumi.Eval.Metric`: `type Metric o`, `type MetricM es o`, `liftMetric`;
  `exactMatch :: Eq o => Metric o`; `normalizedStringSimilarity :: (o -> Text) -> Metric o`;
  `customMetric :: (o -> Prediction o -> Score) -> Metric o`;
  `weightedMean :: [(Double, Metric o)] -> Metric o`;
  `threshold :: Double -> Metric o -> Metric o`; `invert :: Metric o -> Metric o`.
- M3 — `Shikumi.Eval.Report`: `data ExampleResult`, `data FailureReason`,
  `data FailurePolicy`, `data EvalConfig`, `defaultEvalConfig`, `data UsageTotals` (with
  `Monoid`), `emptyUsageTotals`, `data Report`, `mkReport :: [ExampleResult] -> UsageTotals
  -> Report`, `renderReportText :: Report -> Text`.
- M4 — `Shikumi.Eval.Usage`: `withUsageTotals :: (IOE :> es) => Eff es a -> Eff es (a,
  UsageTotals)` (or the substrate-hook adapter). `Shikumi.Eval.Evaluate`:
  `evaluate`, `evaluatePure`, `evaluateWith` with the constraints
  `(LLM :> es, Concurrent :> es, Error ShikumiError :> es, IOE :> es)` returning
  `Eff es Report`.
- M5 — `Shikumi.Eval.Metric` (extended): `semanticSimilarity :: (Embedding :> es) => (o ->
  Text) -> MetricM es o`; `modelJudge :: (LLM :> es) => Text -> (o -> Text) -> MetricM es o`;
  and, if the substrate lacks one, an `Embedding` effect with `embedText :: Text -> Eff es
  (Vector Double)`.
- M6 — `Shikumi.Eval.Golden`: `goldenProgram` and `goldenReport` returning `TestTree`, built
  on `Test.Tasty.Golden.goldenVsString`.
- M7 — `Shikumi.Eval`: re-export module exposing the full public surface.

Integration contract (master-plan integration point #5): this plan **owns** `Example`,
`Prediction`, `Dataset`, `Metric`/`MetricM`, `Score`, and `Report`. The optimizer plan
(`docs/plans/10-optimizer-framework.md`) consumes `Dataset` + `Metric`/`MetricM` as its search
inputs and `Report` (specifically `aggregateScore`) as its objective; the CLI plan
(`docs/plans/12-cli-and-developer-experience.md`) consumes `Report` via `renderReportText` for
the `eval` subcommand. Neither may redefine these types; they import them from `Shikumi.Eval`.
