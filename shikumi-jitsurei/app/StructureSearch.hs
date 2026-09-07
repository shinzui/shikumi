module Main (main) where

import Data.Text (Text)
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Prim.IORef qualified as Ref
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Compile
import Shikumi.Eval (dataset, exactMatch, example, scoreZero)
import Shikumi.Jitsurei.Stub (markerResponse, runStubEval, systemContains)
import Shikumi.LLM (LLM (..), complete, stream)
import Shikumi.Module (predict)
import Shikumi.Optimize.Execution
import Shikumi.Optimize.Feedback (candidateFailurePolicy)
import Shikumi.Optimize.Report
import Shikumi.Optimize.Structure
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)

newtype Input = Input {question :: Text}
  deriving stock (Show, Generic)
  deriving anyclass (FromModel, ToPrompt, ToSchema)

newtype Output = Output {answer :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromModel, ToPrompt, ToSchema, Validatable)

student :: Program Input Output
student = predict (mkSignature "Answer the question")

main :: IO ()
main = do
  registry <- either (fail . show) pure (directCotRegistry "example.qa" student)
  let train = dataset [example (Input "training") (Output "direct")]
      validation = dataset [example (Input "validation one") (Output "cot"), example (Input "validation two") (Output "cot")]
      controls = defaultRunConfig {runLimits = RunLimits 8 2 1 1}
      respond context
        | systemContains "step by step" context = markerResponse [("reasoning", "A scripted reasoning step"), ("value", "{\"answer\":\"cot\"}")]
        | otherwise = markerResponse [("answer", "direct")]
  selected <- runStubEval respond (structureSearchWith controls train validation exactMatch (candidateFailurePolicy scoreZero) qualityPolicy (scalarObjectives exactMatch) registry) >>= either (fail . show) pure
  bytes <- either (fail . show) pure (encodeStructureArtifact registry (selectedRecipeId selected) (selectedStructure selected))
  restored <- either (fail . show) pure (decodeStructureArtifact registry bytes)
  equality <-
    runStubEval
      respond
      ( do
          requests <- Ref.newIORef []
          let capture =
                interpose
                  ( \_ -> \case
                      Complete m c o -> Ref.atomicModifyIORef' requests (\xs -> (xs ++ [c], ())) >> complete m c o
                      Stream m c o -> stream m c o
                  )
          before <- capture (runCompiled (selectedStructure selected) (Input "same request"))
          after <- capture (runCompiled restored (Input "same request"))
          contexts <- Ref.readIORef requests
          pure (before == after, case contexts of [a, b] -> a == b; _ -> False)
      )
      >>= either (fail . show) pure
  putStrLn ("Selected recipe: " ++ show (recipeIdText (selectedRecipeId selected)))
  putStrLn ("Admitted operations: " ++ show (admittedOperations (structureReport selected)) ++ "/8")
  putStrLn ("Restored output equality: " ++ show (fst equality))
  putStrLn ("Restored request equality: " ++ show (snd equality))
