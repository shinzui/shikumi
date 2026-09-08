-- | Scripted real transport for offline runtime/cache/billing integration tests.
module Shikumi.Testing.Transport (scriptedTransport) where

import Baikai
import Control.Exception (throwIO)
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.IORef
import Streamly.Data.Stream qualified as Stream

-- | A fresh isolated registry. Both APIs consume the same script, capturing
-- effective model/options. Exhaustion fails, so unexpected dispatches are visible.
scriptedTransport :: [Response] -> IO (Model, ProviderRegistry, IO [(Model, Options)])
scriptedTransport responses = do
  pending <- newIORef responses
  requests <- newIORef []
  let api = Custom "billing-fixture"
      model = emptyModel & #api .~ api & #provider .~ "fixture" & #modelId .~ "requested-model"
      next m _ o = do
        atomicModifyIORef' requests (\xs -> ((m, o) : xs, ()))
        response <- atomicModifyIORef' pending $ \case
          [] -> ([], Nothing)
          r : rs -> (rs, Just r)
        case response of
          Nothing -> throwIO (invalidRequest "scripted transport exhausted")
          Just r -> pure (r & #model .~ m & #api .~ api & #provider .~ "fixture")
      events m c o = Stream.concatEffect $ do
        r <- next m c o
        let terminal =
              (doneTerminal (r ^. #evidence) Nothing (r ^. #message . #stopReason) (AssistantMessage (r ^. #message)))
                & #errorInfo .~ responseError r
        pure (Stream.fromList [case responseError r of Nothing -> EventDone terminal; Just _ -> EventError terminal])
  registry <- newProviderRegistry
  registerApiProviderWith
    registry
    (apiProviderWith api events next)
      { describeThinking = \_ _ -> noThinkingRequested
      }
  pure (model, registry, reverse <$> readIORef requests)
