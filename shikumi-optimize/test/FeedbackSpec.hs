module FeedbackSpec (tests) where

import Baikai (AssistantContent (..), emptyResponse, emptyTextContent)
import Control.Exception qualified as E
import Control.Lens ((&), (.~))
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Effectful.Prim (Prim, runPrim)
import Shikumi.Compile.Types (compiledProgram)
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval (Dataset, boolScore, dataset, exactMatch, example, scoreZero, unScore)
import Shikumi.Eval.Report (FailurePolicy (..), FailureReason (..))
import Shikumi.LLM (LLM (..))
import Shikumi.Module (predict)
import Shikumi.Optimize (optimize)
import Shikumi.Optimize.Feedback
import Shikumi.Optimize.GEPA (FeedbackCallback (..), ReflectIn (..), ReflectOut (..), captureFeedback, gepaWithFeedback, mutateFromEvidence)
import Shikumi.Optimize.Types (Budget (..))
import Shikumi.Program (Params (..), Program (..), programParams)
import Shikumi.Signature (mkSignature)
import Shikumi.Trace.Feedback (feedbackFor)
import Shikumi.Trace.Node (NodePath (..), NodeStep (..), programNodePaths)
import Shikumi.Trace.Observation (NodeObservation (..))
import StubLM (Label (..), Sentence (..), sentimentProg)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

runScript :: [Either ShikumiError Text] -> Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runScript replies action = do
  ref <- newIORef replies
  runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
    interpret
      ( \_ -> \case
          Complete {} -> do
            next <- liftIO $ atomicModifyIORef' ref $ \case
              [] -> ([], Right "{\"sentiment\":\"positive\"}")
              x : xs -> (xs, x)
            body <- either throwError pure next
            if body == "CANCEL"
              then liftIO (E.throwIO E.ThreadKilled)
              else
                pure (emptyResponse & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ body)))
          Stream {} -> pure []
      )
      action

ok :: Either ShikumiError Text
ok = Right "{\"sentiment\":\"positive\"}"

batch :: Dataset Sentence Label
batch = dataset [example (Sentence (T.pack (show i))) (Label "positive") | i <- [0 .. 2 :: Int]]

metric :: (Applicative m) => Label -> EvaluationEvidence Label -> m FeedbackResult
metric _ _ = pure (FeedbackResult (boolScore True) Nothing [])

checkRight :: (Show e) => Either e a -> (a -> IO ()) -> IO ()
checkRight value check = either (assertFailure . show) check value

tests :: TestTree
tests =
  testGroup
    "failure-aware feedback"
    [ testCase "middle decode failure retains positions, original error, and missing codecs" $ do
        result <- runScript [ok, Right "not JSON", ok] (captureEvidence defaultFeedbackConfig batch metric sentimentProg)
        checkRight result $ \rows -> do
          map (exampleIndex . first) rows @?= [0, 1, 2]
          map (unScore . overallScore . second) rows @?= [1, 0, 1]
          let ev = first (rows !! 1)
          case executionResult ev of Left (MissingField "sentiment") -> pure (); other -> assertFailure (show other)
          length (observations ev) @?= 1
          map observationInput (observations ev) @?= [Nothing]
          map observationPath (observations ev) @?= programNodePaths sentimentProg
          assertBool "failed leaf retained" (all (not . observationEligible) (observations ev)),
      testCase "abort returns exact output error; budget and infrastructure always escape by default" $ do
        let errors = [InvalidJSON "original", BudgetExceeded "budget", ProviderFailure "offline", Timeout "infra"]
        mapM_
          ( \err -> do
              let cfg = if err == InvalidJSON "original" then defaultFeedbackConfig {failureClassification = const FailAbort} else defaultFeedbackConfig
              result <- runScript [ok, Left err, ok] (captureEvidence cfg batch metric sentimentProg)
              result @?= Left err
          )
          errors
        forced <- runScript [Left (BudgetExceeded "hard")] (captureEvidence (defaultFeedbackConfig {failureClassification = const (FailScore scoreZero)}) batch metric sentimentProg)
        forced @?= Left (BudgetExceeded "hard"),
      testCase "cancellation is never a completed batch" $ do
        result <- E.try @E.AsyncException (runScript [ok, Right "CANCEL", ok] (captureEvidence defaultFeedbackConfig batch metric sentimentProg))
        result @?= Left E.ThreadKilled,
      testCase "metric failure is separately labeled" $ do
        result <- runScript [ok] (captureEvidence defaultFeedbackConfig batch (\_ _ -> throwError (ValidationFailure "critic failed")) sentimentProg)
        checkRight result $ \rows -> map third rows @?= replicate 3 (Just (MetricError "ValidationFailure \"critic failed\"")),
      testCase "custom infrastructure classification and failure score" $ do
        let cfg = defaultFeedbackConfig {failureClassification = const (FailScore (boolScore True))}
        result <- runScript [Left (ProviderFailure "explicit")] (captureEvidence cfg batch metric sentimentProg)
        checkRight result $ \rows -> unScore (overallScore (second (rows !! 0))) @?= 1,
      testCase "Map attribution rejects an unexecuted ordinal and wrong example/path" $ do
        let prog = Map 1 sentimentProg
            ds = dataset [example [Sentence "one", Sentence "two"] [Label "positive", Label "positive"]]
        result <- runScript [ok, ok] (captureEvidence defaultFeedbackConfig ds (\_ _ -> pure (FeedbackResult scoreZero Nothing [])) prog)
        checkRight result $ \rows -> do
          let ev = first (rows !! 0)
              target = NodeFeedback 0 (NodePath [StepMap]) (Just 1) "fix" Caller
              validate f = validateFeedback defaultFeedbackConfig (programNodePaths prog) ev (FeedbackResult scoreZero Nothing [f])
          assertBool "real invocation accepted" (either (const False) (const True) (validate target))
          mapM_
            (\f -> assertBool "invalid target rejected" (either (const True) (const False) (validate f)))
            [target {feedbackInvocation = Just 2}, target {feedbackExample = 1}, target {feedbackPath = NodePath []}, target {provenance = LegacyProgram}],
      testCase "zero and odd critique bounds, and negative preflight" $ do
        boundText 0 "abcdef" @?= ""
        boundText 3 "abcdef" @?= "ab…"
        boundText 1 "abcdef" @?= "…"
        result <- runScript [Right "CANCEL"] (captureEvidence (defaultFeedbackConfig {critiqueCharacters = -1}) batch metric sentimentProg)
        case result of Left ValidationFailure {} -> pure (); _ -> assertFailure "expected preflight rejection",
      testCase "second node alone is reflected on with local input and redaction" $ do
        let prog = Compose sentimentProg (predict (mkSignature "classify") :: Program Label Label)
            ds = dataset [example (Sentence "outer-secret") (Label "positive")]
            target _ ev = pure (FeedbackResult scoreZero Nothing [NodeFeedback (exampleIndex ev) (NodePath [StepComposeR]) Nothing "fix secret" Caller])
            cfg = defaultFeedbackConfig {redactEvidence = T.replace "secret" "REDACTED"}
            proposer = Embed $ \input ->
              if "positive" `T.isInfixOf` feedback input
                && "REDACTED" `T.isInfixOf` feedback input
                && not ("secret" `T.isInfixOf` feedback input)
                && not ("outer-" `T.isInfixOf` feedback input)
                then pure (ReflectOut "correct classifier")
                else throwError (ValidationFailure (feedback input))
        result <- runScript [ok, ok] $ do
          rows <- captureEvidence cfg ds target prog
          changed <- mutateFromEvidence cfg proposer "program" "dataset" rows 0 prog
          pure (programParams changed)
        checkRight result $ \params -> do
          take 1 params @?= take 1 (programParams prog)
          instructionOverride (params !! 1) @?= Just "correct classifier",
      testCase "GEPA callback improves only classifier in the complete search" $ do
        let prog = Compose sentimentProg (predict (mkSignature "classify") :: Program Label Label)
            ds = dataset [example (Sentence "outer") (Label "positive")]
            target = FeedbackCallback $ \_ ev ->
              pure
                ( FeedbackResult
                    scoreZero
                    Nothing
                    [NodeFeedback (exampleIndex ev) (NodePath [StepComposeR]) Nothing "correct classifier" Caller]
                )
            proposer = Embed $ \input ->
              if "positive" `T.isInfixOf` feedback input && not ("outer" `T.isInfixOf` feedback input)
                then pure (ReflectOut "correct classifier")
                else throwError (ValidationFailure "wrong evidence")
            wrong = Right "{\"sentiment\":\"negative\"}"
        result <-
          runScript [ok, wrong, ok, wrong, ok, ok] $
            optimize (gepaWithFeedback defaultFeedbackConfig proposer target (Budget 20 2)) ds exactMatch prog
        checkRight result $ \cp -> do
          let params = programParams (compiledProgram cp)
          take 1 params @?= take 1 (programParams prog)
          instructionOverride (params !! 1) @?= Just "correct classifier",
      testCase "empty feedback and zero reflection limits never invoke proposer" $ do
        let ds = dataset [example (Sentence "input") (Label "positive")]
            proposer = Embed (const (throwError (ProviderFailure "must not reflect")))
            target _ ev = pure (FeedbackResult scoreZero Nothing [NodeFeedback (exampleIndex ev) (NodePath []) Nothing "fix" Caller])
        mapM_
          ( \cfg -> do
              result <- runScript [ok] $ do
                rows <- captureEvidence cfg ds target sentimentProg
                programParams <$> mutateFromEvidence cfg proposer "" "" rows 0 sentimentProg
              result @?= Right (programParams sentimentProg)
          )
          [defaultFeedbackConfig {critiqueCharacters = 0}, defaultFeedbackConfig {reflectionExamples = 0}, defaultFeedbackConfig {reflectionCharacters = 0}],
      testCase "reflection excludes sibling critiques" $ do
        let prog = Compose sentimentProg (predict (mkSignature "classify") :: Program Label Label)
            ds = dataset [example (Sentence "input") (Label "positive")]
            target _ ev =
              pure
                ( FeedbackResult
                    scoreZero
                    Nothing
                    [ NodeFeedback (exampleIndex ev) (NodePath [StepComposeL]) Nothing "sibling-only" Caller,
                      NodeFeedback (exampleIndex ev) (NodePath [StepComposeR]) Nothing "local-only" Model
                    ]
                )
            proposer = Embed $ \input ->
              if "local-only" `T.isInfixOf` feedback input && not ("sibling-only" `T.isInfixOf` feedback input)
                then pure (ReflectOut "changed")
                else throwError (ValidationFailure "sibling contamination")
        result <- runScript [ok, ok] $ do
          rows <- captureEvidence defaultFeedbackConfig ds target prog
          programParams <$> mutateFromEvidence defaultFeedbackConfig proposer "" "" rows 1 prog
        checkRight result $ \params -> instructionOverride (params !! 1) @?= Just "changed",
      testCase "odd reflection bound retains prioritized failure and marks truncation" $ do
        let prog = Map 1 sentimentProg
            ds = dataset [example [Sentence "good", Sentence "bad"] [Label "positive", Label "positive"]]
            cfg = defaultFeedbackConfig {reflectionExamples = 1, reflectionCharacters = 101}
            target _ ev =
              pure
                ( FeedbackResult
                    scoreZero
                    Nothing
                    [NodeFeedback (exampleIndex ev) (NodePath [StepMap]) Nothing "fix the failed invocation" Caller]
                )
            proposer = Embed $ \input ->
              if T.length (feedback input) <= 101
                && "MissingField" `T.isInfixOf` feedback input
                && "…" `T.isSuffixOf` feedback input
                && "invocation 1" `T.isInfixOf` feedback input
                then pure (ReflectOut "changed")
                else throwError (ValidationFailure (feedback input))
        result <- runScript [ok, Right "bad"] $ do
          rows <- captureEvidence cfg ds target prog
          programParams <$> mutateFromEvidence cfg proposer "" "" rows 0 prog
        checkRight result $ \params -> instructionOverride (params !! 0) @?= Just "changed",
      testCase "legacy multi-node critique is program-scoped and never broadcast" $ do
        let prog = Compose sentimentProg (predict (mkSignature "classify") :: Program Label Label)
            ds = dataset [example (Sentence "input") (Label "positive")]
        result <- runScript [ok, ok] (captureFeedback ds (\_ _ -> (scoreZero, "fix")) prog)
        checkRight result $ \(logbook, scores) -> do
          scores @?= [0]
          map (`feedbackFor` logbook) (programNodePaths prog) @?= [[], []]
          feedbackFor (NodePath []) logbook @?= ["program (LegacyProgram): fix"],
      testCase "retry evidence keeps rejected and accepted invocation lineage" $ do
        let prog = Retry 2 sentimentProg
            ds = dataset [example (Sentence "input") (Label "positive")]
        result <- runScript [Right "bad JSON", ok] (captureEvidence defaultFeedbackConfig ds metric prog)
        checkRight result $ \rows -> do
          let obs = observations (first (rows !! 0))
          map observationInvocation obs @?= [0, 1]
          assertBool "first rejected" (not (null (observationRejectedBy (obs !! 0))))
          observationEligible (obs !! 1) @?= True
    ]
  where
    first (a, _, _) = a
    second (_, b, _) = b
    third (_, _, c) = c
