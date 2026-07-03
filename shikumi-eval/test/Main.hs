-- | EP-8 acceptance suite for @shikumi-eval@: the data model (@Types@), pure and
-- LM-backed metrics (@Metric@), report aggregation (@Report@), the end-to-end
-- @evaluate@ runner (@Evaluate@), golden program tests (@Golden@), and the
-- documented-usage doctest. Every group is hermetic — no network, no API key.
module Main (main) where

import DocSpec qualified
import EmbeddingSpec qualified
import EvaluateSpec qualified
import GoldenSpec qualified
import MetricLMSpec qualified
import MetricSpec qualified
import ReportSpec qualified
import Test.Tasty (defaultMain, testGroup)
import TypesSpec qualified
import UsageSpec qualified

main :: IO ()
main =
  defaultMain $
    testGroup
      "shikumi-eval"
      [ TypesSpec.tests,
        MetricSpec.tests,
        ReportSpec.tests,
        UsageSpec.tests,
        EvaluateSpec.tests,
        MetricLMSpec.tests,
        GoldenSpec.tests,
        EmbeddingSpec.tests,
        DocSpec.tests
      ]
