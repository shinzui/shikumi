{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the OKF bundle generator (EP-31, Milestones 2 and 3).
--
-- The fixtures deliberately mix the two program shapes the generator must handle:
-- a typed @Predict@ pipeline (rich structural reflection) and an opaque @Embed@
-- program (the shape an agent runtime such as shikigami produces, where reflection
-- is thin and the declared metadata carries the documentation).
module Main (main) where

import Control.Exception (IOException, catch, evaluate)
import Data.Foldable (toList)
import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Okf.Actor (Actor (ProcessActor))
import Okf.Bundle
  ( BundleInventory,
    Concept,
    bundleInventoryOfConcepts,
    conceptDocument,
    conceptGenerated,
    conceptIdOf,
    walkBundle,
  )
import Okf.ConceptId (ConceptId, parseConceptId, renderConceptId)
import Okf.Document (Generated (..), OKFDocument (..), frontmatterLookup)
import Okf.Graph (Edge (..), Graph (..), buildGraph)
import Okf.Index
  ( OkfVersion (..),
    VersionDeclaration (VersionDeclared, VersionUndeclared),
    readBundleVersion,
  )
import Okf.Markdown (computationBlocks)
import Okf.Profile
  ( CompiledProfile,
    compileProfile,
    loadProfileFile,
    validateProfile,
    validateProfileVersion,
  )
import Okf.Validation
  ( ValidationProfile (PermissiveConformance, StrictAuthoring),
    validateBundle,
  )
import Paths_shikumi_okf (getDataFileName)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Module (predict)
import Shikumi.Okf.Generate
  ( GenerateOptions (..),
    defaultGenerateOptions,
    defaultGeneratedBy,
    generateBundle,
    okfVersion02,
    writeProgramBundle,
  )
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
      program = Just (SomeProgram qaProgram)
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
      program = Just (SomeProgram noopProgram)
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
      program = Just (SomeProgram qaPolishedProgram)
    }

-- | A metadata-only doc: no program value (the shape a handan task without an
-- eval handle produces).
metaOnlyDoc :: ProgramDoc
metaOnlyDoc =
  ProgramDoc
    { name = "legacy-task",
      title = Just "Legacy Task",
      description = Just "A task with no recoverable program.",
      tags = [],
      declaredInputs = Nothing,
      declaredOutputs = Nothing,
      program = Nothing
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
      "- 1. inputs (question) -> outputs (answer)",
      "  - Instruction: Answer the question."
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
main = do
  warmUpMarkdown
  defaultMain tests

-- | Parse one Markdown document on the main thread before tasty forks.
--
-- @cmark-gfm@ registers its core extensions lazily: @CMarkGFM.commonmarkToNode@
-- calls @cmark_gfm_core_extensions_ensure_registered@ inside 'unsafePerformIO'
-- on every call, whatever extension list it was given, and that C function is
-- not thread-safe. Two tasty threads reaching it at once make
-- @cmark_register_node_flag@ print @flag initialization error@ and @abort()@ the
-- process — no test failure, just SIGABRT partway through the run.
--
-- okf-core 0.5 made this reachable: it enabled footnotes and routed all three of
-- its parse sites through one options list, so validating a bundle now parses
-- far more Markdown than it used to, and this suite runs with @-N@. One parse
-- here does the registration once, single-threaded, so the tests below race over
-- an already-initialised library.
--
-- __This is not redundant with the fork.__ @cabal.project@ pins
-- @shinzui/cmark-gfm-hs@, which fixes the registration properly, but that pin
-- governs builds of this repository only: a consumer building @shikumi-okf@
-- from Hackage resolves stock @cmark-gfm@ and needs this warm-up. Delete it only
-- when the fix is released upstream.
--
-- The defect is in the @cmark-gfm@ bindings, not in okf or shikumi. Full
-- mechanism: @mori://kivikakk/cmark-gfm-hs@, upstream-issues entry
-- @cmark-gfm-hs-unsafe-concurrent-extension-registration@.
warmUpMarkdown :: IO ()
warmUpMarkdown = do
  _ <- evaluate (length (computationBlocks "# Computation\n\n    warm up\n"))
  pure ()

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
            assertBool "first instruction" ("  - Instruction: Answer the question." `T.isInfixOf` body)
            assertBool "second instruction" ("  - Instruction: Polish the answer." `T.isInfixOf` body),
          testCase "metadata-only body (no program) states structure unavailable" $ do
            let body = renderProgramBody metaOnlyDoc
            assertBool "header" ("# Legacy Task" `T.isInfixOf` body)
            assertBool
              "structure note"
              ("Documented from metadata only; program structure is not available." `T.isInfixOf` body)
        ],
      testGroup
        "Generate"
        [ testCase "generated bundle has no validation errors" $
            withConcepts $ \concepts ->
              validateBundle PermissiveConformance declaredV02 (inventoryOf concepts) concepts @?= [],
          testCase "one app concept plus one per program" $
            withConcepts $ \concepts -> do
              let ids = map (renderConceptId . conceptIdOf) concepts
              assertEqual
                "concept ids"
                ["apps/demo", "programs/qa", "programs/noop-summary", "programs/qa-polished"]
                ids
        ],
      -- OKF v0.2 (okf-core 0.5) moved provenance from the v0.1 `timestamp` key
      -- to the `generated` family and gave a bundle a way to declare the dialect
      -- it targets. These pin both halves: what goes into every concept, and
      -- what goes into the bundle root.
      testGroup
        "OKF v0.2"
        [ testCase "every concept records process:shikumi-okf as its producer" $
            withConcepts $ \concepts ->
              assertEqual
                "generated family"
                (map (const (Just (Generated (ProcessActor "shikumi-okf") Nothing))) concepts)
                (map conceptGenerated concepts),
          testCase "defaultGeneratedBy is the actor written" $
            defaultGeneratedBy @?= ProcessActor "shikumi-okf",
          testCase "no concept carries the superseded v0.1 timestamp key" $
            withConcepts $ \concepts ->
              assertEqual
                "timestamp keys"
                []
                [ renderConceptId (conceptIdOf c)
                | c <- concepts,
                  let OKFDocument {frontmatter} = conceptDocument c,
                  Just _ <- [frontmatterLookup "timestamp" frontmatter]
                ],
          -- The strict pass is what asks for `generated`, and what reports a
          -- v0.1 key surviving in a bundle that declares v0.2. A permissive run
          -- would stay silent on both, so it could not notice this regressing.
          testCase "strict validation of a v0.2-declaring bundle is clean" $
            withConcepts $ \concepts ->
              validateBundle StrictAuthoring declaredV02 (inventoryOf concepts) concepts @?= [],
          testCase "generated.at is omitted by default and written when supplied" $ do
            let opts =
                  defaultGenerateOptions
                    { generated = Just (Generated (ProcessActor "shikumi-okf") (Just "2026-08-07T00:00:00Z"))
                    }
            case generateBundle demoApp opts demoManifest of
              Left err -> fail ("generateBundle failed: " <> show err)
              Right concepts ->
                assertEqual
                  "generated.at"
                  (map (const (Just "2026-08-07T00:00:00Z")) concepts)
                  (map ((generatedAt =<<) . conceptGenerated) concepts),
          testCase "generated = Nothing writes no provenance at all" $ do
            let opts = defaultGenerateOptions {generated = Nothing}
            case generateBundle demoApp opts demoManifest of
              Left err -> fail ("generateBundle failed: " <> show err)
              Right concepts ->
                assertEqual "generated family" [] (mapMaybe conceptGenerated concepts),
          testCase "the written bundle root declares okf_version 0.2" $ do
            root <- freshTempDir "shikumi-okf-version"
            result <- writeProgramBundle root demoApp defaultGenerateOptions demoManifest
            case result of
              Left err -> fail ("writeProgramBundle failed: " <> show err)
              Right () -> do
                declared <- readBundleVersion root
                declared @?= Right (VersionDeclared (OkfVersion 0 2)),
          testCase "okfVersion02 is the version declared" $
            okfVersion02 @?= OkfVersion {okfVersionMajor = 0, okfVersionMinor = 2}
        ],
      testGroup
        "Profile"
        -- The real descriptor, not a Haskell restatement of it. This fails if
        -- profile/shikumi.dhall stops type-checking against the okf-core schema,
        -- stops compiling as a coherent profile, or stops describing what the
        -- generator actually emits.
        --
        -- This replaces a former "Conformance" group that re-asserted the
        -- profile's conventions (concept types, `shikumi://` resource scheme)
        -- in-process against a Haskell copy of them, and so could never notice
        -- the descriptor itself going stale. Every convention it checked is now
        -- expressed by the descriptor and enforced here against the real file.
        [ testCase "profile/shikumi.dhall loads and compiles" $ do
            _ <- loadAndCompileProfile
            pure (),
          testCase "generated bundle conforms to profile/shikumi.dhall" $ do
            compiled <- loadAndCompileProfile
            withConcepts $ \concepts ->
              validateProfile PermissiveConformance compiled concepts @?= [],
          -- The profile carries `requireBundleVersion = Some "0.2"`, which is a
          -- separate entry point from validateProfile because it consults no
          -- concepts. Both directions are pinned: an undeclared bundle must
          -- deviate, or the requirement would be inert and untested.
          testCase "the profile requires a v0.2 declaration, and ours satisfies it" $ do
            compiled <- loadAndCompileProfile
            validateProfileVersion declaredV02 compiled @?= []
            assertBool
              "an undeclared bundle deviates"
              (not (null (validateProfileVersion VersionUndeclared compiled)))
        ],
      testGroup
        "RoundTrip"
        [ testCase "app links to every program (graph edges)" $ do
            root <- freshTempDir "shikumi-okf-roundtrip"
            result <- writeProgramBundle root demoApp defaultGenerateOptions demoManifest
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

-- | Generate the demo bundle with the default options and hand the concepts to
-- an assertion, failing the test rather than pattern-matching at each call site.
withConcepts :: ([Concept] -> IO a) -> IO a
withConcepts assertion =
  case generateBundle demoApp defaultGenerateOptions demoManifest of
    Left err -> fail ("generateBundle failed: " <> show err)
    Right concepts -> assertion concepts

-- | What the generator declares, restated here so a test reads the same
-- declaration a reader of the bundle root would.
declaredV02 :: VersionDeclaration
declaredV02 = VersionDeclared okfVersion02

-- | The inventory an in-memory bundle can honestly report: its own concepts and
-- no non-Markdown file, because there is no directory holding one.
inventoryOf :: [Concept] -> BundleInventory
inventoryOf = bundleInventoryOfConcepts

-- | A clean temp directory (removed if it exists), so the round-trip test is
-- idempotent across runs.
freshTempDir :: FilePath -> IO FilePath
freshTempDir name = do
  base <- getTemporaryDirectory
  let root = base </> name
  removeDirectoryRecursive root `catch` \(_ :: IOException) -> pure ()
  createDirectoryIfMissing True root
  pure root

-- | Load and compile the shipped profile descriptor, failing the test with a
-- readable message at whichever stage breaks. The path is resolved through
-- Cabal's data-files mechanism, so it does not depend on the working directory
-- the test was launched from.
loadAndCompileProfile :: IO CompiledProfile
loadAndCompileProfile = do
  path <- getDataFileName "profile/shikumi.dhall"
  loaded <- loadProfileFile path
  case loaded of
    Left err -> fail ("could not load " <> path <> ": " <> T.unpack err)
    Right spec ->
      case compileProfile spec of
        Left errs -> fail ("profile did not compile: " <> show (toList errs))
        Right compiled -> pure compiled

expectConceptId :: Text -> IO ConceptId
expectConceptId raw =
  case parseConceptId raw of
    Right cid -> pure cid
    Left err -> fail ("bad concept id in test: " <> show err)
