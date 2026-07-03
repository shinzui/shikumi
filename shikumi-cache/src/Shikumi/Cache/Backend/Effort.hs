-- | The one error posture every persistent cache backend shares: best-effort.
-- A failed storage action degrades to its fallback (a MISS for lookups, a no-op
-- for stores) instead of throwing. Asynchronous exceptions such as thread
-- cancellation and timeouts are re-thrown so structured concurrency keeps
-- working correctly.
module Shikumi.Cache.Backend.Effort (bestEffortIO) where

import Control.Exception (SomeAsyncException (..), SomeException, catch, fromException, throwIO)

bestEffortIO :: a -> IO a -> IO a
bestEffortIO fallback act =
  act `catch` \(e :: SomeException) ->
    case fromException e of
      Just (SomeAsyncException _) -> throwIO e
      Nothing -> pure fallback
