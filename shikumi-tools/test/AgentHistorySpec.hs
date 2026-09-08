{-# LANGUAGE DataKinds #-}

module AgentHistorySpec (tests) where

import Baikai qualified as B
import Baikai.Cost qualified as BC
import Baikai.Error (contentFiltered)
import Baikai.Usage qualified as BU
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.Key qualified
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.IORef
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Fixtures
import GHC.Generics (Generic)
import ReActSessionExample qualified
import Shikumi.Adapter qualified
import Shikumi.Agent.History
import Shikumi.Agent.ReAct
import Shikumi.Compaction (CompactionConfig (..))
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..), complete)
import Shikumi.Schema (FromModel, ToSchema, Validatable (..))
import Shikumi.Signature (Signature, mkSignature, setInstruction)
import Shikumi.Testing (mkTextResponse, mkToolCallResponse, mkToolCallsResponse)
import Shikumi.Tool
import Shikumi.Tool.Output
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

newtype Positive = Positive {value :: Int}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema, FromModel)

instance Validatable Positive where
  validate x@(Positive n) = if n > 0 then Right x else Left "must be positive"

cfg :: ReActConfig
cfg = defaultReActConfig {protocol = ProtocolNative, compaction = CompactionConfig 0 4 False}

rich :: ToolOutput
rich = ToolOutput (B.ToolResult (V.singleton (B.ToolResultImage (B.ImageContent "image bytes" "image/png"))) False) (Just (object ["n" .= (42 :: Int)])) [object ["resource" .= String "uri"]]

registry :: ToolRegistry
registry = mkRegistry [dynamic "A", dynamic "B"]
  where
    dynamic name = mkDynTool name "test" (object []) $ \_ -> do
      _ <- complete B.emptyModel (B.emptyContext & #systemPrompt .~ Just ("dispatch:" <> name)) B.emptyOptions
      pure (Right rich)

firstTurn :: B.Response
firstTurn = mkToolCallsResponse [("call-A", "A", object []), ("call-B", "B", object [])]

finalTurn :: B.Response
finalTurn = mkToolCallResponse "final-1" finalToolName (toJSON expectedWeather)

-- The test interpreter observes dispatch via a nested LLM operation, respecting
-- tool bodies' rank-polymorphic effect boundary without unsafe IO in a tool.
recording :: [Either ShikumiError B.Response] -> Eff '[LLM, Error ShikumiError, IOE] a -> IO (Either ShikumiError a, [B.Context], [Text])
recording script action = do
  scriptRef <- newIORef script
  contexts <- newIORef []
  dispatches <- newIORef []
  result <-
    runEff
      . runErrorNoCallStack
      . interpret
        ( \_ -> \case
            Complete _ ctx _ -> case ctx ^. #systemPrompt of
              Just sys | "dispatch:" `T.isPrefixOf` sys -> do
                liftIO (modifyIORef' dispatches (<> [T.drop 9 sys]))
                pure (mkTextResponse "done")
              _ -> do
                liftIO (modifyIORef' contexts (<> [ctx]))
                next <-
                  liftIO
                    ( atomicModifyIORef'
                        scriptRef
                        ( \xs -> case xs of
                            [] -> ([], Left (ProviderFailure "unexpected model call"))
                            x : rest -> (rest, x)
                        )
                    )
                either throwError pure next
            Stream {} -> pure []
        )
      $ action
  (result,,) <$> readIORef contexts <*> readIORef dispatches

start :: Eff '[LLM, Error ShikumiError, IOE] ReActSession
start = startSession weatherSignature registry cfg weatherQuestion

paused :: SessionResult o -> Eff '[LLM, Error ShikumiError, IOE] ReActSession
paused (SessionPaused s) = pure s
paused _ = throwError (ValidationFailure "expected paused session")

restored :: ReActSession -> Eff '[LLM, Error ShikumiError, IOE] ReActSession
restored s = either (throwError . ValidationFailure . T.pack . show) pure (decodeSession (encodeSession s))

assertFinished :: Either ShikumiError (SessionResult WeatherResp) -> Assertion
assertFinished (Right (SessionFinished answer _)) = answer @?= expectedWeather
assertFinished other = assertFailure (show other)

mutate :: Text -> Value -> Value -> Value
mutate key v (Object o) = Object (KM.insert (fromStringKey key) v o)
  where
    fromStringKey = Data.Aeson.Key.fromText
mutate _ _ v = v

tests :: TestTree
tests =
  testGroup
    "AgentHistory"
    [ testCase "documented continuation example" $ do
        ReActSessionExample.example >>= (@?= Right ("Paris, France", 2)),
      testCase "native two-tool checkpoint resumes with exact messages and no extraction" $ do
        (answer, requests, dispatched) <- recording (map Right [firstTurn, finalTurn]) $ do
          s <- start >>= advanceSession weatherSignature registry cfg >>= paused
          copy <- restored s
          if copy == s then pure () else throwError (ValidationFailure "round-trip differs")
          resumed <- continueSession weatherSignature registry cfg weatherQuestion copy
          advanceSession weatherSignature registry cfg resumed
        assertFinished answer
        dispatched @?= ["A", "B"]
        length requests @?= 2
        case requests of
          [_, second] ->
            second ^. #messages
              @?= V.fromList
                [ B.user (Shikumi.Adapter.toPrompt weatherQuestion),
                  B.AssistantMessage (firstTurn ^. #message),
                  toolOutputMessage (B.ToolCall "call-A" "A" (object [])) rich,
                  toolOutputMessage (B.ToolCall "call-B" "B" (object [])) rich,
                  B.user (Shikumi.Adapter.toPrompt weatherQuestion)
                ]
          _ -> assertFailure "wrong request count",
      testCase "resumed and uninterrupted next requests are identical" $ do
        let execute restore = recording (map Right [firstTurn, finalTurn]) $ do
              s <- start >>= advanceSession weatherSignature registry cfg >>= paused
              copy <- if restore then restored s else pure s
              next <- continueSession weatherSignature registry cfg weatherQuestion copy
              advanceSession weatherSignature registry cfg next
        (_, uninterrupted, _) <- execute False
        (_, resumed, _) <- execute True
        resumed @?= uninterrupted,
      testCase "message metadata, thinking signature and rich blocks survive JSON bytes" $ do
        let replay = B.ThinkingReplay B.OpenAIResponses "test-model" (V.singleton (object ["opaque" .= ("replay" :: String)]))
            thinking = B.ThinkingContent "opaque" (Just "signature") True (Just replay)
            response = firstTurn & #message . #content .~ V.cons (B.AssistantThinking thinking) (firstTurn ^. #message . #content)
        (result, _, _) <- recording [Right response] (start >>= advanceSession weatherSignature registry cfg >>= paused)
        case result of
          Right s -> (eitherDecode (encode (encodeSession s)) >>= either (Left . show) Right . decodeSession) @?= Right s
          Left e -> assertFailure (show e),
      testCase "all invalid native proposals are audit-only and dispatch nothing" $ do
        let invalid =
              [ mkToolCallsResponse [("", "A", object []), ("ok", "B", object [])],
                mkToolCallsResponse [("same", "A", object []), ("same", "B", object [])],
                mkToolCallsResponse [("ok", "A", object []), ("cut", "B", String "{")],
                mkToolCallsResponse [("a", "A", object []), ("f", finalToolName, toJSON expectedWeather)],
                mkToolCallResponse "bad-final" finalToolName (object [])
              ]
        mapM_
          ( \response -> do
              (result, requests, dispatched) <- recording [Right response, Right finalTurn] $ do
                s <- start >>= advanceSession weatherSignature registry cfg >>= paused
                copy <- restored s
                advanceSession weatherSignature registry cfg copy
              assertFinished result
              dispatched @?= []
              case requests of
                [_, ctx] -> do
                  assertBool "invalid assistant omitted" (not (B.AssistantMessage (response ^. #message) `elem` V.toList (ctx ^. #messages)))
                  assertBool "no orphan tool results" (null [() | B.ToolResultMessage _ <- V.toList (ctx ^. #messages)])
                _ -> assertFailure "wrong requests"
          )
          invalid,
      testCase "IDs cannot be reused in later accepted exchanges" $ do
        (result, _, dispatched) <- recording (map Right [firstTurn, firstTurn, finalTurn]) $ do
          s <- start >>= advanceSession weatherSignature registry cfg >>= paused
          next <- advanceSession weatherSignature registry cfg s >>= paused
          advanceSession weatherSignature registry cfg next
        assertFinished result
        dispatched @?= ["A", "B"],
      testCase "unknown versions, unresolved exchanges and corrupt JSON are rejected" $ do
        (result, _, _) <- recording [Right firstTurn] (start >>= advanceSession weatherSignature registry cfg >>= paused)
        case result of
          Right s -> do
            assertBool "version" (isLeft (decodeSession (mutate "version" (Number 2) (encodeSession s))))
            let corruptResults (Object o) = case KM.lookup "history" o of
                  Just (Array entries) ->
                    Object
                      ( KM.insert
                          "history"
                          ( Array
                              ( V.map
                                  ( \e -> case e of
                                      Object fields | KM.lookup "kind" fields == Just (String "exchange") -> Object (KM.insert "results" (Array V.empty) fields)
                                      _ -> e
                                  )
                                  entries
                              )
                          )
                          o
                      )
                  _ -> Object o
                corruptResults v = v
            assertBool "unresolved" (isLeft (decodeSession (corruptResults (encodeSession s))))
            assertBool "invalid JSON" (isLeft (eitherDecode "{" :: Either String Value))
          Left e -> assertFailure (show e),
      testCase "signature and registry mismatch fail before any execution" $ do
        (result, requests, dispatched) <- recording [] $ do
          s <- start
          advanceSession (setInstruction "changed" weatherSignature) registry cfg s
        assertBool "signature rejected" (isLeft result)
        requests @?= []
        dispatched @?= []
        (changed, reqs, _) <- recording [] $ do
          s <- start
          advanceSession weatherSignature (mkRegistry []) cfg s
        assertBool "registry rejected" (isLeft changed)
        reqs @?= [],
      testCase "reserved final tool collision is rejected at startup" $ do
        (result, requests, _) <- recording [] (startSession weatherSignature (mkRegistry [mkDynTool finalToolName "" (object []) (\_ -> pure (Right rich))]) cfg weatherQuestion)
        assertBool "collision" (isLeft result)
        requests @?= [],
      testCase "iteration exhaustion returns a checkpoint without another call" $ do
        let limited = cfg {maxIters = 1}
        (result, requests, dispatched) <- recording [Right firstTurn] $ do
          s <- startSession weatherSignature registry limited weatherQuestion
          runSession weatherSignature registry limited s
        case result of
          Right (SessionPaused s) -> sessionTurns s @?= 1
          _ -> assertFailure (show result)
        length requests @?= 1
        dispatched @?= ["A", "B"],
      testCase "prompt fallback preserves continuation and synthetic IDs" $ do
        let promptCfg = cfg {protocol = ProtocolPrompt}
            proposal = mkTextResponse "{\"calls\":[{\"tool\":\"A\",\"args\":{}},{\"tool\":\"B\",\"args\":{}}]}"
            final = mkTextResponse "{\"calls\":[{\"tool\":\"shikumi_submit_final\",\"args\":{\"tempC\":12,\"summary\":\"mild\"}}]}"
        (result, requests, dispatched) <- recording (map Right [proposal, final]) $ do
          s <- startSession weatherSignature registry promptCfg weatherQuestion >>= advanceSession weatherSignature registry promptCfg >>= paused >>= restored
          next <- continueSession weatherSignature registry promptCfg weatherQuestion s
          advanceSession weatherSignature registry promptCfg next
        assertFinished result
        dispatched @?= ["A", "B"]
        length requests @?= 2,
      testCase "context retry compacts whole exchanges without redispatch" $ do
        let compactCfg = cfg {compaction = CompactionConfig 0 1 True}
        (result, requests, dispatched) <- recording [Right firstTurn, Left (ContextWindowExceeded "full"), Right (mkTextResponse "Earlier question"), Right finalTurn] $ do
          s <- startSession weatherSignature registry compactCfg weatherQuestion >>= advanceSession weatherSignature registry compactCfg >>= paused
          advanceSession weatherSignature registry compactCfg s
        assertFinished result
        dispatched @?= ["A", "B"]
        length requests @?= 4
        case result of
          Right (SessionFinished _ s) -> do
            decodeSession (encodeSession s) @?= Right s
            length (auditHistory s) @?= 3
          _ -> pure (),
      testCase "usage compaction retains complete exchanges across restore" $ do
        let compactCfg = cfg {compaction = CompactionConfig 0 1 True}
            large = firstTurn & #model . #contextWindow .~ 10 & #message . #usage . #inputTokens .~ 10
        (result, requests, dispatched) <- recording (map Right [large, mkTextResponse "question summary", finalTurn]) $ do
          s <- startSession weatherSignature registry compactCfg weatherQuestion >>= advanceSession weatherSignature registry compactCfg >>= paused >>= restored
          advanceSession weatherSignature registry compactCfg s
        assertFinished result
        dispatched @?= ["A", "B"]
        length requests @?= 3
        case reverse requests of
          ctx : _ -> do
            length [() | B.AssistantMessage _ <- V.toList (ctx ^. #messages)] @?= 1
            length [() | B.ToolResultMessage _ <- V.toList (ctx ^. #messages)] @?= 2
          _ -> assertFailure "missing request",
      testCase "tool infrastructure failure aborts remaining dispatch without retry" $ do
        let failing = mkRegistry [mkDynTool "A" "" (object []) (\_ -> throwError (BudgetExceeded "tool budget")), mkDynTool "B" "" (object []) (\_ -> pure (Right rich))]
        (result, requests, dispatched) <- recording [Right firstTurn] $ do
          s <- startSession weatherSignature failing cfg weatherQuestion
          advanceSession weatherSignature failing cfg s
        result @?= Left (BudgetExceeded "tool budget")
        length requests @?= 1
        dispatched @?= [],
      testCase "provider error payload is never dispatched" $ do
        let failed = firstTurn & #message . #stopReason .~ B.ErrorReason & #message . #errorMessage .~ Just "transport failed"
        (result, _, dispatched) <- recording [Right failed] (start >>= advanceSession weatherSignature registry cfg)
        result @?= Left (ProviderFailure "transport failed")
        dispatched @?= [],
      testCase "structured refusal preserves error and never dispatches partial calls" $ do
        let err = contentFiltered "refused"
            failed = firstTurn & #message . #stopReason .~ B.ErrorReason & #errorInfo .~ Just err
        (result, requests, dispatched) <- recording [Right failed] (start >>= advanceSession weatherSignature registry cfg)
        result @?= Left (ProviderError err)
        length requests @?= 1
        dispatched @?= [],
      testCase "ordinary tool failures are error-flagged model messages" $ do
        let unknown = mkToolCallResponse "unknown-id" "unknown-tool" (object [])
        (result, requests, _) <- recording (map Right [unknown, finalTurn]) $ do
          s <- start >>= advanceSession weatherSignature registry cfg >>= paused
          advanceSession weatherSignature registry cfg s
        assertFinished result
        case reverse requests of
          ctx : _ -> [p ^. #isError | B.ToolResultMessage p <- V.toList (ctx ^. #messages)] @?= [True]
          _ -> assertFailure "missing request",
      testCase "checkpoint rejects altered result names and duplicate results" $ do
        (result, _, _) <- recording [Right firstTurn] (start >>= advanceSession weatherSignature registry cfg >>= paused)
        case result of
          Right s -> case auditHistory s of
            [_, Exchange payload results Nothing] -> do
              let base = newSession "native" (sessionFingerprint s) (sessionTools s) "question"
                  changed = case results of
                    (call, output) : rest -> (call & #name .~ "different", output) : rest
                    [] -> []
              assertBool "name mismatch" (isLeft (base >>= appendExchange payload changed Nothing False))
              assertBool "duplicate result" (isLeft (base >>= appendExchange payload (results <> results) Nothing False))
            _ -> assertFailure "unexpected audit"
          Left err -> assertFailure (show err),
      testCase "schema changes under an existing tool name require restart" $ do
        let changed = mkRegistry [mkDynTool "A" "test" (object ["type" .= String "string"]) (\_ -> pure (Right rich)), mkDynTool "B" "test" (object []) (\_ -> pure (Right rich))]
        (result, requests, _) <- recording [] $ do
          s <- start
          continueSession weatherSignature changed cfg weatherQuestion s
        assertBool "schema rejected" (isLeft result)
        requests @?= [],
      testCase "fenced prompt uses identical dispatch and persistence parsing" $ do
        let promptCfg = cfg {protocol = ProtocolPrompt}
            proposal = mkTextResponse "```json\n{\"calls\":[{\"tool\":\"A\",\"args\":{}}]}"
        (result, _, dispatched) <- recording [Right proposal] $ do
          s <- startSession weatherSignature registry promptCfg weatherQuestion
          advanceSession weatherSignature registry promptCfg s >>= paused >>= restored
        assertBool "checkpoint returned" (not (isLeft result))
        dispatched @?= ["A"],
      testCase "final submission runs custom semantic validation" $ do
        let sig = mkSignature "Return a positive value" :: Signature AnswerWeatherQuestion Positive
            bad = mkToolCallResponse "bad" finalToolName (object ["value" .= (-1 :: Int)])
            good = mkToolCallResponse "good" finalToolName (object ["value" .= (2 :: Int)])
        (result, requests, dispatched) <- recording (map Right [bad, good]) $ do
          s <- startSession sig registry cfg weatherQuestion
          runSession sig registry cfg s
        case result of
          Right (SessionFinished answer s) -> do
            answer @?= Positive 2
            sessionTurns s @?= 2
          _ -> assertFailure (show result)
        length requests @?= 2
        dispatched @?= [],
      testCase "exact rational costs and timestamps survive checkpoint encoding" $ do
        let cost = BC.Cost (1 / 3) (BC.CostBreakdown (1 / 7) (2 / 9) (1 / 11) (1 / 13)) (BC.CostBasis (Set.singleton BC.StandardTokenRates) (Set.singleton BC.CacheWriteUsageNotReported))
            response =
              firstTurn
                & #message . #usage . #cost .~ cost
                & #message . #usage . #reasoningTokens .~ Just 5
                & #message . #usage . #availability .~ Just (BU.UsageAvailability (Set.singleton BU.CacheWriteUsage) False (Set.singleton (BU.BillingServiceTier "standard")))
                & #message . #timestamp .~ Just (read "2026-09-07 01:00:00 UTC")
                & #message . #errorMessage .~ Just "nonfatal diagnostic"
        (result, _, _) <- recording [Right response] (start >>= advanceSession weatherSignature registry cfg >>= paused)
        case result of
          Right s -> (eitherDecode (encode (encodeSession s)) >>= either (Left . show) Right . decodeSession) @?= Right s
          Left err -> assertFailure (show err),
      testCase "legacy checkpoints without billing metadata still decode" $ do
        let stripBilling (Object fields) = Object (KM.mapWithKey (\_ -> stripBilling) (KM.delete "basis" (KM.delete "availability" fields)))
            stripBilling (Array values) = Array (V.map stripBilling values)
            stripBilling other = other
        (result, _, _) <- recording [Right firstTurn] (start >>= advanceSession weatherSignature registry cfg >>= paused)
        case result of
          Right s -> decodeSession (stripBilling (encodeSession s)) @?= Right s
          Left err -> assertFailure (show err),
      testCase "context retry is bounded" $ do
        let compactCfg = cfg {compaction = CompactionConfig 0 1 True}
        (result, requests, dispatched) <- recording [Right firstTurn, Left (ContextWindowExceeded "full"), Right (mkTextResponse "summary"), Left (ContextWindowExceeded "again")] $ do
          s <- startSession weatherSignature registry compactCfg weatherQuestion >>= advanceSession weatherSignature registry compactCfg >>= paused
          advanceSession weatherSignature registry compactCfg s
        result @?= Left (ContextWindowExceeded "again")
        length requests @?= 4
        dispatched @?= ["A", "B"]
    ]
  where
    isLeft (Left _) = True
    isLeft _ = False
