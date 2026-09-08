-- | Loopback-only fixtures for the released Responses provider. No SDK internals.
module Shikumi.Testing.Responses
  ( ResponsesFixture (..),
    Reply (..),
    sseReply,
    withResponsesFixture,
    completed,
    messageItem,
    functionItem,
    reasoningItem,
    failureFrame,
    fixtureOptions,
    withTransportOptions,
  )
where

import Baikai qualified as B
import Baikai.Provider.OpenAI.Responses (openaiResponsesProvider)
import Control.Concurrent (killThread, myThreadId, threadDelay)
import Control.Exception (bracket_, finally, throwIO)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpose)
import Network.HTTP.Types (mkStatus)
import Network.Wai (rawPathInfo, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp qualified as Warp
import Shikumi.LLM (LLM (..), complete, stream)
import System.Timeout (timeout)

data Reply = Reply {status :: Int, frames :: [Value], delayMicros :: Int}

sseReply :: [Value] -> Reply
sseReply fs = Reply 200 fs 0

data ResponsesFixture = ResponsesFixture
  { model :: B.Model,
    registry :: B.ProviderRegistry,
    requests :: IO [Value],
    activeRequests :: IO Int
  }

-- | Bracket a 127.0.0.1 ephemeral listener. Ten seconds bounds the action;
-- Warp gets one second for shutdown, then explicit worker cleanup gets two.
withResponsesFixture :: [Reply] -> (ResponsesFixture -> IO a) -> IO a
withResponsesFixture script action = do
  pending <- newIORef script
  seen <- newIORef []
  active <- newIORef []
  let enter = myThreadId >>= \tid -> atomicModifyIORef' active (\xs -> (tid : xs, ()))
      leave = myThreadId >>= \tid -> atomicModifyIORef' active (\xs -> (filter (/= tid) xs, ()))
      waitEmpty = readIORef active >>= \xs -> if null xs then pure () else threadDelay 1000 >> waitEmpty
      cleanup = do
        tids <- readIORef active
        result <- timeout 2000000 (mapM_ killThread tids >> waitEmpty)
        maybe (throwIO (userError "Responses fixture workers did not stop")) pure result
      app req respond = bracket_ enter leave $ do
        if requestMethod req /= "POST" || rawPathInfo req /= "/v1/responses"
          then throwIO (userError "unexpected Responses fixture method/path")
          else pure ()
        body <- strictRequestBody req
        value <- either (throwIO . userError) pure (eitherDecode body)
        atomicModifyIORef' seen (\xs -> (value : xs, ()))
        next <- atomicModifyIORef' pending $ \case [] -> ([], Nothing); r : rs -> (rs, Just r)
        reply <- maybe (throwIO (userError "Responses fixture exhausted")) pure next
        threadDelay (max 0 (delayMicros reply))
        let payload =
              if status reply == 200
                then BL.concat ["data: " <> encode frame <> "\n\n" | frame <- frames reply]
                else encode (object ["error" .= object ["message" .= ("scripted transport failure" :: Text)]])
        respond (responseLBS (mkStatus (status reply) "fixture") [("Content-Type", "text/event-stream")] payload)
      settings = Warp.setGracefulShutdownTimeout (Just 1) Warp.defaultSettings
  ( Warp.testWithApplicationSettings settings (pure app) $ \port -> do
      reg <- B.newProviderRegistry
      B.registerApiProviderWith reg openaiResponsesProvider
      let m =
            B.mkModel B.OpenAIResponses "fixture-reasoner" ("http://127.0.0.1:" <> T.pack (show port))
              & #provider .~ "openai"
              & #reasoning .~ True
              & #maxOutputTokens .~ 256
          fixture = ResponsesFixture m reg (reverse <$> readIORef seen) (length <$> readIORef active)
      result <- timeout 10000000 (action fixture)
      maybe (throwIO (userError "Responses fixture action timed out")) pure result
    )
    `finally` cleanup

fixtureOptions :: B.Options
fixtureOptions = B.emptyOptions & #apiKey .~ Just (B.ApiKeyLiteral "fixture-only") & #timeoutMs .~ Just 1000

-- | Credentials and transport timeout are explicit runtime configuration, not
-- request defaults or checkpoint data. Inner per-call values take precedence.
withTransportOptions :: (LLM :> es) => B.Options -> Eff es a -> Eff es a
withTransportOptions transport = interpose $ \_ -> \case
  Complete m c o -> complete m c (apply o)
  Stream m c o -> stream m c (apply o)
  where
    apply o =
      o
        & #apiKey .~ ((o ^. #apiKey) `orElse` (transport ^. #apiKey))
        & #timeoutMs .~ ((o ^. #timeoutMs) `orElse` (transport ^. #timeoutMs))
    orElse Nothing b = b
    orElse a _ = a

completed :: [Value] -> Value
completed items =
  object
    [ "type" .= ("response.completed" :: Text),
      "response"
        .= object
          [ "id" .= ("response-fixture" :: Text),
            "model" .= ("observed-fixture-model" :: Text),
            "output" .= items,
            "usage"
              .= object
                [ "input_tokens" .= (20 :: Int),
                  "output_tokens" .= (5 :: Int),
                  "input_tokens_details" .= object ["cached_tokens" .= (0 :: Int)],
                  "output_tokens_details" .= object ["reasoning_tokens" .= (2 :: Int)]
                ]
          ]
    ]

messageItem :: Text -> Value
messageItem t =
  object
    [ "type" .= ("message" :: Text),
      "id" .= ("message-fixture" :: Text),
      "role" .= ("assistant" :: Text),
      "status" .= ("completed" :: Text),
      "content" .= [object ["type" .= ("output_text" :: Text), "text" .= t]]
    ]

functionItem :: Text -> Text -> Text -> Value -> Value
functionItem itemId callId name args =
  object
    [ "type" .= ("function_call" :: Text),
      "id" .= itemId,
      "call_id" .= callId,
      "name" .= name,
      "arguments" .= TE.decodeUtf8 (BL.toStrict (encode args)),
      "status" .= ("completed" :: Text)
    ]

reasoningItem :: Value
reasoningItem =
  object
    [ "type" .= ("reasoning" :: Text),
      "id" .= ("reasoning-fixture" :: Text),
      "summary" .= ([] :: [Value]),
      "encrypted_content" .= ("opaque-fixture" :: Text),
      "future_extension" .= object ["preserve" .= True]
    ]

failureFrame :: Text -> Value
failureFrame code =
  object
    [ "type" .= ("response.failed" :: Text),
      "response"
        .= object
          ["error" .= object ["code" .= code, "message" .= ("fixture refusal" :: Text)]]
    ]
