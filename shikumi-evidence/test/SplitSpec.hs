module SplitSpec (tests) where

import Data.Aeson (object, (.=))
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Fixture
import Shikumi.Evidence
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

rec' :: Text -> Text -> Text -> EvidenceRecord
rec' ident group text =
  EvidenceRecord
    { exampleId = ident,
      groupKey = group,
      input = object ["summary" .= text],
      expected = Just (object ["disposition" .= ("consistent" :: Text)]),
      label = Just (Label HumanLabel "adjudicator" fixedTime Nothing Nothing Nothing),
      source = EvidenceSource ("run/" <> ident) Nothing [],
      critiques = []
    }

-- A and B share an input under different group keys; B and C share a group key.
records :: [EvidenceRecord]
records =
  [rec' "A" "g-a" "shared input", rec' "B" "g-b" "shared input", rec' "C" "g-b" "another input"]
    ++ [rec' ("F" <> T.pack (show i)) ("g-f" <> T.pack (show i)) ("filler " <> T.pack (show i)) | i <- [1 .. 9 :: Int]]

specWith :: Text -> DatasetSpec
specWith s = uc7Spec {splitPolicy = SplitPolicy "split" "group" s 250 250 0 1}

splitOf :: EvidenceDataset -> Text -> Split
splitOf ds ident = case [e.split | e <- ds.examples, e.exampleId == ident] of
  s : _ -> s
  [] -> error "missing example"

moveTo :: Text -> EvidenceDataset -> EvidenceDataset
moveTo ident ds = sealDatasetValue ds {examples = [if e.exampleId == ident then e {split = other e.split} else e | e <- ds.examples]}
  where
    other Holdout = Train
    other _ = Holdout

sealDatasetValue :: EvidenceDataset -> EvidenceDataset
sealDatasetValue = resealDataset

tests :: TestTree
tests =
  testGroup
    "split-leakage"
    [ testCase "shared inputs and shared groups land in one split under every salt" $
        mapM_
          ( \s -> case sealDataset (specWith s) noRedaction records of
              Left e -> assertFailure (show e)
              Right ds -> do
                splitOf ds "B" @?= splitOf ds "A"
                splitOf ds "C" @?= splitOf ds "B"
          )
          ["salt-" <> T.pack (show i) | i <- [1 .. 12 :: Int]],
      testCase "hand-edited envelopes that move a related example are rejected" $ do
        ds <- either (assertFailure . show) pure (sealDataset (specWith "salt-1") noRedaction records)
        let movedA = validateDataset (moveTo "A" ds)
            movedC = validateDataset (moveTo "C" ds)
        assertBool "moving A across splits accepted" (isLeft movedA)
        assertBool "moving C across splits accepted" (isLeft movedC)
        assertBool "input crossing reported" (either (any (\case InputCrossesSplits {} -> True; _ -> False)) (const False) movedA)
        assertBool "group crossing reported" (either (any (\case GroupCrossesSplits {} -> True; _ -> False)) (const False) movedC),
      testCase "split assignment is deterministic and fills the declared shares" $ do
        let (train, validation, holdout) = datasetSplitCounts uc7Dataset
        (train, validation, holdout) @?= (12, 4, 8)
        assignSplits uc7Spec.splitPolicy uc7Records @?= assignSplits uc7Spec.splitPolicy uc7Records,
      testCase "validation reports every problem, not only the first" $ do
        let broken = sealDatasetValue uc7Dataset {spec = uc7Dataset.spec {behaviorVersions = []}, examples = take 2 uc7Dataset.examples ++ take 1 uc7Dataset.examples}
        case validateDataset broken of
          Left problems -> do
            assertBool "behavior versions" (NoBehaviorVersions `elem` problems)
            assertBool "duplicate id" (any (\case DuplicateExampleId {} -> True; _ -> False) problems)
            assertBool "holdout size" (any (\case HoldoutTooSmall {} -> True; _ -> False) problems)
          Right () -> assertFailure "broken envelope accepted"
    ]
