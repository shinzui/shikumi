-- | Unit tests for report aggregation: 'mkReport' over synthetic per-example
-- results, the 'UsageTotals' 'Monoid', and the deterministic 'renderReportText'
-- format (an inline golden-by-equality check).
module ReportSpec (tests) where

import Data.Ratio ((%))
import Data.Text (Text)
import Shikumi.Eval.Report
  ( ExampleResult (..),
    FailureReason (..),
    Report (..),
    UsageTotals (..),
    emptyUsageTotals,
    mkReport,
    renderReportText,
  )
import Shikumi.Eval.Types (mkScore, scoreOne, scoreZero)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- | Three synthetic outcomes: a perfect pass, a partial, and a program failure.
fixtureResults :: [ExampleResult]
fixtureResults =
  [ ExampleResult {index = 0, score = scoreOne, failure = Nothing, latencyMs = 100},
    ExampleResult {index = 1, score = mkScore 0.5, failure = Nothing, latencyMs = 200},
    ExampleResult
      { index = 2,
        score = scoreZero,
        failure = Just (ProgramError "decode failed"),
        latencyMs = 934
      }
  ]

fixtureUsage :: UsageTotals
fixtureUsage = UsageTotals {totalInputTokens = 120, totalOutputTokens = 45, totalTokens = 165, totalCostUsd = 23 % 10000}

fixtureReport :: Report
fixtureReport = mkReport fixtureResults fixtureUsage

expectedRender :: Text
expectedRender =
  "score=0.5000  pass=1/3  fail=1\n\
  \tokens: in=120 out=45 total=165\n\
  \cost: $0.0023\n\
  \latency: 1234 ms\n\
  \failures:\n\
  \  [2] ProgramError: decode failed"

tests :: TestTree
tests =
  testGroup
    "Report"
    [ testCase "aggregateScore is the mean" $
        assertBool
          ("expected ~0.5, got " <> show (aggregateScore fixtureReport))
          (abs (aggregateScore fixtureReport - 0.5) < 1e-9),
      testCase "passCount counts perfect scores" $ passCount fixtureReport @?= 1,
      testCase "failCount counts failures" $ failCount fixtureReport @?= 1,
      testCase "total counts examples" $ total fixtureReport @?= 3,
      testCase "totalLatencyMs sums" $ totalLatencyMs fixtureReport @?= 1234,
      testCase "results retained in order" $ map index (results fixtureReport) @?= [0, 1, 2],
      testCase "empty report is zero" $ aggregateScore (mkReport [] emptyUsageTotals) @?= 0,
      testCase "UsageTotals Monoid sums" $
        UsageTotals 10 20 30 (1 % 100) <> UsageTotals 1 2 3 (2 % 100)
          @?= UsageTotals 11 22 33 (3 % 100),
      testCase "UsageTotals mempty is empty" $ (mempty :: UsageTotals) @?= emptyUsageTotals,
      testCase "renderReportText matches the documented format" $
        renderReportText fixtureReport @?= expectedRender
    ]
