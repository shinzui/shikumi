-- | The few-shot compiler: inject a /static/ list of demonstrations into every
-- LM-call node's parameters. This is DSPy's @LabeledFewShot@ and the headline
-- compiler of the plan.
--
-- The injected 'Demo's are stored as type-agnostic JSON (EP-4's
-- 'Shikumi.Program.Demo' carries @input@/@output@ as aeson @Value@s), so a
-- single demo pool attaches uniformly to every node regardless of its signature.
-- At run time each node's adapter (EP-3) renders the fields it recognizes; a demo
-- authored for one node's shape simply renders what overlaps at a node with a
-- different shape. Use 'Shikumi.Compile.FewShot.fewShotTyped' to build demos from
-- typed pairs.
module Shikumi.Compile.FewShot
  ( fewShot,
    fewShotTyped,
  )
where

import Control.Lens ((&), (.~))
import Data.Aeson (ToJSON, toJSON)
import Data.Generics.Labels ()
import Shikumi.Compile.Types (Compiler (..))
import Shikumi.Program (Demo (..), mapParams)

-- | Inject the given demos at every node, /replacing/ (not appending) the node's
-- demo list so that re-compiling is idempotent — compiling twice yields the same
-- demos, never duplicates. (If append semantics are ever wanted that is a separate
-- combinator, deliberately out of scope here.)
fewShot :: [Demo] -> Compiler
fewShot ds = Compiler $ mapParams (\ps -> ps & #demos .~ ds)

-- | Build a few-shot compiler from typed input/output pairs, serializing each to a
-- JSON 'Demo'. This is the recommended path when demos must line up with a node's
-- record fields: the JSON keys are the record field names, so the adapter renders
-- them precisely.
fewShotTyped :: (ToJSON i, ToJSON o) => [(i, o)] -> Compiler
fewShotTyped pairs =
  fewShot [Demo {input = toJSON i, output = toJSON o} | (i, o) <- pairs]
