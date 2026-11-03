module SystemOneIntegrationSpec (tests) where

import Baikai qualified as B
import Baikai.Evidence qualified as E
import Control.Concurrent.MVar
import Control.Exception (IOException, throwIO, try)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Effectful (Eff, liftIO, runEff, (:>))
import Effectful.Concurrent (runConcurrent)
import Effectful.Concurrent.Async (cancel, wait, waitCatch, withAsync)
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Shikumi.Adapter (stampTemperature)
import Shikumi.Decision
import Shikumi.Decision.Setting
import Shikumi.Error
import Shikumi.LLM qualified as L
import Shikumi.LLM.Defaults
import Shikumi.LLM.Evidence
import Shikumi.Program
import Shikumi.Routing
import Shikumi.Schema (field, unField)
import Shikumi.Stream
import Shikumi.Testing.DecisionFixtures
import Shikumi.Testing.Fixtures qualified as F
import Shikumi.Testing.Responses (fixtureOptions, withTransportOptions)
import Shikumi.Testing.StubLLM (captureLLMRequests)
import Shikumi.Testing.SystemOne
import Test.Tasty
import Test.Tasty.HUnit

reply :: Value
reply =
  object
    [ "model" .= String "jev-latest",
      "usage" .= object ["input_tokens" .= (10 :: Int), "output_tokens" .= (3 :: Int)],
      "answers"
        .= object
          [ "urgent" .= object ["type" .= String "noul", "noul" .= (0.83 :: Double)],
            "severity" .= object ["type" .= String "score", "probabilities" .= object ["0" .= (0.1 :: Double), "1" .= (0.3 :: Double), "2" .= (0.6 :: Double)], "score" .= (1.5 :: Double), "confidence" .= (0.55 :: Double), "legend" .= object ["0" .= String "Minor", "1" .= String "Disruptive", "2" .= String "Blocking"]],
            "category" .= object ["type" .= String "choice", "probabilities" .= object ["billing" .= (0.2 :: Double), "technical" .= (0.8 :: Double)], "choice" .= String "technical", "confidence" .= (0.65 :: Double)]
          ]
    ]

tests :: TestTree
tests =
  testGroup
    "SystemOne"
    [ lifecycleTests,
      testCase "complete and stream retain raw answers and wire bytes under local calibration" $
        withSystemOneFixture reply $ \model registry requests -> do
          raw <- newIORef []
          events <- newIORef []
          outgoing <- newIORef []
          let retain = interpose $ \_ -> \case
                L.Complete m c o -> do
                  r <- L.complete m c o
                  liftIO (modifyIORef' raw (++ [r ^. #message . #content]))
                  pure r
                L.Stream m c o -> do
                  es <- L.stream m c o
                  liftIO (map eventTag es @?= ["start", "data-start", "data-end", "done"])
                  r <- either (error . show) pure (responseFromEvents m es)
                  liftIO (modifyIORef' raw (++ [r ^. #message . #content]))
                  pure es
              defaults = emptyRequestDefaults {defaultThinking = Just B.ThinkingHigh, defaultMaxTokens = Just 100}
              params =
                setDecisionSetting "urgent" (NoulSetting 0.9)
                  . setDecisionSetting "category" (ChoiceSetting (Map.fromList [("billing", 5), ("technical", 1)]))
                  . setDecisionSetting "severity" (ScoreSetting [0.5, 1.6])
                  $ emptyParams
              execute streamed ps =
                runEff
                  . runErrorNoCallStack @ShikumiError
                  . runRouting model
                  . L.runLLMWith registry
                  . captureLLMRequests outgoing
                  . withTransportOptions fixtureOptions
                  . retain
                  . withRequestDefaults defaults
                  . routeLLM
                  $ if streamed
                    then streamProgram (Predict assessmentSig ps) (Ticket (field "x")) (\e -> liftIO (modifyIORef' events (++ [e])))
                    else runProgram (Predict assessmentSig ps) (Ticket (field "x"))
          normal <- execute False emptyParams
          execute True emptyParams >>= (@?= normal)
          calibrated <- execute False params
          execute True params >>= (@?= calibrated)
          case calibrated of
            Right (Assessment u s c) -> do
              case unField u of Noul value p _ -> do value @?= False; p @?= 0.83
              case unField s of Score value level _ _ -> do value @?= 1.5; level @?= 1
              case unField c of Choice value _ _ -> value @?= Billing
            Left err -> assertFailure (show err)
          readIORef raw >>= assertFourEqual "unchanged raw answers"
          requests >>= assertFourEqual "identical wire requests"
          readIORef events >>= \xs -> length [() | StreamFieldChunk _ <- xs] @?= 0
          readIORef outgoing >>= mapM_ (\(_, _, o) -> do Map.null (o ^. #metadata) @?= True; o ^. #maxTokens @?= Nothing; o ^. #thinking @?= Nothing),
      testCase "program callback exceptions stop before dispatch or after acknowledged completion" $
        mapM_
          ( \failPhase -> withSystemOneFixture reply $ \model registry requests -> do
              receipts <- newIORef []
              result <-
                try @IOException
                  $ runEff
                    . runConcurrent
                    . runErrorNoCallStack @ShikumiError
                    . runRouting model
                    . L.runLLMResilientWithEvidence (\r -> liftIO (modifyIORef' receipts (++ [r]))) (L.defaultLLMConfig registry)
                    . withTransportOptions fixtureOptions
                    . withEvidenceRuns E.EvidenceBestEffort (pure "callback")
                    . routeLLM
                  $ streamProgram
                    (Predict assessmentSig emptyParams)
                    (Ticket (field "x"))
                    ( \case
                        StreamStatus status | phase status == failPhase -> liftIO (throwIO (userError "callback failed"))
                        _ -> pure ()
                    )
              assertBool "callback failure" (case result of Left _ -> True; _ -> False)
              requests >>= \xs -> length xs @?= (if failPhase == LmStart then 0 else 1)
              readIORef receipts >>= \xs -> length xs @?= (if failPhase == LmStart then 0 else 1)
          )
          [LmStart, LmEnd],
      testCase "released provider sends state and criteria; defaults exempt" $
        withSystemOneFixture reply $ \model registry requests -> do
          let defaults = emptyRequestDefaults {defaultThinking = Just B.ThinkingHigh, defaultMaxTokens = Just 100}
          result <-
            runEff . runErrorNoCallStack @ShikumiError . runRouting model . L.runLLMWith registry . withTransportOptions fixtureOptions . withRequestDefaults defaults . routeLLM $
              runProgram (Predict assessmentSig emptyParams) (Ticket (field "Checkout is unavailable."))
          case result of
            Right (Assessment u s c) -> do
              case unField u of Noul value p _ -> do value @?= True; p @?= 0.83
              case unField s of Score value level _ confidence -> do value @?= 1.5; level @?= 2; confidence @?= Just 0.55
              case unField c of Choice value _ confidence -> do value @?= Technical; confidence @?= Just 0.65
            Left err -> assertFailure (show err)
          bodies <- requests
          bodies @?= [object ["model" .= String "jev-latest", "state" .= renderDecisionState assessmentSig (Ticket (field "Checkout is unavailable.")), "questions" .= Map.fromList [(judgmentField j, questionJSON j) | j <- judgmentsOf @Assessment]]],
      testCase "explicit temperature is terminal with zero HTTP requests" $
        withSystemOneFixture reply $ \model registry requests -> do
          result <-
            runEff . runErrorNoCallStack @ShikumiError . runRouting model . L.runLLMWith registry . withTransportOptions fixtureOptions . routeLLM . interpose (\_ -> \case L.Complete m c o -> L.complete m c (stampTemperature 0.7 o); L.Stream m c o -> L.stream m c o) $
              runProgram (Predict assessmentSig emptyParams) (Ticket (field "x"))
          assertBool "terminal refusal" (case result of Left (SchemaMismatch msg) -> "temperature" `T.isInfixOf` msg; _ -> False)
          requests >>= (@?= []),
      testCase "missing wire evidence or undeclared answers fail after one HTTP request" $ do
        let modifyAnswer name f = modifyObject "answers" (adjust (\case Object o -> Object (f o); v -> v) name) reply
            malformed = [modifyAnswer "category" (KM.delete "confidence"), modifyAnswer "severity" (KM.delete "score"), modifyAnswer "severity" (KM.delete "legend"), modifyObject "answers" (KM.insert "unexpected" (object ["type" .= String "noul", "noul" .= (0.5 :: Double)])) reply]
        mapM_
          ( \(streaming, bad) -> withSystemOneFixture bad $ \model registry requests -> do
              result <-
                runEff . runErrorNoCallStack @ShikumiError . runRouting model . L.runLLMWith registry . withTransportOptions fixtureOptions . routeLLM $
                  execute streaming emptyParams
              assertBool "terminal InvalidJSON" (case result of Left (InvalidJSON _) -> True; _ -> False)
              requests >>= (\xs -> length xs @?= 1)
          )
          [(streaming, bad) | streaming <- [False, True], bad <- malformed]
    ]

adjust :: (a -> a) -> Key -> KM.KeyMap a -> KM.KeyMap a
adjust f k o = maybe o (\v -> KM.insert k (f v) o) (KM.lookup k o)

modifyObject :: Key -> (KM.KeyMap Value -> KM.KeyMap Value) -> Value -> Value
modifyObject key f (Object fields) = Object (adjust (\case Object o -> Object (f o); v -> v) key fields)
modifyObject _ _ v = v

-- Real-provider lifecycle tests run both operations through the same transport.
lifecycleTests :: TestTree
lifecycleTests =
  testGroup
    "Lifecycle"
    [ testGroup
        (if streaming then "Stream" else "Complete")
        [ testCase "retry receipts settle before next HTTP request and success return" $
            withSystemOneScript [SystemOneReply 503 (object []) (pure ()), SystemOneReply 200 reply (pure ())] $ \model registry requests -> do
              receipts <- newIORef []
              entered <- newEmptyMVar
              release <- newEmptyMVar
              let observe r = do
                    liftIO (modifyIORef' receipts (++ [r]))
                    liftIO (putMVar entered (attemptOrdinal r) >> takeMVar release)
                  cfg = (L.defaultLLMConfig registry) {L.retryPolicy = L.RetryPolicy 2 0 0}
              result <- runEff
                . runConcurrent
                . runErrorNoCallStack @ShikumiError
                . runRouting model
                . L.runLLMResilientWithEvidence observe cfg
                . withTransportOptions fixtureOptions
                . withEvidenceRuns E.EvidenceBestEffort (pure "logical-run")
                . routeLLM
                $ withAsync (execute streaming emptyParams)
                $ \worker -> do
                  liftIO (takeMVar entered >>= (@?= 1))
                  liftIO (requests >>= \xs -> length xs @?= 1)
                  liftIO (putMVar release ())
                  liftIO (takeMVar entered >>= (@?= 2))
                  liftIO (requests >>= \xs -> length xs @?= 2)
                  liftIO (putMVar release ())
                  wait worker
              assertBool "typed success" (either (const False) (const True) result)
              readIORef receipts >>= \case
                [a, b] -> do
                  logicalCallId a @?= logicalCallId b
                  map attemptOrdinal [a, b] @?= [1, 2]
                  evidence b ^. #attempt @?= 2
                  evidence b ^. #supersedes @?= Just (evidence a ^. #callId)
                  map ((^. #runId) . evidence) [a, b] @?= ["logical-run", "logical-run"]
                rs -> assertFailure (show rs),
          testCase "observer alone preserves wire bytes and emits no receipt" $
            withSystemOneFixture reply $ \model registry requests -> do
              receipts <- newIORef []
              let run observe =
                    runEff
                      . runConcurrent
                      . runErrorNoCallStack @ShikumiError
                      . runRouting model
                      . L.runLLMResilientWithEvidence observe (L.defaultLLMConfig registry)
                      . withTransportOptions fixtureOptions
                      . routeLLM
                      $ execute streaming emptyParams
              a <- run (const (pure ()))
              run (\r -> liftIO (modifyIORef' receipts (++ [r]))) >>= (@?= a)
              readIORef receipts >>= (@?= [])
              requests >>= \case [a, b] -> a @?= b; _ -> assertFailure "expected two requests",
          testCase "strict refusal returns one record before HTTP" $
            withSystemOneFixture reply $ \model registry requests -> do
              receipts <- newIORef []
              result <-
                runEff
                  . runConcurrent
                  . runErrorNoCallStack @ShikumiError
                  . runRouting model
                  . L.runLLMResilientWithEvidence (\r -> liftIO (modifyIORef' receipts (++ [r]))) (L.defaultLLMConfig registry)
                  . withTransportOptions fixtureOptions
                  . withEvidenceRuns (E.EvidenceRequired E.EvidenceFullyObserved) (pure "strict")
                  . routeLLM
                  $ execute streaming emptyParams
              assertBool "refused" (case result of Left _ -> True; _ -> False)
              requests >>= (@?= [])
              readIORef receipts >>= \rs -> length rs @?= 1,
          testCase "cancellation after HTTP arrival joins without a result or fabricated receipt" $ do
            arrived <- newEmptyMVar
            never <- newEmptyMVar
            withSystemOneScript [SystemOneReply 200 reply (putMVar arrived () >> takeMVar never)] $ \model registry requests -> do
              receipts <- newIORef []
              result <- runEff
                . runConcurrent
                . runErrorNoCallStack @ShikumiError
                . runRouting model
                . L.runLLMResilientWithEvidence (\r -> liftIO (modifyIORef' receipts (++ [r]))) (L.defaultLLMConfig registry)
                . withTransportOptions fixtureOptions
                . withEvidenceRuns E.EvidenceBestEffort (pure "cancel")
                . routeLLM
                $ withAsync (execute streaming emptyParams)
                $ \worker -> do
                  liftIO (takeMVar arrived)
                  cancel worker
                  waitCatch worker
              assertBool "cancelled worker" (case result of Right (Left _) -> True; _ -> False)
              requests >>= \xs -> length xs @?= 1
              readIORef receipts >>= (@?= []),
          testCase "evidence observer failures on success and failure never redispatch" $
            mapM_
              ( \failed -> withSystemOneScript [SystemOneReply (if failed then 503 else 200) reply (pure ())] $ \model registry requests -> do
                  let observer _ = throwError (ProviderFailure "persist failed")
                  result <-
                    try @EvidenceObserverFailed
                      $ runEff
                        . runConcurrent
                        . runErrorNoCallStack @ShikumiError
                        . runRouting model
                        . L.runLLMResilientWithEvidence observer (L.defaultLLMConfig registry)
                        . withTransportOptions fixtureOptions
                        . withEvidenceRuns E.EvidenceBestEffort (pure "failure")
                        . routeLLM
                      $ retryWith (\_ _ -> execute streaming emptyParams) (const True) 3 (Predict assessmentSig emptyParams) (Ticket (field "x"))
                  assertBool "observer failure" (case result of Left _ -> True; _ -> False)
                  requests >>= \xs -> length xs @?= 1
              )
              [False, True],
          testCase "billing observer failure never redispatches" $
            withSystemOneFixture reply $ \model registry requests -> do
              let cfg = (L.defaultLLMConfig registry) {L.observer = Just (\_ -> throwIO (userError "billing failed"))}
              result <-
                try @IOException
                  $ runEff
                    . runConcurrent
                    . runErrorNoCallStack @ShikumiError
                    . runRouting model
                    . L.runLLMResilient cfg
                    . withTransportOptions fixtureOptions
                    . routeLLM
                  $ execute streaming emptyParams
              assertBool "billing failed" (case result of Left _ -> True; _ -> False)
              requests >>= \xs -> length xs @?= 1,
          testCase "generation controls and free-form judgment outputs refuse before HTTP" $
            withSystemOneFixture reply $ \model registry requests -> do
              let setControls = interpose $ \_ -> \case
                    L.Complete m c o -> L.complete m c (o & #temperature .~ Just 0.7)
                    L.Stream m c o -> L.stream m c (o & #temperature .~ Just 0.7)
              badControl <-
                runEff
                  . runErrorNoCallStack @ShikumiError
                  . runRouting model
                  . L.runLLMWith registry
                  . withTransportOptions fixtureOptions
                  . setControls
                  . routeLLM
                  $ execute streaming emptyParams
              assertBool "generation refusal" (case badControl of Left SchemaMismatch {} -> True; _ -> False)
              freeform <-
                runEff
                  . runErrorNoCallStack @ShikumiError
                  . runRouting model
                  . L.runLLMWith registry
                  . withTransportOptions fixtureOptions
                  . routeLLM
                  $ if streaming then streamProgram F.instructedProg (F.Question "x") (const (pure ())) else runProgram F.instructedProg (F.Question "x")
              assertBool "free-form refusal" (case freeform of Left ValidationFailure {} -> True; _ -> False)
              requests >>= (@?= []),
          testCase "invalid local settings dispatch nothing in either mode" $
            withSystemOneFixture reply $ \model registry requests -> do
              let invalid =
                    [ setDecisionSetting "urgent" (NoulSetting 1.2) emptyParams,
                      setDecisionSetting "urgent" (ScoreSetting [0.5]) emptyParams,
                      setDecisionSetting "missing" (NoulSetting 0.5) emptyParams,
                      setDecisionSetting "category" (ChoiceSetting (Map.singleton "missing" 2)) emptyParams,
                      setDecisionSetting "severity" (ScoreSetting [1.6, 0.5]) emptyParams
                    ]
              mapM_
                ( \ps -> do
                    statuses <- newIORef []
                    result <-
                      runEff . runErrorNoCallStack @ShikumiError . runRouting model . L.runLLMWith registry . withTransportOptions fixtureOptions . routeLLM $
                        if streaming then streamProgram (Predict assessmentSig ps) (Ticket (field "x")) (\e -> liftIO (modifyIORef' statuses (++ [e]))) else execute False ps
                    assertBool "validation refused" (case result of Left ValidationFailure {} -> True; _ -> False)
                    readIORef statuses >>= (@?= [])
                )
                invalid
              requests >>= (@?= [])
        ]
    | streaming <- [False, True]
    ]

execute :: (L.LLM :> es, Error ShikumiError :> es) => Bool -> Params -> Eff es Assessment
execute streaming ps =
  if streaming
    then streamProgram (Predict assessmentSig ps) (Ticket (field "x")) (const (pure ()))
    else runProgram (Predict assessmentSig ps) (Ticket (field "x"))

eventTag :: B.AssistantMessageEvent -> String
eventTag = \case
  B.EventStart {} -> "start"
  B.DataStart {} -> "data-start"
  B.DataEnd {} -> "data-end"
  B.EventDone {} -> "done"
  _ -> "unexpected"

assertFourEqual :: (Eq a, Show a) => String -> [a] -> IO ()
assertFourEqual label = \case
  [a, b, c, d] -> assertBool label (a == b && a == c && a == d)
  xs -> assertFailure ("expected four values: " ++ show xs)
