{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | Metrics: functions that score how close a program's 'Prediction' is to the
-- expected output. There are two type aliases — a /pure/ 'Metric' and an
-- /effectful/ 'MetricM' (for metrics that must themselves call a model, e.g.
-- embedding similarity or an LLM judge) — with 'liftMetric' embedding the former
-- into the latter so @evaluate@ (defined over 'MetricM') covers both.
--
-- This module ships the pure, offline, deterministic built-ins ('exactMatch',
-- 'normalizedStringSimilarity', the 'customMetric' escape hatch), the combinators
-- ('weightedMean', 'threshold', 'invert'), and the two LM-backed metrics:
-- 'semanticSimilarity' (cosine of embedding vectors, over the 'Embedding' effect)
-- and 'modelJudge' (an LLM-as-grader that runs a tiny shikumi program returning a
-- numeric grade).
module Shikumi.Eval.Metric
  ( -- * Metric types
    Metric,
    MetricM,
    liftMetric,

    -- * Built-in pure metrics
    exactMatch,
    normalizedStringSimilarity,
    customMetric,

    -- * Combinators
    weightedMean,
    threshold,
    invert,

    -- * The embedding capability (for 'semanticSimilarity')
    Embedding (..),
    embedText,
    runEmbedding,

    -- * LM-backed metrics
    semanticSimilarity,
    modelJudge,
  )
where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector (Vector)
import Data.Vector qualified as V
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Error.Static (Error)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval.Types
  ( Prediction,
    Score,
    boolScore,
    mkScore,
    predictionPrimary,
    scoreZero,
    unScore,
  )
import Shikumi.LLM (LLM)
import Shikumi.Module (predict)
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)

-- | A pure metric: the expected output, then the program's prediction, yields a
-- score. Pure metrics are deterministic and offline — ideal for golden tests.
type Metric o = o -> Prediction o -> Score

-- | An effectful metric, for metrics that must call a model (embedding
-- similarity, LLM-as-judge). The effect row @es@ carries whatever capability the
-- metric needs (e.g. @LLM@ or an embedding effect).
type MetricM es o = o -> Prediction o -> Eff es Score

-- | Every pure metric is trivially an effectful one.
liftMetric :: Metric o -> MetricM es o
liftMetric m e p = pure (m e p)

-- | Exact equality of the expected output and the prediction's primary output.
exactMatch :: (Eq o) => Metric o
exactMatch e p = boolScore (e == predictionPrimary p)

-- | The custom-metric escape hatch. It is the identity at the type level; its
-- only purpose is to read intent at the call site (@customMetric $ \\e p -> ...@).
customMetric :: (o -> Prediction o -> Score) -> Metric o
customMetric = id

-- | A pure, offline text-similarity metric. The projection @proj@ points at the
-- text field to compare (so it works on any record), and the score blends a
-- token-set Jaccard similarity with a normalized character-level (Levenshtein)
-- similarity over case-folded, whitespace-collapsed text. Identical strings score
-- 1; disjoint strings score near 0.
normalizedStringSimilarity :: (o -> Text) -> Metric o
normalizedStringSimilarity proj e p =
  textSimilarity (proj e) (proj (predictionPrimary p))

-- | The similarity of two strings: the mean of token-set Jaccard and normalized
-- character-level similarity, both computed over normalized (case-folded,
-- whitespace-collapsed, trimmed) text.
textSimilarity :: Text -> Text -> Score
textSimilarity a0 b0 = mkScore ((jaccard + charSim) / 2)
  where
    a = normalize a0
    b = normalize b0
    toksA = Set.fromList (T.words a)
    toksB = Set.fromList (T.words b)
    union = Set.size (Set.union toksA toksB)
    inter = Set.size (Set.intersection toksA toksB)
    jaccard
      | union == 0 = 1 -- two empty strings are identical
      | otherwise = fromIntegral inter / fromIntegral union
    maxLen = max (T.length a) (T.length b)
    charSim
      | maxLen == 0 = 1
      | otherwise = 1 - fromIntegral (levenshtein a b) / fromIntegral maxLen

-- | Case-fold, collapse runs of whitespace to single spaces, and trim.
normalize :: Text -> Text
normalize = T.unwords . T.words . T.toCaseFold

-- | The Levenshtein edit distance between two strings (the canonical single-row
-- dynamic program, folded over the characters of @t@). Self-contained — no extra
-- dependency.
levenshtein :: Text -> Text -> Int
levenshtein s t = lastElem (foldl transform [0 .. length a] b)
  where
    a = T.unpack s
    b = T.unpack t
    -- Given the previous DP row and the next character of @t@, compute the next
    -- row. @diag@/@up@ are the previous row's cells to the upper-left and above
    -- the cell being filled; @left@ is the cell just produced.
    transform prevRow charB = case prevRow of
      (p0 : rest) -> scanl fill (p0 + 1) (zip3 a prevRow rest)
      [] -> [] -- unreachable: the row always has length (length a + 1) >= 1
      where
        fill left (charA, diag, up) =
          minimum [left + 1, up + 1, diag + (if charA == charB then 0 else 1)]
    -- The last cell of the final row (0 for an empty row, which cannot occur).
    lastElem = foldl (\_ x -> x) 0

-- | Combine several metrics by a weighted average of their scores. An empty list
-- yields the constant zero metric.
weightedMean :: [(Double, Metric o)] -> Metric o
weightedMean [] = \_ _ -> mkScore 0
weightedMean ws = \e p ->
  let totalW = sum (map fst ws)
      weighted = sum [w * unScore (m e p) | (w, m) <- ws]
   in if totalW == 0 then mkScore 0 else mkScore (weighted / totalW)

-- | Turn a graded metric into pass/fail: score 1 when @m@ meets the threshold,
-- else 0.
threshold :: Double -> Metric o -> Metric o
threshold t m = \e p -> boolScore (unScore (m e p) >= t)

-- | Invert a metric (@1 - s@), useful for "lower is better" wrapped metrics.
invert :: Metric o -> Metric o
invert m = \e p -> mkScore (1 - unScore (m e p))

-- ---------------------------------------------------------------------------
-- The embedding capability
-- ---------------------------------------------------------------------------

-- | A minimal embedding effect: turn text into a dense vector. EP-1's @LLM@
-- effect exposes no embedding operation, so 'semanticSimilarity' is expressed
-- over this capability; its interpreter is supplied by the caller (a real
-- embedding backend, or 'runEmbedding' over a pure function for tests).
data Embedding :: Effect where
  EmbedText :: Text -> Embedding m (Vector Double)

type instance DispatchOf Embedding = 'Dynamic

-- | Embed a piece of text.
embedText :: (Embedding :> es) => Text -> Eff es (Vector Double)
embedText t = send (EmbedText t)

-- | Interpret 'Embedding' with a pure function (deterministic; good for tests and
-- for backends that precompute embeddings).
runEmbedding :: (Text -> Vector Double) -> Eff (Embedding : es) a -> Eff es a
runEmbedding f = interpret $ \_ -> \case
  EmbedText t -> pure (f t)

-- | Embedding-based semantic similarity: the cosine similarity of the embeddings
-- of the projected expected and predicted text, mapped from @[-1, 1]@ into
-- @[0, 1]@. A zero-norm vector yields 'scoreZero' (no signal).
semanticSimilarity :: (Embedding :> es) => (o -> Text) -> MetricM es o
semanticSimilarity proj expd predd = do
  a <- embedText (proj expd)
  b <- embedText (proj (predictionPrimary predd))
  pure (cosineScore a b)

-- | Map the cosine similarity of two vectors into a 'Score'.
cosineScore :: Vector Double -> Vector Double -> Score
cosineScore a b
  | na == 0 || nb == 0 = scoreZero
  | otherwise = mkScore ((dot / (na * nb) + 1) / 2)
  where
    dot = V.sum (V.zipWith (*) a b)
    na = sqrt (V.sum (V.map (\x -> x * x) a))
    nb = sqrt (V.sum (V.map (\x -> x * x) b))

-- ---------------------------------------------------------------------------
-- LLM-as-judge
-- ---------------------------------------------------------------------------

-- | The judge's input: the grading rubric plus the reference and candidate texts
-- (plain fields so the rendered prompt stays clean).
data JudgeInput = JudgeInput
  { rubric :: !Text,
    reference :: !Text,
    candidate :: !Text
  }
  deriving stock (Generic, Show)

instance FromModel JudgeInput

instance ToPrompt JudgeInput

-- | The judge's output: a single numeric grade, intended to be in @[0, 1]@
-- (clamped by 'mkScore' regardless).
newtype Grade = Grade {grade :: Double}
  deriving stock (Generic, Show)

instance ToSchema Grade

instance FromModel Grade

instance ToPrompt Grade

instance Validatable Grade

-- | The judge program: a single structured-output predictor that returns a
-- 'Grade'. The @rubricText@ becomes the signature instruction.
judgeProgram :: Text -> Program JudgeInput Grade
judgeProgram rubricText = predict (judgeSig rubricText)

judgeSig :: Text -> Signature JudgeInput Grade
judgeSig rubricText =
  mkSignature $
    rubricText
      <> " Compare the candidate answer to the reference answer and return a single field"
      <> " `grade`: a number in [0,1] where 1 means the candidate fully matches the"
      <> " reference and 0 means it is entirely wrong."

-- | LLM-as-judge: ask a model to grade the prediction against the expected
-- output. The rubric is supplied as text; the model returns a numeric grade,
-- decoded through the structured-output path. A decode failure surfaces as a
-- 'ShikumiError' (the per-example boundary in @evaluate@ turns it into a
-- 'Shikumi.Eval.Report.MetricError'). Threads @Error ShikumiError@ because
-- 'runProgram' does (EP-4): decode failures throw typed errors.
modelJudge ::
  (LLM :> es, Error ShikumiError :> es) =>
  -- | rubric / grading instruction
  Text ->
  -- | render an output as text for the judge to read
  (o -> Text) ->
  MetricM es o
modelJudge rubricText render expd predd = do
  let inp = JudgeInput rubricText (render expd) (render (predictionPrimary predd))
  Grade g <- runProgram (judgeProgram rubricText) inp
  pure (mkScore g)
