-- | Render a documented program into the Markdown body of its OKF concept.
--
-- The body has up to four parts: a heading, the author's prose description, a
-- declared-interface section (free-text input/output summaries), and a structure
-- section derived from the program value itself. The structure section is
-- best-effort: a typed @Predict@ pipeline yields a constructor tree and the
-- input/output field names of each model call, whereas an opaque @Embed@ program
-- (the shape an agent runtime produces) has no inspectable internals, so we say so
-- plainly rather than emit an empty section. The declared-interface fields are
-- what carry the documentary weight in that opaque case.
module Shikumi.Okf.Render
  ( renderProgramBody,
  )
where

import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Shikumi.Okf.Types (ProgramDoc (..), SomeProgram (..))
import Shikumi.Program
  ( NodeFields (..),
    ProgramShape (..),
    nodeFieldsIndexed,
    nodeInstructionsIndexed,
    programShape,
  )

-- | The full Markdown body for one program, with a trailing newline.
renderProgramBody :: ProgramDoc -> Text
renderProgramBody doc =
  T.unlines (intercalate [""] sections)
  where
    sections :: [[Text]]
    sections =
      filter
        (not . null)
        [ ["# " <> fromMaybe (name doc) (title doc)],
          maybe [] pure (description doc),
          interfaceSection doc,
          structureSection (program doc)
        ]

-- | The declared-interface section, present only when the author supplied at
-- least one of the free-text input/output summaries.
interfaceSection :: ProgramDoc -> [Text]
interfaceSection doc =
  case (declaredInputs doc, declaredOutputs doc) of
    (Nothing, Nothing) -> []
    (mi, mo) ->
      ["## Interface", ""]
        <> maybe [] (\t -> ["- Input: " <> t]) mi
        <> maybe [] (\t -> ["- Output: " <> t]) mo

-- | The structure section, derived from the program's run-free shape.
structureSection :: SomeProgram -> [Text]
structureSection (SomeProgram p) =
  ["## Structure", ""] <> bodyLines
  where
    bodyLines = case programShape p of
      ShapeEmbed ->
        ["Opaque embedded program (no inspectable internal structure)."]
      sh ->
        renderShapeTree 0 sh
          <> modelCalls (zip (nodeFieldsIndexed p) (nodeInstructionsIndexed p))

-- | Render the constructor tree as a nested Markdown bullet list. Each level of
-- nesting is indented two spaces.
renderShapeTree :: Int -> ProgramShape -> [Text]
renderShapeTree depth shape = case shape of
  ShapePredict label -> [bullet ("Predict — outputs: " <> label)]
  ShapeCompose a b -> bullet "Compose" : descend a <> descend b
  ShapeFMap a -> bullet "FMap (pure post-processing)" : descend a
  ShapeMap width a -> bullet ("Map (concurrency width " <> tshow width <> ")") : descend a
  ShapeParallel a b -> bullet "Parallel" : descend a <> descend b
  ShapeRetry n a -> bullet ("Retry (up to " <> tshow n <> " attempts)") : descend a
  ShapeRetryWhen n a -> bullet ("RetryWhen (up to " <> tshow n <> " attempts)") : descend a
  ShapeValidate a -> bullet "Validate" : descend a
  ShapeMajorityVote k _ a -> bullet ("MajorityVote (k=" <> tshow k <> ")") : descend a
  ShapeEnsemble as -> bullet "Ensemble" : concatMap descend as
  ShapeEmbed -> [bullet "Embed (opaque effectful program)"]
  where
    bullet t = T.replicate (depth * 2) " " <> "- " <> t
    descend = renderShapeTree (depth + 1)

-- | A "Model calls" subsection listing, for each @Predict@ node in order, its
-- input and output field names and its signature instruction (as a nested bullet).
-- Omitted when the program has no model calls.
modelCalls :: [(NodeFields, Text)] -> [Text]
modelCalls [] = []
modelCalls calls =
  "" : "### Model calls" : "" : concat (zipWith entry [1 :: Int ..] calls)
  where
    entry idx (nf, instruction) =
      [ "- "
          <> tshow idx
          <> ". inputs ("
          <> commaSep (inputFieldNames nf)
          <> ") -> outputs ("
          <> commaSep (outputFieldNames nf)
          <> ")",
        "  - Instruction: " <> instruction
      ]

commaSep :: [Text] -> Text
commaSep = T.intercalate ", "

tshow :: (Show a) => a -> Text
tshow = T.pack . show
