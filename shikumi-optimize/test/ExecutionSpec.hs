{-# LANGUAGE TypeApplications #-}

module ExecutionSpec (tests) where

import Control.Monad (forM, replicateM_)
import Data.Aeson (eitherDecode, encode)
import Data.Either (isLeft)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Concurrent.Async (cancel, mapConcurrently, waitCatch, withAsync)
import Effectful.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Error.Static (Error, catchError, runErrorNoCallStack, throwError)
import Effectful.Exception qualified as E
import Effectful.Prim (Prim, runPrim)
import Effectful.Prim.IORef qualified as Ref
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval (Dataset, FailurePolicy, Metric, dataset, exactMatch, example, scoreZero)
import Shikumi.LLM (LLM (..), complete, stream)
import Shikumi.Optimize (Optimizer (..), freezeProgram, fromLegacyOptimizer, optimizeWith)
import Shikumi.Optimize.Execution
import Shikumi.Optimize.Feedback (candidateFailurePolicy)
import Shikumi.Optimize.Report
import Shikumi.Program (embed, runProgram)
import Shikumi.Trace.Observation (NodeObservation, runProgramObserved)
import StubLM (Label (..), Sentence (..), runGepaStubLM, sentimentProg)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

run :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
run act = runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runGepaStubLM act

cfg :: Int -> Int -> RunConfig
cfg cap width = defaultRunConfig {runLimits = RunLimits cap 8 width 1}

tests :: TestTree
tests =
  testGroup
    "Execution"
    [ testCase "invalid controls reject without dispatch" $ do
        r <- run (runSearchSession (cfg (-1) 1) (const (pure ())))
        assertBool "invalid" (isLeft r),
      testCase "caught budget error cannot admit cap+1" $ do
        r <- run $ runSearchSession (cfg 2 1) $ \_ ->
          replicateM_ 8 $
            (runProgram sentimentProg (Sentence "good") >> pure ()) `catchError` \_ (_ :: ShikumiError) -> pure ()
        check r $ \(_, report) -> do
          admittedOperations report @?= 2
          runStatus report @?= BudgetStopped
          last (map eventKind (events report)) @?= RunFinished BudgetStopped
          eitherDecode (encode report) @?= Right report
          assertBool "future report version rejected" (isLeft (eitherDecode (encode report {reportVersion = 2}) :: Either String OptimizationReport)),
      testCase "opaque optimizer and zero cap" $ do
        r <- run $ optimizeWith (cfg 0 1) (fromLegacyOptimizer (Optimizer $ \_ _ p -> runProgram p (Sentence "good") >> pure (freezeProgram p))) ds exactMatch sentimentProg
        check r $ \(_, report) -> do
          admittedOperations report @?= 0
          resultStatus report @?= Just Unscored,
      testCase "opaque optimizer interrupted mid-run returns explicitly unscored baseline" $ do
        let legacy = Optimizer $ \_ _ p -> do
              _ <- runProgram p (Sentence "good")
              _ <- runProgram p (Sentence "bad")
              pure (freezeProgram p)
        r <- run $ optimizeWith (cfg 1 1) (fromLegacyOptimizer legacy) ds exactMatch sentimentProg
        check r $ \(_, report) -> do
          admittedOperations report @?= 1
          candidateDetailAvailable report @?= False
          resultStatus report @?= Just Unscored,
      testCase "mid candidate stop is incomplete" $ do
        r <- run $ runSearchSession (cfg 1 1) $ \s ->
          evaluateFresh
            s
            ds
            (runProgramObserved sentimentProg)
            (candidateFailurePolicy scoreZero)
            exactMatch
            qualityPolicy
            (scalarObjectives exactMatch)
        check r $ \(_, report) -> do
          map candidateStatus (candidates report) @?= [CandidateIncomplete]
          map completedExamples (candidates report) @?= [1]
          map candidateOperations (candidates report) @?= [1]
          admittedOperations report @?= 1,
      testCase "concurrent final-slot race obeys ceiling and ordered reports" $ do
        r <- run $ runSearchSession (cfg 3 4) $ \s -> do
          ids <- forM [0 .. 3 :: Int] (const (reserveCandidate s))
          evaluateCandidates
            s
            ( \ix ->
                evaluateCandidate
                  s
                  ix
                  ds
                  (runProgramObserved sentimentProg)
                  (candidateFailurePolicy scoreZero)
                  exactMatch
                  qualityPolicy
                  (scalarObjectives exactMatch)
            )
            [ix | Just ix <- ids]
        check r $ \(_, report) -> do
          admittedOperations report @?= 3
          sum (map candidateOperations (candidates report)) @?= 3
          map candidateId (candidates report) @?= [0, 1, 2, 3]
          length [() | OptimizationEvent _ (CandidateEnded _ _) <- events report] @?= 4,
      testCase "observer exception isolated" $ do
        let observer = (cfg 8 1) {eventSink = \_ -> E.throwIO (userError "observer unavailable")}
        r <- run $ runSearchSession observer (const (pure ()))
        check r $ \(_, report) -> do
          runStatus report @?= Completed
          observerFailures report @?= 2,
      testCase "barriers prove dispatch width and reversed completion" $ do
        r <- run $ do
          gate <- newEmptyMVar
          active <- Ref.newIORef (0 :: Int, 0 :: Int, 0 :: Int)
          let provider op =
                E.bracket
                  (Ref.atomicModifyIORef' active (\(n, high, total) -> ((n + 1, max high (n + 1), total + 1), total)))
                  (\_ -> Ref.atomicModifyIORef' active (\(n, high, total) -> ((n - 1, high, total), ())))
                  ( \ordinal -> do
                      if even ordinal then takeMVar gate else putMVar gate ()
                      op
                  )
          result <- interpose
            ( \_ -> \case
                Complete m c o -> provider (complete m c o)
                Stream m c o -> stream m c o
            )
            $ runSearchSession (cfg 8 2)
            $ \s -> do
              ids <- forM [0 .. 3 :: Int] (const (reserveCandidate s))
              evaluateCandidates
                s
                ( \ix ->
                    evaluateCandidate
                      s
                      ix
                      (dataset [example (Sentence "good") (Label "positive")])
                      (runProgramObserved sentimentProg)
                      (candidateFailurePolicy scoreZero)
                      exactMatch
                      qualityPolicy
                      (scalarObjectives exactMatch)
                )
                [ix | Just ix <- ids]
          counts <- Ref.readIORef active
          pure (result, counts)
        check r $ \((_, report), (active, high, total)) -> do
          active @?= 0
          high @?= 2
          total @?= 4
          map candidateId (candidates report) @?= [0, 1, 2, 3]
          map candidateStatus (candidates report) @?= replicate 4 CandidateCompleted,
      testCase "cancellation closes candidate and run and propagates" $ do
        r <- run $ do
          gate <- newEmptyMVar
          blocked <- newEmptyMVar
          observed <- Ref.newIORef []
          let controls = (cfg 8 1) {eventSink = \event -> Ref.atomicModifyIORef' observed (\xs -> (xs ++ [event], ()))}
          result <- withAsync
            ( runSearchSession controls $ \s ->
                evaluateFresh
                  s
                  ds
                  (\inp -> putMVar gate () >> takeMVar blocked >> runProgramObserved sentimentProg inp)
                  (candidateFailurePolicy scoreZero)
                  exactMatch
                  qualityPolicy
                  (scalarObjectives exactMatch)
            )
            $ \worker -> do
              takeMVar gate
              cancel worker
              waitCatch worker
          evs <- Ref.readIORef observed
          pure (isLeft result, evs)
        check r $ \(cancelled, evs) -> do
          assertBool "cancellation propagated" cancelled
          length [() | OptimizationEvent _ (CandidateEnded 0 CandidateIncomplete) <- evs] @?= 1
          length [() | OptimizationEvent _ (RunFinished Cancelled) <- evs] @?= 1,
      testCase "stream and completion share admission" $ do
        r <- run $ runSearchSession (cfg 1 1) $ \_ ->
          interpose
            ( \_ -> \case
                Complete m c o -> stream m c o >> complete m c o
                Stream m c o -> stream m c o
            )
            (runProgram sentimentProg (Sentence "good"))
        check r $ \(_, report) -> do
          admittedOperations report @?= 1
          runStatus report @?= BudgetStopped,
      testCase "failed admitted operations are never refunded" $ do
        r <- run
          $ interpose
            ( \_ -> \case
                Complete {} -> throwError (ProviderFailure "fixture transport failed")
                Stream m c o -> stream m c o
            )
          $ runSearchSession (cfg 2 1)
          $ \_ ->
            replicateM_ 5 $
              (runProgram sentimentProg (Sentence "good") >> pure ()) `catchError` \_ (_ :: ShikumiError) -> pure ()
        check r $ \(_, report) -> admittedOperations report @?= 2,
      testCase "caught stop cannot turn a candidate into completed success" $ do
        r <- run $ runSearchSession (cfg 1 1) $ \s ->
          evaluateFresh
            s
            ds
            ( \inp -> do
                replicateM_ 3 $ (runProgram sentimentProg inp >> pure ()) `catchError` \_ (_ :: ShikumiError) -> pure ()
                pure (Right (Label "positive"), [])
            )
            (candidateFailurePolicy scoreZero)
            exactMatch
            qualityPolicy
            (scalarObjectives exactMatch)
        check r $ \(_, report) -> do
          map candidateStatus (candidates report) @?= [CandidateIncomplete]
          map completedExamples (candidates report) @?= [0],
      testCase "reserved IDs execute once and unused reservations are reported" $ do
        r <- run $ runSearchSession (cfg 8 1) $ \s -> do
          first <- reserveCandidate s
          _ <- reserveCandidate s
          case first of
            Nothing -> throwError (ValidationFailure "missing test reservation")
            Just ident -> do
              let evaluate =
                    evaluateCandidate
                      s
                      ident
                      ds
                      (runProgramObserved sentimentProg)
                      (candidateFailurePolicy scoreZero)
                      exactMatch
                      qualityPolicy
                      (scalarObjectives exactMatch)
              _ <- evaluate
              evaluate
        check r $ \(out, report) -> do
          assertBool "reuse rejected" (isLeft out)
          length (candidates report) @?= 1
          unexecutedReservations report @?= [1],
      testCase "Embed bodies share the operation ceiling" $ do
        r <- run $ runSearchSession (cfg 1 1) $ \_ ->
          runProgram
            (embed (\inp -> runProgram sentimentProg inp >> runProgram sentimentProg inp))
            (Sentence "good")
        check r $ \(_, report) -> do
          admittedOperations report @?= 1
          runStatus report @?= BudgetStopped,
      testCase "nested concurrent runner counts only admitted operations" $ do
        r <- run $ runSearchSession (cfg 2 2) $ \s ->
          evaluateFresh
            s
            (dataset [example (Sentence "good") (Label "positive")])
            ( \inp -> do
                rows <- mapConcurrently (const (runProgramObserved sentimentProg inp)) [1 .. 4 :: Int]
                case rows of
                  row : _ -> pure row
                  [] -> throwError (ValidationFailure "missing nested test rows")
            )
            (candidateFailurePolicy scoreZero)
            exactMatch
            qualityPolicy
            (scalarObjectives exactMatch)
        check r $ \(_, report) -> do
          admittedOperations report @?= 2
          map candidateOperations (candidates report) @?= [2]
          map candidateStatus (candidates report) @?= [CandidateIncomplete],
      testCase "caller BudgetExceeded remains failure" $ do
        r <- run $ runSearchSession (cfg 8 1) (\_ -> throwError (BudgetExceeded "caller") :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] ())
        check r $ \(out, report) -> do
          out @?= Left (BudgetExceeded "caller")
          runStatus report @?= Failed
    ]
  where
    ds = dataset [example (Sentence "good") (Label "positive"), example (Sentence "bad") (Label "negative")]
    check (Left e) _ = assertFailure (show e)
    check (Right x) f = f x

evaluateFresh ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  SearchSession es ->
  Dataset i o ->
  (i -> Eff es (Either ShikumiError o, [NodeObservation])) ->
  (ShikumiError -> FailurePolicy) ->
  Metric o ->
  ObjectivePolicy ->
  ObjectiveMetric es o ->
  Eff es CandidateReport
evaluateFresh s ds runner classifier metric policy objective = do
  ident <- reserveCandidate s
  case ident of
    Nothing -> throwError (ValidationFailure "test exhausted candidate reservations")
    Just ix -> evaluateCandidate s ix ds runner classifier metric policy objective
