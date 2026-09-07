module Main (main) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Eval (dataset, exactMatch, example, scoreOne)
import Shikumi.Jitsurei.Stub (markerResponse, runStubEval, systemContains)
import Shikumi.Module (predict)
import Shikumi.Optimize (FeedbackCallback (..), GEPAConfig (..), ObjectiveCallback (..), defaultGEPAConfig, gepaWith, optimizeWith, reflectiveProposer)
import Shikumi.Optimize.Execution
import Shikumi.Optimize.Feedback
import Shikumi.Optimize.Report
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)

newtype Input = Input {question :: Text} deriving stock (Show, Generic)

instance FromModel Input

instance ToPrompt Input

newtype Output = Output {answer :: Text} deriving stock (Eq, Show, Generic)

instance ToPrompt Output

instance FromModel Output

instance ToSchema Output

instance Validatable Output

student :: Program Input Output
student = predict (mkSignature "Candidate A")

main :: IO ()
main = do
  let train = dataset [example (Input "training") (Output "A")]
      validation = dataset [example (Input "validation") (Output "B")]
      feedbackFn = FeedbackCallback $ \_ _ -> pure (FeedbackResult scoreOne (Just (Caller, "Try candidate B")) [])
      cost = ObjectiveSpec "cost" "fixture work units" Minimize Mean Required (Just 0) (Just 2)
      policy = qualityPolicy {objectives = objectives qualityPolicy ++ [cost]}
      config =
        (defaultGEPAConfig feedbackFn)
          { validationDataset = Just validation,
            feedbackConfig = defaultFeedbackConfig {includeProgramCritique = True},
            objectivePolicy = policy,
            objectiveCallback =
              Just
                ( ObjectiveCallback $ \expected measured -> do
                    quality <- scalarObjectives exactMatch expected measured
                    let work = case executionResult (evidence measured) of Right (Output "A") -> 3; _ -> 1
                    pure (Map.insert "cost" work quality)
                ),
            minibatchSize = 1
          }
      runConfig = defaultRunConfig {runLimits = RunLimits 20 2 2 1}
      respond context
        | systemContains "proposedInstruction" context = markerResponse [("proposedInstruction", "Candidate B")]
        | systemContains "Candidate B" context = markerResponse [("answer", "B")]
        | otherwise = markerResponse [("answer", "A")]
  result <- runStubEval respond $ optimizeWith runConfig (gepaWith config reflectiveProposer) train exactMatch student
  case result of
    Left err -> fail (show err)
    Right (_, report) -> do
      putStrLn ("Validation-selected candidate: " ++ if selectedCandidate report == Just 1 then "B" else show (selectedCandidate report))
      putStrLn ("Objective frontier: " ++ show [(candidateId c, objectiveValues c) | c <- candidates report, candidateId c `elem` frontier report])
      putStrLn ("Admitted operations: " ++ show (admittedOperations report) ++ "/20")
      putStrLn ("Termination: " ++ show (runStatus report))
