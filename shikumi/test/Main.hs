-- | Test entry point for shikumi. Drives the hermetic specs through one tasty
-- 'defaultMain'; the live spec (M5) is gated at runtime on @SHIKUMI_LIVE@.
module Main (main) where

import ErrorSpec qualified
import LLMSpec qualified
import LiveSpec qualified
import ResilienceSpec qualified
import SchemaSpec qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "shikumi"
      [ ErrorSpec.tests,
        SchemaSpec.tests,
        LLMSpec.tests,
        ResilienceSpec.tests,
        LiveSpec.tests
      ]
