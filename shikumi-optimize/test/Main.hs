-- | EP-10 acceptance suite for @shikumi-optimize@: the M0 scaffold, the four
-- optimizers (M1 labeled few-shot, M2 bootstrap, M3 instruction search, M4
-- ensemble), and the M5 end-to-end held-out-improvement acceptance. Every group
-- is hermetic — it runs against the deterministic stub LM with no network and no
-- API key.
module Main (main) where

import AcceptanceSpec qualified
import BootstrapSpec qualified
import CoproSpec qualified
import EnsembleSpec qualified
import GepaSpec qualified
import InstructionSpec qualified
import KNNSpec qualified
import LabeledFewShotSpec qualified
import Miprov2Spec qualified
import OptimizeSpec qualified
import ProposeSpec qualified
import RandomSearchSpec qualified
import SearchSpec qualified
import SeedingSpec qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "shikumi-optimize"
      [ OptimizeSpec.tests,
        LabeledFewShotSpec.tests,
        BootstrapSpec.tests,
        InstructionSpec.tests,
        EnsembleSpec.tests,
        ProposeSpec.tests,
        Miprov2Spec.tests,
        CoproSpec.tests,
        GepaSpec.tests,
        KNNSpec.tests,
        RandomSearchSpec.tests,
        SearchSpec.tests,
        SeedingSpec.tests,
        AcceptanceSpec.tests
      ]
