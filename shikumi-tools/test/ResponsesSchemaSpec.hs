module ResponsesSchemaSpec (tests) where

import Baikai qualified as B
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Adapter (attachSchema)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM qualified as L
import Shikumi.LLM.Defaults
import Shikumi.Program (runProgram)
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Schema (deriveSchema)
import Shikumi.Testing.Fixtures
import Shikumi.Testing.Responses
import Test.Tasty
import Test.Tasty.HUnit

field :: [Key] -> Value -> Maybe Value
field [] v = Just v
field (k : ks) (Object o) = KM.lookup k o >>= field ks
field _ _ = Nothing

tests :: TestTree
tests =
  testGroup
    "Responses real adapter"
    [ testCase "typed schema, defaults and streamed terminal cross actual HTTP" $
        withResponsesFixture (replicate 2 (sseReply [completed [messageItem "{\"answer\":\"Forty-two\",\"confidence\":0.9}"]])) $ \f -> do
          let defaults = emptyRequestDefaults {defaultThinking = Just B.ThinkingHigh, defaultMaxTokens = Just 128}
              schema = object ["type" .= String "object", "properties" .= object ["answer" .= object ["type" .= String "string"]]]
          result <-
            runEff
              . runErrorNoCallStack @ShikumiError
              . runRouting (model f)
              . L.runLLMWith (registry f)
              . withTransportOptions fixtureOptions
              . withRequestDefaults defaults
              . routeLLM
              $ runProgram instructedProg (Question "What is the answer?")
          result @?= Right (Answer "Forty-two" 0.9)
          streamed <-
            runEff
              . runErrorNoCallStack @ShikumiError
              . runRouting (model f)
              . L.runLLMWith (registry f)
              . withTransportOptions fixtureOptions
              . withRequestDefaults defaults
              . routeLLM
              $ L.stream (model f) B.emptyContext (attachSchema schema B.emptyOptions)
          case streamed of
            Right events -> case [p | B.EventDone tp <- events, B.AssistantMessage p <- [tp ^. #message]] of
              [p] -> do
                p ^. #usage . #inputTokens @?= 20
                p ^. #usage . #outputTokens @?= 5
              _ -> assertFailure "missing terminal payload"
            Left e -> assertFailure (show e)
          bodies <- requests f
          length bodies @?= 2
          map (field ["text", "format", "schema"]) bodies @?= [Just (deriveSchema @Answer), Just schema]
          mapM_
            ( \body -> do
                field ["model"] body @?= Just (String "fixture-reasoner")
                field ["stream"] body @?= Just (Bool True)
                field ["store"] body @?= Just (Bool False)
                field ["max_output_tokens"] body @?= Just (Number 128)
                field ["reasoning", "effort"] body @?= Just (String "high")
                field ["text", "format", "type"] body @?= Just (String "json_schema")
                field ["text", "format", "strict"] body @?= Just (Bool True)
                field ["include"] body @?= Just (Array (V.singleton (String "reasoning.encrypted_content")))
            )
            bodies,
      testCase "unsupported stop and image tool output fail before HTTP" $
        withResponsesFixture [] $ \f -> do
          let badImage = B.ToolResultMessage (B.ToolResultPayload "call" "lookup" (V.singleton (B.ToolResultImage (B.ImageContent "bytes" "image/png"))) False Nothing)
          -- Both failures are exercised through the released mapper.
          a <-
            runEff . runErrorNoCallStack @ShikumiError . L.runLLMWith (registry f) $
              L.complete (model f) B.emptyContext (fixtureOptions & #stopSequences .~ ["stop"])
          b <-
            runEff . runErrorNoCallStack @ShikumiError . L.runLLMWith (registry f) $
              L.complete (model f) (B.emptyContext & #messages .~ V.singleton badImage) fixtureOptions
          assertBool "stop rejected" (either (const True) (const False) a)
          assertBool "image result rejected" (either (const True) (const False) b)
          requests f >>= (@?= [])
    ]
