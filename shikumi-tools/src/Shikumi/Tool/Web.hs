{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RankNTypes #-}

-- | Swappable HTTP operations for the built-in web tools.
--
-- 'web_fetch' is functional with only a TLS 'Manager'. 'web_search' requires a
-- configured provider because search APIs need provider-specific credentials.
module Shikumi.Tool.Web
  ( FetchResult (..),
    SearchHit (..),
    SearchResult (..),
    SearchConfig (..),
    WebClient (..),
    localWebClient,
    newTlsManager,
    Manager,
  )
where

import Control.Exception (try)
import Control.Lens ((^.))
import Data.Aeson (FromJSON, ToJSON, eitherDecode)
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Effectful (Eff)
import Effectful.Dispatch.Static (unsafeEff_)
import Effectful.Error.Static (throwError)
import GHC.Generics (Generic)
import Network.HTTP.Client
  ( HttpException,
    Manager,
    httpLbs,
    parseRequest,
    responseBody,
    responseHeaders,
    responseStatus,
    setQueryString,
  )
import Network.HTTP.Client.TLS qualified as TLS
import Network.HTTP.Types.Header (ResponseHeaders)
import Network.HTTP.Types.Status (statusCode)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Tool.Env (EnvRow)

data FetchResult = FetchResult
  { status :: !Int,
    contentType :: !Text,
    body :: !Text,
    truncated :: !Bool
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (FromJSON, ToJSON)

data SearchHit = SearchHit
  { title :: !Text,
    url :: !Text,
    snippet :: !Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (FromJSON, ToJSON)

newtype SearchResult = SearchResult {hits :: [SearchHit]}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (FromJSON, ToJSON)

data SearchConfig = SearchConfig
  { baseUrl :: !Text,
    apiKey :: !Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

data WebClient = WebClient
  { webFetch :: forall es. (EnvRow es) => Text -> Maybe Int -> Eff es FetchResult,
    webSearch :: forall es. (EnvRow es) => Text -> Maybe Int -> Eff es SearchResult
  }

localWebClient :: Manager -> Maybe SearchConfig -> WebClient
localWebClient manager searchConfig =
  WebClient
    { webFetch = \url maxBytes -> localFetch manager url maxBytes,
      webSearch = \query maxResults -> localSearch manager searchConfig query maxResults
    }

newTlsManager :: IO Manager
newTlsManager = TLS.newTlsManager

localFetch :: (EnvRow es) => Manager -> Text -> Maybe Int -> Eff es FetchResult
localFetch manager url maxBytes = do
  response <- httpIO "web_fetch" $ do
    request <- parseRequest (T.unpack url)
    httpLbs request manager
  let maxBodyBytes = max 0 (maybe 100000 id maxBytes)
      rawBody = responseBody response
      limitedBody = LBS.take (fromIntegral maxBodyBytes) rawBody
      truncated = LBS.length rawBody > fromIntegral maxBodyBytes
      decodedBody = TE.decodeUtf8With lenientDecode (LBS.toStrict limitedBody)
  pure
    FetchResult
      { status = statusCode (responseStatus response),
        contentType = contentTypeOf (responseHeaders response),
        body = decodedBody,
        truncated
      }

localSearch :: (EnvRow es) => Manager -> Maybe SearchConfig -> Text -> Maybe Int -> Eff es SearchResult
localSearch _ Nothing _ _ =
  throwError (ProviderFailure "web_search: no search provider configured")
localSearch manager (Just config) query maxResults = do
  response <- httpIO "web_search" $ do
    request0 <- parseRequest (T.unpack (config ^. #baseUrl))
    let request =
          setQueryString
            [ ("q", Just (TE.encodeUtf8 query)),
              ("key", Just (TE.encodeUtf8 (config ^. #apiKey))),
              ("limit", Just (B8.pack (show (maybe 10 id maxResults))))
            ]
            request0
    httpLbs request manager
  case eitherDecode (responseBody response) of
    Right result -> pure result
    Left err -> throwError (ProviderFailure ("web_search: could not decode search response: " <> T.pack err))

httpIO :: (EnvRow es) => Text -> IO a -> Eff es a
httpIO label action = do
  result <- unsafeEff_ (try action)
  case result of
    Right value -> pure value
    Left (err :: HttpException) ->
      throwError (ProviderFailure (label <> ": " <> T.pack (show err)))

contentTypeOf :: ResponseHeaders -> Text
contentTypeOf headers =
  maybe "" (TE.decodeUtf8With lenientDecode) (lookup "Content-Type" headers)
