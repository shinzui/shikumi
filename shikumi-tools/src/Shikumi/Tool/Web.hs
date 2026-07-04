{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RankNTypes #-}

-- | Swappable HTTP operations for the built-in web tools.
--
-- 'web_fetch' is functional with only a TLS 'Manager'. 'web_search' requires a
-- configured provider because search APIs need provider-specific credentials.
--
-- Security posture: the default fetch policy denies non-http(s) schemes and the
-- most common SSRF destinations (loopback, link-local, and RFC-1918 private host
-- literals) before opening a connection, and caps response bytes while reading.
-- It does not resolve hostnames to detect private addresses behind DNS; supply a
-- stricter 'FetchPolicy' through 'localWebClientWith' when deployments need that.
module Shikumi.Tool.Web
  ( FetchResult (..),
    SearchHit (..),
    SearchResult (..),
    SearchConfig (..),
    FetchPolicy (..),
    defaultFetchPolicy,
    checkFetchUrl,
    readCapped,
    WebClient (..),
    localWebClient,
    localWebClientWith,
    newTlsManager,
    Manager,
  )
where

import Control.Exception (SomeException, try)
import Control.Lens ((^.))
import Data.Aeson (FromJSON, ToJSON, eitherDecode)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
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
    Request,
    brRead,
    host,
    httpLbs,
    parseRequest,
    responseBody,
    responseHeaders,
    responseStatus,
    setQueryString,
    withResponse,
  )
import Network.HTTP.Client.TLS qualified as TLS
import Network.HTTP.Types.Header (ResponseHeaders)
import Network.HTTP.Types.Status (statusCode)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Tool.Env (EnvRow)
import Text.Read (readMaybe)

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

data FetchPolicy = FetchPolicy
  { maxResponseBytes :: !Int,
    checkUrl :: !(Text -> Either Text ())
  }

defaultFetchPolicy :: FetchPolicy
defaultFetchPolicy =
  FetchPolicy
    { maxResponseBytes = 5 * 1024 * 1024,
      checkUrl = defaultCheckUrl
    }

data WebClient = WebClient
  { webFetch :: forall es. (EnvRow es) => Text -> Maybe Int -> Eff es FetchResult,
    webSearch :: forall es. (EnvRow es) => Text -> Maybe Int -> Eff es SearchResult
  }

localWebClient :: Manager -> Maybe SearchConfig -> WebClient
localWebClient = localWebClientWith defaultFetchPolicy

localWebClientWith :: FetchPolicy -> Manager -> Maybe SearchConfig -> WebClient
localWebClientWith policy manager searchConfig =
  WebClient
    { webFetch = \url maxBytes -> localFetch policy manager url maxBytes,
      webSearch = \query maxResults -> localSearch manager searchConfig query maxResults
    }

newTlsManager :: IO Manager
newTlsManager = TLS.newTlsManager

localFetch :: (EnvRow es) => FetchPolicy -> Manager -> Text -> Maybe Int -> Eff es FetchResult
localFetch policy manager url maxBytes =
  case checkFetchUrl policy url of
    Left reason ->
      throwError (ValidationFailure ("web_fetch: refused by fetch policy: " <> reason))
    Right () -> do
      let maxBodyBytes = min (maxResponseBytes policy) (max 0 (maybe 100000 id maxBytes))
      (st, ct, bodyBytes, wasTruncated) <- httpIO "web_fetch" $ do
        request <- parseRequest (T.unpack url)
        withResponse request manager $ \response -> do
          (bytes, cut) <- readCapped maxBodyBytes (brRead (responseBody response))
          pure (statusCode (responseStatus response), contentTypeOf (responseHeaders response), bytes, cut)
      let decodedBody = TE.decodeUtf8With lenientDecode bodyBytes
      pure
        FetchResult
          { status = st,
            contentType = ct,
            body = decodedBody,
            truncated = wasTruncated
          }

checkFetchUrl :: FetchPolicy -> Text -> Either Text ()
checkFetchUrl policy = checkUrl policy

defaultCheckUrl :: Text -> Either Text ()
defaultCheckUrl url
  | not ("http://" `T.isPrefixOf` lowerUrl || "https://" `T.isPrefixOf` lowerUrl) =
      Left "scheme must be http or https"
  | otherwise =
      case parseRequest (T.unpack url) :: Either SomeException Request of
        Left err -> Left ("invalid URL: " <> T.pack (show err))
        Right request ->
          let hostText = T.toLower (TE.decodeUtf8With lenientDecode (host request))
           in if deniedHost hostText
                then Left ("host is not allowed by default fetch policy: " <> hostText)
                else Right ()
  where
    lowerUrl = T.toLower url

deniedHost :: Text -> Bool
deniedHost h =
  h
    `elem` [ "localhost",
             "localhost.",
             "0.0.0.0",
             "::1",
             "[::1]"
           ]
    || "127." `T.isPrefixOf` h
    || "169.254." `T.isPrefixOf` h
    || "10." `T.isPrefixOf` h
    || "192.168." `T.isPrefixOf` h
    || is172Private h

is172Private :: Text -> Bool
is172Private h =
  case traverse readInt (T.splitOn "." h) of
    Just [first, second, _, _] -> first == 172 && second >= 16 && second <= 31
    _ -> False
  where
    readInt :: Text -> Maybe Int
    readInt = readMaybe . T.unpack

readCapped :: Int -> IO BS.ByteString -> IO (BS.ByteString, Bool)
readCapped cap next = go 0 []
  where
    go n acc = do
      chunk <- next
      if BS.null chunk
        then pure (BS.concat (reverse acc), False)
        else do
          let n' = n + BS.length chunk
          if n' >= cap
            then do
              let keep = BS.take (cap - n) chunk
              more <- if n' > cap then pure True else (not . BS.null) <$> next
              pure (BS.concat (reverse (keep : acc)), more)
            else go n' (chunk : acc)

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
