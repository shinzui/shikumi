-- | Test entry point for shikumi. Drives the hermetic specs through one tasty
-- 'defaultMain'; the live spec (M5) is gated at runtime on @SHIKUMI_LIVE@.
module Main (main) where

import AdapterSpec qualified
import CombinatorSpec qualified
import EndToEndSpec qualified
import ErrorSpec qualified
import LLMSpec qualified
import LiveSpec qualified
import ModuleSpec qualified
import MultimodalAdapterSpec qualified
import MultimodalEndToEndSpec qualified
import MultimodalSpec qualified
import ProgramAcceptanceSpec qualified
import ProgramSpec qualified
import RefineSpec qualified
import ResilienceSpec qualified
import RoutingSpec qualified
import SchemaSpec qualified
import SerializeSpec qualified
import Shikumi.Effect.TimeSpec qualified
import SignatureSpec qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "shikumi"
      [ ErrorSpec.tests,
        SchemaSpec.tests,
        SignatureSpec.tests,
        AdapterSpec.tests,
        EndToEndSpec.tests,
        LLMSpec.tests,
        ResilienceSpec.tests,
        ProgramSpec.tests,
        RoutingSpec.tests,
        SerializeSpec.tests,
        ModuleSpec.tests,
        ProgramAcceptanceSpec.tests,
        CombinatorSpec.tests,
        RefineSpec.tests,
        MultimodalSpec.tests,
        MultimodalAdapterSpec.tests,
        MultimodalEndToEndSpec.tests,
        Shikumi.Effect.TimeSpec.tests,
        LiveSpec.tests
      ]
