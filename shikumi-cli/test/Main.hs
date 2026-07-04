{-# LANGUAGE OverloadedStrings #-}

-- | Offline acceptance for the shikumi CLI (EP-12). Exercises the four
-- subcommands' underlying capabilities against the bundled example, entirely
-- hermetically (deterministic stub LM, no network). The deterministic parts of
-- each transcript are asserted directly; trace timings (wall-clock) are checked
-- structurally rather than byte-for-byte.
module Main (main) where

import Control.Exception (bracket)
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure)
import Shikumi.Cli (dispatch)
import Shikumi.Cli.Example
  ( SentimentOutput (..),
    canonicalInput,
    exampleRegistry,
    exampleResponder,
    reviews,
    sentiment,
    sentimentMetric,
  )
import Shikumi.Cli.Options
  ( Command (..),
    EvalOpts (..),
    GlobalOpts (..),
    RecordOpts (..),
    TraceOpts (..),
    parseCommand,
  )
import Shikumi.Cli.Run (replayFailureMessage, validTraceId)
import Shikumi.Cli.Runtime (recordTrace, runReplayProgram, runStubEval, runStubProgram)
import Shikumi.Compile (encodeCompiled)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval (evaluatePure, renderReportText)
import Shikumi.Optimize (labeledFewShot, optimize)
import Shikumi.Trace (renderTree)
import Shikumi.Trace.Store (readTraceFile, writeTraceFile)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getTemporaryDirectory, removePathForcibly)
import System.FilePath ((</>))
import Test.Tasty (TestTree, defaultMain, localOption, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Runners (NumThreads (..))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "shikumi-cli"
    [ testCase "eval renders a deterministic Report (score 0.5, 2/4 pass)" $ do
        r <- runStubEval exampleResponder (evaluatePure reviews sentimentMetric sentiment)
        case r of
          Left e -> assertFailure ("eval failed: " <> show e)
          Right rep -> do
            let txt = renderReportText rep
            contains "score=0.5000" txt
            contains "pass=2/4" txt
            contains "in=72 out=20" txt,
      testCase "trace renders the program and llm-call spans" $ do
        (res, tree) <- recordTrace exampleResponder "sentiment" sentiment canonicalInput
        res @?= Right ()
        let txt = renderTree tree
        contains "sentiment" txt
        contains "llm-call" txt
        contains "in=18 out=5" txt,
      testCase "trace round-trips through the on-disk store" $ do
        (_, tree) <- recordTrace exampleResponder "sentiment" sentiment canonicalInput
        dir <- (</> "shikumi-cli-test") <$> getTemporaryDirectory
        createDirectoryIfMissing True dir
        let path = dir </> "sentiment.json"
        writeTraceFile path tree
        loaded <- readTraceFile path
        case loaded of
          Left err -> assertFailure ("trace round-trip failed: " <> T.unpack err)
          Right tree' -> renderTree tree' @?= renderTree tree,
      testCase "optimize (labeled-fewshot) saves a compiled program with demos" $ do
        r <- runStubEval exampleResponder (optimize (labeledFewShot 2) reviews sentimentMetric sentiment)
        case r of
          Left e -> assertFailure ("optimize failed: " <> show e)
          Right cp -> do
            let saved = decodeUtf8 (BL.toStrict (encodeCompiled cp))
            contains "demos" saved
            contains "Loved it, would buy again" saved,
      testCase "replay output is identical to the recorded run, zero provider calls" $ do
        (_, tree) <- recordTrace exampleResponder "sentiment" sentiment canonicalInput
        replayed <- runReplayProgram tree sentiment canonicalInput
        reference <- runStubProgram exampleResponder sentiment canonicalInput
        case (replayed, reference) of
          (Right ro, Right refo) -> do
            ro @?= refo
            ro @?= SentimentOutput "positive"
          _ -> assertFailure "replay or reference run failed",
      cliLayerTests
    ]

cliLayerTests :: TestTree
cliLayerTests =
  localOption (NumThreads 1) $
    testGroup
      "cli-layer"
      [ testCase "parseCommand covers defaults, flags, and parse failures" $ do
          parses ["trace", "sentiment"]
            @?= Just (GlobalOpts ".shikumi" False, CmdTrace (TraceOpts "sentiment"))
          parses ["--store-dir", "/tmp/x", "--otel", "trace", "t"]
            @?= Just (GlobalOpts "/tmp/x" True, CmdTrace (TraceOpts "t"))
          parses ["eval", "--program", "sentiment"]
            @?= Just (GlobalOpts ".shikumi" False, CmdEval (EvalOpts "sentiment"))
          parses ["bogus-command"] @?= Nothing
          parses ["eval"] @?= Nothing,
        testCase "validTraceId rejects path-escaping ids with user-facing reasons" $ do
          validTraceId "" @?= Left "trace id must not be empty"
          validTraceId "." @?= Left "trace id must not be \".\""
          validTraceId "../../escape" @?= Left "trace id must not contain path separators"
          validTraceId "../oops" @?= Left "trace id must not contain path separators"
          validTraceId "a\\b" @?= Left "trace id must not contain path separators"
          validTraceId "abc..def" @?= Left "trace id must not contain \"..\""
          validTraceId "sentiment" @?= Right "sentiment",
        testCase "invalid record ids are rejected before the store directory is created" $
          withTempRoot "invalid-trace-id" $ \root -> do
            let store = root </> "store"
            validTraceId "../oops" @?= Left "trace id must not contain path separators"
            storeCreated <- doesDirectoryExist store
            storeCreated @?= False,
        testCase "dispatch: record creates a trace inside the configured store dir" $
          withTempRoot "happy-path" $ \root -> do
            let store = root </> "store"
                gopts = GlobalOpts store False
                tracePath = store </> "sentiment.json"
            dispatch exampleRegistry gopts (CmdRecord (RecordOpts "sentiment"))
            traceExists <- doesFileExist tracePath
            traceExists @?= True,
        testCase "replayFailureMessage names the failing side" $ do
          replayFailureMessage (Left (InvalidJSON "bad replay")) (Right (SentimentOutput "positive"))
            @?= Just "replay failed: the replayed run errored: InvalidJSON \"bad replay\""
          replayFailureMessage (Right (SentimentOutput "positive")) (Left (ValidationFailure "bad reference"))
            @?= Just "replay failed: the reference (stub) run errored: ValidationFailure \"bad reference\""
          assertBool
            "old vague replay message should be gone"
            (not ("program error during replay or reference run" `T.isInfixOf` maybe "" id (replayFailureMessage (Left (InvalidJSON "bad")) (Right (SentimentOutput "positive")))))
      ]

contains :: Text -> Text -> IO ()
contains needle hay =
  assertBool ("expected to find " <> show needle <> " in:\n" <> T.unpack hay) (needle `T.isInfixOf` hay)

parses :: [String] -> Maybe (GlobalOpts, Command)
parses args = case execParserPure defaultPrefs parseCommand args of
  Success parsed -> Just parsed
  _ -> Nothing

withTempRoot :: FilePath -> (FilePath -> IO a) -> IO a
withTempRoot suffix =
  bracket
    ( do
        tmp <- getTemporaryDirectory
        let root = tmp </> ("shikumi-cli-" <> suffix)
        removePathForcibly root
        createDirectoryIfMissing True root
        pure root
    )
    removePathForcibly
