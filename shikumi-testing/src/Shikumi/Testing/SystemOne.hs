-- | Offline structured decision responses using Baikai's public content carrier.
module Shikumi.Testing.SystemOne (systemOneModel, systemOneResponse, systemOneResponder, withSystemOneFixture) where

import Baikai
import Baikai.Models.Generated (typesafe_jev_latest)
import Baikai.Provider.TypeSafe.Api (typesafeProvider)
import Control.Exception (throwIO)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..), eitherDecode, encode, toJSON)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Network.HTTP.Types (status200)
import Network.Wai (rawPathInfo, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp qualified as Warp
import Shikumi.Decision
import System.Timeout (timeout)

systemOneModel :: Text -> Model
systemOneModel name = typesafe_jev_latest & #modelId .~ name

systemOneResponse :: [(Text, FieldEvidence)] -> Response
systemOneResponse fields = emptyResponse & #message . #content .~ V.singleton (AssistantData payload)
  where
    payload = DataContent Null (Just (Map.fromList [(n, probs e) | (n, e) <- fields])) (Just (Map.fromList [(n, c) | (n, e) <- fields, Just c <- [conf e]])) (Just "provider_classification")
    probs = \case
      FieldNoul (NoulEvidence p) -> Map.fromList [("true", p), ("false", 1 - p)]
      FieldChoice (ChoiceEvidence ps _) -> ps
      FieldScore (ScoreEvidence ps _) -> Map.fromList [(T.pack (show i), p) | (i, p) <- zip [0 :: Int ..] (V.toList ps)]
    conf = \case FieldNoul _ -> Nothing; FieldChoice (ChoiceEvidence _ c) -> c; FieldScore (ScoreEvidence _ c) -> c

systemOneResponder :: (Value -> [(Text, FieldEvidence)]) -> Context -> Response
systemOneResponder f ctx = case V.toList (ctx ^. #messages) of
  [UserMessage p] -> case V.toList (p ^. #content) of
    [UserData state] -> systemOneResponse (f state)
    _ -> systemOneResponse (f (toJSON ctx))
  _ -> systemOneResponse (f (toJSON ctx))

-- | A bounded JSON loopback with an isolated provider registry and captured POSTs.
withSystemOneFixture :: Value -> (Model -> ProviderRegistry -> IO [Value] -> IO a) -> IO a
withSystemOneFixture reply action = do
  seen <- newIORef []
  let app req respond = do
        if requestMethod req == "POST" && rawPathInfo req == "/v1/systemone" then pure () else throwIO (userError "unexpected System One method/path")
        body <- strictRequestBody req
        v <- either (throwIO . userError) pure (eitherDecode body)
        atomicModifyIORef' seen (\xs -> (v : xs, ()))
        respond (responseLBS status200 [("Content-Type", "application/json")] (encode reply))
  Warp.testWithApplication (pure app) $ \port -> do
    registry <- newProviderRegistry
    registerApiProviderWith registry typesafeProvider
    result <- timeout 10000000 (action (systemOneModel "jev-latest" & #baseUrl .~ ("http://127.0.0.1:" <> T.pack (show port))) registry (reverse <$> readIORef seen))
    maybe (throwIO (userError "System One fixture timeout")) pure result
