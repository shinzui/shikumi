module AttemptEvidenceSpec (tests) where

import Baikai qualified as B
import Baikai.Error qualified as BE
import Baikai.Evidence qualified as E
import Control.Concurrent.MVar
import Control.Exception (throwIO, try)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (void)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Concurrent.Async (cancel, wait, waitCatch, withAsync)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Shikumi.Error
import Shikumi.LLM qualified as L
import Shikumi.LLM.Budget (newBudget)
import Shikumi.LLM.Defaults
import Shikumi.LLM.Evidence
import Shikumi.LLM.Observation qualified as O
import Shikumi.Program (Program (Compose, Embed, Parallel), retryWith, runProgram, runProgramConc)
import StubProvider
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit

transient :: BE.BaikaiError
transient = (BE.providerError "fixture failure") {BE.category = BE.TransientError}

opts :: B.Options
opts = stubOptions & #evidence .~ Just (E.evidenceRequest "run" & #attempt .~ 4 & #supersedes .~ Just "before")

invoke :: Bool -> B.Options -> Eff '[L.LLM, Error ShikumiError, Concurrent, IOE] ()
invoke streaming o = if streaming then void (L.stream stubModel stubContext o) else void (L.complete stubModel stubContext o)

config :: B.ProviderRegistry -> L.LLMConfig
config reg = (L.defaultLLMConfig reg) {L.retryPolicy = L.RetryPolicy 3 0 0}

record :: (IOE :> es) => IORef [AttemptReceipt] -> EvidenceObserver es
record ref receipt = liftIO (atomicModifyIORef' ref (\xs -> (xs ++ [receipt], ())))

runCall :: EvidenceObserver '[Error ShikumiError, Concurrent, IOE] -> L.LLMConfig -> Eff '[L.LLM, Error ShikumiError, Concurrent, IOE] a -> IO (Either ShikumiError a)
runCall observe cfg action = runEff . runConcurrent . runErrorNoCallStack @ShikumiError . L.runLLMResilientWithEvidence observe cfg $ action

bounded :: IO a -> IO a
bounded action = timeout 3000000 action >>= maybe (assertFailure "test timeout") pure

tests :: TestTree
tests =
  testGroup "AttemptEvidence" $
    [ testGroup
        (if streaming then "Stream" else "Complete")
        [ testCase "retry acknowledges exact records and preserves caller provenance" $ do
            calls <- newIORef []
            receipts <- newIORef []
            reg <- evidenceStubRegistry calls 1 transient
            result <- runCall (record receipts) (config reg) (invoke streaming opts)
            result @?= Right ()
            sent <- readIORef calls
            rs <- readIORef receipts
            map attemptOrdinal rs @?= [1, 2]
            case rs of
              [a, b] -> do
                logicalCallId a @?= logicalCallId b
                evidence a ^. #attempt @?= 4
                evidence b ^. #attempt @?= 5
                evidence b ^. #supersedes @?= Just (evidence a ^. #callId)
                map ((^. #runId) . evidence) rs @?= ["run", "run"]
                evidence a ^. #supersedes @?= Just "before"
                (sent !! 1) ^. #evidence @?= Just (E.evidenceRequest "run" & #attempt .~ 5 & #supersedes .~ Just (evidence a ^. #callId))
                map callKind rs @?= replicate 2 (if streaming then O.StreamCall else O.CompletionCall)
              _ -> assertFailure (show rs),
          testCase "terminal failure is acknowledged before it is raised" $ do
            calls <- newIORef []
            receipts <- newIORef []
            let err = BE.invalidRequest "terminal"
            reg <- evidenceStubRegistry calls 10 err
            result <- runCall (record receipts) (config reg) (invoke streaming opts)
            result @?= Left (fromBaikaiError err)
            readIORef receipts >>= \rs -> map ((^. #status) . evidence) rs @?= [E.CallFailed],
          testCase "acknowledgement blocks return and the next dispatch" $ bounded $ do
            calls <- newIORef []
            reg <- evidenceStubRegistry calls 1 transient
            entered <- newEmptyMVar
            release <- newEmptyMVar
            result <- runEff
              . runConcurrent
              . runErrorNoCallStack @ShikumiError
              . L.runLLMResilientWithEvidence (\r -> if attemptOrdinal r == 1 then liftIO (putMVar entered () >> takeMVar release) else pure ()) (config reg)
              $ withAsync (invoke streaming opts)
              $ \worker -> do
                liftIO (takeMVar entered)
                liftIO (readIORef calls >>= \xs -> length xs @?= 1)
                liftIO (putMVar release ())
                wait worker
            result @?= Right (),
          testCase "successful acknowledgement blocks typed return" $ bounded $ do
            calls <- newIORef []
            reg <- evidenceStubRegistry calls 0 transient
            entered <- newEmptyMVar
            release <- newEmptyMVar
            returned <- newIORef False
            result <- runEff
              . runConcurrent
              . runErrorNoCallStack @ShikumiError
              . L.runLLMResilientWithEvidence (\_ -> liftIO (putMVar entered () >> takeMVar release)) (config reg)
              $ withAsync (invoke streaming opts >> liftIO (writeIORef returned True))
              $ \worker -> do
                liftIO (takeMVar entered >> readIORef returned >>= (@?= False))
                liftIO (putMVar release ())
                wait worker
            result @?= Right (),
          testCase "typed observer failure escapes both retry layers" $ do
            calls <- newIORef []
            reg <- evidenceStubRegistry calls 0 transient
            result <-
              try @EvidenceObserverFailed $
                runCall
                  (\_ -> throwError (ProviderFailure "persist failed"))
                  (config reg)
                  (retryWith (\_ () -> invoke streaming opts) (const True) 3 (Embed (\() -> pure ())) ())
            assertBool "observer exception" (case result of Left _ -> True; _ -> False)
            readIORef calls >>= \xs -> length xs @?= 1,
          testCase "observer exception after failed attempt never retries" $ do
            calls <- newIORef []
            reg <- evidenceStubRegistry calls 1 transient
            result <- try @BE.BaikaiError $ runCall (\_ -> liftIO (throwIO transient)) (config reg) (invoke streaming opts)
            result @?= Left transient
            readIORef calls >>= \xs -> length xs @?= 1,
          testCase "no evidence request means identical options and no receipts" $ do
            calls <- newIORef []
            receipts <- newIORef []
            reg <- evidenceStubRegistry calls 1 transient
            runCall (record receipts) (config reg) (invoke streaming stubOptions) >>= (@?= Right ())
            readIORef calls >>= (@?= [stubOptions, stubOptions])
            readIORef receipts >>= (@?= []),
          testCase "budget refusal creates neither dispatch nor receipt" $ do
            calls <- newIORef []
            receipts <- newIORef []
            reg <- evidenceStubRegistry calls 0 transient
            budget <- newBudget (Just 0)
            result <- runCall (record receipts) ((config reg) {L.budget = Just budget}) (invoke streaming opts)
            assertBool "refused" (case result of Left BudgetExceeded {} -> True; _ -> False)
            readIORef calls >>= (@?= [])
            readIORef receipts >>= (@?= []),
          testCase "bare runner acknowledges the same record" $ do
            calls <- newIORef []
            receipts <- newIORef []
            reg <- evidenceStubRegistry calls 0 transient
            result <- runEff . runConcurrent . runErrorNoCallStack @ShikumiError . L.runLLMWithEvidence reg O.noObservation (record receipts) $ invoke streaming opts
            result @?= Right ()
            readIORef receipts >>= \rs -> map attemptOrdinal rs @?= [1],
          testCase "strict refusal delivers a real record with zero provider invocations" $ do
            calls <- newIORef []
            receipts <- newIORef []
            reg <- evidenceStubRegistry calls 0 transient
            let strict = opts & #evidence .~ Just (E.evidenceRequest "strict" & #strictness .~ E.EvidenceRequired E.EvidenceModelObserved)
            result <- runCall (record receipts) (config reg) (invoke streaming strict)
            assertBool "refused" (case result of Left _ -> True; _ -> False)
            readIORef calls >>= (@?= [])
            readIORef receipts >>= \rs -> length rs @?= 1,
          testCase "billing settles before evidence acknowledgement" $ do
            calls <- newIORef []
            reg <- evidenceStubRegistry calls 0 transient
            (billing, snapshot) <- O.newBillingCollector
            result <- runCall (\_ -> liftIO (snapshot >>= \s -> O.completedAttempts s @?= 1)) ((config reg) {L.observer = Just billing}) (invoke streaming opts)
            result @?= Right (),
          testCase "cancelled rate-limit waiter never dispatches or emits a receipt" $ bounded $ do
            calls <- newIORef []
            receipts <- newIORef []
            reg <- evidenceStubRegistry calls 0 transient
            limiter <- L.newRateLimiter 0
            result <- runEff
              . runConcurrent
              . runErrorNoCallStack @ShikumiError
              . L.runLLMResilientWithEvidence (record receipts) ((config reg) {L.rateLimit = Just limiter})
              $ withAsync (invoke streaming opts)
              $ \worker -> cancel worker >> waitCatch worker
            assertBool "cancelled" (case result of Right (Left _) -> True; _ -> False)
            readIORef calls >>= (@?= [])
            readIORef receipts >>= (@?= []),
          testCase "concurrent programs keep retry provenance isolated" $ do
            calls <- newIORef []
            receipts <- newIORef []
            reg <- evidenceStubRegistry calls 1 transient
            let leaf = Embed (\() -> void (L.complete stubModel stubContext opts))
            result <- runCall (record receipts) (config reg) (runProgramConc (Parallel leaf leaf) ())
            result @?= Right ((), ())
            rs <- readIORef receipts
            let groups = foldr (\r -> Map.insertWith (++) (logicalCallId r) [r]) Map.empty rs
            Map.size groups @?= 2
            mapM_
              ( \group -> case group of
                  [a, b] -> evidence b ^. #supersedes @?= Just (evidence a ^. #callId)
                  [_] -> pure ()
                  _ -> assertFailure (show group)
              )
              (Map.elems groups),
          testCase "Compose mints a distinct run for each operation" $ do
            calls <- newIORef []
            reg <- evidenceStubRegistry calls 0 transient
            count <- newIORef (0 :: Int)
            let mint = liftIO (atomicModifyIORef' count (\n -> (n + 1, if n == 0 then "first" else "second")))
                leaf = Embed (\() -> void (L.complete stubModel stubContext stubOptions))
            result <-
              runCall (const (pure ())) (config reg) . withEvidenceRuns E.EvidenceBestEffort mint $
                runProgram (Compose leaf leaf) ()
            result @?= Right ()
            readIORef calls >>= \xs -> map (fmap (^. #runId) . (^. #evidence)) xs @?= [Just "first", Just "second"],
          testCase "per-operation run minting survives retries and honors explicit requests" $ do
            calls <- newIORef []
            reg <- evidenceStubRegistry calls 1 transient
            minted <- newIORef (0 :: Int)
            let mint = liftIO (atomicModifyIORef' minted (\n -> (n + 1, if n == 0 then "first" else "second")))
            result <- runCall (const (pure ())) (config reg) . withEvidenceRuns E.EvidenceBestEffort mint $ do
              invoke streaming stubOptions
              invoke streaming stubOptions
              invoke streaming opts
            result @?= Right ()
            readIORef calls >>= \xs -> map (fmap (^. #runId) . (^. #evidence)) xs @?= map Just ["first", "first", "second", "run"]
            readIORef minted >>= (@?= 2)
        ]
    | streaming <- [False, True]
    ]
      ++ [ testCase "strict thrown transport failure fails closed without retry" $ do
             calls <- newIORef 0
             reg <- failingStubRegistry calls 10 "ok"
             let strict = opts & #evidence .~ Just (E.evidenceRequest "strict" & #strictness .~ E.EvidenceRequired E.EvidenceRequestedOnly)
             result <- runCall (const (pure ())) (config reg) (invoke False strict)
             assertBool "terminal validation failure" (case result of Left ValidationFailure {} -> True; _ -> False)
             readIORef calls >>= (@?= 1)
         ]
