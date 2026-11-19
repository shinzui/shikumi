{-# LANGUAGE OverloadedRecordDot #-}

-- | Production-evidence optimization, replayed from checked-in data.
--
-- This example reads the UC-7 fixture from @shikumi-evidence\/fixtures\/uc7@: a
-- sealed dataset of adjudicated reviews, a baseline reviewer program, a metric
-- policy, and the recorded provider responses of two jobs. It replays both jobs
-- with a provider that fails if it is ever reached: one whose reflective proposer
-- found a better instruction, and one whose proposer found a verbose instruction
-- that costs four times as much per answer. It verifies that each report binds
-- exactly the artifacts it names, checks that the replay reproduced the
-- checked-in digests, writes the candidate and report of each job, and prints
-- each conclusion.
--
-- The reviewer program, codec, measures and optimizer below are this example's
-- own copy of the ones the test suite used to record the fixture. If they drift,
-- the requests no longer match the recording and the replay fails loudly.
--
-- Run from the repository root:
--
-- > cabal run -v0 exe:jitsurei-evidence [output-directory [fixture-directory]]
module Main (main) where

import Baikai.Api (Api (Custom))
import Baikai.Model (emptyModel)
import Control.Lens ((&), (.~))
import Control.Monad (forM, unless)
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpose)
import GHC.Generics (Generic)
import Numeric (showFFloat)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Eval (Metric, boolScore, predictionPrimary)
import Shikumi.Evidence
import Shikumi.Jitsurei.Stub (runStubEval)
import Shikumi.LLM (LLM (..), complete, stream)
import Shikumi.Module (predict)
import Shikumi.Optimize.Execution (RunLimits (..))
import Shikumi.Optimize.Feedback (EvaluationEvidence (..))
import Shikumi.Optimize.GEPA (reflectiveProposer)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.FilePath (takeDirectory, (</>))

-- ---------------------------------------------------------------------------
-- The reviewer program
-- ---------------------------------------------------------------------------

newtype Review = Review {summary :: Text}
  deriving stock (Show, Generic)

instance FromModel Review

instance ToSchema Review

instance ToPrompt Review

newtype Finding = Finding {disposition :: Text}
  deriving stock (Eq, Show, Generic)

instance FromModel Finding

instance ToSchema Finding

instance ToPrompt Finding

instance Validatable Finding

reviewer :: Program Review Finding
reviewer = predict (mkSignature "Classify how a changed decision record relates to the guidance it cites.")

exactDisposition :: Metric Finding
exactDisposition expected p = boolScore (expected.disposition == (predictionPrimary p).disposition)

-- | One when the reviewer raises an actionable finding on a consistent record.
falseActionable :: Finding -> EvaluationEvidence Finding -> Map Text Double
falseActionable expected ev = Map.singleton "false_actionable" $ case executionResult ev of
  Right out | expected.disposition == "consistent" && out.disposition /= "consistent" -> 1
  _ -> 0

-- | Route every call to the stub model the recording was made against.
route :: (LLM :> es) => Eff es a -> Eff es a
route = interpose $ \_ -> \case
  Complete _ c o -> complete model c o
  Stream _ c o -> stream model c o
  where
    model =
      emptyModel
        & #modelId .~ "fixture-reviewer-1"
        & #provider .~ "fixture"
        & #api .~ Custom "fixture-stub"
        & #baseUrl .~ "stub://fixture"

sources :: [SourceRef]
sources =
  [ SourceRef "program-template" "repo_shikumi" "1111111111111111111111111111111111111111",
    SourceRef "shikumi" "repo_shikumi" "2222222222222222222222222222222222222222"
  ]

-- ---------------------------------------------------------------------------
-- Replaying the jobs
-- ---------------------------------------------------------------------------

defaultFixtureDir :: FilePath
defaultFixtureDir = "shikumi-evidence" </> "fixtures" </> "uc7"

load :: (Show e) => FilePath -> FilePath -> (BL.ByteString -> Either e a) -> IO a
load fixtureDir path decode = do
  bytes <- BL.readFile (fixtureDir </> path)
  either (\e -> fail (path <> ": " <> show e)) pure (decode bytes)

data Outcome = Outcome
  { name :: String,
    result :: EvidenceJobResult,
    candidate :: ProgramArtifact
  }

replayJob :: FilePath -> EvidenceDataset -> ProgramArtifact -> MetricPolicy -> String -> IO Outcome
replayJob fixtureDir ds base pol jobName = do
  optimization <- load fixtureDir (jobName </> "recording-optimization.json") readRecordingForReplay
  comparison <- load fixtureDir (jobName </> "recording-comparison.json") readRecordingForReplay
  checkedCandidate <- load fixtureDir (jobName </> "candidate.json") decodeArtifact
  checkedReport <- load fixtureDir (jobName </> "report.json") decodeReport
  -- What a lifecycle owner checks before anything else: the checked-in report
  -- binds exactly the baseline, candidate, dataset, policy and sources held here.
  either (\e -> fail (jobName <> ": binding verification failed: " <> show e)) pure $
    verifyReportBinding checkedReport base checkedCandidate ds pol sources
  let job =
        EvidenceJob
          { dataset = ds,
            codec = modelEvidenceCodec,
            template = reviewer,
            baseline = base,
            optimizer = gepaEvidenceOptimizer defaultGepaEvidenceConfig reflectiveProposer,
            limits = RunLimits 60 2 1 1,
            searchMetric = exactDisposition,
            customMeasures = falseActionable,
            policy = pol,
            context = ExecutionContext "fixture-runner" (UTCTime (fromGregorian 2026 11 1) 0) (T.pack ("uc7-" <> jobName)) Nothing sources noPriorExposure,
            requestPipeline = route,
            mode = Replay (JobRecordings optimization (Just comparison))
          }
      unreachable _ = error "the replayed job reached a provider"
  outcome <- runStubEval unreachable (runEvidenceJob job) >>= either (fail . show) pure
  cand <- maybe (fail (jobName <> ": no candidate")) pure outcome.candidate
  unless (cand.contentDigest == checkedCandidate.contentDigest && outcome.report.contentDigest == checkedReport.contentDigest) $
    fail (jobName <> ": replay did not reproduce the checked-in digests")
  either (\e -> fail (jobName <> ": binding verification failed: " <> show e)) pure $
    verifyReportBinding outcome.report base cand ds pol sources
  pure (Outcome jobName outcome cand)

-- ---------------------------------------------------------------------------
-- Printing
-- ---------------------------------------------------------------------------

fmt :: Double -> String
fmt x = showFFloat (Just 4) x ""

digest :: Digest -> String
digest = T.unpack . renderDigest

pad :: Int -> String -> String
pad n s = s <> replicate (n - length s) ' '

describe :: Outcome -> String
describe o =
  pad 10 o.name <> " candidate " <> digest o.candidate.contentDigest <> "  " <> pad 10 (show rep.conclusion) <> " " <> detail
  where
    rep = o.result.report
    violated = [c | c <- rep.constraintResults, c.verdict == Violated]
    detail = case violated of
      [] ->
        "quality "
          <> maybe "?" (\p -> maybe "?" fmt p.baselineValue <> " -> " <> maybe "?" fmt p.candidateValue) rep.primaryComparison
          <> "  cost ratio "
          <> maybe "?" fmt (ratioOf =<< find (\c -> c.constraintId == "cost-per-success") rep.constraintResults)
      cs -> "violated: " <> unwords [T.unpack c.constraintId <> " (" <> boundText c <> ")" | c <- cs]
    ratioOf c = (/) <$> c.candidateValue <*> c.baselineValue
    boundText c = case c.bound of
      BaselineRatio r -> "ratio " <> maybe "?" fmt (ratioOf c) <> " > " <> fmt r
      BaselineMargin m -> "change " <> maybe "?" fmt ((-) <$> c.candidateValue <*> c.baselineValue) <> " > " <> fmt m
      AbsoluteLimit l -> "value " <> maybe "?" fmt c.candidateValue <> " beyond " <> fmt l

main :: IO ()
main = do
  args <- getArgs
  let (outDir, fixtureDir) = case args of
        out : fixtures : _ -> (out, fixtures)
        [out] -> (out, defaultFixtureDir)
        [] -> ("dist-newstyle" </> "jitsurei-evidence", defaultFixtureDir)
  ds <- load fixtureDir "dataset.json" decodeDataset
  base <- load fixtureDir "baseline.json" decodeArtifact
  pol <- load fixtureDir "policy.json" decodePolicy
  let (train, validation, holdout) = datasetSplitCounts ds
  putStrLn (pad 10 "dataset" <> " " <> digest ds.contentDigest <> "  train=" <> show train <> " validation=" <> show validation <> " holdout=" <> show holdout)
  putStrLn (pad 10 "baseline" <> " " <> digest base.contentDigest)
  outcomes <- forM ["good", "costly"] (replayJob fixtureDir ds base pol)
  mapM_ (putStrLn . describe) outcomes
  putStrLn "replay reproduced the checked-in candidate and report digests"
  putStrLn "bindings verified for good and costly reports"
  mapM_
    ( \o -> do
        let write file bytes = do
              let path = outDir </> o.name </> file
              createDirectoryIfMissing True (takeDirectory path)
              BL.writeFile path bytes
              putStrLn ("wrote " <> path)
        write "candidate.json" (encodeEnvelope o.candidate)
        write "report.json" (encodeEnvelope o.result.report)
    )
    outcomes
