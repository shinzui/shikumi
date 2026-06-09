-- | EP-8 acceptance suite for @shikumi-eval@: the data model (@Types@), pure and
-- LM-backed metrics (@Metric@), report aggregation (@Report@), the end-to-end
-- @evaluate@ runner (@Evaluate@), golden program tests (@Golden@), and the
-- documented-usage doctest. Every group is hermetic — no network, no API key.
module Main (main) where

import EvaluateSpec qualified
import MetricSpec qualified
import ReportSpec qualified
import Test.Tasty (defaultMain, testGroup)
import TypesSpec qualified

main :: IO ()
main =
  defaultMain $
    testGroup
      "shikumi-eval"
      [ TypesSpec.tests,
        MetricSpec.tests,
        ReportSpec.tests,
        EvaluateSpec.tests
      ]
