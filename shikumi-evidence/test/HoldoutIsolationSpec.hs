module HoldoutIsolationSpec (tests) where

import Data.Aeson (object, toJSON, (.=))
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Fixture
import Shikumi.Evidence
import Shikumi.Testing (captureLLMRequests, systemContains)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

sentinel :: Split -> Text -> Text
sentinel s ident = case s of
  Holdout -> " HOLDOUTSENTINEL" <> ident
  Validation -> " VALIDATIONSENTINEL" <> ident
  Train -> ""

-- | The fixture records with a unique sentinel word in every holdout and
-- validation summary. Sentinels do not change the split assignment.
sentinelDataset :: EvidenceDataset
sentinelDataset = sealFixture marked
  where
    splits = assignSplits uc7Spec.splitPolicy uc7Records
    marked =
      [ r {input = object ["summary" .= (summaryOf r <> sentinel s r.exampleId)]}
      | (r, s) <- zip uc7Records splits
      ]
    summaryOf r = case r.input of
      A.Object o | Just (A.String t) <- KM.lookup "summary" o -> t
      _ -> ""

tests :: TestTree
tests =
  testGroup
    "holdout-isolation"
    [ testCase "the optimizer, the proposer and the candidate never see protected text" $ do
        ref <- newIORef []
        let job = (uc7Job "isolation" RecordLive) {dataset = sentinelDataset, requestPipeline = captureLLMRequests ref}
        result <- expectRight =<< runJob (respond Good) job
        captured <- readIORef ref
        optimizationCalls <- case result.candidate of
          Just c | Just o <- c.optimization -> pure o.admittedOperations
          _ -> assertFailure ("no candidate: " <> show result.report.reasons) >> pure 0
        assertBool "optimization made no calls" (optimizationCalls > 0)
        let optimization = take optimizationCalls captured
            comparison = drop optimizationCalls captured
            texts = [requestText c | (_, c, _) <- optimization]
            proposerTexts = [requestText c | (_, c, _) <- optimization, systemContains "proposedInstruction" c]
            candidateText = maybe "" (\c -> TE.decodeUtf8 (BL.toStrict (A.encode (toJSON c.compiledState)))) result.candidate
        assertBool "no proposer request" (not (null proposerTexts))
        assertBool "an optimization request contains holdout text" (not (any ("HOLDOUTSENTINEL" `T.isInfixOf`) texts))
        assertBool "a proposer request contains validation text" (not (any ("VALIDATIONSENTINEL" `T.isInfixOf`) proposerTexts))
        assertBool "the optimizer never scored validation" (any ("VALIDATIONSENTINEL" `T.isInfixOf`) texts)
        assertBool "the comparison never ran the holdout" (any (\(_, c, _) -> "HOLDOUTSENTINEL" `T.isInfixOf` requestText c) comparison)
        assertBool "candidate parameters contain protected text" (not ("SENTINEL" `T.isInfixOf` candidateText))
    ]
