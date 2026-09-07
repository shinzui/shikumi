module StructureSpec (tests) where

import Baikai (AssistantContent (..), Context, Response, emptyResponse, emptyTextContent)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (replicateM_)
import Data.Aeson (eitherDecode, encode)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Effectful.Dispatch.Dynamic (interpose, interpret)
import Effectful.Error.Static (Error, catchError, runErrorNoCallStack, throwError)
import Effectful.Prim (Prim, runPrim)
import Effectful.Prim.IORef qualified as Ref
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Compile
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval (Dataset, dataset, exactMatch, example, scoreZero)
import Shikumi.LLM (LLM (..), complete, stream)
import Shikumi.Module (predict)
import Shikumi.Optimize.Execution
import Shikumi.Optimize.Feedback (candidateFailurePolicy)
import Shikumi.Optimize.Report
import Shikumi.Optimize.Structure
import Shikumi.Program (Program (..), embed, runProgram)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)
import Test.Tasty
import Test.Tasty.HUnit

newtype Input = Input {question :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype Output = Output {answer :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

base :: Program Input Output
base = predict (mkSignature "Answer")

response :: Bool -> Text -> Response
response cot directAnswer = emptyResponse & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ body))
  where
    body =
      if cot
        then "[[ ## reasoning ## ]]\nreason\n[[ ## value ## ]]\n{\"answer\":\"cot\"}\n[[ ## completed ## ]]"
        else "[[ ## answer ## ]]\n" <> directAnswer <> "\n[[ ## completed ## ]]"

respond :: Context -> Response
respond context = response (maybe False (T.isInfixOf "step by step") (context ^. #systemPrompt)) (if "held-out 1" `T.isInfixOf` T.pack (show context) then "cot" else "direct")

-- The provider returns different typed answers for direct and reasoning requests.
run :: Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
run action =
  runEff . runPrim . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $
    interpret (\_ -> \case Complete _ c _ -> pure (respond c); Stream {} -> pure []) action

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

cfg :: Int -> Int -> Int -> RunConfig
cfg cap candidatesCount width = defaultRunConfig {runLimits = RunLimits cap candidatesCount width 1}

train :: Dataset Input Output
train = dataset [example (Input "training") (Output "direct")]

validation :: Dataset Input Output
validation = dataset [example (Input "held-out 1") (Output "cot"), example (Input "held-out 2") (Output "cot")]

search :: RunConfig -> StructureRegistry Input Output -> Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] (StructureSearchResult Input Output)
search controls = structureSearchWith controls train validation exactMatch (candidateFailurePolicy scoreZero) qualityPolicy (scalarObjectives exactMatch)

tests :: TestTree
tests =
  testGroup
    "structure search"
    [ testCase "validation selects CoT, report identity and artifact behavior agree" $ do
        registry <- right (directCotRegistry "fixture" base)
        result <- run (search (cfg 8 2 1) registry) >>= right
        recipeIdText (selectedRecipeId result) @?= "cot"
        let report = structureReport result
        selectedCandidate report @?= Just 1
        map objectiveValues (candidates report) @?= [Map.singleton "quality" 0.5, Map.singleton "quality" 1]
        admittedOperations report @?= 4
        Map.lookup 1 (candidateMetadata report) @?= Just (Map.fromList [("recipeId", "cot"), ("recipeRevision", "1"), ("registryId", "fixture")])
        eitherDecode (encode report) @?= Right report
        bytes <- right (encodeStructureArtifact registry (selectedRecipeId result) (selectedStructure result))
        restored <- right (decodeStructureArtifact registry bytes)
        (before, restoredOutput, requests) <-
          run
            ( do
                ref <- Ref.newIORef []
                let capture =
                      interpose
                        ( \_ -> \case
                            Complete m c o -> Ref.atomicModifyIORef' ref (\xs -> (xs ++ [c], ())) >> complete m c o
                            Stream m c o -> stream m c o
                        )
                before <- capture (runCompiled (selectedStructure result) (Input "same"))
                restoredOutput <- capture (runCompiled restored (Input "same"))
                requests <- Ref.readIORef ref
                pure (before, restoredOutput, requests)
            )
            >>= right
        before @?= Output "cot"
        restoredOutput @?= before
        length requests @?= 2
        case requests of
          [originalRequest, restoredRequest] -> originalRequest @?= restoredRequest
          _ -> assertFailure "expected two captured requests",
      testCase "opposite validation ranking selects direct despite CoT training labels" $ do
        registry <- right (directCotRegistry "fixture" base)
        result <- run (structureSearchWith (cfg 8 2 1) validation train exactMatch (candidateFailurePolicy scoreZero) qualityPolicy (scalarObjectives exactMatch) registry) >>= right
        recipeIdText (selectedRecipeId result) @?= "direct",
      testCase "zero candidate or operation budgets return unscored baseline" $ do
        registry <- right (directCotRegistry "fixture" base)
        mapM_
          ( \controls -> do
              result <- run (search controls registry) >>= right
              recipeIdText (selectedRecipeId result) @?= "direct"
              resultStatus (structureReport result) @?= Just Unscored
              admittedOperations (structureReport result) @?= 0
          )
          [cfg 0 2 1, cfg 8 0 1],
      testCase "partial CoT cannot displace completed direct" $ do
        registry <- right (directCotRegistry "fixture" base)
        result <- run (search (cfg 3 2 1) registry) >>= right
        recipeIdText (selectedRecipeId result) @?= "direct"
        map candidateStatus (candidates (structureReport result)) @?= [CandidateCompleted, CandidateIncomplete]
        admittedOperations (structureReport result) @?= 3,
      testCase "candidate ceiling only evaluates the first recipe" $ do
        registry <- right (directCotRegistry "fixture" base)
        result <- run (search (cfg 8 1 1) registry) >>= right
        recipeIdText (selectedRecipeId result) @?= "direct"
        length (candidates (structureReport result)) @?= 1
        runStatus (structureReport result) @?= BudgetStopped,
      testCase "opaque caught denials and nested retries cannot overspend" $ do
        let opaque =
              embed
                ( \inp -> do
                    replicateM_ 9 ((runProgram base inp >> pure ()) `catchError` \_ (_ :: ShikumiError) -> pure ())
                    pure (Output "cot")
                )
        recipe <- right (structureRecipe "opaque" 1 "" (Retry 3 opaque))
        registry <- right (structureRegistry "fixture" [recipe])
        (result, actual) <-
          run
            ( do
                counter <- Ref.newIORef (0 :: Int)
                result <-
                  interpose
                    ( \_ -> \case
                        Complete m c o -> Ref.atomicModifyIORef' counter (\n -> (n + 1, ())) >> complete m c o
                        Stream m c o -> Ref.atomicModifyIORef' counter (\n -> (n + 1, ())) >> stream m c o
                    )
                    (search (cfg 2 1 1) registry)
                actual <- Ref.readIORef counter
                pure (result, actual)
            )
            >>= right
        actual @?= 2
        admittedOperations (structureReport result) @?= actual
        map candidateStatus (candidates (structureReport result)) @?= [CandidateIncomplete],
      testCase "queued candidates do not start after exact exhaustion" $ do
        registry <- right (directCotRegistry "fixture" base)
        result <- run (search (cfg 2 2 1) registry) >>= right
        map candidateStatus (candidates (structureReport result)) @?= [CandidateCompleted]
        unexecutedReservations (structureReport result) @?= [1]
        selectedCandidate (structureReport result) @?= Just 0,
      testCase "nested ensemble stream and completion share the cap" $ do
        recipe <- right (structureRecipe "ensemble" 1 "" (Ensemble [base, base] (const (Output "cot"))))
        registry <- right (structureRegistry "fixture" [recipe])
        result <- run (searchWithStreams registry) >>= right
        admittedOperations (structureReport result) @?= 3
        map candidateStatus (candidates (structureReport result)) @?= [CandidateIncomplete],
      testCase "ties retain registry order under reversed completion" $ do
        registry <- right (directCotRegistry "fixture" base)
        result <-
          run
            ( do
                gate <- newEmptyMVar
                let controls =
                      (cfg 8 2 2)
                        { eventSink = \event -> case eventKind event of
                            CandidateEnded 1 CandidateCompleted -> putMVar gate ()
                            _ -> pure ()
                        }
                interpose
                  ( \_ -> \case
                      Complete m c o ->
                        if maybe False (T.isInfixOf "step by step") (c ^. #systemPrompt)
                          then complete m c o
                          else takeMVar gate >> complete m c o
                      Stream m c o -> stream m c o
                  )
                  (structureSearchWith controls train train exactMatch (candidateFailurePolicy scoreZero) qualityPolicy (\_ _ -> pure (Map.singleton "quality" 1)) registry)
            )
            >>= right
        recipeIdText (selectedRecipeId result) @?= "direct"
        selectedCandidate (structureReport result) @?= Just 0,
      testCase "empty validation and non-finite objectives reject" $ do
        registry <- right (directCotRegistry "fixture" base)
        invalid <- run (structureSearchWith (cfg 0 0 1) train (dataset []) exactMatch (candidateFailurePolicy scoreZero) qualityPolicy (scalarObjectives exactMatch) registry)
        assertBool "invalid dataset" (isLeft invalid)
        result <- run (structureSearchWith (cfg 8 2 1) train validation exactMatch (candidateFailurePolicy scoreZero) qualityPolicy (\_ _ -> pure (Map.singleton "quality" (0 / 0))) registry) >>= right
        resultStatus (structureReport result) @?= Just Unscored
        map candidateStatus (candidates (structureReport result)) @?= [CandidateFailed, CandidateFailed],
      testCase "infrastructure failures propagate" $ do
        recipe <- right (structureRecipe "broken" 1 "" (embed (\_ -> throwError (ProviderFailure "offline failure")) :: Program Input Output))
        registry <- right (structureRegistry "fixture" [recipe])
        result <- run (search (cfg 8 1 1) registry)
        assertBool "propagated" (isLeft result)
    ]

-- Each predictor dispatches a stream followed by completion inside the session.
searchWithStreams :: StructureRegistry Input Output -> Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] (StructureSearchResult Input Output)
searchWithStreams registry = do
  let withStreams =
        embed
          ( \inp ->
              interpose
                ( \_ -> \case
                    Complete m c o -> stream m c o >> complete m c o
                    Stream m c o -> stream m c o
                )
                (runProgram (recipeProgram (NE.head (registryRecipes registry))) inp)
          )
  case structureRecipe "stream-ensemble" 1 "" withStreams >>= \recipe -> structureRegistry "streams" [recipe] of
    Left err -> throwError (ValidationFailure (T.pack (show err)))
    Right registered -> search (cfg 3 1 1) registered
