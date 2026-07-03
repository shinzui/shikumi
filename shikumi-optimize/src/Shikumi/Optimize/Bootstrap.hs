{-# LANGUAGE ScopedTypeVariables #-}

-- | M2 — bootstrap few-shot. Run a /teacher/ program over the training set, keep
-- the runs the metric judged correct, and attach those input/output pairs as
-- demonstrations to the /student/. This "bootstraps" high-quality demos from the
-- program's own successful behaviour (DSPy's @BootstrapFewShot@).
--
-- __Adapted to the delivered substrate.__ The plan envisioned recovering a demo
-- for every /internal/ node by reading EP-7's trace tree, keyed by a per-node
-- @NodePath@, via a @runProgramTraced@. The delivered EP-7
-- (@docs/plans/7-…replay.md@) records LM-call spans by opaque @SpanId@ with the
-- canonical-request and raw-response JSON, but provides neither a
-- @NodePath@↔program-node correlation nor a @runProgramTraced@, and the recorded
-- prompt is the rendered wire request, not the structured typed input. So this
-- plan recovers demos at the __program-I/O level__: a demo is the pair of the
-- example's input and the teacher's produced output ('recoverDemo'), and the kept
-- demos are attached to every node (the DSPy default for multi-module programs).
-- This is faithful to bootstrap's user-visible behaviour and is exactly what the
-- single-node acceptance test (M5) verifies; per-internal-node recovery waits on
-- EP-7/EP-4 exposing a node-correlated trace. See the plan's Decision Log.
module Shikumi.Optimize.Bootstrap
  ( bootstrapFewShot,
    bootstrapFewShotWith,
    bootstrapKeptDemos,
    BootstrapConfig (..),
    defaultBootstrapConfig,
    recoverDemo,
  )
where

import Data.Aeson (ToJSON, toJSON)
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, catchError)
import Effectful.Prim (Prim)
import GHC.Generics (Generic)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, Example (..), Metric, datasetExamples, prediction, unScore)
import Shikumi.LLM (LLM)
import Shikumi.Optimize.LabeledFewShot (withDemos)
import Shikumi.Optimize.Search (BudgetMeter, freezeProgram, newBudgetMeter, tryCharge)
import Shikumi.Optimize.Types (Budget (..), Optimizer (..))
import Shikumi.Program (Demo (..), Program, foldParams, runProgram)

-- | Tunables for a bootstrap search.
data BootstrapConfig = BootstrapConfig
  { -- | minimum metric score for a teacher run to contribute a demo (default
    -- @1.0@: keep only exactly-correct runs)
    passThreshold :: !Double,
    -- | cap on the demos attached, so prompts stay bounded (default @4@)
    maxBootstrappedDemos :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | Keep only perfectly-correct teacher runs; attach at most four demos.
defaultBootstrapConfig :: BootstrapConfig
defaultBootstrapConfig = BootstrapConfig {passThreshold = 1.0, maxBootstrappedDemos = 4}

-- | Recover a demonstration from one teacher run: pair the typed input with the
-- teacher's produced output, serialized to the JSON 'Demo' the run-time adapter
-- decodes back into the node's typed demo channel. (The JSON keys are the record
-- field names, so @fromModel@ round-trips them — see the unit test.)
recoverDemo :: (ToJSON i, ToJSON o) => i -> o -> Demo
recoverDemo i o = Demo {input = toJSON i, output = toJSON o}

-- | Bootstrap few-shot with the default configuration.
bootstrapFewShot :: (ToJSON i, ToJSON o) => Program i o -> Budget -> Optimizer i o
bootstrapFewShot = bootstrapFewShotWith defaultBootstrapConfig

-- | Bootstrap few-shot with an explicit configuration. The @teacher@ may be a
-- stronger or chain-of-thought variant of the student, or the student itself; it
-- must share the student's input/output types. Each teacher run reserves one
-- predicted LM completion per teacher predict node before it runs; when the next
-- teacher run does not fit the 'Budget', demo recovery stops and the demos found so
-- far are attached.
bootstrapFewShotWith ::
  (ToJSON i, ToJSON o) =>
  BootstrapConfig ->
  -- | teacher program whose successful runs supply demos
  Program i o ->
  Budget ->
  Optimizer i o
bootstrapFewShotWith cfg teacher budget = Optimizer $ \train metric student -> do
  meter <- newBudgetMeter budget
  kept <- bootstrapKeptDemos cfg meter teacher train metric
  pure (freezeProgram (withDemos kept student))

-- | Recover metric-passing demos from teacher runs under a shared budget meter.
bootstrapKeptDemos ::
  (ToJSON i, ToJSON o, LLM :> es, Error ShikumiError :> es, Prim :> es) =>
  BootstrapConfig ->
  BudgetMeter ->
  Program i o ->
  Dataset i o ->
  Metric o ->
  Eff es [Demo]
bootstrapKeptDemos cfg meter teacher train metric = do
  let teacherCost = max 1 (length (foldParams teacher))
      cap = max 0 (maxBootstrappedDemos cfg)
      keepIfPassing (Example inp expd) =
        ( do
            out <- runProgram teacher inp
            let s = unScore (metric expd (prediction out))
            pure [recoverDemo inp out | s >= passThreshold cfg]
        )
          `catchError` \_ (_ :: ShikumiError) -> pure []
      collect kept []
        | length kept >= cap = pure (take cap kept)
        | otherwise = pure kept
      collect kept (ex : rest)
        | length kept >= cap = pure (take cap kept)
        | otherwise = do
            fits <- tryCharge meter teacherCost
            if not fits
              then pure kept
              else do
                newKept <- keepIfPassing ex
                collect (kept ++ newKept) rest
  collect [] (datasetExamples train)
