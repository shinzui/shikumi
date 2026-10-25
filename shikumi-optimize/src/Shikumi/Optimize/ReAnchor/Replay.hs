{-# LANGUAGE RankNTypes #-}

-- | Run-local response replay, placed inside candidate admission. Node-path
-- capture works for ordinary Predict leaves without requiring typed codecs.
module Shikumi.Optimize.ReAnchor.Replay (ReplayStore, newReplayStore, withReplay, runResponses) where

import Baikai (Response)
import Data.Map.Strict qualified as Map
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Error.Static (Error, catchError)
import Effectful.Prim.IORef (IORef, Prim, modifyIORef', newIORef, readIORef)
import Shikumi.Cache.Key (CacheKey, cacheKey)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..), complete, stream)
import Shikumi.Program (Program, runProgram)
import Shikumi.Trace.Node (NodePath)
import Shikumi.Trace.Program (walkProgramWith)

newtype ReplayStore = ReplayStore (IORef (Map.Map CacheKey Response))

newReplayStore :: (Prim :> es) => Eff es ReplayStore
newReplayStore = ReplayStore <$> newIORef Map.empty

withReplay :: (LLM :> es, Prim :> es) => ReplayStore -> Eff es a -> Eff es a
withReplay (ReplayStore store) = interpose $ \_ -> \case
  Complete m c o -> do
    let key = cacheKey m c o
    recorded <- Map.lookup key <$> readIORef store
    case recorded of
      Just response -> pure response
      Nothing -> do
        response <- complete m c o
        modifyIORef' store (Map.insert key response)
        pure response
  Stream m c o -> stream m c o

runResponses :: forall es i o. (LLM :> es, Prim :> es, Error ShikumiError :> es) => ReplayStore -> IORef [(NodePath, Response)] -> Program i o -> i -> Eff es (Either ShikumiError o)
runResponses store seen program input =
  (Right <$> walkProgramWith (\_ _ action -> action) leaf (pure ()) program input) `catchError` \_ err -> pure (Left err)
  where
    leaf :: forall x y. NodePath -> Program x y -> x -> Eff es y
    leaf path node x =
      interpose
        ( \_ -> \case
            Complete m c o -> do
              response <- withReplay store (complete m c o)
              modifyIORef' seen (++ [(path, response)])
              pure response
            Stream m c o -> stream m c o
        )
        (runProgram node x)
