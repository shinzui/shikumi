module ConclusionSpec (tests) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Fixture
import Shikumi.Evidence
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

metricsOf :: [(Text, Double)] -> Map.Map Text (Maybe Double)
metricsOf = Map.fromList . map (fmap Just)

baselineValues :: [(Text, Double)]
baselineValues = [("quality", 0.25), ("completion-rate", 1), ("false-actionable", 0), ("cost-per-success", 0.001), ("mean-latency", 4)]

improvedValues :: [(Text, Double)]
improvedValues = [("quality", 0.75), ("completion-rate", 1), ("false-actionable", 0), ("cost-per-success", 0.001), ("mean-latency", 4)]

facts :: [(Text, Double)] -> ComparisonFacts
facts cand =
  ComparisonFacts
    { inputProblems = [],
      structureMatches = True,
      holdoutContaminated = False,
      holdoutSize = 8,
      holdoutMinimum = 8,
      labeledSamples = 8,
      missingLabels = 0,
      exposureLimitReached = False,
      candidateIdentical = False,
      routesMatch = True,
      comparisonFinished = True,
      baselineMetrics = metricsOf baselineValues,
      candidateMetrics = metricsOf cand
    }

with :: Text -> Double -> [(Text, Double)] -> [(Text, Double)]
with k v = map (\(k', v') -> if k' == k then (k', v) else (k', v'))

codes :: (Conclusion, [Reason]) -> [Text]
codes = map (.code) . snd

tests :: TestTree
tests =
  testGroup
    "conclusion"
    [ testCase "a clean improvement is Improved" $
        fst (conclude uc7Policy (facts improvedValues)) @?= Improved,
      testCase "a quality gain with a safety, cost, latency or completion violation is Regressed" $
        mapM_
          ( \(name, cand) -> do
              let result = conclude uc7Policy (facts cand)
              assertBool (name <> " was " <> show (fst result)) (fst result == Regressed)
              assertBool (name <> " did not name a constraint") ("constraint-violated" `elem` codes result)
          )
          [ ("safety", with "false-actionable" 1 improvedValues),
            ("cost", with "cost-per-success" 0.004 improvedValues),
            ("latency", with "mean-latency" 8 improvedValues),
            ("completion", with "completion-rate" 0.875 improvedValues)
          ],
      testCase "a primary metric worse than the margin is Regressed" $
        fst (conclude uc7Policy (facts (with "quality" 0.2 improvedValues))) @?= Regressed,
      testCase "failing evidence is Invalid or Inconclusive, never Improved" $
        mapM_
          ( \(name, expected, f) -> do
              let result = conclude uc7Policy f
              assertBool (name <> " was " <> show result) (fst result == expected)
          )
          [ ("too few labels", Inconclusive, (facts improvedValues) {labeledSamples = 4, holdoutSize = 8}),
            ("too many missing labels", Inconclusive, (facts improvedValues) {labeledSamples = 8, holdoutSize = 12, missingLabels = 4, holdoutMinimum = 8}),
            ("too small an improvement", Inconclusive, facts (with "quality" 0.3 improvedValues)),
            ("contaminated holdout", Invalid, (facts improvedValues) {holdoutContaminated = True}),
            ("holdout below minimum", Invalid, (facts improvedValues) {holdoutSize = 4}),
            ("unlabeled holdout", Invalid, (facts improvedValues) {labeledSamples = 0}),
            ("exhausted exposure", Invalid, (facts improvedValues) {exposureLimitReached = True}),
            ("different routes", Invalid, (facts improvedValues) {routesMatch = False}),
            ("unfinished comparison", Invalid, (facts improvedValues) {comparisonFinished = False}),
            ("missing required metric", Invalid, (facts improvedValues) {candidateMetrics = Map.insert "cost-per-success" Nothing (metricsOf improvedValues)}),
            ("structure mismatch", Invalid, (facts improvedValues) {structureMatches = False}),
            ("identical candidate", Inconclusive, (facts improvedValues) {candidateIdentical = True}),
            ("invalid inputs", Invalid, (facts improvedValues) {inputProblems = [Reason "policy-invalid" "x"]})
          ],
      testCase "invalidity outranks regression" $
        fst (conclude uc7Policy ((facts (with "cost-per-success" 0.004 improvedValues)) {holdoutContaminated = True})) @?= Invalid,
      testCase "constraints are read in their metric's direction" $ do
        let results = evaluateConstraints uc7Policy (metricsOf baselineValues) (metricsOf (with "cost-per-success" 0.004 improvedValues))
        map (\r -> (r.constraintId, r.verdict)) results
          @?= [("full-completion", Satisfied), ("no-new-false-actionable", Satisfied), ("cost-per-success", Violated), ("latency", Satisfied)]
    ]
