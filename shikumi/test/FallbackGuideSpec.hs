{-# LANGUAGE DataKinds #-}

-- | EP-67 M3: the fallback adapter's output guide shows the JSON shape of every
-- structured (object or array) output field, while a scalar-only guide stays
-- byte-for-byte what it was before shapes were added. Each case pins the full
-- system prompt 'fallbackAdapter' renders.
module FallbackGuideSpec (tests) where

import Baikai (Context)
import CliSchemaSpec (Assessment, Proposal (..), Severity)
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Fixtures (Article, Summary, sampleArticle)
import GHC.Generics (Generic)
import Shikumi.Adapter (Adapter (..), ToPrompt, fallbackAdapter)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Schema.Types (Field (..), field)
import Shikumi.Signature (Signature, mkSignature)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- | A scalar-only output: two text fields (one described) and an enum.
data Triage = Triage
  { label :: !(Field "Short label" Text),
    reason :: !Text,
    level :: !Severity
  }
  deriving stock (Generic, Show, Eq)

instance ToSchema Triage

instance FromModel Triage

instance ToPrompt Triage

instance Validatable Triage

systemOf :: Context -> Text
systemOf ctx = fromMaybe "" (ctx ^. #systemPrompt)

proposal :: Proposal
proposal = Proposal {plan = field "Ship on Friday."}

assessSystem :: Text
assessSystem =
  systemOf . fst $
    render
      fallbackAdapter
      (mkSignature "Assess whether the release plan is ready." :: Signature Proposal Assessment)
      proposal

triageSystem :: Text
triageSystem =
  systemOf . fst $
    render fallbackAdapter (mkSignature "Triage the plan." :: Signature Proposal Triage) proposal

summarySystem :: Text
summarySystem =
  systemOf . fst $
    render fallbackAdapter (mkSignature "Summarize the article" :: Signature Article Summary) sampleArticle

-- | Written by hand from the pre-EP-67 'fallbackOutputGuide' before it changed.
expectedTriage :: Text
expectedTriage =
  "Triage the plan.\n\n\
  \Reply using these sections, each marker on its own line:\n\
  \[[ ## label ## ]]  -- Short label\n\
  \[[ ## reason ## ]]\n\
  \[[ ## level ## ]]\n\
  \[[ ## completed ## ]]"

expectedAssessment :: Text
expectedAssessment =
  "Assess whether the release plan is ready.\n\n\
  \Reply using these sections, each marker on its own line:\n\
  \[[ ## concerns ## ]]  -- Readiness concerns\n\
  \JSON shape: [{\"statement\": string, \"severity\": \"Blocker\" | \"Major\" | \"Minor\"}, ...]\n\
  \[[ ## verdict ## ]]  -- Overall verdict\n\
  \[[ ## completed ## ]]"

tests :: TestTree
tests =
  testGroup
    "FallbackGuide"
    [ testCase "scalar-only guide is unchanged" $
        triageSystem @?= expectedTriage,
      testCase "a list of records shows its nested keys and enum values" $
        assessSystem @?= expectedAssessment,
      testCase "Summary gains shape lines for bullets and author only" $
        filter ("JSON shape:" `T.isPrefixOf`) (T.lines summarySystem)
          @?= [ "JSON shape: [string, ...]",
                "JSON shape: {\"name\": string}"
              ]
    ]
