{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the OKF bundle generator (EP-31, Milestones 2 and 3).
--
-- The fixtures deliberately mix the two program shapes the generator must handle:
-- a typed @Predict@ pipeline (rich structural reflection) and an opaque @Embed@
-- program (the shape an agent runtime such as shikigami produces, where reflection
-- is thin and the declared metadata carries the documentation).
module Main (main) where

import Control.Exception (IOException, catch)
import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Okf.Bundle (conceptIdOf, walkBundle)
import Okf.ConceptId (ConceptId, parseConceptId, renderConceptId)
import Okf.Graph (Edge (..), Graph (..), buildGraph)
import Okf.Validation (ValidationProfile (PermissiveConformance), validateBundle)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Module (predict)
import Shikumi.Okf.Generate (generateBundle, writeProgramBundle)
import Shikumi.Okf.Render (renderProgramBody)
import Shikumi.Okf.Types
  ( AppInfo (..),
    ProgramDoc (..),
    ProgramManifest (..),
    SomeProgram (..),
  )
import Shikumi.Program (Program, embed, pipeline)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)
import System.Directory
  ( createDirectoryIfMissing,
    getTemporaryDirectory,
    removeDirectoryRecursive,
  )
import System.FilePath ((</>))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Fixture record types and programs
-- ---------------------------------------------------------------------------

newtype Question = Question {question :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Question

instance FromModel Question

instance ToPrompt Question

instance Validatable Question

newtype Answer = Answer {answer :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Answer

instance FromModel Answer

instance ToPrompt Answer

instance Validatable Answer

qaSig :: Signature Question Answer
qaSig = mkSignature "Answer the question."

polishSig :: Signature Answer Answer
polishSig = mkSignature "Polish the answer."

-- | A single model call.
qaProgram :: Program Question Answer
qaProgram = predict qaSig

-- | A two-stage pipeline: answer, then polish. Exercises the Compose tree and
-- multiple model-call entries.
qaPolishedProgram :: Program Question Answer
qaPolishedProgram = pipeline (predict qaSig) (predict polishSig)

-- | An opaque embedded program (the shikigami shape): no inspectable structure.
-- The lambda's polymorphic effect row is inferred from 'embed's rank-2 argument
-- type, so no local signature (which would be flagged redundant) is needed.
noopProgram :: Program () ()
noopProgram = embed (\_ -> pure ())

-- ---------------------------------------------------------------------------
-- Fixture manifest
-- ---------------------------------------------------------------------------

qaDoc :: ProgramDoc
qaDoc =
  ProgramDoc
    { name = "qa",
      title = Just "Question Answering",
      description = Just "Answers a question.",
      tags = ["nlp"],
      declaredInputs = Nothing,
      declaredOutputs = Nothing,
      program = SomeProgram qaProgram
    }

noopDoc :: ProgramDoc
noopDoc =
  ProgramDoc
    { name = "noop-summary",
      title = Just "Noop Summary",
      description = Just "Returns a fixed digest.",
      tags = [],
      declaredInputs = Just "Ignored trigger payload (JSON).",
      declaredOutputs = Just "A fixed summary digest (JSON).",
      program = SomeProgram noopProgram
    }

polishedDoc :: ProgramDoc
polishedDoc =
  ProgramDoc
    { name = "qa-polished",
      title = Just "Polished QA",
      description = Just "Answer then polish.",
      tags = [],
      declaredInputs = Nothing,
      declaredOutputs = Nothing,
      program = SomeProgram qaPolishedProgram
    }

demoApp :: AppInfo
demoApp =
  AppInfo
    { appNamespace = "shinzui",
      appName = "demo",
      appTitle = Just "Demo App",
      appDescription = Just "A demo application."
    }

demoManifest :: ProgramManifest
demoManifest = ProgramManifest [qaDoc, noopDoc, polishedDoc]

-- ---------------------------------------------------------------------------
-- Expected rendered bodies (inline goldens — self-contained, pin exact format)
-- ---------------------------------------------------------------------------

expectedQaBody :: Text
expectedQaBody =
  T.unlines
    [ "# Question Answering",
      "",
      "Answers a question.",
      "",
      "## Structure",
      "",
      "- Predict — outputs: answer",
      "",
      "### Model calls",
      "",
      "- 1. inputs (question) -> outputs (answer)"
    ]

expectedNoopBody :: Text
expectedNoopBody =
  T.unlines
    [ "# Noop Summary",
      "",
      "Returns a fixed digest.",
      "",
      "## Interface",
      "",
      "- Input: Ignored trigger payload (JSON).",
      "- Output: A fixed summary digest (JSON).",
      "",
      "## Structure",
      "",
      "Opaque embedded program (no inspectable internal structure)."
    ]

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "shikumi-okf"
    [ testGroup
        "Render"
        [ testCase "typed Predict body (golden)" $
            renderProgramBody qaDoc @?= expectedQaBody,
          testCase "opaque Embed body (golden)" $
            renderProgramBody noopDoc @?= expectedNoopBody,
          testCase "Compose tree renders both model calls" $ do
            let body = renderProgramBody polishedDoc
            assertBool "has Compose" ("- Compose" `T.isInfixOf` body)
            assertBool "nests Predict" ("  - Predict — outputs: answer" `T.isInfixOf` body)
            assertBool "first call" ("inputs (question) -> outputs (answer)" `T.isInfixOf` body)
            assertBool "second call" ("inputs (answer) -> outputs (answer)" `T.isInfixOf` body)
        ],
      testGroup
        "Generate"
        [ testCase "generated bundle has no validation errors" $
            case generateBundle demoApp Nothing demoManifest of
              Left err -> fail ("generateBundle failed: " <> show err)
              Right concepts ->
                validateBundle PermissiveConformance concepts @?= [],
          testCase "one app concept plus one per program" $
            case generateBundle demoApp Nothing demoManifest of
              Left err -> fail (show err)
              Right concepts -> do
                let ids = map (renderConceptId . conceptIdOf) concepts
                assertEqual
                  "concept ids"
                  ["apps/demo", "programs/qa", "programs/noop-summary", "programs/qa-polished"]
                  ids
        ],
      testGroup
        "RoundTrip"
        [ testCase "app links to every program (graph edges)" $ do
            root <- freshTempDir "shikumi-okf-roundtrip"
            result <- writeProgramBundle root demoApp Nothing demoManifest
            case result of
              Left err -> fail ("writeProgramBundle failed: " <> show err)
              Right () -> do
                walked <- walkBundle root
                case walked of
                  Left err -> fail ("walkBundle failed: " <> show err)
                  Right concepts -> do
                    let graph = buildGraph concepts
                    assertEqual "node count (app + 3 programs)" 4 (length (nodes graph))
                    appId <- expectConceptId "apps/demo"
                    let targetsFromApp =
                          mapMaybe
                            (\e -> if source e == appId then Just (renderConceptId (target e)) else Nothing)
                            (edges graph)
                    -- Compare as a set: buildGraph orders edges by target, which is
                    -- not the manifest order, but every app->program edge must exist.
                    assertEqual
                      "app -> program edges"
                      (sort ["programs/qa", "programs/noop-summary", "programs/qa-polished"])
                      (sort targetsFromApp)
        ]
    ]

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | A clean temp directory (removed if it exists), so the round-trip test is
-- idempotent across runs.
freshTempDir :: FilePath -> IO FilePath
freshTempDir name = do
  base <- getTemporaryDirectory
  let root = base </> name
  removeDirectoryRecursive root `catch` \(_ :: IOException) -> pure ()
  createDirectoryIfMissing True root
  pure root

expectConceptId :: Text -> IO ConceptId
expectConceptId raw =
  case parseConceptId raw of
    Right cid -> pure cid
    Left err -> fail ("bad concept id in test: " <> show err)
