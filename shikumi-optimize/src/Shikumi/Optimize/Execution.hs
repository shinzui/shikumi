{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Shared execution and accounting, independent of any mutation strategy.
module Shikumi.Optimize.Execution
  ( RunLimits (..),
    RunConfig (..),
    defaultRunConfig,
    validateRunConfig,
    SearchSession,
    CandidateId,
    sessionLimits,
    runSearchSession,
    markLegacy,
    setSelection,
    sessionStopped,
    canStartCandidate,
    addPredictedWork,
    reserveCandidate,
    annotateCandidate,
    remainingCandidates,
    evaluateCandidate,
    evaluateCandidates,
    ObjectiveMetric,
    ExampleMeasurement (..),
    scalarObjectives,
  )
where

import Control.Monad (forM, unless, when)
import Data.Aeson (FromJSON, ToJSON)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Effectful (Eff, Effect, (:>))
import Effectful.Concurrent (Concurrent, ThreadId, myThreadId)
import Effectful.Concurrent.Async (mapConcurrently)
import Effectful.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Error.Static (Error, throwError)
import Effectful.Exception qualified as E
import Effectful.Prim.IORef (IORef, Prim, atomicModifyIORef', newIORef, readIORef)
import GHC.Generics (Generic)
import Shikumi.Effect.Time (Time, getMonotonicTimeNSec)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval (Dataset, Example (..), Metric, datasetExamples, datasetSize, prediction, unScore)
import Shikumi.Eval.Evaluate (scoreExecution, tryShikumi)
import Shikumi.Eval.Report (FailurePolicy (..))
import Shikumi.Eval.Usage (withUsageTotals)
import Shikumi.LLM (LLM (..), complete, stream)
import Shikumi.Optimize.Feedback (EvaluationEvidence (..))
import Shikumi.Optimize.Report
import Shikumi.Trace.Observation (NodeObservation)

-- | Serializable controls; the executable observer is deliberately separate.
data RunLimits = RunLimits
  { operationLimit :: !Int,
    candidateLimit :: !Int,
    evaluationConcurrency :: !Int,
    deterministicSeed :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data RunConfig = RunConfig
  { runLimits :: !RunLimits,
    eventSink :: forall es. (Concurrent :> es, Prim :> es) => OptimizationEvent -> Eff es ()
  }

defaultRunConfig :: RunConfig
defaultRunConfig = RunConfig (RunLimits 200 32 1 1) (const (pure ()))

validateRunConfig :: RunConfig -> Either ShikumiError ()
validateRunConfig cfg =
  unless
    (operationLimit l >= 0 && candidateLimit l >= 0 && evaluationConcurrency l > 0)
    (Left (ValidationFailure "execution limits must be nonnegative, concurrency positive"))
  where
    l = runLimits cfg

data SearchSession (es :: [Effect]) = SearchSession
  { config :: !RunConfig,
    state :: !(IORef OptimizationReport),
    reserved :: !(IORef Int),
    operationCollectors :: !(IORef (Map.Map ThreadId [IORef Int])),
    startedCandidates :: !(IORef (Set.Set Int)),
    stopped :: !(IORef Bool),
    dispatchPermits :: !QSem,
    observerLock :: !QSem
  }

-- | An opaque reservation tied to exactly one run. It cannot be forged from a
-- report's numeric ID, reused, or transferred to another session.
data CandidateId = CandidateId !(IORef Int) !Int deriving stock (Eq)

sessionLimits :: SearchSession es -> RunLimits
sessionLimits = runLimits . config

modifyReport :: (Prim :> es) => SearchSession es -> (OptimizationReport -> OptimizationReport) -> Eff es ()
modifyReport s f = atomicModifyIORef' (state s) (\r -> (f r, ()))

emit :: (Concurrent :> es, Prim :> es) => SearchSession es -> EventKind -> Eff es ()
emit s kind = E.bracket_ (waitQSem (observerLock s)) (signalQSem (observerLock s)) $ do
  ev <- atomicModifyIORef' (state s) $ \r ->
    let e = OptimizationEvent (length (events r)) kind in (r {events = events r ++ [e]}, e)
  eventSink (config s) ev `E.catchSync` \_ -> modifyReport s (\r -> r {observerFailures = observerFailures r + 1})

sessionStopped :: (Prim :> es) => SearchSession es -> Eff es Bool
sessionStopped = readIORef . stopped

stop :: (Prim :> es) => SearchSession es -> Eff es ()
stop s = atomicModifyIORef' (stopped s) (const (True, ()))

-- | The action's typed error is returned alongside diagnostics. Cancellation and
-- host exceptions propagate after terminal bookkeeping; observers are best effort.
runSearchSession ::
  forall es a.
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Prim :> es) =>
  RunConfig -> (SearchSession es -> Eff es a) -> Eff es (Either ShikumiError a, OptimizationReport)
runSearchSession cfg action = do
  either throwError pure (validateRunConfig cfg)
  ref <- newIORef (OptimizationReport 1 Completed 0 0 (Map.fromList [("operationLimit", operationLimit (runLimits cfg)), ("candidateLimit", candidateLimit (runLimits cfg)), ("evaluationConcurrency", evaluationConcurrency (runLimits cfg)), ("deterministicSeed", deterministicSeed (runLimits cfg))]) Nothing [] Map.empty [] [] Nothing (Just Unscored) "Unscored baseline" True "unspecified" 0 [])
  count <- newIORef 0
  started <- newIORef Set.empty
  collectors <- newIORef Map.empty
  halted <- newIORef False
  terminal <- newIORef False
  permits <- newQSem (evaluationConcurrency (runLimits cfg))
  lock <- newQSem 1
  let s = SearchSession cfg ref count collectors started halted permits lock
      finish status = do
        first <- atomicModifyIORef' terminal (\done -> (True, not done))
        when first $ do
          when (status == BudgetStopped) (emit s BudgetStop)
          allocated <- readIORef count
          startedIds <- readIORef started
          modifyReport s (\r -> r {runStatus = status, candidates = sortOn candidateId (candidates r), unexecutedReservations = [ix | ix <- [0 .. allocated - 1], Set.notMember ix startedIds]})
          emit s (RunFinished status)
      dispatch :: forall x. Eff es x -> Eff es x
      dispatch op = E.bracket_ (waitQSem (dispatchPermits s)) (signalQSem (dispatchPermits s)) $ E.mask $ \restore -> do
        admitted <- atomicModifyIORef' ref $ \r ->
          if admittedOperations r < operationLimit (runLimits cfg)
            then (r {admittedOperations = admittedOperations r + 1}, True)
            else (r, False)
        unless admitted (stop s >> throwError (BudgetExceeded "optimizer operation admission exhausted"))
        tid <- myThreadId
        localCollectors <- Map.findWithDefault [] tid <$> readIORef collectors
        mapM_ (\counter -> atomicModifyIORef' counter (\n -> (n + 1, ()))) localCollectors
        restore op

  result <-
    ( do
        emit s RunStarted
        when (operationLimit (runLimits cfg) == 0 || candidateLimit (runLimits cfg) == 0) (stop s)
        outcome <-
          tryShikumi $
            interpose
              ( \_ -> \case
                  Complete m c o -> dispatch (complete m c o)
                  Stream m c o -> dispatch (stream m c o)
              )
              (action s)
        exhausted <- sessionStopped s
        current <- readIORef ref
        let onlyFailures = not (null (candidates current)) && all ((== CandidateFailed) . candidateStatus) (candidates current)
        finish
          ( case outcome of
              Left e
                | exhausted && e == BudgetExceeded "optimizer operation admission exhausted" -> BudgetStopped
                | otherwise -> Failed
              Right _
                | exhausted || runStatus current == BudgetStopped -> BudgetStopped
                | onlyFailures -> Failed
                | otherwise -> Completed
          )
        pure outcome
    )
      `E.withException` (\(e :: E.SomeException) -> finish (if E.isAsyncException e then Cancelled else Failed))
  report <- readIORef ref
  pure (result, report)

markLegacy :: (Prim :> es) => SearchSession es -> Eff es ()
markLegacy s = modifyReport s (\r -> r {candidateDetailAvailable = False, resultStatus = Nothing, selectionReason = "Opaque legacy optimizer; candidate details unavailable", validationMode = "legacy optimizer controlled"})

setSelection :: (Prim :> es) => SearchSession es -> Text -> ObjectivePolicy -> Eff es ()
setSelection s mode policy = modifyReport s $ \r ->
  let winner = selectObjectiveWinner policy (candidates r)
   in r
        { frontier = map candidateId (objectiveFrontier policy (candidates r)),
          selectedCandidate = candidateId <$> winner,
          resultStatus = Just (maybe Unscored (const CandidateCompleted) winner),
          selectionReason = maybe "Unscored baseline: no eligible completed candidate" (const ("Pareto frontier; primary objective " <> primaryObjective policy <> "; ordered ties; creation order")) winner,
          reportedPolicy = Just policy,
          validationMode = mode
        }

addPredictedWork :: (Prim :> es) => SearchSession es -> Int -> Eff es ()
addPredictedWork s n = modifyReport s (\r -> r {predictedWork = predictedWork r + max 0 n})

-- | Unreserved candidate slots in this session.
remainingCandidates :: (Prim :> es) => SearchSession es -> Eff es Int
remainingCandidates s = (\n -> max 0 (candidateLimit (sessionLimits s) - n)) <$> readIORef (reserved s)

-- | Reserve IDs in scheduling order before spawning any workers.
reserveCandidate :: (Prim :> es) => SearchSession es -> Eff es (Maybe CandidateId)
reserveCandidate s = do
  halted <- sessionStopped s
  if halted
    then pure Nothing
    else do
      ix <- atomicModifyIORef' (reserved s) $ \n -> if n < candidateLimit (sessionLimits s) then (n + 1, Just n) else (n, Nothing)
      when (ix == Nothing) (modifyReport s (\r -> r {runStatus = BudgetStopped}))
      pure (CandidateId (reserved s) <$> ix)

data ExampleMeasurement o = ExampleMeasurement
  {evidence :: !(EvaluationEvidence o), operations :: !Int, latencySeconds :: !Double}
  deriving stock (Eq, Show)

type ObjectiveMetric es o = o -> ExampleMeasurement o -> Eff es ObjectiveValues

scalarObjectives :: (Applicative m) => Metric o -> o -> ExampleMeasurement o -> m ObjectiveValues
scalarObjectives metric expected measured = pure $ Map.singleton "quality" $ case executionResult (evidence measured) of
  Left _ -> 0
  Right out -> unScore (metric expected (prediction out))

-- | All validation positions are required. The runner preserves root errors and
-- observations; isolated collectors measure each example, including nested calls.
evaluateCandidate ::
  forall es i o.
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  SearchSession es ->
  CandidateId ->
  Dataset i o ->
  (i -> Eff es (Either ShikumiError o, [NodeObservation])) ->
  (ShikumiError -> FailurePolicy) ->
  Metric o ->
  ObjectivePolicy ->
  ObjectiveMetric es o ->
  Eff es CandidateReport
evaluateCandidate s (CandidateId owner ident) ds runner classify metric policy objective = E.mask $ \restore -> do
  unless (owner == reserved s) (throwError (ValidationFailure "candidate reservation belongs to another session"))
  fresh <- atomicModifyIORef' (startedCandidates s) (\seen -> (Set.insert ident seen, Set.notMember ident seen))
  unless fresh (throwError (ValidationFailure "candidate reservation has already executed"))
  rowsRef <- newIORef []
  calls <- newIORef 0
  ended <- newIORef False
  let finish status reason = do
        first <- atomicModifyIORef' ended (\b -> (True, not b))
        rows <- reverse <$> readIORef rowsRef
        n <- readIORef calls
        let aggregates = aggregateObjectives policy [vs | (_, _, vs) <- rows]
            report = CandidateReport ident status (datasetSize ds) (length rows) [(ix, sc) | (ix, sc, _) <- rows] (either (const Map.empty) id aggregates) n reason
        when first $ do
          modifyReport s (\r -> r {candidates = report : candidates r})
          emit s (CandidateEnded ident status)
        pure report
      -- Register the collector for this dispatch, including inherited handlers
      -- in child threads. Only the admission boundary increments it: waiting,
      -- denied and cancelled-before-admission calls are never counted.
      counted :: forall x. Eff es x -> Eff es x
      counted op = do
        tid <- myThreadId
        E.bracket_
          (atomicModifyIORef' (operationCollectors s) (\m -> (Map.insertWith (++) tid [calls] m, ())))
          (atomicModifyIORef' (operationCollectors s) (\m -> (Map.update (\xs -> case drop 1 xs of [] -> Nothing; rest -> Just rest) tid m, ())))
          op
      count act =
        interpose
          ( \_ -> \case
              Complete m c o -> counted (complete m c o)
              Stream m c o -> counted (stream m c o)
          )
          act
      body = forM (zip [0 ..] (datasetExamples ds)) $ \(ix, Example inp expected) -> do
        before <- readIORef calls
        start <- getMonotonicTimeNSec
        ((out, obs), usage) <- withUsageTotals (count (runner inp))
        end <- getMonotonicTimeNSec
        after <- readIORef calls
        let ev = EvaluationEvidence ix out obs usage
            failurePolicy BudgetExceeded {} = FailAbort
            failurePolicy e = classify e
        (_, (score, _)) <- scoreExecution failurePolicy executionResult (pure ev) (pure . metric expected . prediction)
        vs <- objective expected (ExampleMeasurement ev (after - before) (fromIntegral (end - start) / 1e9))
        exhausted <- sessionStopped s
        unless exhausted $ atomicModifyIORef' rowsRef (\rows -> ((ix, unScore score, vs) : rows, ()))
        when exhausted (throwError (BudgetExceeded "optimizer operation admission exhausted"))
  outcome <- (emit s (CandidateStarted ident) >> restore (tryShikumi body)) `E.onException` (finish CandidateIncomplete (Just "execution interrupted") >> pure ())
  halted <- sessionStopped s
  case outcome of
    Left e
      | halted && e == BudgetExceeded "optimizer operation admission exhausted" -> finish CandidateIncomplete (Just "operation budget exhausted")
      | otherwise -> do
          r <- finish CandidateFailed (Just "typed execution failure")
          case e of
            BudgetExceeded {} -> throwError e
            _ -> case classify e of FailAbort -> throwError e; _ -> pure r
    Right _ | halted -> finish CandidateIncomplete (Just "operation budget exhausted")
    Right _ -> do
      rows <- readIORef rowsRef
      case aggregateObjectives policy [vs | (_, _, vs) <- rows] of
        Left reason -> finish CandidateFailed (Just reason)
        Right _ -> finish CandidateCompleted Nothing

-- | Finite batches bound candidate jobs; examples within each job are sequential.
-- The independent dispatch semaphore also bounds nested Program/Embed concurrency.
evaluateCandidates :: (Concurrent :> es) => SearchSession es -> (a -> Eff es b) -> [a] -> Eff es [b]
evaluateCandidates s f = go
  where
    go [] = pure []
    go xs = do
      let (batch, rest) = splitAt (evaluationConcurrency (sessionLimits s)) xs
      done <- mapConcurrently f batch
      (done ++) <$> go rest

-- | Attach caller-owned non-sensitive identity before starting a candidate.
annotateCandidate :: (Concurrent :> es, Prim :> es, Error ShikumiError :> es) => SearchSession es -> CandidateId -> Map.Map Text Text -> Eff es ()
annotateCandidate s (CandidateId owner ident) metadata = do
  unless (owner == reserved s) (throwError (ValidationFailure "candidate reservation belongs to another session"))
  modifyReport s (\r -> r {candidateMetadata = Map.insert ident metadata (candidateMetadata r)})
  emit s (CandidateMetadata ident metadata)

-- | Check operation capacity before starting another scheduled candidate.
-- Completed candidates are unaffected when the last slot was used exactly.
canStartCandidate :: (Prim :> es) => SearchSession es -> Eff es Bool
canStartCandidate s = do
  halted <- sessionStopped s
  current <- readIORef (state s)
  let available = not halted && admittedOperations current < operationLimit (sessionLimits s)
  unless available (modifyReport s (\r -> r {runStatus = BudgetStopped}))
  pure available
