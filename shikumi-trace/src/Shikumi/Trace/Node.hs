{-# LANGUAGE ScopedTypeVariables #-}

-- | Node identity for the trace (EP-16, M1).
--
-- A 'NodePath' names a 'Shikumi.Program.Program' node's structural position as the
-- list of branch steps from the program root. 'programNodePaths' enumerates the
-- path of every @Predict@ node in /exactly/ the left-to-right depth-first order
-- 'Shikumi.Program.foldParams' yields their @Params@ — so @programNodePaths p !! n@
-- is the path to the same node @mapParamsAt n@ edits and @foldParams p !! n@
-- parameterizes. That agreement is the parent MasterPlan's integration point #3,
-- and it is structural (the enumeration reuses the identical depth-first descent),
-- not a coincidence two functions must independently maintain.
module Shikumi.Trace.Node
  ( NodeStep (..),
    NodePath (..),
    programNodePaths,
    renderNodePath,
    nodeFields,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Shikumi.Program
  ( NodeFields,
    Program
      ( Compose,
        Embed,
        Ensemble,
        FMap,
        MajorityVote,
        Map,
        Parallel,
        Predict,
        Retry,
        RetryWhen,
        Validate
      ),
    nodeFieldsIndexed,
  )

-- | One structural step from a parent node to a child, naming which branch was
-- taken. The labels mirror the 'Shikumi.Program.Program' constructors so a path is
-- human-readable and shape-stable: two programs of the same shape yield identical
-- paths.
data NodeStep
  = -- | into the left side of @Compose@
    StepComposeL
  | -- | into the right side of @Compose@
    StepComposeR
  | -- | through an @FMap@
    StepFMap
  | -- | through a @Map@
    StepMap
  | -- | into the left side of @Parallel@
    StepParallelL
  | -- | into the right side of @Parallel@
    StepParallelR
  | -- | through a @Retry@
    StepRetry
  | -- | through a @RetryWhen@
    StepRetryWhen
  | -- | through a @Validate@
    StepValidate
  | -- | through a @MajorityVote@
    StepMajorityVote
  | -- | into the i-th member of an @Ensemble@ (0-based)
    StepEnsemble !Int
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The structural position of a node within a 'Shikumi.Program.Program', as the
-- list of steps from the program root to that node, outermost first. A bare
-- root @Predict@ has the empty path.
newtype NodePath = NodePath [NodeStep]
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | Enumerate the 'NodePath' of every @Predict@ node, in the same left-to-right
-- depth-first order as 'Shikumi.Program.foldParams'. Reuses that identical descent
-- so length and node order agree by construction.
programNodePaths :: Program i o -> [NodePath]
programNodePaths = go []
  where
    -- @prefix@ is the reversed list of steps taken so far; we reverse on emit.
    go :: forall x y. [NodeStep] -> Program x y -> [NodePath]
    go prefix (Predict _ _) = [NodePath (reverse prefix)]
    go prefix (Compose a b) = go (StepComposeL : prefix) a ++ go (StepComposeR : prefix) b
    go prefix (FMap _ p) = go (StepFMap : prefix) p
    go prefix (Map _ p) = go (StepMap : prefix) p
    go prefix (Parallel a b) = go (StepParallelL : prefix) a ++ go (StepParallelR : prefix) b
    go prefix (Retry _ p) = go (StepRetry : prefix) p
    go prefix (RetryWhen _ _ p) = go (StepRetryWhen : prefix) p
    go prefix (Validate _ p) = go (StepValidate : prefix) p
    go prefix (MajorityVote _ _ p) = go (StepMajorityVote : prefix) p
    go prefix (Ensemble ps _) = concat (zipWith (\i p -> go (StepEnsemble i : prefix) p) [0 ..] ps)
    go _ (Embed _) = []

-- | Render a 'NodePath' to a short, stable string (e.g. @compose.0/predict@-style
-- slash-joined steps), suitable as a trace/OTel attribute value. The empty path
-- renders as @\"root\"@.
renderNodePath :: NodePath -> Text
renderNodePath (NodePath []) = "root"
renderNodePath (NodePath steps) = T.intercalate "/" (map stepLabel steps)
  where
    stepLabel = \case
      StepComposeL -> "compose.l"
      StepComposeR -> "compose.r"
      StepFMap -> "fmap"
      StepMap -> "map"
      StepParallelL -> "parallel.l"
      StepParallelR -> "parallel.r"
      StepRetry -> "retry"
      StepRetryWhen -> "retryWhen"
      StepValidate -> "validate"
      StepMajorityVote -> "majorityVote"
      StepEnsemble i -> "ensemble." <> T.pack (show i)

-- | Associate each @Predict@ node's 'NodePath' with its input/output field names.
-- A consumer with a 'NodePath' from a trace span zips against this to map
-- path → field metadata; one with a @foldParams@ index uses
-- 'Shikumi.Program.nodeFieldsIndexed' directly.
nodeFields :: Program i o -> [(NodePath, NodeFields)]
nodeFields p = zip (programNodePaths p) (nodeFieldsIndexed p)
