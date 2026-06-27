-- | A 'Signature' bundles a task's natural-language instruction, its worked
-- demonstrations, and the input/output field metadata derived from the @i@/@o@
-- record types.
--
-- The @instruction@ and @demos@ are the framework's /optimizable parameters/
-- (integration point #3): they are first-class, replaceable values that the
-- compiler (EP-9) and optimizer (EP-10) rewrite to improve quality. The
-- @inputFields@/@outputFields@ are /derived metadata/ (not optimizable). Because
-- 'Signature' derives 'Generic', the @#instruction@ / @#demos@ @generic-lens@
-- optics are available to downstream plans for free.
module Shikumi.Signature
  ( Demo (..),
    Signature (..),
    mkSignature,
    getInstruction,
    setInstruction,
    getDemos,
    setDemos,
  )
where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Text (Text)
import GHC.Generics (Generic, Rep)
import Shikumi.Schema (GFieldMetas, fieldMetasOf)
import Shikumi.Schema.Types (FieldMeta)

-- | A worked input -> output example shown to the model. Optimizers select and
-- rewrite these.
data Demo i o = Demo
  { input :: !i,
    output :: !o
  }
  deriving stock (Generic, Show, Eq)

-- | A typed task signature. @i@ and @o@ are the input/output record types; they
-- are kept in the type so a program can hold a @Signature Article Summary@ and
-- the compiler enforces the input/output types.
data Signature i o = Signature
  { -- | optimizable: the task description
    instruction :: !Text,
    -- | optimizable: worked examples
    demos :: ![Demo i o],
    -- | derived metadata: the input record's fields
    inputFields :: ![FieldMeta],
    -- | derived metadata: the output record's fields
    outputFields :: ![FieldMeta]
  }
  deriving stock (Generic, Show)

-- | Build a signature from an instruction; demos start empty and the field
-- metadata is derived from @i@ and @o@ by the shared 'fieldMetasOf' traversal.
mkSignature ::
  forall i o.
  (GFieldMetas (Rep i), GFieldMetas (Rep o)) =>
  Text ->
  Signature i o
mkSignature instr =
  Signature
    { instruction = instr,
      demos = [],
      inputFields = fieldMetasOf @i,
      outputFields = fieldMetasOf @o
    }

-- | Read the (optimizable) instruction.
getInstruction :: Signature i o -> Text
getInstruction = instruction

-- | Replace the (optimizable) instruction.
setInstruction :: Text -> Signature i o -> Signature i o
setInstruction t sig = sig & #instruction .~ t

-- | Read the (optimizable) demonstrations.
getDemos :: Signature i o -> [Demo i o]
getDemos = demos

-- | Replace the (optimizable) demonstrations.
setDemos :: [Demo i o] -> Signature i o -> Signature i o
setDemos ds sig = sig & #demos .~ ds
