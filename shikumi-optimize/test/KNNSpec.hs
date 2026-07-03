{-# LANGUAGE TypeApplications #-}

-- | EP-23 acceptance (KNN): under a known stub-embedder geometry, the demos
-- attached are the input-nearest training examples (run-time form) and the
-- centroid-nearest examples (compile-time fallback). Plus the serialization
-- round-trip: the run-time Embed form carries no Params (like @react@); the centroid
-- form's baked demos persist.
module KNNSpec (tests) where

import Data.Aeson (toJSON)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector (Vector)
import Data.Vector qualified as V
import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (Prim, runPrim)
import Shikumi.Adapter (toPrompt)
import Shikumi.Compile.Serialize (decodeCompiledOnto, encodeCompiled)
import Shikumi.Compile.Types (compiledProgram)
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, dataset, datasetExamples, exactMatch, example)
import Shikumi.LLM (LLM)
import Shikumi.Optimize (knnDemos, knnFewShot, knnFewShotCentroid, nearestDemos, optimize, withLmCallCount)
import Shikumi.Optimize.Search (freezeProgram)
import Shikumi.Program (Demo (..), Params (..), programParams, runProgram)
import StubLM (Label (..), Sentence (..), runStubLM, sentimentProg)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Stub embedder (a known 2-D geometry) and fixtures
-- ---------------------------------------------------------------------------

-- | Geography text → near @[1, 0]@; arithmetic text → near @[0, 1]@; else the
-- diagonal. The two clusters are near-orthogonal, so "nearest" is unambiguous.
stubEmbed :: Text -> Vector Double
stubEmbed t
  | any (`T.isInfixOf` lt) ["france", "paris", "capital", "geography", "city"] = V.fromList [1.0, 0.1]
  | any (`T.isInfixOf` lt) ["plus", "sum", "arithmetic", "two", "three"] = V.fromList [0.1, 1.0]
  | otherwise = V.fromList [0.5, 0.5]
  where
    lt = T.toLower t

-- A balanced training set: two geography, two arithmetic (foldParams index order).
geoA, geoB, ariA, ariB :: Sentence
geoA = Sentence "capital of france"
geoB = Sentence "capital city geography"
ariA = Sentence "two plus two"
ariB = Sentence "three plus three sum"

balanced :: Dataset Sentence Label
balanced =
  dataset
    [ example geoA (Label "paris"),
      example ariA (Label "four"),
      example geoB (Label "city"),
      example ariB (Label "six")
    ]

-- A geography-skewed set, so the centroid lands in the geography cluster.
skewed :: Dataset Sentence Label
skewed =
  dataset
    [ example geoA (Label "paris"),
      example geoB (Label "city"),
      example (Sentence "capital paris france") (Label "fr"),
      example ariA (Label "four")
    ]

runStub :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runStub act = runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runStubLM act

tests :: TestTree
tests = testGroup "KNN" [inputNearest, centroidNearest, runtimeRuns, optimizeBudget, roundTrips]

-- ---------------------------------------------------------------------------
-- M1 — selection
-- ---------------------------------------------------------------------------

inputNearest :: TestTree
inputNearest =
  testCase "nearestDemos attaches the input-nearest training examples" $ do
    let geoQuery = nearestDemos stubEmbed 2 (datasetExamples balanced) (toPrompt (Sentence "france capital quiz"))
        ariQuery = nearestDemos stubEmbed 2 (datasetExamples balanced) (toPrompt (Sentence "sum two plus three"))
    [i | Demo i _ <- geoQuery] @?= [toJSON geoA, toJSON geoB]
    [i | Demo i _ <- ariQuery] @?= [toJSON ariA, toJSON ariB]

centroidNearest :: TestTree
centroidNearest =
  testCase "knnFewShotCentroid bakes the centroid-nearest examples as demos" $ do
    res <- runStub (optimize (knnFewShotCentroid stubEmbed 2) skewed exactMatch sentimentProg)
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right cp -> case programParams (compiledProgram cp) of
        (ps : _) -> [i | Demo i _ <- demos ps] @?= [toJSON geoA, toJSON geoB]
        [] -> assertFailure "expected one node"

runtimeRuns :: TestTree
runtimeRuns =
  testCase "the run-time KNN program runs end-to-end under the stub LM" $ do
    let prog = knnDemos stubEmbed 2 balanced sentimentProg
    res <- runStub (runProgram prog (Sentence "france capital quiz"))
    assertBool "the Embed-wrapped KNN program runs" (either (const False) (const True) res)

optimizeBudget :: TestTree
optimizeBudget =
  testCase "KNN optimizers make zero LM calls at optimize time" $ do
    res <-
      runStub $ do
        (_, runtimeCalls) <- withLmCallCount (optimize (knnFewShot stubEmbed 2) balanced exactMatch sentimentProg)
        (_, centroidCalls) <- withLmCallCount (optimize (knnFewShotCentroid stubEmbed 2) skewed exactMatch sentimentProg)
        pure (runtimeCalls, centroidCalls)
    case res of
      Left e -> assertFailure ("unexpected error: " <> show e)
      Right counts -> counts @?= (0, 0)

-- ---------------------------------------------------------------------------
-- M3 — serialization round-trip
-- ---------------------------------------------------------------------------

roundTrips :: TestTree
roundTrips =
  testGroup
    "round-trips"
    [ testCase "run-time KNN serializes as the empty Params vector (like react)" $ do
        let compiled = freezeProgram (knnDemos stubEmbed 2 balanced sentimentProg)
        programParams (compiledProgram compiled) @?= []
        case decodeCompiledOnto (knnDemos stubEmbed 2 balanced sentimentProg) (encodeCompiled compiled) of
          Left err -> assertFailure ("decode failed: " <> err)
          Right cp' -> programParams (compiledProgram cp') @?= [],
      testCase "centroid KNN baked demos round-trip onto the bare student" $ do
        res <- runStub (optimize (knnFewShotCentroid stubEmbed 2) skewed exactMatch sentimentProg)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right cp -> case decodeCompiledOnto sentimentProg (encodeCompiled cp) of
            Left err -> assertFailure ("decode failed: " <> err)
            Right cp' -> programParams (compiledProgram cp') @?= programParams (compiledProgram cp)
    ]
