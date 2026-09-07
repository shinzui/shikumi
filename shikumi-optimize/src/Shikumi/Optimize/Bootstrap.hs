{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Recover typed demonstrations from accepted teacher invocations, keyed by
-- student node. Composite programs require explicit capture codecs.
module Shikumi.Optimize.Bootstrap
  ( bootstrapFewShot,
    bootstrapFewShotWith,
    bootstrapKeptDemos,
    bootstrapNodeDemos,
    bootstrapDemosFor,
    withNodeDemos,
    NodeBootstrapConfig (..),
    defaultNodeBootstrapConfig,
    BootstrapReport (..),
    BootstrapConfig (..),
    defaultBootstrapConfig,
    recoverDemo,
  )
where

import Control.Monad (unless, when)
import Data.Aeson (ToJSON, Value (Bool), toJSON)
import Data.List (nub, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)
import Effectful.Prim (Prim)
import GHC.Generics (Generic)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval (Dataset, Example (..), Metric, datasetExamples, prediction, unScore)
import Shikumi.LLM (LLM)
import Shikumi.Optimize.Search (BudgetMeter, freezeProgram, newBudgetMeter, tryCharge)
import Shikumi.Optimize.Types (Budget (..), Optimizer (..))
import Shikumi.Program (CaptureCodec (..), Demo (..), Params (..), Program (..), ProgramShape (..), foldParams, mapParamsAt, programShape)
import Shikumi.Schema (FromModel, deriveSchema, fromModel)
import Shikumi.Schema.Types (fieldName, objectSchema)
import Shikumi.Signature (Signature, inputFields)
import Shikumi.Trace.Node (NodePath (..), programNodePaths, renderNodePath)
import Shikumi.Trace.Observation (NodeObservation (..), runProgramObserved)

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
  (kept, _) <- bootstrapDemosFor (defaultNodeBootstrapConfig {nodeBootstrapConfig = cfg}) meter teacher train metric student
  pure (freezeProgram (withNodeDemos kept student))

-- | Separate configuration keeps existing BootstrapConfig record construction
-- source compatible. Explicit mappings are teacher-to-student; omitted nodes
-- receive no recovered demos. Duplicate targets require explicit merge consent.
data NodeBootstrapConfig = NodeBootstrapConfig
  { nodeBootstrapConfig :: !BootstrapConfig,
    nodeMapping :: !(Maybe [(NodePath, NodePath)]),
    mergeTargetMappings :: !Bool,
    nodeSeed :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

defaultNodeBootstrapConfig :: NodeBootstrapConfig
defaultNodeBootstrapConfig = NodeBootstrapConfig defaultBootstrapConfig Nothing False Nothing

-- | Runtime rejection diagnostics, including metric failures and opaque limits.
newtype BootstrapReport = BootstrapReport {bootstrapDiagnostics :: [Text]}
  deriving stock (Eq, Show)

data LeafEvidence = LeafEvidence (Maybe (Value, Value)) (Demo -> Either ShikumiError ())

leafEvidence :: forall i o. (FromModel i, FromModel o) => Maybe (CaptureCodec i o) -> Signature i o -> LeafEvidence
leafEvidence codec _ = LeafEvidence ((\c -> (captureInputSchema c, captureOutputSchema c)) <$> codec) $ \(Demo i o) -> do
  _ <- (fromModel i :: Either ShikumiError i)
  _ <- (fromModel o :: Either ShikumiError o)
  pure ()

evidence :: Program i o -> [LeafEvidence]
evidence = go
  where
    go :: Program x y -> [LeafEvidence]
    go (Predict sig _) = [leafEvidence Nothing sig]
    go (PredictCaptured codec sig _) = [leafEvidence (Just codec) sig]
    go (Compose a b) = go a ++ go b
    go (FMap _ p) = go p
    go (Map _ p) = go p
    go (Parallel a b) = go a ++ go b
    go (Retry _ p) = go p
    go (RetryWhen _ _ p) = go p
    go (Validate _ p) = go p
    go (MajorityVote _ _ _ p) = go p
    go (Ensemble ps _) = concatMap go ps
    go (Embed _) = []

-- Opaque limits are reported even if no teacher invocation is necessary.
hasOpaque :: ProgramShape -> Bool
hasOpaque ShapeEmbed = True
hasOpaque (ShapePredict _) = False
hasOpaque (ShapeCompose a b) = hasOpaque a || hasOpaque b
hasOpaque (ShapeFMap p) = hasOpaque p
hasOpaque (ShapeMap _ p) = hasOpaque p
hasOpaque (ShapeParallel a b) = hasOpaque a || hasOpaque b
hasOpaque (ShapeRetry _ p) = hasOpaque p
hasOpaque (ShapeRetryWhen _ p) = hasOpaque p
hasOpaque (ShapeValidate p) = hasOpaque p
hasOpaque (ShapeMajorityVote _ _ p) = hasOpaque p
hasOpaque (ShapeEnsemble ps) = any hasOpaque ps

-- | Install only the pool addressed to each node, preserving template codecs.
withNodeDemos :: Map.Map NodePath [Demo] -> Program i o -> Program i o
withNodeDemos pools program = foldl install program (zip [0 ..] (programNodePaths program))
  where
    install p (idx, path) = mapParamsAt idx (\ps -> ps {demos = Map.findWithDefault [] path pools}) p

-- | Capture-capable entry point. Mapping/schema failures happen before budget
-- charges or LM calls; declared schemas are also checked by target decoding.
bootstrapNodeDemos ::
  (LLM :> es, Error ShikumiError :> es, Prim :> es) =>
  NodeBootstrapConfig ->
  BudgetMeter ->
  Program i o ->
  Dataset i o ->
  Metric o ->
  Program j k ->
  Eff es (Map.Map NodePath [Demo], BootstrapReport)
bootstrapNodeDemos cfg meter teacher train metric student = do
  let teachers = Map.fromList (zip (programNodePaths teacher) (evidence teacher))
      students = Map.fromList (zip (programNodePaths student) (evidence student))
      failWith = throwError . ValidationFailure
      settings = nodeBootstrapConfig cfg
      cap = max 0 (maxBootstrappedDemos settings)
  pairs <- case nodeMapping cfg of
    Just mappings -> pure mappings
    Nothing -> do
      unless (programShape teacher == programShape student) $
        failWith "bootstrap: different teacher/student structures require an explicit nodeMapping"
      pure [(p, p) | p <- Map.keys students]
  unless (mergeTargetMappings cfg || length (map snd pairs) == length (nub (map snd pairs))) $
    failWith "bootstrap: duplicate student targets require mergeTargetMappings"
  when (any (\(LeafEvidence schema _) -> isNothing schema) (Map.elems teachers ++ Map.elems students)) $
    failWith "bootstrap: composite programs require predictCaptured at every predictor (missing capture codec/schema)"
  mappings <-
    traverse
      ( \(src, dst) -> case (Map.lookup src teachers, Map.lookup dst students) of
          (Just (LeafEvidence (Just ts) _), Just (LeafEvidence (Just ss) decode))
            | ts == ss -> pure (src, dst, decode)
            | otherwise -> failWith ("bootstrap: incompatible schemas for " <> renderNodePath src <> " -> " <> renderNodePath dst)
          _ -> failWith "bootstrap: unknown mapping path or missing capture schema"
      )
      pairs
  let emptyPools = Map.fromList [(p, []) | p <- Map.keys students]
      recover (pools, notes) obs =
        foldl
          (attach obs)
          (pools, notes)
          [(dst, decode) | (src, dst, decode) <- mappings, src == observationPath obs]
      attach obs (pools, notes) (dst, decode)
        | not (observationEligible obs) = (pools, notes)
        | otherwise = case (observationInput obs, observationOutput obs) of
            (Just i, Just o) ->
              let demo = Demo i o
               in case decode demo of
                    Left err -> (pools, notes ++ ["bootstrap: rejected captured demo at " <> renderNodePath dst <> ": " <> T.pack (show err)])
                    Right () -> (Map.adjust (++ [demo]) dst pools, notes)
            _ -> (pools, notes ++ ["bootstrap: missing encoded invocation at " <> renderNodePath dst])
      full pools = all (\(_, dst, _) -> length (Map.findWithDefault [] dst pools) >= cap) mappings
      collect acc [] = pure acc
      collect acc@(pools, notes) (Example inp expd : rest)
        | null mappings || cap == 0 || (isNothing (nodeSeed cfg) && full pools) = pure acc
        | otherwise = do
            fits <- tryCharge meter (max 1 (length (foldParams teacher)))
            if not fits
              then pure acc
              else do
                (result, obs) <- runProgramObserved teacher inp
                let next = case result of
                      Left err -> (pools, notes ++ ["bootstrap: teacher example failed: " <> T.pack (show err)])
                      Right out | unScore (metric expd (prediction out)) >= passThreshold settings -> foldl recover (pools, notes) obs
                      Right _ -> (pools, notes ++ ["bootstrap: teacher example below metric threshold"])
                collect next rest
  let limits = ["bootstrap: Embed is opaque; internal predictors cannot supply demonstrations" | hasOpaque (programShape teacher) || hasOpaque (programShape student)]
  (pools, notes) <- collect (emptyPools, limits) (datasetExamples train)
  pure (Map.mapWithKey (select cap (nodeSeed cfg)) pools, BootstrapReport notes)

-- Independent, reproducible streams use the stable target path, never map index.
select :: Int -> Maybe Int -> NodePath -> [Demo] -> [Demo]
select cap Nothing _ = take cap
select cap (Just seed) path = take cap . map snd . sortOn fst . zip keys
  where
    start = T.foldl' (\n c -> (n * 131 + toInteger (fromEnum c)) `mod` 2147483648) (toInteger seed) (renderNodePath path)
    keys = drop 1 (iterate (\n -> (1103515245 * n + 12345) `mod` 2147483648) start)

-- | Legacy outer encoders apply only to a bare single prediction. Signature
-- field metadata supplies matching evidence for this same-typed compatibility
-- case; all composite programs use explicit CaptureCodec schema evidence.
bootstrapDemosFor ::
  (ToJSON i, ToJSON o, LLM :> es, Error ShikumiError :> es, Prim :> es) =>
  NodeBootstrapConfig ->
  BudgetMeter ->
  Program i o ->
  Dataset i o ->
  Metric o ->
  Program i o ->
  Eff es (Map.Map NodePath [Demo], BootstrapReport)
bootstrapDemosFor cfg meter teacher train metric student = case (teacher, student) of
  (Predict {}, Predict {}) -> bootstrapNodeDemos cfg meter (legacy teacher) train metric (legacy student)
  (Predict sig ps, PredictCaptured codec _ _) -> bootstrapNodeDemos cfg meter (PredictCaptured (codec {encodeCaptureInput = toJSON, encodeCaptureOutput = toJSON}) sig ps) train metric student
  (PredictCaptured codec _ _, Predict sig ps) -> bootstrapNodeDemos cfg meter teacher train metric (PredictCaptured (codec {encodeCaptureInput = toJSON, encodeCaptureOutput = toJSON}) sig ps)
  _ -> bootstrapNodeDemos cfg meter teacher train metric student
  where
    legacy :: forall x y. (ToJSON x, ToJSON y) => Program x y -> Program x y
    legacy (Predict sig ps) = PredictCaptured (CaptureCodec toJSON toJSON (objectSchema [(name, Bool True) | name <- map fieldName (inputFields sig)] (map fieldName (inputFields sig))) (deriveSchema @y)) sig ps
    legacy p = p

-- | Compatibility pool of outer input/output demos, for a bare single predictor
-- only. Composite callers must migrate to bootstrapNodeDemos/bootstrapDemosFor.
bootstrapKeptDemos ::
  (ToJSON i, ToJSON o, LLM :> es, Error ShikumiError :> es, Prim :> es) =>
  BootstrapConfig -> BudgetMeter -> Program i o -> Dataset i o -> Metric o -> Eff es [Demo]
bootstrapKeptDemos cfg meter teacher train metric = case teacher of
  Predict {} -> recover teacher
  PredictCaptured _ sig ps -> recover (Predict sig ps)
  _ -> throwError (ValidationFailure "bootstrapKeptDemos: composite programs require node-local bootstrapDemosFor")
  where
    recover outerTeacher = do
      (pools, _) <- bootstrapDemosFor (defaultNodeBootstrapConfig {nodeBootstrapConfig = cfg}) meter outerTeacher train metric outerTeacher
      pure (Map.findWithDefault [] (NodePath []) pools)
