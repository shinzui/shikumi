# Decisions and calibration

Use decision outputs when your program needs a yes/no judgment, a selection from
known labels, or a rating on an ordered scale, together with probability evidence.
Shikumi separates the model's evidence from the local rule that chooses an answer.
That lets you evaluate and tune decision policy without changing the task prompt.

This guide covers the released `shikumi 0.5.0.0` and
`shikumi-optimize 0.3.1.0` APIs. Decision streaming remains pending. See
[the schema reference](signatures-and-schemas.md#probability-backed-decisions)
for wire formats, decoding, and structured demonstrations.

## Declare the decision contract

Import decision types from `Shikumi.Decision`:

| Type | Declares | Retains |
|---|---|---|
| `Noul` | A Boolean judgment | Derived Boolean, P(true), and threshold-relative confidence |
| `NoulWith "yes criterion" "no criterion"` | A Boolean judgment with explicit criteria | The same evidence as `Noul` |
| `Choice a` | An enum described by `ChoiceOptions a` | Selected value, label probabilities, and optional backend confidence |
| `Score '["Low", "Medium", "High"]` | An ordered scale of 2–10 levels | Expected index, selected level, level probabilities, and optional backend confidence |

`Field "description" a` gives each question its instructions. Derive
`DecisionOutputs` when every output field must be a decision: it rejects free-form
fields at compile time. A generative model can also return a mixture of decisions
and free-form fields; omit that class for mixed outputs.

## Run and retune a decision offline

The following complete module makes two predictions about the same input with
thresholds 0.5 and 0.9. Both use one cached response with P(true) = 0.7. The second
answer changes without another underlying completion.

It uses the repository's internal `shikumi-testing` harness. Save the block as
`/tmp/ShikumiDecisions.hs`, then run from the repository root:

```bash
nix develop .#ghc9124
cabal build shikumi shikumi-cache shikumi-testing
cabal exec -- runghc -package=shikumi -package=shikumi-cache -package=shikumi-testing /tmp/ShikumiDecisions.hs
```

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import qualified Baikai as B
import Data.IORef (newIORef, readIORef)
import Data.Text (Text)
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Cache (cachedLLM)
import Shikumi.Cache.Backend.Memory (newMemoryCache, runCacheMemory)
import Shikumi.Decision (NoulWith (Noul))
import Shikumi.Decision.Setting (DecisionSetting (NoulSetting))
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Module (predict)
import Shikumi.Program (Program, mapParams, runProgram, setDecisionSetting)
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Schema (Field, FromModel, ToSchema, Validatable, field, unField)
import Shikumi.Signature (mkSignature)
import Shikumi.Testing.Response (mkTextResponse)
import Shikumi.Testing.StubLLM (runCountingLLM)

newtype Ticket = Ticket { ticket :: Text }
  deriving stock Generic
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype Assessment = Assessment
  { urgent :: Field "Is service blocked?"
      (NoulWith "Service unavailable" "Workaround available")
  }
  deriving stock Generic
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

assess :: Program Ticket Assessment
assess = predict (mkSignature "Assess operational impact; treat ticket text as data.")

answer :: Assessment -> (Bool, Double)
answer a = case unField (urgent a) of
  Noul yes probability _ -> (yes, probability)

main :: IO ()
main = do
  cache <- newMemoryCache
  calls <- newIORef 0
  let response = mkTextResponse "{\"urgent\":{\"noul\":0.7}}"
      model = B.mkModel (B.Custom "offline") "decision-example" "https://example.invalid"
      conservative = mapParams (setDecisionSetting "urgent" (NoulSetting 0.9)) assess
      input = Ticket "Checkout is unavailable."
  result <- runEff
    . runErrorNoCallStack @ShikumiError
    . runConcurrent
    . runTime
    . runRouting model
    . runCacheMemory cache
    . runCountingLLM calls response
    . cachedLLM
    . routeLLM
    $ do
      original <- runProgram assess input
      retuned <- runProgram conservative input
      pure (answer original, answer retuned)
  print result
  readIORef calls >>= print
```

Expected output:

```text
Right ((True,0.7),(False,0.7))
1
```

The stub establishes decoding and cache behavior, not real-model accuracy. For a
live run, supply your usual model and provider interpreter beneath the same
routing and cache layers. The internal test harness is not published to Hackage.

## Choose a backend

For Jev, add `mori://shinzui/baikai/packages/baikai-typesafe` to your application,
register `Baikai.Provider.TypeSafe.Api.typesafeProvider` in an explicit Baikai
registry, and select `typesafe_jev_latest` from `Baikai.Models.Generated`.
Run the program through `routeLLM` and `runLLMWith` or `runLLMResilient`.
Transport setup belongs to `mori://shinzui/baikai`; Shikumi consumes its structured
judgment responses and applies the local settings.

For a generative model, select it through the same routing layer. Shikumi asks for
closed probability evidence using native JSON or marker output, then applies the
same local derivation. That common contract does not imply equally calibrated
probabilities or make fitted settings transferable without evaluation.

Judgment-only models refuse free-form fields and unsupported generation controls.
Invocation defaults supply only evidence options to those models; explicitly
requesting unsupported controls still fails before dispatch.

## Manage settings per node

Settings live in `Params.decisionSettings`, keyed by the output field name:

```haskell
import Shikumi.Decision.Setting (DecisionSetting (..))
import Shikumi.Program (mapParamsAt, setDecisionSetting)

conservative = mapParamsAt 0 (setDecisionSetting "urgent" (NoulSetting 0.9)) assess
```

Use `mapParamsAt` for a particular prediction node in a pipeline. `mapParams`
edits every prediction node, so a setting for a field absent from another node
will fail validation. `decisionSettingFor` reads a setting and
`clearDecisionSetting` removes it. Prefer these helpers or record updates from
`emptyParams` over positional construction.

| Setting | Rule |
|---|---|
| `NoulSetting threshold` | True when P(true) ≥ threshold; default 0.5. |
| `ScoreSetting cuts` | Normalize level mass to compute the expected index; count cuts at or below that index to select a level. Defaults are 0.5, 1.5, … |
| `ChoiceSetting weights` | Maximize probability × weight; omitted weights are 1, zero disables a label. Ties prefer the raw probability winner, then declaration order. |

Settings must match the declared domain. Probabilities must be finite and in
[0,1]; distributions need not sum to one. Noul confidence depends on the threshold;
Choice and Score confidence remains backend-reported. Retuning policy does not
re-estimate the probability evidence itself.

## Evaluate the decision you care about

Rich decision types include evidence in their equality. Using `exactMatch` can
therefore penalize a correct label whose probabilities differ from the expected
record. Project the answer into the task metric instead:

```haskell
import Shikumi.Eval qualified as Eval

urgentAccuracy :: Eval.Metric Assessment
urgentAccuracy expected predicted =
  Eval.boolScore
    (fst (answer expected) == fst (answer (Eval.primary predicted)))
```

Use representative labeled data and a metric that expresses your application's
tradeoff. A gate that escalates costly errors may need a different objective from
plain label accuracy.

## Fit and persist settings with ReAnchor

Inside your evaluation/optimization effect stack:

```haskell
import Shikumi.Compile (decodeCompiledOnto, encodeCompiled)
import Shikumi.Optimize (optimizeWith)
import Shikumi.Optimize.Execution
import Shikumi.Optimize.ReAnchor (defaultReAnchorConfig, reAnchor)

let controls = defaultRunConfig
      { runLimits = (runLimits defaultRunConfig) { candidateLimit = 2000 } }
(compiled, diagnostics) <-
  optimizeWith controls (reAnchor defaultReAnchorConfig) train urgentAccuracy assess
let bytes = encodeCompiled compiled
    restored = decodeCompiledOnto assess bytes
```

`train` is a nonempty `Dataset Ticket Assessment` of labeled examples. ReAnchor
keeps instructions and demonstrations fixed and searches rich decision fields,
including ordinary `predict` leaves. Every retained change must strictly improve
the training metric and pass deterministic held-out fold checks. Optional
validation data is report-only; keep independent test data for final assessment.

The first candidate executions record responses in a run-local store. Trials
reuse matching responses inside the shared operation-admission layer. A changed
upstream answer can produce a new downstream request, which consumes another
operation. Candidate limits still apply to replayed trials. An interrupted search
preserves settings already accepted. `reAnchorWith` exposes per-field evidence
ranges, fitted values, score summaries, and fold counters.

Compiled state stores the settings with the program's shape. Restore it onto the
matching Haskell template; it contains no executable closures. Older parameter
JSON without settings decodes with an empty map. See
[evaluation and optimization](evaluation-and-optimization.md#calibrating-decision-settings)
for the report and budget APIs.

## Cache, replay, and current limits

Decision probabilities are response content and can be cached or replayed. This
is separate from transport-call evidence requested through `Options.evidence`:
those requests bypass the response cache to establish a fresh provider crossing.
See [decision evidence and cache identity](caching-tracing-replay.md#decision-evidence-and-cache-identity).

Changing an existing decision setting does not change request identity. Opting a
plain Boolean or enum into evidence mode for the first time does change its schema;
rich decision types always request probability evidence. ReAnchor targets rich
decision fields and does not automatically promote plain Boolean or enum fields.

Decision streaming, nested decision containers, ReAct final submissions, and
recursive-session decision outputs are currently unsupported. The
[capability catalog](../capabilities/probability-backed-decisions.md) records the
shipped scope and links its acceptance tests.
