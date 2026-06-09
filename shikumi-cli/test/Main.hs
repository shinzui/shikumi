{-# LANGUAGE OverloadedStrings #-}

-- | Offline acceptance for the shikumi CLI (EP-12). Exercises the four
-- subcommands' underlying capabilities against the bundled example, entirely
-- hermetically (deterministic stub LM, no network). The deterministic parts of
-- each transcript are asserted directly; trace timings (wall-clock) are checked
-- structurally rather than byte-for-byte.
module Main (main) where

import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Shikumi.Cli.Example
  ( SentimentOutput (..),
    canonicalInput,
    exampleResponder,
    reviews,
    sentiment,
    sentimentMetric,
  )
import Shikumi.Cli.Runtime (recordTrace, runReplayProgram, runStubEval, runStubProgram)
import Shikumi.Compile (encodeCompiled)
import Shikumi.Eval (evaluatePure, renderReportText)
import Shikumi.Optimize (labeledFewShot, optimize)
import Shikumi.Trace (renderTree)
import Shikumi.Trace.Store (readTraceFile, writeTraceFile)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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
          _ -> assertFailure "replay or reference run failed"
    ]

contains :: Text -> Text -> IO ()
contains needle hay =
  assertBool ("expected to find " <> show needle <> " in:\n" <> T.unpack hay) (needle `T.isInfixOf` hay)
