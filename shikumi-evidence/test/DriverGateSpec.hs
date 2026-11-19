module DriverGateSpec (tests) where

import Data.Map.Strict qualified as Map
import Fixture
import Shikumi.Evidence
import Shikumi.Evidence.Driver qualified as Job
import Shikumi.Optimize.Execution (RunLimits (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

codes :: EvidenceJobResult -> [Reason]
codes r = r.report.reasons

hasCode :: EvidenceJobResult -> String -> Bool
hasCode r c = any (\x -> show x.code == show c) (codes r)

tests :: TestTree
tests =
  testGroup
    "driver-gates"
    [ testCase "an unchanged candidate is Inconclusive and spends no exposure" $ do
        r <- expectRight =<< runJob (respond Good) ((uc7Job "same" RecordLive) {optimizer = identityOptimizer})
        r.report.conclusion @?= Inconclusive
        assertBool "reason" (hasCode r "candidate-identical")
        r.report.admittedOperations @?= 0
        r.report.exposure.ordinal @?= Nothing
        assertBool "candidate sealed" (r.candidate /= Nothing),
      testCase "a differently shaped candidate is Invalid, emitted nowhere, and never touches the holdout" $ do
        r <- expectRight =<< runJob (respond Good) ((uc7Job "reshape" RecordLive) {optimizer = reshapingOptimizer})
        r.report.conclusion @?= Invalid
        assertBool "reason" (hasCode r "structure-mismatch")
        r.candidate @?= Nothing
        r.report.admittedOperations @?= 0
        r.recordings.comparisonRecording @?= Nothing,
      testCase "insufficient evidence through the real driver is never Improved" $ do
        let improving = (uc7Job "gate" RecordLive) {optimizer = fixedInstructionOptimizer ruleInstruction}
            contaminated = resealDataset uc7Dataset {examples = [if e.exampleId == "uc7-1a" then e {split = Holdout} else e | e <- uc7Dataset.examples] ++ []}
            moved = if any (\e -> e.exampleId == "uc7-1a" && e.split == Holdout) uc7Dataset.examples then resealDataset uc7Dataset {examples = [if e.exampleId == "uc7-1a" then e {split = Train} else e | e <- uc7Dataset.examples]} else contaminated
        tooFew <- expectRight =<< runJob (respond Good) improving {Job.policy = uc7Policy {minLabeledSamples = 9}}
        tooFew.report.conclusion @?= Inconclusive
        assertBool "insufficient-labels" (hasCode tooFew "insufficient-labels")
        dirty <- expectRight =<< runJob unreachable improving {dataset = moved}
        dirty.report.conclusion @?= Invalid
        assertBool "holdout-contaminated" (hasCode dirty "holdout-contaminated")
        exhausted <- expectRight =<< runJob (respond Good) improving {context = improving.context {Job.exposure = HoldoutExposure 3 Nothing}}
        exhausted.report.conclusion @?= Invalid
        assertBool "exposure-exhausted" (hasCode exhausted "exposure-exhausted")
        exhausted.report.admittedOperations @?= 0
        overridden <- expectRight =<< runJob (respond Good) improving {context = improving.context {Job.exposure = HoldoutExposure 3 (Just (ExposureOverride "release-manager" "re-run after provider outage" fixedTime))}}
        overridden.report.conclusion @?= Improved
        overridden.report.exposure.ordinal @?= Just 4
        noMeasure <- expectRight =<< runJob (respond Good) improving {Job.customMeasures = \_ _ -> Map.empty}
        noMeasure.report.conclusion @?= Invalid
        assertBool "metric-missing" (hasCode noMeasure "metric-missing")
        concurrent <- expectRight =<< runJob unreachable improving {limits = uc7Limits {evaluationConcurrency = 2}}
        concurrent.report.conclusion @?= Invalid
        assertBool "concurrency-not-sequential" (hasCode concurrent "concurrency-not-sequential")
        unsourced <- expectRight =<< runJob unreachable improving {context = improving.context {Job.sources = take 1 sources}}
        unsourced.report.conclusion @?= Invalid
    ]
