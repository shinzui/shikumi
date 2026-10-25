{-# LANGUAGE DataKinds #-}

module ReAnchorSpec (tests) where

import Baikai qualified
import Baikai.Models.Generated (openai_gpt_4o_mini)
import Control.Lens ((^.))
import Data.Aeson (Value (..), eitherDecode, encode, toJSON)
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (liftIO, runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Prim (runPrim)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Decision
import Shikumi.Decision.Setting
import Shikumi.Effect.Time (runTime)
import Shikumi.Error
import Shikumi.Eval qualified as E
import Shikumi.LLM (LLM (..), complete, stream)
import Shikumi.Optimize hiding (field)
import Shikumi.Optimize.Execution
import Shikumi.Optimize.ReAnchor.Fit
import Shikumi.Optimize.Report qualified as R
import Shikumi.Program
import Shikumi.Routing
import Shikumi.Schema (field, unField)
import Shikumi.Signature (mkSignature)
import Shikumi.Testing.DecisionFixtures
import Shikumi.Testing.Response (evidenceJSONResponse, evidenceMarkerResponse)
import Shikumi.Testing.StubLLM
import Shikumi.Testing.SystemOne
import Test.Tasty
import Test.Tasty.HUnit

number :: Value -> Double
number (Object o) | Just (Object inputs) <- KM.lookup "inputs" o, Just (String t) <- KM.lookup "ticket" inputs = read (T.unpack t)
number _ = 0

assessment :: Double -> Double -> Double -> Assessment
assessment p mean categoryP = Assessment (field (Noul (p >= 0.72) p 0)) (field (Score mean (if mean >= 1.6 then 2 else if mean >= 0.5 then 1 else 0) (probs mean) Nothing)) (field (Choice (if categoryP >= 0.7 then Technical else Billing) (Map.fromList [("technical", categoryP), ("billing", 1 - categoryP)]) Nothing))

probs :: Double -> V.Vector Double
probs mean
  | mean <= 1 = V.fromList [1 - mean, mean, 0]
  | otherwise = V.fromList [0, 2 - mean, mean - 1]

response :: Double -> [(T.Text, FieldEvidence)]
response p = [("urgent", FieldNoul (NoulEvidence p)), ("severity", FieldScore (ScoreEvidence (probs (2 * p)) Nothing)), ("category", FieldChoice (ChoiceEvidence (Map.fromList [("technical", p), ("billing", 1 - p)]) Nothing))]

metric :: E.Metric Assessment
metric expected actual = E.boolScore (flag expected == flag (E.predictionPrimary actual))
  where
    flag (Assessment u _ _) = case unField u of Noul v _ _ -> v

train :: E.Dataset Ticket Assessment
train = E.dataset [E.example (Ticket (field (T.pack (show p)))) (assessment p (2 * p) p) | p <- [0.1, 0.2, 0.3, 0.4, 0.55, 0.6, 0.65, 0.75, 0.8, 0.9]]

cfg :: RunConfig
cfg = defaultRunConfig {runLimits = RunLimits 100 1000 1 1}

tests :: TestTree
tests =
  testGroup
    "ReAnchor"
    [ testCase "gaps tidy, thin, and separate adjacent floats" $ do
        map fst (gaps 40 False [0.98, 1] 0 1) @?= [0.5, 0.99]
        assertBool "bounded" (length (gaps 40 False [fromIntegral n / 100 | n <- [1 .. 50 :: Int]] 0 1) <= 40)
        let lo = 0.5; hi = castWord64ToDouble (castDoubleToWord64 lo + 1)
        assertBool "adjacent upper" (hi `elem` map fst (thresholdCandidates 40 [lo, hi] 0.2))
        assertBool "zero threshold" (0 `elem` map fst (thresholdCandidates 40 [0, 0.5] 0.2))
        assertBool "ordered cuts" (all (\(c, _) -> c > 0.5 && c < 1.8) (cutCandidates 40 [0.8, 1.2, 1.7] 0.5 1.8 1.5)),
      testCase "fold selection refuses isolated gain and accepts spread gain" $ do
        let (a, refused) = selectKept 5 [0, 0, 0, 0, 0] [([1, 0, 0, 0, 0], [], ())]
        fmap (const ()) a @?= Nothing
        refused @?= True
        let (b, _) = selectKept 5 [0, 0, 0, 0, 0] [([1, 1, 1, 1, 1], [], ())]
        fmap (const ()) b @?= Just ()
        sort (concat (folds 5 13)) @?= [0 .. 12],
      testCase "fits threshold, replays every candidate, and persists only settings" $ do
        calls <- newIORef 0
        let program = Predict assessmentSig emptyParams
        result <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError . runRouting (systemOneModel "jev-latest") . runStubLLM (systemOneResponder (response . number)) . interpose (\_ -> \case Complete m c o -> liftIO (modifyIORef' calls (+ 1)) >> complete m c o; Stream m c o -> stream m c o) . routeLLM $
            runSearchSession cfg (\s -> reAnchorWith defaultReAnchorConfig s train metric program)
        case result of
          Right (Right (CompiledProgram tuned, report), diagnostics) -> do
            trainScoreBefore report @?= 0.7
            trainScore report @?= 1
            case decisionSettingFor "urgent" (head (foldParams tuned)) of
              Just (NoulSetting t) -> assertBool "observed gap" (t > 0.65 && t <= 0.75)
              other -> assertFailure (show other)
            let ps = foldParams tuned
            eitherDecode (encode ps) @?= Right ps
            map instructionOverride ps @?= [Nothing]
            map demos ps @?= [[]]
            R.admittedOperations diagnostics @?= 10
            assertBool "accepted candidate recorded" (R.selectedCandidate diagnostics /= Nothing)
          Left err -> assertFailure (show err)
          Right (Left err, _) -> assertFailure (show err)
        readIORef calls >>= (@?= 10),
      testCase "fold-refused fit restores absent entries and budgets keep accepted state" $ do
        let ds = E.dataset [E.example (Ticket (field (T.pack (show p)))) (assessment p (2 * p) p) | p <- [0.6, 0.1, 0.2, 0.3, 0.8]]
        result <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError . runRouting (systemOneModel "jev-latest") . runStubLLM (systemOneResponder (response . number)) . routeLLM $
            optimizeWith cfg (reAnchor defaultReAnchorConfig) ds metric (Predict assessmentSig emptyParams)
        case result of
          Right (CompiledProgram tuned, _) -> map decisionSettings (foldParams tuned) @?= [Map.empty]
          Left err -> assertFailure (show err),
      testCase "score cuts and choice weights improve distributed errors" $ do
        let scoreMetric expected actual = E.boolScore (lev expected == lev (E.predictionPrimary actual))
            lev (Assessment _ s _) = case unField s of Score _ l _ _ -> l
            choiceMetric expected actual = E.boolScore (cat expected == cat (E.predictionPrimary actual))
            cat (Assessment _ _ c) = case unField c of Choice v _ _ -> v
            scoreData = E.dataset [E.example (Ticket (field (T.pack (show p)))) (assessment p (2 * p) p) | p <- [0.1, 0.2, 0.3, 0.4, 0.755, 0.77, 0.785, 0.825, 0.9, 0.95]]
            run ds met =
              runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError . runRouting (systemOneModel "jev-latest") . runStubLLM (systemOneResponder (response . number)) . routeLLM $
                runSearchSession cfg (\s -> reAnchorWith defaultReAnchorConfig s ds met (Predict assessmentSig emptyParams))
        fittedScore <- run scoreData scoreMetric
        case fittedScore of
          Right (Right (CompiledProgram tuned, report), _) -> do
            trainScore report @?= 1
            case decisionSettingFor "severity" (head (foldParams tuned)) of
              Just (ScoreSetting [a, b]) -> assertBool "ordered fitted boundary" (a < b && b > 1.57 && b <= 1.65)
              _ -> assertFailure "missing fitted cuts"
          Left err -> assertFailure (show err)
          Right (Left err, _) -> assertFailure (show err)
        fittedChoice <- run train choiceMetric
        case fittedChoice of
          Right (Right (CompiledProgram tuned, report), _) -> do
            trainScore report @?= 1
            case decisionSettingFor "category" (head (foldParams tuned)) of
              Just (ChoiceSetting ws) -> assertBool "technical has lower relative weight" (Map.findWithDefault 1 "technical" ws < Map.findWithDefault 1 "billing" ws)
              _ -> assertFailure "missing fitted weights"
          Left err -> assertFailure (show err)
          Right (Left err, _) -> assertFailure (show err),
      testCase "fits a three-label choice" $ do
        let ds = E.dataset [E.example (Ticket (field (T.pack (show p)))) (ChoiceAssessment (Choice (if p >= 0.7 then FirstLabel else SecondLabel) Map.empty Nothing)) | p <- [0.1, 0.2, 0.3, 0.4, 0.55, 0.6, 0.65, 0.75, 0.8, 0.9]]
            met (ChoiceAssessment (Choice expected _ _)) predicted = case E.predictionPrimary predicted of ChoiceAssessment (Choice actual _ _) -> E.boolScore (expected == actual)
            resp state = [("selection", FieldChoice (ChoiceEvidence (Map.fromList [("FirstLabel", p), ("SecondLabel", 0.8 * (1 - p)), ("ThirdLabel", 0.2 * (1 - p))]) Nothing))] where p = number state
        result <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError . runRouting (systemOneModel "jev-latest") . runStubLLM (systemOneResponder resp) . routeLLM $
            runSearchSession cfg (\s -> reAnchorWith defaultReAnchorConfig s ds met (Predict (mkSignature "Choose a label") emptyParams))
        case result of
          Right (Right (CompiledProgram tuned, report), _) -> do
            trainScore report @?= 1
            case decisionSettingFor "selection" (head (foldParams tuned)) of
              Just (ChoiceSetting ws) -> assertBool "over-picked label downweighted" (Map.findWithDefault 1 "FirstLabel" ws < Map.findWithDefault 1 "SecondLabel" ws)
              _ -> assertFailure "missing fitted weights"
          Left err -> assertFailure (show err)
          Right (Left err, _) -> assertFailure (show err),
      testCase "changed upstream answers admit new downstream requests; budget stops safely" $ do
        let program = Compose (Predict assessmentSig emptyParams) (Predict (mkSignature "Downstream decision") emptyParams)
            respond state = response $ case state of
              Object o | Just (Object inputs) <- KM.lookup "inputs" o, Just (Bool flag) <- KM.lookup "urgent" inputs -> if flag then 0.9 else 0.1
              _ -> number state
        result <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError . runRouting (systemOneModel "jev-latest") . runStubLLM (systemOneResponder respond) . routeLLM $
            optimizeWith cfg (reAnchor defaultReAnchorConfig) train metric program
        case result of
          Right (_, diagnostics) -> do
            assertBool "new downstream states admitted" (R.admittedOperations diagnostics > 12)
            assertBool "new requests respect admission ceiling" (R.admittedOperations diagnostics <= 100)
          Left err -> assertFailure (show err)
        stopped <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError . runRouting (systemOneModel "jev-latest") . runStubLLM (systemOneResponder (response . number)) . routeLLM $
            optimizeWith (cfg {runLimits = RunLimits 100 1 1 1}) (reAnchor defaultReAnchorConfig) train metric (Predict assessmentSig emptyParams)
        case stopped of
          Right (CompiledProgram tuned, diagnostics) -> do
            map decisionSettings (foldParams tuned) @?= [Map.empty]
            R.selectedCandidate diagnostics @?= Just 0
          Left err -> assertFailure (show err),
      testCase "generative JSON and marker evidence fit the same threshold" $ do
        let payload = \case FieldNoul e -> toJSON e; FieldChoice (ChoiceEvidence ps _) -> toJSON (ChoiceEvidence ps (Just 0.8)); FieldScore (ScoreEvidence ps _) -> toJSON (ScoreEvidence ps (Just 0.8))
        mapM_
          ( \builder -> do
              result <-
                runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError . runRouting openai_gpt_4o_mini . runStubLLM (\ctx -> builder [(k, payload e) | (k, e) <- response (numberFromContext ctx)]) . routeLLM $
                  optimizeWith cfg (reAnchor defaultReAnchorConfig) train metric (Predict assessmentSig emptyParams)
              case result of
                Right (CompiledProgram tuned, diagnostics) -> do
                  case decisionSettingFor "urgent" (head (foldParams tuned)) of
                    Just (NoulSetting t) -> assertBool "fitted gap" (t > 0.65 && t <= 0.75)
                    _ -> assertFailure "missing threshold"
                  R.admittedOperations diagnostics @?= 10
                Left err -> assertFailure (show err)
          )
          [evidenceJSONResponse, evidenceMarkerResponse],
      testCase "no decision output fails before dispatch" $ do
        let program = embed (\input -> pure input) :: Program Ticket Ticket
        result <-
          runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError . runStubLLM (const (systemOneResponse [])) $
            optimizeWith cfg (reAnchor defaultReAnchorConfig) (E.dataset [E.example (Ticket (field "x")) (Ticket (field "x"))]) E.exactMatch program
        assertBool "typed refusal" (case result of Left (ValidationFailure _) -> True; _ -> False)
    ]

-- Native contexts retain the ordinary user turn. Its typed Field Show spelling
-- contains the ticket number; use the shared prompt text projection for fixtures.
numberFromContext :: Baikai.Context -> Double
numberFromContext ctx = case [t | Baikai.UserMessage p <- V.toList (ctx ^. #messages), Baikai.UserText (Baikai.TextContent t) <- V.toList (p ^. #content)] of
  t : _ -> case reads (T.unpack (T.filter (\c -> c `elem` ("0123456789." :: String)) t)) of (p, _) : _ -> p; _ -> 0
  _ -> 0
