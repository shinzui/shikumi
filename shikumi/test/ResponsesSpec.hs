module ResponsesSpec (tests) where

import Baikai qualified as B
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..), object, (.=))
import Data.Generics.Labels ()
import Data.IORef
import Effectful (liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Adapter (ModelCapability (..), attachSchema, capabilityFor)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM qualified as L
import Shikumi.Routing (routeLLM, runRouting)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests = testCase "Responses routes strict native schemas for both operations" $ do
  let model = B.mkModel B.OpenAIResponses "fixture" "https://example.invalid" & #provider .~ "openai"
      schema = object ["type" .= String "object", "properties" .= object []]
  case capabilityFor model of NativeSchema -> pure (); _ -> assertFailure "Responses must be native"
  seen <- newIORef []
  result <- runEff
    . runErrorNoCallStack @ShikumiError
    . runRouting model
    . interpret
      ( \_ -> \case
          L.Complete m _ o -> liftIO (modifyIORef' seen (<> [(m, o)])) >> pure B.emptyResponse
          L.Stream m _ o -> liftIO (modifyIORef' seen (<> [(m, o)])) >> pure []
      )
    . routeLLM
    $ do
      _ <- L.complete B.emptyModel B.emptyContext (attachSchema schema B.emptyOptions)
      _ <- L.stream B.emptyModel B.emptyContext (attachSchema schema B.emptyOptions)
      pure ()
  result @?= Right ()
  recorded <- readIORef seen
  length recorded @?= 2
  mapM_
    ( \(m, o) -> do
        m ^. #api @?= B.OpenAIResponses
        o ^. #responseFormat @?= Just (B.JsonSchema (B.jsonSchemaFormat "output" schema & #strict .~ True))
    )
    recorded
