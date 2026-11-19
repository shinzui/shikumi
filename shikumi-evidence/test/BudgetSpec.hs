module BudgetSpec (tests) where

import Fixture
import Shikumi.Eval.Report (UsageTotals (..))
import Shikumi.Eval.Usage (withUsageTotals)
import Shikumi.Evidence
import Shikumi.Optimize (optimizeWith)
import Shikumi.Optimize.Execution (RunConfig (..))
import Shikumi.Optimize.GEPA (reflectiveProposer)
import Shikumi.Optimize.Report (OptimizationReport (..), RunStatus (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "budget"
    [ testCase "the candidate and report carry predicted and actual work and usage" $ do
        result <- expectRight =<< runJob (respond Good) (uc7Job "uc7-good" RecordLive)
        record <- maybe (assertFailure "no optimization record" >> error "x") pure (result.candidate >>= (.optimization))
        -- The same optimizer run directly, outside the driver.
        sealed <- either (assertFailure . show) pure (openDataset codec uc7Dataset)
        let spec = gepaEvidenceOptimizer defaultGepaEvidenceConfig reflectiveProposer
            inputs = OptimizerInputs (sealedValidation sealed) (sealedTrainingIds sealed) (sealedTrainingCritiques sealed) exactDisposition
            direct = optimizeWith (RunConfig uc7Limits (const (pure ()))) (spec.buildOptimizer inputs) (sealedTraining sealed) exactDisposition reviewer
        ((_, report), usage) <- expectRight =<< runJobWith (respond Good) (withUsageTotals direct)
        record.predictedOperations @?= report.predictedWork
        record.admittedOperations @?= report.admittedOperations
        record.runStatus @?= report.runStatus
        record.usage @?= usageSummary usage
        (record.predictedOperations, record.admittedOperations, record.runStatus) @?= (17, 17, BudgetStopped)
        record.usage.costUsd @?= "17/1000"
        totalTokens usage @?= 17 * 23
        record.budget @?= uc7Limits
        let rep = result.report
        (rep.predictedOperations, rep.admittedOperations) @?= (16, 16)
        fmap (.admittedOperations) rep.baselineResult @?= Just 8
        fmap (.usage.costUsd) rep.candidateResult @?= Just "1/125"
    ]
