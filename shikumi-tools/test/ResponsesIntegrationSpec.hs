module ResponsesIntegrationSpec (tests) where

import Baikai qualified as B
import Baikai.Error qualified as BE
import Control.Concurrent (forkFinally, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.IORef
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Concurrent (runConcurrent)
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Effectful.Prim (runPrim)
import Shikumi.Agent.History qualified as H
import Shikumi.Agent.ReAct qualified as R
import Shikumi.Cache (cachedLLM)
import Shikumi.Cache.Backend.Memory (newMemoryCache, runCacheMemory)
import Shikumi.Compaction (CompactionConfig (..))
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM qualified as L
import Shikumi.LLM.Defaults
import Shikumi.LLM.Observation qualified as O
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Testing.Fixtures (Answer (..), Question (..), instructedSig)
import Shikumi.Testing.Responses
import Shikumi.Tool qualified as Tool
import Shikumi.Tool.Output (textToolOutput)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit

cfg :: R.ReActConfig
cfg = R.defaultReActConfig {R.protocol = R.ProtocolNative, R.maxIters = 3, R.compaction = CompactionConfig 0 4 False}

tools :: Tool.ToolRegistry
tools =
  Tool.mkRegistry
    [ Tool.mkDynTool "lookup" "Return the stored city." (object ["type" .= String "object", "properties" .= object []]) $ \_ -> do
        _ <- L.complete B.emptyModel (B.emptyContext & #systemPrompt .~ Just "local-lookup") B.emptyOptions
        pure (Right (textToolOutput "Paris"))
    ]

-- Count actual body entries via a local effect handler; it never dispatches HTTP.
countLookup :: (L.LLM :> es, IOE :> es) => IORef Int -> Eff es a -> Eff es a
countLookup ref = interpose $ \_ -> \case
  L.Complete _ c _ | c ^. #systemPrompt == Just "local-lookup" -> do
    liftIO (atomicModifyIORef' ref (\n -> (n + 1, ())))
    pure B.emptyResponse
  L.Complete m c o -> L.complete m c o
  L.Stream m c o -> L.stream m c o

firstReply :: Reply
firstReply = sseReply [completed [reasoningItem, functionItem "item-lookup" "call-lookup" "lookup" (object [])]]

lastReply :: Reply
lastReply = sseReply [completed [functionItem "item-final" "call-final" R.finalToolName (object ["answer" .= String "Paris", "confidence" .= (0.9 :: Double)])]]

restore :: H.ReActSession -> Either String H.ReActSession
restore s = eitherDecode (encode (H.encodeSession s)) >>= either (Left . show) Right . H.decodeSession

tests :: TestTree
tests =
  testGroup
    "Responses sessions"
    [ testCase "real reasoning and tool IDs survive checkpoint bytes with one dispatch" $
        withResponsesFixture [firstReply, lastReply] $ \f -> do
          ref <- newIORef 0
          result <- runEff
            . runErrorNoCallStack @ShikumiError
            . runRouting (model f)
            . L.runLLMWith (registry f)
            . withTransportOptions fixtureOptions
            . withRequestDefaults (emptyRequestDefaults {defaultThinking = Just B.ThinkingHigh})
            . routeLLM
            . countLookup ref
            $ do
              initial <- R.startSessionWithModel (model f) instructedSig tools cfg (Question "Look up the city.")
              step <- R.advanceSession instructedSig tools cfg initial
              checkpoint <- case step of R.SessionPaused s -> pure s; _ -> throwError (ValidationFailure "expected checkpoint")
              saved <- either (throwError . ValidationFailure . T.pack) pure (restore checkpoint)
              resumed <- R.continueSession instructedSig tools cfg (Question "Submit the answer.") saved
              finished <- R.runSession instructedSig tools cfg resumed
              pure (checkpoint, saved, finished)
          case result of
            Right (before, saved, R.SessionFinished answer _) -> do
              before @?= saved
              answer @?= Answer "Paris" 0.9
              assertBool "unsafe compaction fails" (either (const True) (const False) (H.compactSession 1 "summary" saved))
            other -> assertFailure (show other)
          readIORef ref >>= (@?= 1)
          bodies <- requests f
          length bodies @?= 2
          case bodies of
            [_, Object second] -> case KM.lookup "input" second of
              Just (Array items) -> do
                assertBool "opaque reasoning item is byte-structurally intact" (reasoningItem `elem` V.toList items)
                let typed kind = [o | Object o <- V.toList items, KM.lookup "type" o == Just (String kind)]
                map (KM.lookup "call_id") (typed "function_call") @?= [Just (String "call-lookup")]
                map (KM.lookup "call_id") (typed "function_call_output") @?= [Just (String "call-lookup")]
                let kinds = [KM.lookup "type" o | Object o <- V.toList items]
                assertBool "call precedes result" (V.findIndex (== Just (String "function_call")) (V.fromList kinds) < V.findIndex (== Just (String "function_call_output")) (V.fromList kinds))
              _ -> assertFailure "missing wire input"
            _ -> assertFailure "wrong request count",
      testCase "wrong routed model and API fail before a second HTTP request" $
        withResponsesFixture [firstReply] $ \f -> do
          ref <- newIORef 0
          initial <- runEff
            . runErrorNoCallStack @ShikumiError
            . runRouting (model f)
            . L.runLLMWith (registry f)
            . withTransportOptions fixtureOptions
            . routeLLM
            . countLookup ref
            $ do
              s <- R.startSessionWithModel (model f) instructedSig tools cfg (Question "lookup")
              R.advanceSession instructedSig tools cfg s
          case initial of
            Right (R.SessionPaused checkpoint) ->
              mapM_
                ( \wrong -> do
                    result <-
                      runEff
                        . runErrorNoCallStack @ShikumiError
                        . runRouting wrong
                        . L.runLLMWith (registry f)
                        . withTransportOptions fixtureOptions
                        . routeLLM
                        $ R.advanceSession instructedSig tools cfg checkpoint
                    assertBool "origin rejected" (case result of Left (ValidationFailure _) -> True; _ -> False)
                )
                [model f & #modelId .~ "wrong-model", model f & #api .~ B.OpenAIChatCompletions]
            other -> assertFailure (show other)
          requests f >>= (\xs -> length xs @?= 1)
          readIORef ref >>= (@?= 1),
      testCase "released refusal error is terminal; transient transport retries are observed" $ do
        withResponsesFixture [sseReply [failureFrame "content_filter"]] $ \f -> do
          (observe, snapshot) <- O.newBillingCollectorWithLimit 4
          let policy = (L.defaultLLMConfig (registry f)) {L.observer = Just observe, L.retryPolicy = L.RetryPolicy 3 0 0}
          result <-
            runEff . runConcurrent . runErrorNoCallStack @ShikumiError . L.runLLMResilient policy $
              L.complete (model f) B.emptyContext fixtureOptions
          case result of
            Left (ProviderError e) -> BE.category e @?= BE.OtherError
            other -> assertFailure (show other)
          requests f >>= (\xs -> length xs @?= 1)
          snapshot >>= (\s -> O.failedAttempts s @?= 1)
        withResponsesFixture [Reply 500 [] 0, sseReply [completed [messageItem "ok"]]] $ \f -> do
          (observe, snapshot) <- O.newBillingCollectorWithLimit 4
          let policy = (L.defaultLLMConfig (registry f)) {L.observer = Just observe, L.retryPolicy = L.RetryPolicy 2 0 0}
          result <-
            runEff . runConcurrent . runErrorNoCallStack @ShikumiError . L.runLLMResilient policy $
              L.complete (model f) B.emptyContext fixtureOptions
          assertBool "retry succeeds" (either (const False) (const True) result)
          summary <- snapshot
          map O.attempt (O.retainedAttempts summary) @?= [1, 2]
          O.completedAttempts summary @?= 1
          O.failedAttempts summary @?= 1,
      testCase "cache hit adds no released transport attempt" $
        withResponsesFixture [sseReply [completed [messageItem "ok"]]] $ \f -> do
          cache <- newMemoryCache
          (observe, snapshot) <- O.newBillingCollectorWithLimit 4
          let policy = (L.defaultLLMConfig (registry f)) {L.observer = Just observe}
          result <- runEff
            . runPrim
            . runTime
            . runConcurrent
            . runErrorNoCallStack @ShikumiError
            . runCacheMemory cache
            . L.runLLMResilient policy
            . cachedLLM
            $ do
              _ <- L.complete (model f) B.emptyContext fixtureOptions
              _ <- L.complete (model f) B.emptyContext fixtureOptions
              pure ()
          result @?= Right ()
          requests f >>= (\xs -> length xs @?= 1)
          snapshot >>= (\s -> O.completedAttempts s @?= 1),
      testCase "timeout and cancellation release loopback workers" $ do
        cleanup <- withResponsesFixture [Reply 200 [completed [messageItem "late"]] 2000000] $ \f -> do
          result <-
            runEff . runErrorNoCallStack @ShikumiError . L.runLLMWith (registry f) $
              L.complete (model f) B.emptyContext (fixtureOptions & #timeoutMs .~ Just 50)
          assertBool "transport timeout fails" (either (const True) (const False) result)
          pure (activeRequests f)
        drained <- timeout 2000000 (waitForZero cleanup)
        drained @?= Just ()
        cleanup2 <- withResponsesFixture [Reply 200 [completed [messageItem "late"]] 2000000] $ \f -> do
          done <- newEmptyMVar
          tid <-
            forkFinally
              ( runEff . runErrorNoCallStack @ShikumiError . L.runLLMWith (registry f) $
                  L.complete (model f) B.emptyContext (fixtureOptions & #timeoutMs .~ Just 5000)
              )
              (putMVar done)
          entered <- timeout 2000000 (waitForActive (activeRequests f))
          killThread tid
          outcome <- takeMVar done
          assertBool "cancellation propagates from the released adapter" (either (const True) (const False) outcome)
          entered @?= Just ()
          pure (activeRequests f)
        drained2 <- timeout 2000000 (waitForZero cleanup2)
        drained2 @?= Just ()
    ]

waitForZero :: IO Int -> IO ()
waitForZero readCount = readCount >>= \n -> if n == 0 then pure () else threadDelay 1000 >> waitForZero readCount

waitForActive :: IO Int -> IO ()
waitForActive readCount = readCount >>= \n -> if n > 0 then pure () else threadDelay 1000 >> waitForActive readCount
