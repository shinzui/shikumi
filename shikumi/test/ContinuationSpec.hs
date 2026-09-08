module ContinuationSpec (tests) where

import Baikai qualified as B
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..))
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM
import Shikumi.LLM.Continuation
import Shikumi.Routing (routeLLM, runRouting)
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

model :: B.Model
model = B.mkModel (B.Custom "continuation-test") "model" "https://provider.example"

context :: B.Context
context = B.emptyContext & #systemPrompt .~ Just "system" & #messages .~ V.fromList [B.user "input", B.AssistantMessage (B.emptyResponse ^. #message & #content .~ V.singleton (B.AssistantThinking (B.ThinkingContent "" (Just "signature") False Nothing)))]

options :: B.Options
options = stampContinuation (requestOrigin model) (Just (contextIdentity context)) B.emptyOptions

tests :: TestTree
tests =
  testGroup
    "Continuation"
    [ testCase "ordered prefix permits only append and construction timestamp changes" $ do
        validateRequestContinuation model context options @?= Right ()
        let appended = context & #messages .~ (context ^. #messages <> V.singleton (B.user "next"))
        validateRequestContinuation model appended options @?= Right ()
        let timestamped = context & #messages .~ V.map (\case B.AssistantMessage p -> B.AssistantMessage (p & #timestamp .~ Just (read "2026-09-08 00:00:00 UTC")); x -> x) (context ^. #messages)
        validateRequestContinuation model timestamped options @?= Right ()
        mapM_
          (\c -> assertRejected (validateRequestContinuation model c options))
          [context & #systemPrompt .~ Just "different", context & #messages .~ V.reverse (context ^. #messages), context & #tools .~ V.singleton B.emptyTool],
      testCase "unknown and malformed expectations reject opaque history" $ do
        assertRejected (validateRequestContinuation model context B.emptyOptions)
        assertRejected (validateRequestContinuation model context (stampContinuation Nothing Nothing B.emptyOptions))
        assertRejected (validateRequestContinuation model context (B.emptyOptions & #metadata .~ Map.singleton "shikumi.continuation.v1" (String "bad"))),
      testCase "bare, resilient and routed calls reject changed targets before transport" $ do
        (reg, seen) <- recordingRegistry
        let changed = [model & #modelId .~ "other", model & #api .~ B.OpenAIResponses, model & #provider .~ "other", model & #baseUrl .~ "https://other.example"]
        mapM_
          ( \m -> do
              runEff (runErrorNoCallStack @ShikumiError (runLLMWith reg (complete m context options))) >>= assertRejected
              runEff (runErrorNoCallStack @ShikumiError (runLLMWith reg (stream m context options))) >>= assertRejected
              runEff (runErrorNoCallStack @ShikumiError (runConcurrent (runLLMResilient (defaultLLMConfig reg) (complete m context options)))) >>= assertRejected
              runEff (runErrorNoCallStack @ShikumiError (runConcurrent (runLLMResilient (defaultLLMConfig reg) (stream m context options)))) >>= assertRejected
              runEff (runErrorNoCallStack @ShikumiError (runRouting m (runLLMWith reg (routeLLM (complete B.emptyModel context options))))) >>= assertRejected
          )
          changed
        readIORef seen >>= (@?= []),
      testCase "compatible route preserves payload and strips only private continuation metadata" $ do
        (reg, seen) <- recordingRegistry
        let opts = options & #metadata .~ Map.insert "public" (String "value") (options ^. #metadata)
        result <- runEff . runErrorNoCallStack @ShikumiError . runRouting model . runLLMWith reg . routeLLM $ complete B.emptyModel context opts
        case result of Left e -> assertFailure (show e); Right _ -> pure ()
        readIORef seen >>= (@?= [(context, stripContinuationMetadata opts)]),
      testCase "Responses replay scope is cross-checked independently of expectation" $ do
        let replay = B.ThinkingReplay B.OpenAIResponses "other" V.empty
            msg = B.AssistantMessage (B.emptyResponse ^. #message & #content .~ V.singleton (B.AssistantThinking (B.ThinkingContent "" Nothing False (Just replay))))
        assertRejected (validateReplayOrigin model [msg]),
      testCase "credentials never enter request-origin records" $ do
        requestOrigin (model & #baseUrl .~ "https://user:secret@provider.example") @?= Nothing
        requestOrigin (model & #baseUrl .~ "https://provider.example?key=secret") @?= Nothing
    ]

assertRejected :: Either ShikumiError a -> Assertion
assertRejected (Left (ValidationFailure _)) = pure ()
assertRejected _ = assertFailure "expected local continuation validation failure"

recordingRegistry :: IO (B.ProviderRegistry, IORef [(B.Context, B.Options)])
recordingRegistry = do
  seen <- newIORef []
  reg <- B.newProviderRegistry
  B.registerApiProviderWith
    reg
    ( ( B.apiProviderWith
          (model ^. #api)
          (\_ c o -> Stream.concatEffect $ modifyIORef' seen (<> [(c, o)]) >> pure (Stream.fromList []))
          (\m c o -> modifyIORef' seen (<> [(c, o)]) >> pure (B.emptyResponse & #model .~ m))
      )
        { B.describeThinking = \_ _ -> B.noThinkingRequested
        }
    )
  pure (reg, seen)
