-- | Metrics: functions that score how close a program's 'Prediction' is to the
-- expected output. There are two type aliases — a /pure/ 'Metric' and an
-- /effectful/ 'MetricM' (for metrics that must themselves call a model, e.g.
-- embedding similarity or an LLM judge) — with 'liftMetric' embedding the former
-- into the latter so @evaluate@ (defined over 'MetricM') covers both.
--
-- This module ships the pure, offline, deterministic built-ins ('exactMatch',
-- 'normalizedStringSimilarity', the 'customMetric' escape hatch) and the
-- combinators ('weightedMean', 'threshold', 'invert'). The LM-backed metrics
-- ('Shikumi.Eval.Metric.semanticSimilarity' / @modelJudge@) live alongside these
-- once the LM milestone lands.
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
  )
where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff)
import Shikumi.Eval.Types
  ( Prediction,
    Score,
    boolScore,
    mkScore,
    predictionPrimary,
    unScore,
  )

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
levenshtein s t = last (foldl transform [0 .. length a] b)
  where
    a = T.unpack s
    b = T.unpack t
    -- Given the previous DP row and the next character of @t@, compute the next
    -- row. @diag@/@up@ are the previous row's cells to the upper-left and above
    -- the cell being filled; @left@ is the cell just produced.
    transform prevRow charB =
      scanl fill (head prevRow + 1) (zip3 a prevRow (tail prevRow))
      where
        fill left (charA, diag, up) =
          minimum [left + 1, up + 1, diag + (if charA == charB then 0 else 1)]

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
