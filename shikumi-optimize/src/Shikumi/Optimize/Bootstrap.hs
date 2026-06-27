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
    BootstrapConfig (..),
    defaultBootstrapConfig,
    recoverDemo,
  )
where

import Data.Aeson (ToJSON, toJSON)
import Effectful.Error.Static (catchError)
import GHC.Generics (Generic)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Example (..), datasetExamples, prediction, unScore)
import Shikumi.Optimize.LabeledFewShot (withDemos)
import Shikumi.Optimize.Search (freezeProgram)
import Shikumi.Optimize.Types (Budget (..), Optimizer (..))
import Shikumi.Program (Demo (..), Program, runProgram)

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
-- must share the student's input/output types.
bootstrapFewShotWith ::
  (ToJSON i, ToJSON o) =>
  BootstrapConfig ->
  -- | teacher program whose successful runs supply demos
  Program i o ->
  Budget ->
  Optimizer i o
bootstrapFewShotWith cfg teacher budget = Optimizer $ \train metric student -> do
  -- Bound the number of teacher runs by the budget (each run is >= 1 LM call).
  let exs = take (max 0 (maxLmCalls budget)) (datasetExamples train)
      -- Run the teacher on one example; if it succeeds and the metric passes,
      -- emit its recovered demo, else emit nothing. Recovery is total: a teacher
      -- error yields no demo rather than aborting the search.
      keepIfPassing (Example inp expd) =
        ( do
            out <- runProgram teacher inp
            let s = unScore (metric expd (prediction out))
            pure [recoverDemo inp out | s >= passThreshold cfg]
        )
          `catchError` \_ (_ :: ShikumiError) -> pure []
  kept <- concat <$> mapM keepIfPassing exs
  pure (freezeProgram (withDemos (take (maxBootstrappedDemos cfg) kept) student))
