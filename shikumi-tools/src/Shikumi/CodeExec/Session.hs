-- | Experimental, invocation-local data operations. No host execution capability.
module Shikumi.CodeExec.Session
  ( ContextStore,
    contextStore,
    contextMetadata,
    SessionConfig (..),
    defaultSessionConfig,
    validateSessionConfig,
    SessionState,
    newSession,
    operationCount,
    subqueryAttempts,
    observedChars,
    SessionAction (..),
    parseSessionAction,
    SessionError (..),
    SessionLimit (..),
    SessionResult (..),
    SessionObservation (..),
    Truncation (..),
    renderObservation,
    stepSession,
    recordObservation,
    attemptedSubquery,
  )
where

import Baikai (Model, emptyModel)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), eitherDecodeStrict, object, withObject, (.:), (.=))
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as M
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Shikumi.CodeExec.Prompt (encodeText)

newtype ContextStore = ContextStore (Map Text Text)

-- | Names and contents are immutable. Total size is checked by 'newSession'.
contextStore :: [(Text, Text)] -> Either SessionError ContextStore
contextStore xs
  | any (not . validName . fst) xs = Left (SessionError "invalid document name")
  | M.size m /= length xs = Left (SessionError "duplicate document name")
  | otherwise = Right (ContextStore m)
  where
    m = M.fromList xs

contextMetadata :: ContextStore -> Value
contextMetadata (ContextStore m) = object ["documents" .= [object ["name" .= n, "length" .= T.length t] | (n, t) <- M.toList m]]

data SessionConfig = SessionConfig
  { maxContextChars :: !Int,
    maxStoredChars :: !Int,
    maxActionBytes :: !Int,
    maxObservationChars :: !Int,
    maxObservedChars :: !Int,
    maxOperations :: !Int,
    maxScanChars :: !Int,
    maxMatches :: !Int,
    maxSubqueries :: !Int,
    maxSubqueryChars :: !Int,
    subModel :: !Model
  }

defaultSessionConfig :: SessionConfig
defaultSessionConfig = SessionConfig 4000000 16000 16000 4000 32000 40 1000000 100 8 8000 emptyModel

validateSessionConfig :: SessionConfig -> Either SessionError ()
validateSessionConfig c
  | any (<= 0) [maxContextChars c, maxStoredChars c, maxActionBytes c, maxObservationChars c, maxObservedChars c, maxOperations c, maxScanChars c, maxMatches c, maxSubqueries c, maxSubqueryChars c] = Left (SessionError "all session limits must be positive")
  | otherwise = Right ()

data SessionState = SessionState
  { sessionConfig :: !SessionConfig,
    documents :: !ContextStore,
    variables :: !(Map Text Value),
    operationCount :: !Int,
    reservedSubqueries :: !Int,
    subqueryAttempts :: !Int,
    observedChars :: !Int
  }

newSession :: SessionConfig -> ContextStore -> Either SessionError SessionState
newSession c docs@(ContextStore m) = do
  validateSessionConfig c
  if sum [toInteger (T.length n) + toInteger (T.length t) | (n, t) <- M.toList m] > toInteger (maxContextChars c)
    then Left (SessionError "context character limit exceeded (including names)")
    else Right (SessionState c docs M.empty 0 0 0 0)

newtype SessionError = SessionError Text deriving stock (Eq, Show)

data SessionLimit = OuterIterations | Operations | Subqueries | RequestCharacters | ObservationCharacters
  deriving stock (Eq, Show)

data SessionAction
  = Describe Text
  | Slice Text Int Int
  | Find Text Text Int Int
  | Store Text Value
  | Load Text
  | Submit Value
  | Query Text
  | QueryBatch [Text]
  deriving stock (Eq, Show)

instance ToJSON SessionAction where
  toJSON a = case a of
    Describe n -> action "describe" ["name" .= n]
    Slice n start count -> action "slice" ["name" .= n, "start" .= start, "count" .= count]
    Find n needle start limit -> action "find" ["name" .= n, "needle" .= needle, "start" .= start, "limit" .= limit]
    Store n v -> action "store" ["name" .= n, "value" .= v]
    Load n -> action "load" ["name" .= n]
    Submit v -> action "submit" ["value" .= v]
    Query p -> action "query" ["prompt" .= p]
    QueryBatch ps -> action "query_batch" ["prompts" .= ps]
    where
      action op fields = object (("op" .= (op :: Text)) : fields)

instance FromJSON SessionAction where
  parseJSON = withObject "session action" $ \o -> do
    op <- o .: "op"
    case (op :: Text) of
      "describe" -> Describe <$> o .: "name"
      "slice" -> Slice <$> o .: "name" <*> o .: "start" <*> o .: "count"
      "find" -> Find <$> o .: "name" <*> o .: "needle" <*> o .: "start" <*> o .: "limit"
      "store" -> Store <$> o .: "name" <*> o .: "value"
      "load" -> Load <$> o .: "name"
      "submit" -> Submit <$> o .: "value"
      "query" -> Query <$> o .: "prompt"
      "query_batch" -> QueryBatch <$> o .: "prompts"
      _ -> fail "unknown operation"

parseSessionAction :: SessionConfig -> Text -> Either SessionError SessionAction
parseSessionAction c raw
  | BS.length (encodeUtf8 raw) > maxActionBytes c = Left (SessionError "action byte limit exceeded")
  | otherwise = case eitherDecodeStrict (encodeUtf8 raw) of
      Left _ -> Left (SessionError "invalid action JSON or fields")
      Right a -> Right a

data Truncation = Truncation
  { originalChars :: !Int,
    displayedChars :: !Int,
    nextOffset :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

data SessionObservation = SessionObservation
  { observationValue :: !Value,
    observationError :: !(Maybe SessionError),
    truncation :: !(Maybe Truncation)
  }
  deriving stock (Eq, Show)

renderObservation :: SessionObservation -> Text
renderObservation o =
  encodeText $
    object
      [ "value" .= observationValue o,
        "error" .= fmap (\(SessionError e) -> e) (observationError o),
        "truncation" .= fmap (\t -> object ["originalChars" .= originalChars t, "displayedChars" .= displayedChars t, "nextOffset" .= nextOffset t]) (truncation o)
      ]

data SessionResult = Observed SessionObservation | RunQueries [Text] | Submitted Value
  deriving stock (Eq, Show)

-- | Every action, including a parse error, consumes one operation. Rejected
-- actions preserve variables. Whole batches reserve slots before any dispatch.
stepSession :: SessionState -> Either SessionError SessionAction -> (SessionState, Either SessionLimit SessionResult)
stepSession s action
  | operationCount s >= maxOperations c = (s, Left Operations)
  | otherwise = case action of
      Left e -> bad e
      Right a | BS.length (encodeUtf8 (encodeText (toJSON a))) > maxActionBytes c -> bad (SessionError "action byte limit exceeded")
      Right a -> case a of
        Describe n -> doc n $ \t -> good (object ["name" .= n, "length" .= T.length t])
        Slice n start count -> doc n $ \t ->
          if start < 0 || start > T.length t || count < 0 || count > T.length t - start
            then bad (SessionError "slice outside document")
            else (s1, Right (Observed (sliceObservation n start count t (maxObservationChars c))))
        Find n needle start limit -> doc n $ \t ->
          if start < 0 || start > T.length t || limit <= 0 || limit > maxMatches c || T.null needle || T.length needle > maxScanChars c
            then bad (SessionError "invalid find offset, needle or match limit")
            else
              let chunk = T.take (maxScanChars c) (T.drop start t)
                  (matches, resume) = search needle limit start chunk
                  end = start + T.length chunk
                  next = if resume < end then resume else if end < T.length t then max (start + 1) (end - T.length needle + 1) else end
               in good (object ["matches" .= matches, "scannedEnd" .= end, "nextOffset" .= next, "complete" .= (next == T.length t)])
        Store n v
          | not (validName n) || M.member n dm -> bad (SessionError "reserved or invalid variable name")
          | otherwise ->
              let vs = M.insert n v (variables s)
               in if sum [toInteger (T.length k) + toInteger (T.length (encodeText x)) | (k, x) <- M.toList vs] > toInteger (maxStoredChars c)
                    then bad (SessionError "stored value character limit exceeded")
                    else (s1 {variables = vs}, Right (Observed (ok (String "stored"))))
        Load n -> maybe (bad (SessionError "unknown variable")) good (M.lookup n (variables s))
        Submit v -> (s1, Right (Submitted v))
        Query p -> queries [p]
        QueryBatch ps -> queries ps
  where
    c = sessionConfig s
    ContextStore dm = documents s
    s1 = s {operationCount = operationCount s + 1}
    bad e = (s1, Right (Observed (SessionObservation Null (Just e) Nothing)))
    good v = (s1, Right (Observed (ok v)))
    doc n f = maybe (bad (SessionError "unknown document")) f (M.lookup n dm)
    queries ps
      | null ps || any ((> maxSubqueryChars c) . T.length) ps = bad (SessionError "empty batch or oversized subquery")
      | length ps > maxSubqueries c - reservedSubqueries s = (s1, Left Subqueries)
      | otherwise = (s1 {reservedSubqueries = reservedSubqueries s + length ps}, Right (RunQueries ps))

ok :: Value -> SessionObservation
ok v = SessionObservation v Nothing Nothing

-- Keep source-relative offsets intact even when JSON escaping expands a slice.
sliceObservation :: Text -> Int -> Int -> Text -> Int -> SessionObservation
sliceObservation name start count source budget = fit (min count budget)
  where
    fit n =
      let v = object ["name" .= name, "start" .= start, "end" .= (start + n), "text" .= T.take n (T.drop start source)]
          tr = if n < count then Just (Truncation count n (Just (start + n))) else Nothing
          o = SessionObservation v Nothing tr
       in if n == 0 || T.length (renderObservation o) <= budget then o else fit (n `div` 2)

search :: Text -> Int -> Int -> Text -> ([Int], Int)
search needle = go
  where
    go 0 offset _ = ([], offset)
    go remaining offset t =
      let (before, after) = T.breakOn needle t
       in if T.null after
            then ([], offset + T.length t)
            else
              let found = offset + T.length before
                  (rest, end) = go (remaining - 1) (found + 1) (T.drop 1 after)
               in (found : rest, end)

-- | Count actual logical LLM dispatch attempts, separately from batch reservations.
attemptedSubquery :: SessionState -> SessionState
attemptedSubquery s = s {subqueryAttempts = subqueryAttempts s + 1}

-- | Bound the complete serialized observation, including metadata and escaping.
-- Oversized non-slice values are shown as a JSON-text prefix, explicitly marked.
-- A limit too small even for metadata exhausts instead of hiding truncation.
recordObservation :: SessionState -> SessionObservation -> (SessionState, Either SessionLimit SessionObservation)
recordObservation s o
  | size > maxObservationChars c || size > maxObservedChars c - observedChars s = (s, Left ObservationCharacters)
  | otherwise = (s {observedChars = observedChars s + size}, Right bounded)
  where
    c = sessionConfig s
    raw = encodeText (observationValue o)
    bounded
      | T.length (renderObservation o) <= maxObservationChars c = o
      | truncation o /= Nothing = o
      | otherwise = fit (min (T.length raw) (maxObservationChars c))
    fit n =
      let candidate = SessionObservation (String (T.take n raw)) (observationError o) (Just (Truncation (T.length raw) n Nothing))
       in if n == 0 || T.length (renderObservation candidate) <= maxObservationChars c then candidate else fit (n `div` 2)
    size = T.length (renderObservation bounded)

validName :: Text -> Bool
validName n = not (T.null n) && T.length n <= 128 && T.all (\x -> x >= 'a' && x <= 'z' || x >= 'A' && x <= 'Z' || x >= '0' && x <= '9' || x == '_' || x == '-') n && n `notElem` ["describe", "slice", "find", "store", "load", "submit", "query", "query_batch"]
