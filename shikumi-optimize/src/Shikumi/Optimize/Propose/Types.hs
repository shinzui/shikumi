-- | The shared types of the grounded instruction proposer (EP-19): the per-node
-- field-metadata accessor (integration point #3), the instruction-history vocabulary,
-- and the proposer's request/result records.
--
-- This is the contract MIPROv2 (@docs/plans/20-miprov2-optimizer.md@) and COPRO
-- (@docs/plans/21-copro-instruction-optimizer.md@) both consume, so it lives in its
-- own module — neither optimizer drags in @instructionSearch@'s loop to use it.
module Shikumi.Optimize.Propose.Types
  ( -- * Per-node field metadata (integration point #3)
    NodeFieldNames (..),
    programFieldNames,
    moduleSignatureAt,

    -- * Instruction history
    PastInstruction (..),
    renderHistory,

    -- * The proposer request/result
    ProposeRequest (..),
    ProposeResult (..),
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Shikumi.Program (NodeFields (NodeFields), Program, nodeFieldsIndexed)

-- | A node's input/output field names, recovered structurally. A 'Predict' node
-- hides its @i@/@o@ types existentially, so this carries the field /names/ (plain
-- 'Text'), never a typed @Signature@ — exactly what EP-16's @nodeFieldsIndexed@
-- returns.
data NodeFieldNames = NodeFieldNames
  { inputFieldNames :: ![Text],
    outputFieldNames :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

-- | One 'NodeFieldNames' per 'Predict' node, in @foldParams@/@mapParamsAt@ order
-- (integration point #3). Delegates to EP-16's @nodeFieldsIndexed@; the count and
-- ordering align with @foldParams@ by construction, so
-- @programFieldNames prog !! k@ describes the node @mapParamsAt k@ edits.
programFieldNames :: Program i o -> [NodeFieldNames]
programFieldNames = map convert . nodeFieldsIndexed
  where
    convert (NodeFields i o) = NodeFieldNames i o

-- | A human-readable signature for node @k@: @predict(in1, in2) -> out1@. Used as
-- the @moduleSignature@ signal in a proposal prompt. An out-of-range index yields
-- @predict(?) -> ?@.
moduleSignatureAt :: Int -> Program i o -> Text
moduleSignatureAt k prog = case drop k (programFieldNames prog) of
  (nf : _) -> "predict(" <> commas (inputFieldNames nf) <> ") -> " <> commas (outputFieldNames nf)
  [] -> "predict(?) -> ?"
  where
    commas xs = if null xs then "?" else T.intercalate ", " xs

-- | One past attempt for a node: the instruction text and the score it earned.
data PastInstruction = PastInstruction
  { pastInstruction :: !Text,
    pastScore :: !Double
  }
  deriving stock (Eq, Show, Generic)

-- | Render the instruction history as lines @"score 0.83 :: <instruction>"@, capped
-- at @maxInHistory@ entries. Empty history renders as @"No previous instructions."@
-- so the proposal prompt is always well-formed.
renderHistory :: Int -> [PastInstruction] -> Text
renderHistory maxInHistory hist = case take (max 0 maxInHistory) hist of
  [] -> "No previous instructions."
  xs -> T.intercalate "\n" (map line xs)
  where
    line (PastInstruction ins sc) = "score " <> tshow sc <> " :: " <> ins

-- | Everything the grounded proposer needs to propose instructions for one node.
data ProposeRequest i o = ProposeRequest
  { -- | the program being optimized
    program :: !(Program i o),
    -- | @foldParams@ index of the node to propose for
    targetNode :: !Int,
    -- | the node's instruction now (always retained as a candidate)
    currentInstruction :: !Text,
    -- | prior attempts + scores for this node
    history :: ![PastInstruction],
    -- | rendered demos for this node (may be empty)
    bootstrappedDemos :: ![Text],
    -- | how many fresh candidates to ask for (N)
    numCandidates :: !Int,
    -- | selects a tip deterministically (added to the per-candidate offset)
    tipIndex :: !Int,
    -- | dataset rows to sample for the summary
    viewBatch :: !Int
  }

-- | A ranked list of candidate instruction strings for one node, distinct and with
-- the current instruction always present (and first). The proposer does not score —
-- scoring belongs to the calling optimizer.
newtype ProposeResult = ProposeResult {rankedCandidates :: [Text]}
  deriving stock (Eq, Show, Generic)

tshow :: (Show a) => a -> Text
tshow = T.pack . show
