module ReplaySpec (tests) where

import Baikai.Context (emptyContext)
import Baikai.Evidence (evidenceRequest)
import Baikai.Model (emptyModel)
import Baikai.Options (emptyOptions)
import Control.Exception (SomeException, try)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Set qualified as Set
import Data.Text qualified as T
import Effectful (Eff)
import Fixture
import Shikumi.Combinator (retry)
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Error (ShikumiError (..))
import Shikumi.Evidence
import Shikumi.LLM (complete, stream)
import Shikumi.Testing (systemContains)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | Replay a job's recordings over a provider that fails if reached.
replay :: (ExecutionMode -> EvidenceJob Stack Review Finding) -> JobRecordings -> IO (Either SomeException (Either ShikumiError EvidenceJobResult))
replay mk recs = try (runJob unreachable (mk (Replay recs)))

dropFirstOutcome :: Recording -> Recording
dropFirstOutcome r = sealRecording r {entries = case r.entries of e : rest -> e {outcomes = drop 1 e.outcomes} : rest; [] -> []}

addSurplusOutcome :: Recording -> Recording
addSurplusOutcome r = sealRecording r {entries = case r.entries of e : rest -> e {outcomes = e.outcomes ++ take 1 e.outcomes} : rest; [] -> []}

-- | The retry template's job: a fixed improved instruction and no optimizer
-- calls, so every call of interest is in the comparison.
retryJob :: ExecutionMode -> EvidenceJob Stack Review Finding
retryJob m =
  (uc7Job "retry" m)
    { template = retry 2 reviewer,
      baseline = either (error . show) id (sealBaseline (ArtifactSpec "retry-baseline" sources fixedTime "fixture") codec (CompiledProgram (retry 2 reviewer))),
      optimizer = fixedInstructionOptimizer ruleInstruction,
      dataset = either (error . show) id (sealDataset uc7Spec noRedaction uc7Records)
    }

-- | The holdout group numbers of the fixture, as text.
holdoutGroups :: [T.Text]
holdoutGroups = Set.toList (Set.fromList [T.take 1 (T.drop 4 e.exampleId) | e <- uc7Dataset.examples, e.split == Holdout])

isDivergence :: Either SomeException a -> Bool
isDivergence = \case
  Left e -> "ReplayDivergence" `T.isInfixOf` T.pack (show e)
  Right _ -> False

tests :: TestTree
tests =
  testGroup
    "replay"
    [ testCase "a replayed job reproduces the candidate and report digests without a provider" $ do
        live <- expectRight =<< runJob (respond Good) (uc7Job "uc7-good" RecordLive)
        replayed <- either (\e -> assertFailure (show e) >> error "x") expectRight =<< replay (uc7Job "uc7-good") live.recordings
        fmap (.contentDigest) replayed.candidate @?= fmap (.contentDigest) live.candidate
        replayed.report.contentDigest @?= live.report.contentDigest
        replayed.recordings @?= live.recordings
        live.summary.executionMode @?= "record-live"
        replayed.summary.executionMode @?= "replay",
      testCase "a missing or surplus outcome is a replay divergence" $ do
        live <- expectRight =<< runJob (respond Good) (uc7Job "uc7-good" RecordLive)
        let recs = live.recordings
        missing <- replay (uc7Job "uc7-good") recs {optimizationRecording = dropFirstOutcome recs.optimizationRecording}
        assertBool ("missing outcome: " <> show (fmap (fmap (.report.conclusion)) missing)) (isDivergence missing)
        surplus <- replay (uc7Job "uc7-good") recs {comparisonRecording = addSurplusOutcome <$> recs.comparisonRecording}
        assertBool ("surplus outcome: " <> show (fmap (fmap (.report.conclusion)) surplus)) (isDivergence surplus),
      testCase "a retry that recovers live recovers in replay, and provider timeouts count in both" $ do
        seen <- newIORef Set.empty
        (flakyGroup, slowGroup) <- case holdoutGroups of
          a : b : _ -> pure (a, b)
          _ -> assertFailure "the fixture holdout has fewer than two groups" >> error "x"
        let flaky ctx = do
              let s = userText ctx
              firstTime <- atomicModifyIORef' seen (\xs -> (Set.insert (requestText ctx) xs, Set.notMember (requestText ctx) xs))
              pure $
                if ("Record " <> flakyGroup <> " contradicts") `T.isInfixOf` s && firstTime
                  then Right (responseFor 1 [("unexpected", "garbage")])
                  else
                    if ("Record " <> slowGroup <> " keeps") `T.isInfixOf` s
                      then Left (Timeout "provider deadline exceeded")
                      else Right (respond Good ctx)
        live <- expectRight =<< runEffectful flaky (runEvidenceJob (retryJob RecordLive))
        replayed <- either (\e -> assertFailure (show e) >> error "x") expectRight =<< try @SomeException (runJob unreachable (retryJob (Replay live.recordings)))
        replayed.report.contentDigest @?= live.report.contentDigest
        let rowsOf r = maybe [] (.rows) r.report.candidateResult
            outcomeOf ident r = [row.outcome | row <- rowsOf r, row.exampleId == ident]
        mapM_
          ( \r -> do
              outcomeOf ("uc7-" <> flakyGroup <> "b") r @?= [RowCompleted]
              outcomeOf ("uc7-" <> slowGroup <> "a") r @?= [RowTimedOut]
              fmap (.timeouts) r.report.candidateResult @?= Just 1
          )
          [live, replayed]
        -- The flaky request was answered twice live: once badly, once well.
        fmap (.admittedOperations) live.report.candidateResult @?= Just 10,
      testCase "recorded latency above the policy's example timeout counts as timed out" $ do
        let slow ctx
              | systemContains "RULE" ctx && "keeps" `T.isInfixOf` userText ctx = pure (Right ((respond Good ctx) & #latencyMs .~ 5000))
              | otherwise = pure (Right (respond Good ctx))
        live <- expectRight =<< runEffectful slow (runEvidenceJob ((uc7Job "slow" RecordLive) {optimizer = fixedInstructionOptimizer ruleInstruction}))
        fmap (.timeouts) live.report.baselineResult @?= Just 0
        fmap (.timeouts) live.report.candidateResult @?= Just 2
        live.report.conclusion @?= Regressed
        assertBool "completion constraint not violated" (any (\c -> c.constraintId == "full-completion" && c.verdict == Violated) live.report.constraintResults),
      testCase "streamed and evidence-requesting calls are unrecordable" $ do
        let attempt :: Eff Stack () -> IO (Either UnrecordableCall (Either ShikumiError ()))
            attempt act = try (runJobWith (respond Good) (newRecorder >>= \b -> withBoundary b act))
        streamed <- attempt (stream emptyModel emptyContext emptyOptions >> pure ())
        assertBool "streamed call recorded" (either (const True) (const False) streamed)
        evidenced <- attempt (complete emptyModel emptyContext (emptyOptions & #evidence .~ Just (evidenceRequest "run-1")) >> pure ())
        assertBool "evidence-requesting call recorded" (either (const True) (const False) evidenced)
    ]
