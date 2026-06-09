{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The per-node feedback channel (EP-16, M3).
--
-- A 'FeedbackLog' is a sibling of the trace (deliberately /not/ part of
-- 'Shikumi.Trace.TraceTree', whose serialized format is pinned and consumed by
-- replay): it maps a node's 'NodePath' to the textual critiques attached to it. A
-- metric or LM-judge writes a critique with 'attachFeedback' during evaluation; an
-- optimizer reads all critiques for a node with 'feedbackFor' during a proposal
-- step. GEPA (@docs/plans/22-gepa-reflective-optimizer.md@) is the headline
-- consumer.
module Shikumi.Trace.Feedback
  ( FeedbackLog (..),
    emptyFeedback,
    feedbackFor,
    Feedback (..),
    attachFeedback,
    runFeedback,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Prim (Prim)
import Effectful.Prim.IORef (modifyIORef', newIORef, readIORef)
import Shikumi.Trace.Node (NodePath)

-- | All feedback gathered during a run: critiques keyed by the node they target. A
-- node may accumulate several critiques (e.g. one per example), kept in attach
-- order.
newtype FeedbackLog = FeedbackLog (Map NodePath [Text])
  deriving stock (Eq, Show)

-- | Serialized as a list of @(NodePath, [Text])@ pairs, so 'NodePath' needs only
-- 'ToJSON'\/'FromJSON' (not a text 'ToJSONKey').
instance ToJSON FeedbackLog where
  toJSON (FeedbackLog m) = toJSON (Map.toList m)

instance FromJSON FeedbackLog where
  parseJSON v = FeedbackLog . Map.fromList <$> parseJSON v

-- | The empty log.
emptyFeedback :: FeedbackLog
emptyFeedback = FeedbackLog Map.empty

-- | All critiques attached to a node, in attach order (empty if none).
feedbackFor :: NodePath -> FeedbackLog -> [Text]
feedbackFor p (FeedbackLog m) = Map.findWithDefault [] p m

-- | The effect a metric or judge uses to attach feedback during a run.
data Feedback :: Effect where
  AttachFeedback :: NodePath -> Text -> Feedback m ()

type instance DispatchOf Feedback = 'Dynamic

-- | Attach a short textual critique to a node.
attachFeedback :: (Feedback :> es) => NodePath -> Text -> Eff es ()
attachFeedback p t = send (AttachFeedback p t)

-- | Run the feedback effect, returning the result paired with the collected log.
-- Accumulates into an @IORef@ via 'Prim' (the same mechanism @runTrace@ uses),
-- appending each critique to its node's list.
runFeedback :: (Prim :> es) => Eff (Feedback : es) a -> Eff es (a, FeedbackLog)
runFeedback act = do
  ref <- newIORef Map.empty
  a <-
    interpret
      ( \_ -> \case
          AttachFeedback p t -> modifyIORef' ref (Map.insertWith (\new old -> old ++ new) p [t])
      )
      act
  m <- readIORef ref
  pure (a, FeedbackLog m)
