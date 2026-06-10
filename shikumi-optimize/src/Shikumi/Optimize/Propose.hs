-- | The grounded instruction proposer (EP-19), a single import for consumers
-- (instruction search today; MIPROv2 and COPRO next). Re-exports the public surface:
-- the 'proposeInstructions' driver, its request/result records, the per-node
-- field-metadata accessor (integration point #3), the instruction-history vocabulary,
-- and the tip bank.
module Shikumi.Optimize.Propose
  ( -- * The proposer
    proposeInstructions,
    ProposeRequest (..),
    ProposeResult (..),

    -- * Per-node field metadata (integration point #3)
    NodeFieldNames (..),
    programFieldNames,
    moduleSignatureAt,

    -- * Instruction history
    PastInstruction (..),
    renderHistory,

    -- * Tips
    tipBank,
    tipAt,

    -- * Pseudo-code and dataset summary (reusable by GEPA, EP-22)
    renderProgramPseudo,
    datasetSummary,
  )
where

import Shikumi.Optimize.Propose.Grounded (proposeInstructions)
import Shikumi.Optimize.Propose.Summarize (datasetSummary, renderProgramPseudo)
import Shikumi.Optimize.Propose.Tips (tipAt, tipBank)
import Shikumi.Optimize.Propose.Types
  ( NodeFieldNames (..),
    PastInstruction (..),
    ProposeRequest (..),
    ProposeResult (..),
    moduleSignatureAt,
    programFieldNames,
    renderHistory,
  )
