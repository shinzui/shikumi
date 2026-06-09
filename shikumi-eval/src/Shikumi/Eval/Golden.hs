{-# LANGUAGE RankNTypes #-}

-- | Golden testing for programs. A golden test pins a program's observable
-- behaviour to a checked-in file; the test fails if that behaviour changes.
-- Determinism comes from the caller supplying a runner that discharges the effect
-- stack under a /mock or replayed/ LM (never a live one), so the only thing that
-- can change the output is a genuine change in program behaviour.
--
-- 'goldenProgram' compares a per-example transcript (one @index\\t<output>@ line
-- per example, in dataset order); 'goldenReport' compares the rendered 'Report'
-- from 'evaluate'. Both are built on @tasty-golden@'s 'goldenVsString' —
-- regenerate the golden file with @cabal test --test-options=--accept@.
--
-- The runner is a single rank-2 function @forall a. Eff es a -> IO a@, so the
-- helper stays agnostic to the exact effect stack: the caller picks a concrete
-- @es@ (e.g. @'[LLM, Error ShikumiError, IOE]@) and a function collapsing it to
-- 'IO' (throwing on a 'ShikumiError').
module Shikumi.Eval.Golden
  ( goldenProgram,
    goldenReport,
  )
where

import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful (Eff, IOE, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Error.Static (Error)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval.Evaluate (evaluate)
import Shikumi.Eval.Metric (MetricM)
import Shikumi.Eval.Report (renderReportText)
import Shikumi.Eval.Types (Dataset, Example (..), datasetExamples)
import Shikumi.LLM (LLM)
import Shikumi.Program (Program, runProgram)
import Test.Tasty (TestName, TestTree)
import Test.Tasty.Golden (goldenVsString)

-- | Turn a program plus a dataset into a golden test over a deterministic
-- per-example transcript. Each example's input is run through the program (under
-- the supplied offline runner), its output rendered, and the lines compared to
-- the golden file at @path@.
goldenProgram ::
  (LLM :> es, Error ShikumiError :> es) =>
  TestName ->
  -- | golden file path (relative to the package directory)
  FilePath ->
  -- | how to run the effect stack (mock/replay), throwing on a 'ShikumiError'
  (forall a. Eff es a -> IO a) ->
  Dataset i o ->
  Program i o ->
  -- | render an output line for the transcript
  (o -> Text) ->
  TestTree
goldenProgram name path runner ds prog render =
  goldenVsString name path $ do
    let inputs = map input (datasetExamples ds)
    outs <- runner (traverse (runProgram prog) inputs)
    pure (encodeText (renderTranscript (zip [0 ..] (map render outs))))

-- | Like 'goldenProgram' but compares the rendered 'Report' produced by
-- 'evaluate' with the given metric, rather than a raw transcript.
goldenReport ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, IOE :> es) =>
  TestName ->
  FilePath ->
  (forall a. Eff es a -> IO a) ->
  Dataset i o ->
  MetricM es o ->
  Program i o ->
  TestTree
goldenReport name path runner ds metric prog =
  goldenVsString name path $ do
    report <- runner (evaluate ds metric prog)
    pure (encodeText (renderReportText report))

-- | One @index\\t<rendered output>@ line per example, in dataset order.
renderTranscript :: [(Int, Text)] -> Text
renderTranscript = T.unlines . map (\(i, t) -> T.pack (show i) <> "\t" <> t)

-- | Encode text as a UTF-8 lazy 'LBS.ByteString'.
encodeText :: Text -> LBS.ByteString
encodeText = LBS.fromStrict . TE.encodeUtf8
