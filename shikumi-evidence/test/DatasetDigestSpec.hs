module DatasetDigestSpec (tests) where

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft)
import Data.Text (Text)
import Fixture
import Shikumi.Evidence
import Shikumi.Evidence.Dataset qualified as D
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

sealWith :: DatasetSpec -> RedactionPolicy -> [EvidenceRecord] -> EvidenceDataset
sealWith spec policy records = either (error . show) id (sealDataset spec policy records)

digestOf :: EvidenceDataset -> Digest
digestOf ds = ds.contentDigest

base :: EvidenceDataset
base = sealWith uc7Spec noRedaction uc7Records

changedFirst :: (EvidenceRecord -> EvidenceRecord) -> [EvidenceRecord]
changedFirst f = case uc7Records of
  r : rest -> f r : rest
  [] -> []

tests :: TestTree
tests =
  testGroup
    "dataset-digest"
    [ testCase "an untouched re-seal reproduces the digest" $
        digestOf (sealWith uc7Spec noRedaction uc7Records) @?= digestOf base,
      testCase "each provenance-bearing change produces a different digest" $ do
        let variants :: [(Text, EvidenceDataset)]
            variants =
              [ ("example input", sealWith uc7Spec noRedaction (changedFirst (\r -> r {input = object ["summary" .= ("Record 1 is entirely new." :: Text)]}))),
                ("source reference", sealWith uc7Spec noRedaction (changedFirst (\r -> r {source = EvidenceSource "run/other" Nothing []}))),
                ("split-policy field", sealWith uc7Spec {splitPolicy = uc7Spec.splitPolicy {holdoutExposureLimit = 4}} noRedaction uc7Records),
                ("example order", sealWith uc7Spec noRedaction (case uc7Records of a : b : rest -> b : a : rest; xs -> xs)),
                ("schema digest", sealWith uc7Spec {D.outputSchemaDigest = digestValue (String "another schema")} noRedaction uc7Records),
                ("redaction policy id", sealWith uc7Spec noRedaction {redactionId = "redaction-none-v2"} uc7Records)
              ]
        mapM_ (\(name, ds) -> assertBool ("digest unchanged by " <> show name) (digestOf ds /= digestOf base)) variants,
      testCase "a sealed envelope decodes back to itself" $
        decodeDataset (encodeEnvelope base) @?= Right base,
      testCase "an edited envelope fails its digest on the raw value" $ do
        let edited = case toJSON base of
              Object o -> Object (KM.insert "agent" (String "kikan/other") o)
              v -> v
        assertBool "edited envelope accepted" (isLeft (decodeDataset (canonicalBytes edited))),
      testCase "unknown fields are rejected even with a recomputed digest" $ do
        let extended = case toJSON base of
              Object o ->
                let o' = KM.insert "unexpected" (String "smuggled") o
                 in Object (KM.insert "contentDigest" (toJSON (envelopeDigest (Object o'))) o')
              v -> v
        assertBool "unknown field accepted" (isLeft (decodeDataset (canonicalBytes extended)))
    ]
