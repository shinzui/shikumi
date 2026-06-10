{-# LANGUAGE FlexibleContexts #-}

-- | The signal-gatherers of the grounded proposer (EP-19) that are themselves typed
-- Shikumi 'Program's — preserving V1's "the optimizer is written in the framework it
-- optimizes" pattern. Each mirrors a DSPy proposer sub-module:
--
--   * 'renderProgramPseudo' / 'programDescriber' — DSPy's @DescribeProgram@: render
--     the whole program as deterministic pseudo-code and describe what it does.
--   * 'datasetDescriber' / 'observationSummarizer' / 'datasetSummary' — DSPy's
--     @DatasetDescriptor@ + @ObservationSummarizer@: observe patterns across sampled
--     rows, then condense them into a 2-3 sentence summary.
--   * 'moduleDescriber' — DSPy's @DescribeModule@: describe one node's role within
--     the broader program.
module Shikumi.Optimize.Propose.Summarize
  ( -- * Program pseudo-code
    renderProgramPseudo,

    -- * Row rendering (shared with the grounded driver)
    renderExampleRow,
    encodeJsonText,

    -- * The program describer
    ProgramDescribeIn (..),
    ProgramDescribeOut (..),
    programDescriber,

    -- * The dataset summarizer
    DatasetDescribeIn (..),
    DatasetDescribeOut (..),
    datasetDescriber,
    SummarizeIn (..),
    SummarizeOut (..),
    observationSummarizer,
    datasetSummary,

    -- * The module describer
    ModuleDescribeIn (..),
    ModuleDescribeOut (..),
    moduleDescriber,
  )
where

import Data.Aeson (ToJSON)
import Data.Aeson.Text (encodeToLazyText)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, Example (..), datasetExamples)
import Shikumi.LLM (LLM)
import Shikumi.Module (predict)
import Shikumi.Optimize.Propose.Types (NodeFieldNames (..), programFieldNames)
import Shikumi.Program
  ( Program,
    ProgramShape (..),
    programShape,
    runProgram,
  )
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)

-- ---------------------------------------------------------------------------
-- Program pseudo-code
-- ---------------------------------------------------------------------------

-- | Render a program as a short, deterministic, human-readable outline: one line
-- per node and combinator, with 'Predict' nodes shown as @predict(inputs) ->
-- outputs@ (using 'programFieldNames') and combinators shown by name. Shikumi's
-- analogue of DSPy's @get_dspy_source_code@. Deterministic, so tests can assert on it.
renderProgramPseudo :: Program i o -> Text
renderProgramPseudo prog = T.intercalate "\n" (fst (go (programShape prog) (programFieldNames prog)))
  where
    go :: ProgramShape -> [NodeFieldNames] -> ([Text], [NodeFieldNames])
    go (ShapePredict lbl) nfs = case nfs of
      (nf : rest) ->
        (["predict(" <> commas (inputFieldNames nf) <> ") -> " <> commas (outputFieldNames nf)], rest)
      [] -> (["predict(?) -> " <> lbl], [])
    go (ShapeCompose a b) nfs = combine "compose" [a, b] nfs
    go (ShapeFMap a) nfs = combine "fmap" [a] nfs
    go (ShapeMap _ a) nfs = combine "map" [a] nfs
    go (ShapeParallel a b) nfs = combine "parallel" [a, b] nfs
    go (ShapeRetry _ a) nfs = combine "retry" [a] nfs
    go (ShapeRetryWhen _ a) nfs = combine "retryWhen" [a] nfs
    go (ShapeValidate a) nfs = combine "validate" [a] nfs
    go (ShapeMajorityVote _ _ a) nfs = combine "majorityVote" [a] nfs
    go (ShapeEnsemble as) nfs = combine "ensemble" as nfs
    go ShapeEmbed nfs = (["embed"], nfs)
    combine name children nfs0 =
      let (lns, rest) = foldl step ([], nfs0) children
          step (acc, nf) c = let (l, nf') = go c nf in (acc ++ l, nf')
       in ((name <> ":") : map ("  " <>) lns, rest)
    commas xs = if null xs then "?" else T.intercalate ", " xs

-- | Render a single dataset example as @<input-json> => <expected-json>@.
renderExampleRow :: (ToJSON i, ToJSON o) => Example i o -> Text
renderExampleRow (Example i o) = encodeJsonText i <> " => " <> encodeJsonText o

-- | Encode any 'ToJSON' value to compact 'Text'.
encodeJsonText :: (ToJSON a) => a -> Text
encodeJsonText = TL.toStrict . encodeToLazyText

-- ---------------------------------------------------------------------------
-- The program describer
-- ---------------------------------------------------------------------------

data ProgramDescribeIn = ProgramDescribeIn
  { programCode :: Text,
    programExample :: Text
  }
  deriving stock (Generic, Show)

instance FromModel ProgramDescribeIn

instance ToPrompt ProgramDescribeIn

newtype ProgramDescribeOut = ProgramDescribeOut {programDescription :: Text}
  deriving stock (Generic, Show)

instance ToSchema ProgramDescribeOut

instance FromModel ProgramDescribeOut

instance ToPrompt ProgramDescribeOut

instance Validatable ProgramDescribeOut

programDescriber :: Program ProgramDescribeIn ProgramDescribeOut
programDescriber =
  predict
    ( mkSignature
        "Below is pseudo-code for a pipeline that solves a task with calls to a language \
        \model. Describe, in two or three sentences, what task this program is designed to \
        \solve and how it goes about solving it. Write your answer in the `programDescription` field."
    )

-- ---------------------------------------------------------------------------
-- The dataset summarizer
-- ---------------------------------------------------------------------------

newtype DatasetDescribeIn = DatasetDescribeIn {examples :: Text}
  deriving stock (Generic, Show)

instance FromModel DatasetDescribeIn

instance ToPrompt DatasetDescribeIn

newtype DatasetDescribeOut = DatasetDescribeOut {observations :: Text}
  deriving stock (Generic, Show)

instance ToSchema DatasetDescribeOut

instance FromModel DatasetDescribeOut

instance ToPrompt DatasetDescribeOut

instance Validatable DatasetDescribeOut

datasetDescriber :: Program DatasetDescribeIn DatasetDescribeOut
datasetDescriber =
  predict
    ( mkSignature
        "Given several examples from a dataset, write observations about trends that hold for \
        \most or all of the samples — topics, content, syntax, brevity — and guess at the task \
        \the dataset enables. Write them in the `observations` field."
    )

newtype SummarizeIn = SummarizeIn {observations :: Text}
  deriving stock (Generic, Show)

instance FromModel SummarizeIn

instance ToPrompt SummarizeIn

newtype SummarizeOut = SummarizeOut {summary :: Text}
  deriving stock (Generic, Show)

instance ToSchema SummarizeOut

instance FromModel SummarizeOut

instance ToPrompt SummarizeOut

instance Validatable SummarizeOut

observationSummarizer :: Program SummarizeIn SummarizeOut
observationSummarizer =
  predict
    ( mkSignature
        "Condense the dataset notes below into a brief two-to-three sentence summary highlighting \
        \only the most important details. Write it in the `summary` field."
    )

-- | Sample up to @viewBatch@ rows, render them, observe trends, then condense into a
-- short summary. A single observation batch (DSPy's batched refinement loop is noted
-- as a future enhancement); the goal here is that the summary signal /reaches/ the
-- proposer.
datasetSummary ::
  (ToJSON i, ToJSON o, LLM :> es, Error ShikumiError :> es) =>
  -- | viewBatch: how many rows to sample
  Int ->
  Dataset i o ->
  Eff es Text
datasetSummary viewBatch ds = do
  let rendered = T.intercalate "\n" (map renderExampleRow (take (max 1 viewBatch) (datasetExamples ds)))
  DatasetDescribeOut obs <- runProgram datasetDescriber (DatasetDescribeIn rendered)
  SummarizeOut s <- runProgram observationSummarizer (SummarizeIn obs)
  pure s

-- ---------------------------------------------------------------------------
-- The module describer
-- ---------------------------------------------------------------------------

data ModuleDescribeIn = ModuleDescribeIn
  { programCode :: Text,
    programDescription :: Text,
    moduleSignature :: Text
  }
  deriving stock (Generic, Show)

instance FromModel ModuleDescribeIn

instance ToPrompt ModuleDescribeIn

newtype ModuleDescribeOut = ModuleDescribeOut {moduleDescription :: Text}
  deriving stock (Generic, Show)

instance ToSchema ModuleDescribeOut

instance FromModel ModuleDescribeOut

instance ToPrompt ModuleDescribeOut

instance Validatable ModuleDescribeOut

moduleDescriber :: Program ModuleDescribeIn ModuleDescribeOut
moduleDescriber =
  predict
    ( mkSignature
        "Below is pseudo-code for a language-model pipeline and a description of what it does. \
        \Describe the role of the one specified module within the broader program. Write it in \
        \the `moduleDescription` field."
    )
