-- | Required test 12: the UC-7 fixture yields a held-out improvement and rejects
-- the costly candidate. The live run is compared with the checked-in golden
-- artifacts under @fixtures/uc7@, and a replay of the checked-in recordings must
-- reproduce the checked-in candidate and report digests.
module Uc7Spec (tests) where

import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Fixture
import Shikumi.Evidence
import System.FilePath ((</>))
import Test.Tasty (DependencyType (..), TestTree, after, testGroup)
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

fixtureDir :: FilePath
fixtureDir = "fixtures" </> "uc7"

-- | Run a provider's job live.
live :: Provider -> IO EvidenceJobResult
live provider = expectRight =<< runJob (respond provider) (uc7Job (jobName provider) RecordLive)

jobName :: Provider -> Text
jobName = \case
  Good -> "uc7-good"
  Costly -> "uc7-costly"

dirOf :: Provider -> FilePath
dirOf = \case
  Good -> "good"
  Costly -> "costly"

golden :: FilePath -> IO BL.ByteString -> TestTree
golden path = goldenVsString path (fixtureDir </> path)

jobGoldens :: Provider -> [TestTree]
jobGoldens provider =
  [ golden (d </> "recording-optimization.json") (encodeEnvelope . (.recordings.optimizationRecording) <$> live provider),
    golden (d </> "recording-comparison.json") (maybe "" encodeEnvelope . (.recordings.comparisonRecording) <$> live provider),
    golden (d </> "candidate.json") (maybe "" encodeEnvelope . (.candidate) <$> live provider),
    golden (d </> "report.json") (encodeEnvelope . (.report) <$> live provider)
  ]
  where
    d = dirOf provider

readFixture :: FilePath -> IO BL.ByteString
readFixture path = BL.readFile (fixtureDir </> path)

decoded :: (Show e) => FilePath -> (BL.ByteString -> Either e a) -> IO a
decoded path decode = readFixture path >>= either (\e -> assertFailure (path <> ": " <> show e) >> error "x") pure . decode

-- | Replay a job from the checked-in files and compare digests.
replayFromFiles :: Provider -> IO EvidenceJobResult
replayFromFiles provider = do
  let d = dirOf provider
  ds <- decoded "dataset.json" decodeDataset
  base <- decoded "baseline.json" decodeArtifact
  pol <- decoded "policy.json" decodePolicy
  opt <- decoded (d </> "recording-optimization.json") readRecordingForReplay
  cmp <- decoded (d </> "recording-comparison.json") readRecordingForReplay
  cand <- decoded (d </> "candidate.json") decodeArtifact
  rep <- decoded (d </> "report.json") decodeReport
  let job = (uc7Job (jobName provider) (Replay (JobRecordings opt (Just cmp)))) {dataset = ds, baseline = base, policy = pol}
  result <- expectRight =<< runJob unreachable job
  fmap (.contentDigest) result.candidate @?= Just cand.contentDigest
  result.report.contentDigest @?= rep.contentDigest
  verifyReportBinding result.report base cand ds pol sources @?= Right ()
  pure result

primaryOf :: EvidenceJobResult -> Maybe (Maybe Double, Maybe Double)
primaryOf r = (\p -> (p.baselineValue, p.candidateValue)) <$> r.report.primaryComparison

tests :: TestTree
tests =
  testGroup
    "uc7"
    [ testGroup
        "golden"
        ( [ golden "dataset.json" (pure (encodeEnvelope uc7Dataset)),
            golden "baseline.json" (pure (encodeEnvelope baselineArtifact)),
            golden "policy.json" (pure (encodePolicy uc7Policy))
          ]
            ++ jobGoldens Good
            ++ jobGoldens Costly
        ),
      after AllFinish "/uc7.golden/" $
        testGroup
          "replay"
          [ testCase "the good candidate is Improved on the holdout, reproducibly" $ do
              r <- replayFromFiles Good
              r.report.conclusion @?= Improved
              primaryOf r @?= Just (Just 0.25, Just 0.75)
              let (train, validation, holdout) = datasetSplitCounts uc7Dataset
              (train, validation, holdout) @?= (12, 4, 8),
            testCase "the costly candidate is Regressed on cost, reproducibly" $ do
              r <- replayFromFiles Costly
              r.report.conclusion @?= Regressed
              primaryOf r @?= Just (Just 0.25, Just 0.75)
              let violated = [c | c <- r.report.constraintResults, c.verdict == Violated]
              map (.constraintId) violated @?= ["cost-per-success"]
              case violated of
                [c] | Just b <- c.baselineValue, Just v <- c.candidateValue -> assertBool "cost ratio is not four" (abs (v / b - 4) < 1e-9)
                _ -> assertFailure "no cost values"
              assertBool "reason names the constraint" (any (\x -> "cost-per-success" `T.isPrefixOf` x.detail) r.report.reasons)
          ]
    ]
