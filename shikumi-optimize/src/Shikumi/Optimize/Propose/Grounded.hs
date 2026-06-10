{-# LANGUAGE FlexibleContexts #-}

-- | The assembled grounded proposer (EP-19): the final instruction-generating
-- predictor (DSPy's @GenerateSingleModuleInstruction@) and the 'proposeInstructions'
-- driver that gathers every signal and returns ranked candidate instructions for one
-- node — with the current instruction always retained, so a node can never degrade.
module Shikumi.Optimize.Propose.Grounded
  ( GenerateInstructionIn (..),
    GenerateInstructionOut (..),
    instructionGenerator,
    proposeInstructions,
  )
where

import Control.Monad (forM)
import Data.Aeson (ToJSON)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, datasetExamples)
import Shikumi.LLM (LLM)
import Shikumi.Module (predict)
import Shikumi.Optimize.Propose.Summarize
  ( ModuleDescribeIn (..),
    ModuleDescribeOut (..),
    ProgramDescribeIn (..),
    ProgramDescribeOut (..),
    datasetSummary,
    moduleDescriber,
    programDescriber,
    renderExampleRow,
    renderProgramPseudo,
  )
import Shikumi.Optimize.Propose.Tips (tipAt)
import Shikumi.Optimize.Propose.Types
  ( ProposeRequest (..),
    ProposeResult (..),
    moduleSignatureAt,
    renderHistory,
  )
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)

-- | The grounded proposer's input: every signal about the optimization target,
-- rendered into the prompt under its field name by the generic 'ToPrompt'.
data GenerateInstructionIn = GenerateInstructionIn
  { datasetDescription :: Text,
    programCode :: Text,
    programDescription :: Text,
    moduleSignature :: Text,
    moduleDescription :: Text,
    taskDemos :: Text,
    previousInstructions :: Text,
    basicInstruction :: Text,
    tip :: Text
  }
  deriving stock (Generic, Show)

instance FromModel GenerateInstructionIn

instance ToPrompt GenerateInstructionIn

newtype GenerateInstructionOut = GenerateInstructionOut {proposedInstruction :: Text}
  deriving stock (Generic, Show)

instance ToSchema GenerateInstructionOut

instance FromModel GenerateInstructionOut

instance ToPrompt GenerateInstructionOut

instance Validatable GenerateInstructionOut

instructionGenerator :: Program GenerateInstructionIn GenerateInstructionOut
instructionGenerator =
  predict
    ( mkSignature
        "Use the information below to understand a task that is solved with calls to a language \
        \model, then write a NEW instruction that will prompt the model to solve the task better. \
        \Consider the dataset notes, the program outline and what it does, the target module's \
        \role and its fields, any demonstrations, the previously-tried instructions with their \
        \scores, the current instruction, and the tip. Write only the new instruction text in the \
        \`proposedInstruction` field."
    )

-- | Gather every grounding signal and return ranked candidate instructions for the
-- request's target node. Runs, in order: dataset summary → program pseudo-code →
-- program description → module description → @numCandidates@ instruction generations
-- (each varying the tip so the candidates are distinct), then prepends the current
-- instruction and deduplicates preserving order. Makes exactly @4 + numCandidates@ LM
-- calls (2 for the summary, 1 program describe, 1 module describe, N generations).
proposeInstructions ::
  (ToJSON i, ToJSON o, LLM :> es, Error ShikumiError :> es) =>
  Dataset i o ->
  ProposeRequest i o ->
  Eff es ProposeResult
proposeInstructions ds req = do
  summary <- datasetSummary (viewBatch req) ds
  let prog = program req
      code = renderProgramPseudo prog
      sigStr = moduleSignatureAt (targetNode req) prog
      sampleRow = case take 1 (datasetExamples ds) of
        (ex : _) -> renderExampleRow ex
        [] -> "No example provided."
  ProgramDescribeOut desc <- runProgram programDescriber (ProgramDescribeIn code sampleRow)
  ModuleDescribeOut modDesc <- runProgram moduleDescriber (ModuleDescribeIn code desc sigStr)
  proposed <- forM [0 .. max 0 (numCandidates req) - 1] $ \j -> do
    let genIn =
          GenerateInstructionIn
            { datasetDescription = summary,
              programCode = code,
              programDescription = desc,
              moduleSignature = sigStr,
              moduleDescription = modDesc,
              taskDemos = renderDemos (bootstrappedDemos req),
              previousInstructions = renderHistory 5 (history req),
              basicInstruction = currentInstruction req,
              tip = tipAt (tipIndex req + j)
            }
    GenerateInstructionOut p <- runProgram instructionGenerator genIn
    pure p
  pure (ProposeResult (dedup (currentInstruction req : proposed)))

-- | Render bootstrapped demos, or a placeholder when there are none.
renderDemos :: [Text] -> Text
renderDemos [] = "No task demos provided."
renderDemos xs = T.intercalate "\n" xs

-- | Order-preserving de-duplication.
dedup :: (Eq a) => [a] -> [a]
dedup = go []
  where
    go _ [] = []
    go seen (x : xs)
      | x `elem` seen = go seen xs
      | otherwise = x : go (x : seen) xs
