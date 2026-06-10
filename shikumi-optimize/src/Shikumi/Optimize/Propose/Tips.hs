-- | The stylistic tip bank (EP-19), porting DSPy's @GroundedProposer.TIPS@. A tip
-- is a one-sentence suggestion to the proposing model. Selection is deterministic
-- (an index modulo the bank size), not a hidden RNG, so proposals are reproducible
-- and a search can vary the tip across rounds by varying the index.
module Shikumi.Optimize.Propose.Tips
  ( tipBank,
    tipAt,
  )
where

import Data.Text (Text)

-- | The stylistic tips, in a fixed order: none, creative, simple, descriptive,
-- high-stakes, persona.
tipBank :: [Text]
tipBank =
  [ "",
    "Don't be afraid to be creative when creating the new instruction!",
    "Keep the instruction clear and concise.",
    "Make sure your instruction is very informative and descriptive.",
    "The instruction should describe a high-stakes scenario in which the model must solve the task.",
    "Include a persona relevant to the task in the instruction (e.g. \"You are a ...\")."
  ]

-- | The tip at @i@ modulo the bank size (so an out-of-range index wraps).
tipAt :: Int -> Text
tipAt i = tipBank !! (i `mod` length tipBank)
