{-# LANGUAGE RankNTypes #-}

-- | Recordings of provider outcomes and the record/replay boundary.
--
-- A recording maps each request key ('Shikumi.Cache.Key.cacheKey') to the
-- ordered list of that request's outcomes, in the order the calls were issued.
-- It does not memoize one answer per key: a 'Shikumi.Program.Retry' re-issues the
-- identical request, and a replay must hand the retry the next recorded answer,
-- not the failing first one. An outcome is a response or one of the typed errors
-- the comparison counts as an example failure.
--
-- The recording boundary always calls through, stores the response's JSON, and
-- returns the decoded form of what it stored, so a live run computes from the
-- same bytes a replay will see. The replaying boundary never calls through: the
-- nth request for a key receives the nth recorded outcome, and a missing outcome,
-- or one left unconsumed when the phase ends, raises
-- t'Shikumi.Trace.Replay.ReplayDivergence'.
--
-- Both boundaries refuse, with t'UnrecordableCall', calls they cannot record
-- faithfully: streamed calls and calls whose options request provider evidence
-- (a stored response drops its evidence record). t'UnrecordableCall' is an
-- exception, not a t'ShikumiError', so no typed-error boundary can score it as an
-- ordinary failed example.
module Shikumi.Evidence.Recording
  ( -- * Routes
    RouteIdentity (..),
    RouteCount (..),
    routeOf,

    -- * Recordings
    Recording (..),
    RecordingEntry (..),
    RecordedOutcome (..),
    RecordingError (..),
    recordingKind,
    sealRecording,
    readRecordingForReplay,
    decodeRecording,
    validateRecording,
    recordableError,

    -- * The boundary
    UnrecordableCall (..),
    Boundary,
    newRecorder,
    newReplayer,
    withBoundary,
    setBoundaryScope,
    boundaryRoutes,
    finishBoundary,
  )
where

import Baikai (Model, Response)
import Baikai.Api (renderApi)
import Control.Lens ((^.))
import Control.Monad (forM_, unless, when)
import Data.Aeson (FromJSON (..), Result (..), ToJSON (..), Value (..), fromJSON, object, withObject, (.:), (.:?), (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Error.Static (Error, catchError, throwError)
import Effectful.Exception (Exception, throwIO)
import Effectful.Prim.IORef (IORef, Prim, atomicModifyIORef', newIORef, readIORef)
import GHC.Generics (Generic)
import Shikumi.Cache.Key (CacheKey (..), cacheKey, currentKeyVersion)
import Shikumi.Cache.ResponseJSON ()
import Shikumi.Error (ShikumiError (..))
import Shikumi.Evidence.Digest
import Shikumi.LLM (LLM (..), complete)
import Shikumi.Trace.Replay (ReplayDivergence (..))

-- ---------------------------------------------------------------------------
-- Routes
-- ---------------------------------------------------------------------------

-- | The requested route of a call: provider, model id, API and base URL. This is
-- read from the request, because a response's model is the request's model
-- echoed back and the observed identity lives only in provider evidence (ADR-13).
data RouteIdentity = RouteIdentity
  { provider :: !Text,
    modelId :: !Text,
    api :: !Text,
    baseUrl :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A route with the number of calls dispatched to it.
data RouteCount = RouteCount
  { route :: !RouteIdentity,
    calls :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The requested route of a model.
routeOf :: Model -> RouteIdentity
routeOf m = RouteIdentity (m ^. #provider) (m ^. #modelId) (renderApi (m ^. #api)) (m ^. #baseUrl)

-- ---------------------------------------------------------------------------
-- Recordings
-- ---------------------------------------------------------------------------

-- | One recorded outcome.
data RecordedOutcome
  = -- | the response's JSON, as 'Shikumi.Cache.ResponseJSON' encodes it
    RecordedResponse !Value
  | -- | a typed error: its constructor name and payload
    RecordedError !Text !Text
  deriving stock (Eq, Show)

instance ToJSON RecordedOutcome where
  toJSON = \case
    RecordedResponse v -> object ["response" .= v]
    RecordedError c m -> object ["error" .= object ["constructor" .= c, "message" .= m]]

instance FromJSON RecordedOutcome where
  parseJSON = withObject "RecordedOutcome" $ \o -> do
    response <- o .:? "response"
    failure <- o .:? "error"
    case (response, failure) of
      (Just v, Nothing) -> pure (RecordedResponse v)
      (Nothing, Just e) -> withObject "RecordedError" (\eo -> RecordedError <$> eo .: "constructor" <*> eo .: "message") e
      _ -> fail "a recorded outcome holds exactly one of response or error"

-- | All outcomes of one request key, in issue order.
data RecordingEntry = RecordingEntry
  { requestKey :: !Text,
    outcomes :: ![RecordedOutcome]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The recording envelope of one phase. Entries are sorted by key.
data Recording = Recording
  { artifactKind :: !Text,
    schemaVersion :: !Int,
    -- | @optimization@ or @comparison@
    phase :: !Text,
    cacheKeyVersion :: !Text,
    entries :: ![RecordingEntry],
    contentDigest :: !Digest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The @artifactKind@ of a recording envelope.
recordingKind :: Text
recordingKind = "shikumi.evidence.recording"

-- | Compute and store a recording's digest.
sealRecording :: Recording -> Recording
sealRecording = sealEnvelope (\d r -> r {contentDigest = d})

-- | Problems with a recording envelope.
data RecordingError
  = MalformedRecording !Text
  | WrongRecordingKind !Text
  | UnsupportedRecordingVersion !Int
  | RecordingDigestMismatch !Digest !Digest
  | CacheKeyVersionMismatch !Text !Text
  | UnsortedEntries
  | EmptyEntry !Text
  | UnknownErrorConstructor !Text
  deriving stock (Eq, Show)

-- | Decode a recording: digest on the raw value, exact round trip, validation.
decodeRecording :: BL.ByteString -> Either [RecordingError] Recording
decodeRecording bytes = do
  (_, r) <- either (Left . (: []) . MalformedRecording) Right (decodeEnvelope True bytes)
  r <$ validateRecording r

-- | Read a recording to replay it. Everything 'decodeRecording' checks is
-- checked except the stored digest, which is recomputed from the content
-- instead. A replay establishes a recording's integrity itself: a missing or
-- surplus outcome raises t'ReplayDivergence', and any other change alters the
-- recording digest that the candidate and report bind, so their digests no
-- longer match the originals.
readRecordingForReplay :: BL.ByteString -> Either [RecordingError] Recording
readRecordingForReplay bytes = do
  (_, r) <- either (Left . (: []) . MalformedRecording) Right (decodeEnvelope False bytes)
  let resealed = sealRecording r
  resealed <$ validateRecording resealed

-- | Validate a recording envelope.
validateRecording :: Recording -> Either [RecordingError] ()
validateRecording r = if null problems then Right () else Left problems
  where
    computed = envelopeDigest (toJSON r)
    keys = map (.requestKey) r.entries
    problems =
      [WrongRecordingKind (r.artifactKind) | r.artifactKind /= recordingKind]
        ++ [UnsupportedRecordingVersion (r.schemaVersion) | r.schemaVersion /= 1]
        ++ [RecordingDigestMismatch (r.contentDigest) computed | r.contentDigest /= computed]
        ++ [CacheKeyVersionMismatch (r.cacheKeyVersion) currentKeyVersion | r.cacheKeyVersion /= currentKeyVersion]
        ++ [UnsortedEntries | keys /= sort keys || length keys /= Map.size (Map.fromList (map (,()) keys))]
        ++ [EmptyEntry (e.requestKey) | e <- r.entries, null (e.outcomes)]
        ++ [UnknownErrorConstructor c | e <- r.entries, RecordedError c m <- e.outcomes, not (isJust (fromRecordedError c m))]

-- | The typed errors a recording stores and the comparison counts as example
-- failures, with their constructor name and payload.
recordableError :: ShikumiError -> Maybe (Text, Text)
recordableError = \case
  InvalidJSON t -> Just ("InvalidJSON", t)
  MissingField t -> Just ("MissingField", t)
  SchemaMismatch t -> Just ("SchemaMismatch", t)
  ValidationFailure t -> Just ("ValidationFailure", t)
  Timeout t -> Just ("Timeout", t)
  ContextWindowExceeded t -> Just ("ContextWindowExceeded", t)
  CodeExecFailed t -> Just ("CodeExecFailed", t)
  _ -> Nothing

fromRecordedError :: Text -> Text -> Maybe ShikumiError
fromRecordedError c t = case c of
  "InvalidJSON" -> Just (InvalidJSON t)
  "MissingField" -> Just (MissingField t)
  "SchemaMismatch" -> Just (SchemaMismatch t)
  "ValidationFailure" -> Just (ValidationFailure t)
  "Timeout" -> Just (Timeout t)
  "ContextWindowExceeded" -> Just (ContextWindowExceeded t)
  "CodeExecFailed" -> Just (CodeExecFailed t)
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- The boundary
-- ---------------------------------------------------------------------------

-- | A call the boundary cannot record faithfully. Never a t'ShikumiError'.
newtype UnrecordableCall = UnrecordableCall Text
  deriving stock (Eq, Show)
  deriving anyclass (Exception)

data Mode
  = Recording' !(IORef (Map CacheKey [RecordedOutcome]))
  | Replaying' !Recording !(Map CacheKey [RecordedOutcome]) !(IORef (Map CacheKey Int))

-- | One phase's record or replay boundary, with the routes it saw per scope.
data Boundary = Boundary
  { mode :: !Mode,
    scope :: !(IORef Text),
    routes :: !(IORef (Map Text (Map RouteIdentity Int)))
  }

-- | A boundary that records live outcomes.
newRecorder :: (Prim :> es) => Eff es Boundary
newRecorder = Boundary <$> (Recording' <$> newIORef Map.empty) <*> newIORef "" <*> newIORef Map.empty

-- | A boundary that replays a recording.
newReplayer :: (Prim :> es) => Recording -> Eff es Boundary
newReplayer r =
  Boundary
    <$> (Replaying' r (Map.fromList [(CacheKey (e.requestKey), e.outcomes) | e <- r.entries]) <$> newIORef Map.empty)
    <*> newIORef ""
    <*> newIORef Map.empty

-- | Attribute subsequent calls' routes to a scope, such as an arm.
setBoundaryScope :: (Prim :> es) => Boundary -> Text -> Eff es ()
setBoundaryScope b label = atomicModifyIORef' (b.scope) (const (label, ()))

-- | Routes seen under a scope, or under every scope when 'Nothing'.
boundaryRoutes :: (Prim :> es) => Boundary -> Maybe Text -> Eff es [RouteCount]
boundaryRoutes b which = do
  byScope <- readIORef (b.routes)
  let chosen = maybe (Map.elems byScope) (\k -> [Map.findWithDefault Map.empty k byScope]) which
  pure [RouteCount r n | (r, n) <- Map.toList (Map.unionsWith (+) chosen)]

-- | Install the boundary on every LLM call of an action.
withBoundary :: (LLM :> es, Prim :> es, Error ShikumiError :> es) => Boundary -> Eff es a -> Eff es a
withBoundary b = interpose $ \_ -> \case
  Stream m _ _ -> do
    _ <- throwIO (UnrecordableCall ("streamed call to " <> m ^. #modelId <> " cannot be recorded"))
    pure []
  Complete m c o -> do
    when (isJust (o ^. #evidence)) $
      throwIO (UnrecordableCall ("call to " <> m ^. #modelId <> " requests provider evidence, which a recording cannot reproduce"))
    label <- readIORef (b.scope)
    atomicModifyIORef' (b.routes) (\rs -> (Map.insertWith (Map.unionWith (+)) label (Map.singleton (routeOf m) 1) rs, ()))
    let key = cacheKey m c o
    case b.mode of
      Recording' store -> do
        let append outcome = atomicModifyIORef' store (\s -> (Map.insertWith (flip (++)) key [outcome] s, ()))
        result <- (Right <$> complete m c o) `catchError` \_ e -> pure (Left e)
        case result of
          Right response -> do
            let stored = toJSON response
            case fromJSON stored of
              Success decoded -> do
                append (RecordedResponse stored)
                pure (decoded :: Response)
              Error e -> throwIO (UnrecordableCall ("response does not round-trip through JSON: " <> T.pack e))
          Left e -> case recordableError e of
            Just (cons, payload) -> append (RecordedError cons payload) >> throwError e
            Nothing -> throwError e
      Replaying' _ recorded cursors -> do
        n <- atomicModifyIORef' cursors (\cs -> let k = Map.findWithDefault 0 key cs in (Map.insert key (k + 1) cs, k))
        case drop n (Map.findWithDefault [] key recorded) of
          [] -> throwIO (ReplayDivergence key (m ^. #modelId) (if n == 0 then "request absent from the recording" else "recording has no outcome " <> T.pack (show (n + 1)) <> " for this request"))
          RecordedResponse v : _ -> case fromJSON v of
            Success response -> pure response
            Error e -> throwIO (ReplayDivergence key (m ^. #modelId) ("recorded response failed to decode: " <> T.pack e))
          RecordedError cons payload : _ -> case fromRecordedError cons payload of
            Just e -> throwError e
            Nothing -> throwIO (ReplayDivergence key (m ^. #modelId) ("recorded error has an unknown constructor: " <> cons))

-- | End a phase. A recorder seals what it saw; a replayer checks that every
-- recorded outcome was consumed and returns the recording it replayed.
finishBoundary :: (Prim :> es) => Boundary -> Text -> Eff es Recording
finishBoundary b phaseName = case b.mode of
  Recording' store -> do
    recorded <- readIORef store
    pure $
      sealRecording
        Recording
          { artifactKind = recordingKind,
            schemaVersion = 1,
            phase = phaseName,
            cacheKeyVersion = currentKeyVersion,
            entries = [RecordingEntry (unCacheKey k) os | (k, os) <- Map.toAscList recorded],
            contentDigest = Digest ""
          }
  Replaying' r recorded cursors -> do
    used <- readIORef cursors
    forM_ (Map.toAscList recorded) $ \(key, os) -> do
      let n = Map.findWithDefault 0 key used
      unless (n >= length os) $
        throwIO (ReplayDivergence key "" ("recorded outcome " <> T.pack (show (n + 1)) <> " of " <> T.pack (show (length os)) <> " was never requested"))
    pure r
