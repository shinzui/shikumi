module LabelSpec (tests) where

import Data.Aeson (object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Fixture
import Shikumi.Evidence
import Shikumi.Optimize.Feedback (Provenance (..), StoredCritique (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- | A production row as an upstream system might store it.
data Row = Row
  { rowId :: Text,
    rowSummary :: Text,
    rowOutcome :: Text,
    rowSource :: RowSource
  }

data RowSource
  = HumanAdjudication Text
  | ModelCritique Text Text
  | OperationalOutcome Text

-- | The fixture adapter: one record per row, keeping who produced each label
-- and critique.
adapter :: Row -> EvidenceRecord
adapter row =
  EvidenceRecord
    { exampleId = row.rowId,
      groupKey = "conversation-" <> row.rowId,
      input = object ["summary" .= row.rowSummary],
      expected = Just (object ["disposition" .= row.rowOutcome]),
      label = Just labelFor,
      source = EvidenceSource ("run/" <> row.rowId) Nothing ["feedback/" <> row.rowId],
      critiques = critiqueFor
    }
  where
    labelFor = case row.rowSource of
      HumanAdjudication who -> Label HumanLabel who fixedTime Nothing (Just "corrected") (Just "reviewer overruled the agent")
      ModelCritique who _ -> Label ModelLabel who fixedTime (Just 0.8) Nothing Nothing
      OperationalOutcome system -> Label InferredLabel system fixedTime Nothing (Just "useful") Nothing
    critiqueFor = case row.rowSource of
      ModelCritique who text -> [Critique (Just "root") text ModelLabel who fixedTime]
      HumanAdjudication who -> [Critique Nothing "The agent missed the contradiction; token secret-token-42 was in the log." HumanLabel who fixedTime]
      OperationalOutcome _ -> []

rows :: [Row]
rows =
  [ Row "r1" "Record contradicts guidance; contact secret-token-17." "adr-suspect" (HumanAdjudication "adjudicator-7"),
    Row "r2" "Record follows guidance." "consistent" (ModelCritique "critic-model-v2" "Cite the guidance section."),
    Row "r3" "Record uses outdated guidance." "guidance-suspect" (OperationalOutcome "incident-tracker")
  ]

allTraining :: DatasetSpec
allTraining = uc7Spec {datasetId = "labels", splitPolicy = SplitPolicy "all-train" "conversation" "s" 0 0 0 1}

redaction :: RedactionPolicy
redaction = RedactionPolicy "redact-tokens-v1" (T.replace "secret-token-" "[redacted]-") (T.isInfixOf "secret-token")

tests :: TestTree
tests =
  testGroup
    "labels"
    [ testCase "label kinds and authors survive sealing and reach stored critiques" $ do
        ds <- either (assertFailure . show) pure (sealDataset allTraining redaction (map adapter rows))
        map (\e -> fmap (\l -> (l.kind, l.author)) e.label) ds.examples
          @?= [Just (HumanLabel, "adjudicator-7"), Just (ModelLabel, "critic-model-v2"), Just (InferredLabel, "incident-tracker")]
        sealed <- either (assertFailure . show) pure (openDataset codec ds)
        map (\c -> (critiqueExampleId c, critiqueProvenance c, critiqueAuthor c)) (sealedTrainingCritiques sealed)
          @?= [("r1", Human, "adjudicator-7"), ("r2", Model, "critic-model-v2")]
        decodeDataset (encodeEnvelope ds) @?= Right ds,
      testCase "prohibited text is rewritten in inputs, labels and critiques" $ do
        ds <- either (assertFailure . show) pure (sealDataset allTraining redaction (map adapter rows))
        let text = TE.decodeUtf8 (BL.toStrict (encodeEnvelope ds))
        assertBool "prohibited content remains" (not ("secret-token" `T.isInfixOf` text))
        assertBool "rewritten marker missing" ("[redacted]-17" `T.isInfixOf` text && "[redacted]-42" `T.isInfixOf` text),
      testCase "content the rewriter misses fails the build" $ do
        let strict = redaction {prohibited = \t -> "secret-token" `T.isInfixOf` t || "SSN " `T.isInfixOf` t}
            leaky = adapter (Row "r4" "Record mentions SSN 000-00-0000." "consistent" (OperationalOutcome "tracker"))
        sealDataset allTraining strict (map adapter rows ++ [leaky]) @?= Left [ProhibitedContent "r4"],
      testCase "critiques outside training and duplicate program critiques are rejected" $ do
        let split' = allTraining {splitPolicy = SplitPolicy "holdout-all" "conversation" "s" 0 1000 0 1}
            twice = (adapter (head' rows)) {critiques = replicate 2 (Critique Nothing "again" HumanLabel "a" fixedTime)}
        case sealDataset split' redaction [adapter (head' rows)] of
          Left problems -> assertBool "critique outside training accepted" (CritiqueOutsideTraining "r1" `elem` problems)
          Right _ -> assertFailure "critique on a holdout example accepted"
        case sealDataset allTraining redaction [twice] of
          Left problems -> assertBool "two program critiques accepted" (MultipleProgramCritiques "r1" `elem` problems)
          Right _ -> assertFailure "two program critiques accepted"
    ]
  where
    head' (x : _) = x
    head' [] = error "empty"
