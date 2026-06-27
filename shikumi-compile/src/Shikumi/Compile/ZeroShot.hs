-- | The zero-shot compiler: set a single instruction at every LM-call node and
-- clear all demonstrations. The simplest real compiler, and the first to exercise
-- EP-4's parameter traversal ('Shikumi.Program.mapParams').
module Shikumi.Compile.ZeroShot
  ( zeroShot,
    zeroShotClear,
  )
where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Text (Text)
import Shikumi.Compile.Types (Compiler (..))
import Shikumi.Program (mapParams)

-- | Override every node's instruction with @instr@ and remove all demos. Reaches
-- every 'Shikumi.Program.Predict' node in the program — including nodes nested
-- inside @Compose@/@Parallel@/@Retry@/etc. — because 'mapParams' visits them all.
zeroShot :: Text -> Compiler
zeroShot instr =
  Compiler $
    mapParams (\ps -> ps & #instructionOverride .~ Just instr & #demos .~ [])

-- | Clear demos at every node but keep each node's existing instruction override
-- (i.e. fall back to the signature default where none was set). Useful to strip a
-- few-shot program back to zero-shot without choosing a new instruction.
zeroShotClear :: Compiler
zeroShotClear = Compiler $ mapParams (\ps -> ps & #demos .~ [])
