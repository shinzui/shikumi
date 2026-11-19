module BindingSpec (tests, sampleReport) where

import Data.Aeson (object)
import Data.Either (isLeft)
import Fixture
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Eval.Report (emptyUsageTotals)
import Shikumi.Evidence
import Shikumi.Optimize.Report (RunStatus (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

candidateArtifact :: ProgramArtifact
candidateArtifact =
  either (error . show) id $
    sealArtifact (ArtifactSpec "uc7-candidate" sources fixedTime "fixture") codec (Just baselineArtifact.contentDigest) (Just record) (CompiledProgram reviewer)
  where
    record =
      OptimizationRecord "test" "0" (object []) 1 uc7Limits 0 0 (usageSummary emptyUsageTotals) Completed uc7Dataset.contentDigest [] (digestValue (object []))

-- | A value-level report binding the fixture's baseline, candidate, dataset and
-- policy.
sampleReport :: ProgramArtifact -> ProgramArtifact -> EvidenceDataset -> MetricPolicy -> [SourceRef] -> ComparisonReport
sampleReport base cand ds pol refs =
  sealReport
    ComparisonReport
      { artifactKind = reportKind,
        schemaVersion = 1,
        reportId = "sample/report",
        bindings = ReportBindings base.contentDigest (Just cand.contentDigest) ds.contentDigest (digestPolicy pol) (digestEvaluator evidenceEvaluator) refs,
        policy = pol,
        evaluator = evidenceEvaluator,
        baselineResult = Nothing,
        candidateResult = Nothing,
        constraintResults = [],
        primaryComparison = Nothing,
        exposure = ExposureRecord 3 0 Nothing Nothing,
        predictedOperations = 0,
        admittedOperations = 0,
        recordingDigest = Nothing,
        traceRef = Nothing,
        conclusion = Inconclusive,
        reasons = [],
        createdAt = fixedTime,
        createdBy = "fixture",
        contentDigest = Digest ""
      }

tests :: TestTree
tests =
  testGroup
    "binding"
    [ testCase "a report binds exactly what it was sealed with" $
        verifyReportBinding report baselineArtifact candidateArtifact uc7Dataset uc7Policy sources @?= Right (),
      testCase "changing any bound digest invalidates the binding" $ do
        let otherBaseline = resealArtifact baselineArtifact {identity = baselineArtifact.identity {artifactId = "other-baseline"}}
            otherCandidate = resealArtifact candidateArtifact {identity = candidateArtifact.identity {artifactId = "other-candidate"}}
            otherDataset = resealDataset uc7Dataset {spec = uc7Dataset.spec {datasetId = "other-dataset"}}
            otherPolicy = uc7Policy {minImprovement = 0.2}
            otherSources = [s {revision = "3333333333333333333333333333333333333333"} | s <- sources]
        mapM_
          (\(name, result) -> assertBool (name <> " still verified") (isLeft result))
          [ ("baseline", verifyReportBinding report otherBaseline candidateArtifact uc7Dataset uc7Policy sources),
            ("candidate", verifyReportBinding report baselineArtifact otherCandidate uc7Dataset uc7Policy sources),
            ("dataset", verifyReportBinding report baselineArtifact candidateArtifact otherDataset uc7Policy sources),
            ("policy", verifyReportBinding report baselineArtifact candidateArtifact uc7Dataset otherPolicy sources),
            ("sources", verifyReportBinding report baselineArtifact candidateArtifact uc7Dataset uc7Policy otherSources)
          ],
      testCase "a held artifact with a stale digest field fails verification" $ do
        let tampered = baselineArtifact {identity = baselineArtifact.identity {artifactId = "tampered"}}
        assertBool "tampered baseline verified" (isLeft (verifyReportBinding report tampered candidateArtifact uc7Dataset uc7Policy sources)),
      testCase "a report round-trips through its canonical file" $
        decodeReport (encodeEnvelope report) @?= Right report
    ]
  where
    report = sampleReport baselineArtifact candidateArtifact uc7Dataset uc7Policy sources
