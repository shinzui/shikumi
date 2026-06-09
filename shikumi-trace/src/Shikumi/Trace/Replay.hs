{-# LANGUAGE GADTs #-}

-- | Deterministic offline replay of the @LLM@ effect (EP-7, M3).
--
-- 'runLLMReplay' is a drop-in /alternative interpreter/ of EP-1's @LLM@ effect:
-- where the real interpreter dispatches to a provider, this one answers every
-- 'Shikumi.LLM.complete' from a recorded trace. It computes the EP-6
-- content-addressed 'Shikumi.Cache.Key.cacheKey' of the request, looks it up in a
-- replay index (built by 'Shikumi.Trace.Store.replayIndex'), and returns the
-- recorded 'Baikai.Response' — decoded via the 'Shikumi.Trace.ResponseJSON'
-- instances. Because it replaces the @LLM@ effect at the /same boundary/, the rest
-- of the program (modules, combinators, decoding) runs exactly as in live mode, so
-- the typed outputs are identical; only the leaf LM calls are redirected.
--
-- Divergence is __fail-closed and loud__: a request whose key is not in the trace
-- raises a typed 'ReplayDivergence' carrying the key, the model id, and a redacted
-- prompt summary. It never falls through to the network and never fabricates a
-- response. (There is no registry in this interpreter at all, so "zero provider
-- calls" is structural, not merely policy.)
module Shikumi.Trace.Replay
  ( ReplayDivergence (..),
    runLLMReplay,
  )
where

import Baikai (Context, Model, Response)
import Control.Lens ((^.))
import Data.Aeson (Result (Error, Success), Value, fromJSON)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Exception (Exception, throwIO)
import GHC.Generics (Generic)
import Shikumi.Cache.Key (CacheKey (..), cacheKey)
import Shikumi.LLM (LLM (..))
import Shikumi.Trace.ResponseJSON ()

-- | Raised when a replayed program issues an LM call that the recorded trace
-- never saw.
data ReplayDivergence = ReplayDivergence
  { -- | the content-addressed key that was absent from the trace
    divergedKey :: !CacheKey,
    -- | the model the diverging call targeted
    divergedModel :: !Text,
    -- | a redacted one-line summary of the diverging request
    promptSummary :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Exception)

-- | Interpret the @LLM@ effect by lookup in a replay index instead of calling a
-- provider. A hit returns the recorded response; a miss raises 'ReplayDivergence'.
-- Streaming completions are not replayable and raise a divergence naming the key.
--
-- No @IOE@ is required: the lookup and decode are pure, and 'ReplayDivergence' is
-- raised with @effectful@'s pure-in-@Eff@ 'throwIO'. The contract the plan sketched
-- as @(IOE :> es)@ is therefore satisfied with a strictly weaker constraint.
runLLMReplay :: Map CacheKey Value -> Eff (LLM : es) a -> Eff es a
runLLMReplay idx = interpret $ \_ -> \case
  Complete m c o -> do
    let key = cacheKey m c o
    case Map.lookup key idx of
      Nothing -> throwIO (divergence key m c)
      Just v -> case fromJSON v of
        Success r -> pure (r :: Response)
        Error e ->
          throwIO
            (divergence key m c) {promptSummary = "recorded response failed to decode: " <> T.pack e}
  Stream m c o ->
    throwIO
      (divergence (cacheKey m c o) m c) {promptSummary = "replay does not support streaming completions"}

-- | Build a 'ReplayDivergence' for a request.
divergence :: CacheKey -> Model -> Context -> ReplayDivergence
divergence key m c =
  ReplayDivergence
    { divergedKey = key,
      divergedModel = m ^. #modelId,
      promptSummary = summarizeRequest m c
    }

-- | A redacted, one-line request summary for divergence errors: the routing
-- identity and the message count (no message bodies — those may be sensitive).
summarizeRequest :: Model -> Context -> Text
summarizeRequest m c =
  (m ^. #provider)
    <> "/"
    <> (m ^. #modelId)
    <> " ("
    <> T.pack (show (length (c ^. #messages)))
    <> " messages)"
