-- | EP-5 acceptance: every combinator demonstrated against a deterministic mock
-- LM, asserting observable aggregate behaviour. Order-sensitive cases run under
-- the sequential 'runProgram'; 'runProgramConc' is exercised with
-- order-independent (identical) replies so the concurrent pop order cannot affect
-- the assertion. The final group proves integration point #4's cross-cutting
-- properties (the parameter traversal reaches every nested leaf; the structural
-- shape and parameter vector round-trip).
module CombinatorSpec (tests) where

import Data.IORef (newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import ProgramFixtures
  ( Cell (..),
    Draft (..),
    Topic (..),
    cellSig,
    draftResponse,
    markerBody,
    mkResponse,
    outlineResponse,
    outlineToDraft,
    runRecordingLLM,
    runScriptedLLM,
    topicToOutline,
  )
import Shikumi.Combinator
  ( TempSchedule (..),
    chain,
    ensemble,
    majorityVote,
    majorityVoteBy,
    mapP,
    mapSeqP,
    parallel2,
    parallelN,
    retry,
    retryWhen,
    validate,
    validateRetry,
    (>>>),
  )
import Shikumi.Error (ShikumiError (..), isTransient)
import Shikumi.LLM (Response)
import Shikumi.LLM.Mock (MockReply (..), runMockLLM, runMockLLMCounting)
import Shikumi.Module (predict)
import Shikumi.Program
  ( Params (..),
    Program,
    ProgramShape (..),
    ProgramShapeError (..),
    emptyParams,
    foldParams,
    mapParams,
    programParams,
    programShape,
    runProgram,
    runProgramConc,
    setProgramParams,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- ---------------------------------------------------------------------------
-- Run harnesses
-- ---------------------------------------------------------------------------

-- | Run a program sequentially against a list of canned success 'Response's.
runSeq :: Program i o -> [Response] -> i -> IO (Either ShikumiError o)
runSeq prog rs i = do
  ref <- newIORef rs
  runEff . runErrorNoCallStack @ShikumiError . runScriptedLLM ref $ runProgram prog i

-- | Run a program sequentially against scripted replies (successes /and/
-- failures).
runMockSeq :: Program i o -> [MockReply] -> i -> IO (Either ShikumiError o)
runMockSeq prog rs i =
  runEff . runErrorNoCallStack @ShikumiError . runMockLLM rs $ runProgram prog i

-- | Run a program and report both the result and the number of completions
-- issued. The counter is read after the run resolves, so it survives a failure
-- short-circuit.
runCounted :: Program i o -> [MockReply] -> i -> IO (Either ShikumiError o, Int)
runCounted prog rs i = do
  cnt <- newIORef 0
  res <- runEff . runErrorNoCallStack @ShikumiError . runMockLLMCounting cnt rs $ runProgram prog i
  n <- readIORef cnt
  pure (res, n)

-- | Run a program through the concurrent executor. Replies are popped from a
-- shared queue, so callers pass identical replies when the assertion is
-- order-sensitive.
runConc ::
  Program i o -> [Response] -> i -> IO (Either ShikumiError o)
runConc prog rs i = do
  ref <- newIORef rs
  runEff . runErrorNoCallStack @ShikumiError . runConcurrent . runScriptedLLM ref $
    runProgramConc prog i

-- | Run sequentially while recording each request's rendered system prompt.
runRec :: Program i o -> [Response] -> i -> IO [Text]
runRec prog rs i = do
  cap <- newIORef []
  ref <- newIORef rs
  _ <- runEff . runErrorNoCallStack @ShikumiError . runRecordingLLM cap ref $ runProgram prog i
  readIORef cap

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

-- | A @Cell -> Cell@ predictor — the simplest typed leaf to compose.
cellP :: Program Cell Cell
cellP = predict cellSig

-- | A canned response decoding to @Cell {cell = v}@.
cellResp :: Text -> Response
cellResp v = mkResponse (markerBody [("cell", v)])

-- | A transient (retryable) failure.
transientFail :: MockReply
transientFail = MockFail (ProviderFailure "stub transient")

-- | Concatenate the cells (a reducer for outputs that are not usefully modal).
concatCells :: [Cell] -> Cell
concatCells cs = Cell (T.concat (map cell cs))

-- | A fixed single-temperature schedule (the schedule is inert on the wire; see
-- 'Shikumi.Program.TempSchedule').
sched1 :: TempSchedule
sched1 = TempFixed [0.0]

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "CombinatorSpec"
    [ smokeTests,
      pipelineTests,
      mapTests,
      parallelTests,
      retryTests,
      validateTests,
      majorityVoteTests,
      ensembleTests,
      crossCuttingTests
    ]

smokeTests :: TestTree
smokeTests =
  testGroup
    "smoke"
    [ testCase "predict through the mock LLM returns the decoded value" $ do
        r <- runSeq cellP [cellResp "echoed"] (Cell "in")
        r @?= Right (Cell "echoed")
    ]

pipelineTests :: TestTree
pipelineTests =
  testGroup
    "Pipeline"
    [ testCase "(>>>) threads an intermediate type absent from the composite signature" $ do
        let pipe = predict topicToOutline >>> predict outlineToDraft :: Program Topic Draft
        r <- runSeq pipe [outlineResponse, draftResponse] (Topic "haskell")
        r @?= Right (Draft "A fine essay about the outline."),
      testCase "chain composes n same-type stages, returning the last stage's output" $ do
        let pipe = chain [cellP, cellP, cellP]
        r <- runSeq pipe [cellResp "a", cellResp "b", cellResp "c"] (Cell "in")
        r @?= Right (Cell "c")
    ]

mapTests :: TestTree
mapTests =
  testGroup
    "Map"
    [ testCase "mapSeqP runs once per element, preserving input order" $ do
        let prog = mapSeqP cellP
        r <- runSeq prog [cellResp "1", cellResp "2", cellResp "3", cellResp "4", cellResp "5"] (replicate 5 (Cell "in"))
        r @?= Right [Cell "1", Cell "2", Cell "3", Cell "4", Cell "5"],
      testCase "mapP runs under the concurrent executor and yields one output per input" $ do
        let prog = mapP 2 cellP
        r <- runConc prog (replicate 3 (cellResp "x")) (replicate 3 (Cell "in"))
        r @?= Right [Cell "x", Cell "x", Cell "x"]
    ]

parallelTests :: TestTree
parallelTests =
  testGroup
    "Parallel"
    [ testCase "parallel2 runs both programs on the same input and pairs the outputs" $ do
        let prog = parallel2 cellP cellP
        r <- runSeq prog [cellResp "L", cellResp "R"] (Cell "in")
        r @?= Right (Cell "L", Cell "R"),
      testCase "parallelN collects every program's output in order" $ do
        let prog = parallelN [cellP, cellP, cellP]
        r <- runSeq prog [cellResp "1", cellResp "2", cellResp "3"] (Cell "in")
        r @?= Right [Cell "1", Cell "2", Cell "3"],
      testCase "parallel2 runs concurrently under runProgramConc" $ do
        let prog = parallel2 cellP cellP
        r <- runConc prog [cellResp "z", cellResp "z"] (Cell "in")
        r @?= Right (Cell "z", Cell "z")
    ]

retryTests :: TestTree
retryTests =
  testGroup
    "Retry"
    [ testCase "fail-then-succeed returns the success after exactly two attempts" $ do
        (r, n) <- runCounted (retry 3 cellP) [transientFail, MockOk (cellResp "ok")] (Cell "in")
        r @?= Right (Cell "ok")
        n @?= 2,
      testCase "all-fail surfaces the last error after exactly n attempts" $ do
        (r, n) <- runCounted (retry 3 cellP) [transientFail, transientFail, transientFail] (Cell "in")
        r @?= Left (ProviderFailure "stub transient")
        n @?= 3,
      testCase "retryWhen skips a non-matching error after a single attempt" $ do
        (r, n) <-
          runCounted
            (retryWhen isTransient 3 cellP)
            [MockFail (SchemaMismatch "nope"), MockOk (cellResp "ok")]
            (Cell "in")
        r @?= Left (SchemaMismatch "nope")
        n @?= 1
    ]

validateTests :: TestTree
validateTests =
  testGroup
    "Validate"
    [ testCase "a rejected output surfaces ValidationFailure with the reason" $ do
        let prog = validate (\c -> cell c == "good") "cell must be good" cellP
        r <- runMockSeq prog [MockOk (cellResp "bad")] (Cell "in")
        r @?= Left (ValidationFailure "cell must be good"),
      testCase "an accepted output passes through unchanged" $ do
        let prog = validate (\c -> cell c == "good") "cell must be good" cellP
        r <- runMockSeq prog [MockOk (cellResp "good")] (Cell "in")
        r @?= Right (Cell "good"),
      testCase "validateRetry recovers when a later attempt passes" $ do
        let prog = validateRetry 2 (\c -> cell c == "good") "cell must be good" cellP
        (r, n) <- runCounted prog [MockOk (cellResp "bad"), MockOk (cellResp "good")] (Cell "in")
        r @?= Right (Cell "good")
        n @?= 2
    ]

majorityVoteTests :: TestTree
majorityVoteTests =
  testGroup
    "MajorityVote"
    [ testCase "five samples A,B,A,A,B return the modal A" $ do
        let prog = majorityVote 5 sched1 cellP
        r <-
          runSeq
            prog
            [cellResp "A", cellResp "B", cellResp "A", cellResp "A", cellResp "B"]
            (Cell "in")
        r @?= Right (Cell "A"),
      testCase "a tie resolves to the first-seen value" $ do
        let prog = majorityVote 2 sched1 cellP
        r <- runSeq prog [cellResp "A", cellResp "B"] (Cell "in")
        r @?= Right (Cell "A"),
      testCase "majorityVoteBy applies the custom reducer" $ do
        let prog = majorityVoteBy 3 sched1 concatCells cellP
        r <- runSeq prog [cellResp "x", cellResp "y", cellResp "z"] (Cell "in")
        r @?= Right (Cell "xyz")
    ]

ensembleTests :: TestTree
ensembleTests =
  testGroup
    "Ensemble"
    [ testCase "ensemble folds every member's output with the reducer" $ do
        let prog = ensemble [cellP, cellP, cellP] concatCells
        r <- runSeq prog [cellResp "1", cellResp "2", cellResp "3"] (Cell "in")
        r @?= Right (Cell "123"),
      testCase "the parameter traversal reaches a leaf inside every member" $
        length (foldParams (ensemble [cellP, cellP, cellP] concatCells)) @?= 3
    ]

-- A deliberately deep program: a Pipeline of (a Retry of a MajorityVote) then a
-- Validate — every combinator wrapper nests a single Predict leaf, so the
-- traversal must reach two leaves total.
deepProg :: Program Cell Cell
deepProg =
  chain
    [ retry 2 (majorityVote 3 sched1 cellP),
      validate (const True) "always ok" cellP
    ]

crossCuttingTests :: TestTree
crossCuttingTests =
  testGroup
    "cross-cutting (traversal + serialization)"
    [ testCase "the traversal reaches every nested leaf" $
        length (foldParams deepProg) @?= 2,
      testCase "an instruction written through the traversal reaches the deepest leaf at run time" $ do
        let sentinel = "SENTINEL-INSTRUCTION"
            rewritten = mapParams (\p -> p {instructionOverride = Just sentinel}) deepProg
        -- stage 1 samples the MajorityVote leaf 3×, stage 2 the Validate leaf 1×.
        prompts <-
          runRec
            rewritten
            (replicate 4 (cellResp "v"))
            (Cell "in")
        assertBool
          ("expected the sentinel in every captured prompt; got: " <> show prompts)
          (length prompts == 4 && all (T.isInfixOf sentinel) prompts),
      testCase "the structural shape is parameter-independent and round-trips the parameter vector" $ do
        let p1 = emptyParams {instructionOverride = Just "one"}
            p2 = emptyParams {instructionOverride = Just "two"}
        programParams deepProg @?= [emptyParams, emptyParams]
        case setProgramParams [p1, p2] deepProg of
          Left e -> assertBool ("unexpected setProgramParams failure: " <> show e) False
          Right prog' -> do
            programParams prog' @?= [p1, p2]
            programShape prog' @?= programShape deepProg,
      testCase "a parameter-vector length mismatch is a typed error, not a crash" $
        case setProgramParams [emptyParams] deepProg of
          Left (ParamCountMismatch (expected, got)) -> (expected, got) @?= (2, 1)
          Right _ -> assertBool "expected a ParamCountMismatch" False,
      testCase "a function-carrying node serializes its structure (closure omitted) without crashing" $
        case programShape (ensemble [cellP] concatCells) of
          ShapeEnsemble [ShapePredict _] -> pure ()
          other -> assertBool ("expected ShapeEnsemble [ShapePredict _]; got: " <> show other) False
    ]
