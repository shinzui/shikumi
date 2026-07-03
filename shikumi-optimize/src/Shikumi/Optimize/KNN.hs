-- | KNN few-shot demo selection (EP-23): pick, for each input, the training
-- examples whose inputs are most /semantically similar/ to it, and show those as the
-- demos. Two forms:
--
--   * 'knnFewShot' — the faithful run-time form: a single 'Embed' node that, per
--     input, embeds the input, ranks the training examples by cosine similarity, and
--     runs the student under the @k@ nearest as demos. Demos depend on the input.
--   * 'knnFewShotCentroid' — a compile-time fallback that bakes the @k@ examples
--     nearest the training centroid as a fixed demo set (a plain @Params@ artifact),
--     for callers who cannot run an embedder at execution time.
--
-- The embedder is injected as a /pure/ closure @Text -> Vector Double@ (the shape of
-- EP-15's pure @runEmbedding@ argument), not the @Embedding@ effect: an 'Embed'
-- body's row is fixed to @(LLM, Error ShikumiError)@, so it cannot call @embedText@;
-- all embedding-effect work happens at the caller, outside the node. The run-time
-- form carries no @Params@ (it serializes as the empty vector, exactly like @react@).
module Shikumi.Optimize.KNN
  ( -- * Run-time form (the faithful analog)
    knnFewShot,
    knnDemos,

    -- * Compile-time fallback
    knnFewShotCentroid,

    -- * Pure helpers (exposed so callers/tests can reproduce the ranking)
    cosine,
    nearestDemos,
    centroid,
  )
where

import Data.Aeson (ToJSON, toJSON)
import Data.List (sortBy)
import Data.Ord (Down (..), comparing)
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Shikumi.Adapter (ToPrompt, toPrompt)
import Shikumi.Eval (Dataset, Example (..), datasetExamples)
import Shikumi.Optimize.LabeledFewShot (withDemos)
import Shikumi.Optimize.Search (freezeProgram)
import Shikumi.Optimize.Types (Optimizer (..))
import Shikumi.Program (Demo (..), Program, embed, runProgram)

-- | Cosine similarity of two vectors: @dot a b / (‖a‖·‖b‖)@, in @[-1, 1]@. A
-- zero-norm vector yields @0@ (no signal). Ranking by cosine puts the most similar
-- examples first.
cosine :: Vector Double -> Vector Double -> Double
cosine a b
  | na == 0 || nb == 0 = 0
  | otherwise = dot a b / (na * nb)
  where
    dot x y = V.sum (V.zipWith (*) x y)
    na = sqrt (dot a a)
    nb = sqrt (dot b b)

-- | The @k@ training examples whose input embeddings are nearest a query vector,
-- nearest first, as JSON demos. Ties break by original order (a stable sort).
nearestDemosByVec ::
  (ToJSON i, ToJSON o, ToPrompt i) =>
  (Text -> Vector Double) ->
  Int ->
  [Example i o] ->
  Vector Double ->
  [Demo]
nearestDemosByVec embedder k exs qv =
  [Demo (toJSON i) (toJSON o) | (_, _, Example i o) <- take (max 0 k) sorted]
  where
    scored = [(cosine (embedder (toPrompt i)) qv, idx, ex) | (idx, ex@(Example i _)) <- zip [0 :: Int ..] exs]
    sorted = sortBy (comparing (\(s, idx, _) -> (Down s, idx))) scored

-- | The @k@ training examples nearest a rendered query input, nearest first.
nearestDemos ::
  (ToJSON i, ToJSON o, ToPrompt i) =>
  (Text -> Vector Double) ->
  Int ->
  [Example i o] ->
  Text ->
  [Demo]
nearestDemos embedder k exs query = nearestDemosByVec embedder k exs (embedder query)

-- | The component-wise mean of a list of equal-length vectors (empty list → empty
-- vector).
centroid :: [Vector Double] -> Vector Double
centroid [] = V.empty
centroid vs = V.map (/ fromIntegral (length vs)) (foldl1 (V.zipWith (+)) vs)

-- | The run-time KNN node: for each input, attach the @k@ nearest training examples
-- as demos and run the student under them. A plain @Program i o@ (an 'Embed' node)
-- usable anywhere a Program is; it carries no @Params@ (like @react@).
knnDemos ::
  (ToJSON i, ToJSON o, ToPrompt i) =>
  (Text -> Vector Double) ->
  Int ->
  Dataset i o ->
  Program i o ->
  Program i o
knnDemos embedder k train student =
  let exs = datasetExamples train
   in embed $ \i -> runProgram (withDemos (nearestDemos embedder k exs (toPrompt i)) student) i

-- | Run-time KNN as an 'Optimizer': selection is by embedding geometry, not by
-- score, so it consults neither the metric nor the LM at optimize time and spends
-- zero optimizer LM calls.
knnFewShot ::
  (ToJSON i, ToJSON o, ToPrompt i) =>
  (Text -> Vector Double) ->
  Int ->
  Optimizer i o
knnFewShot embedder k = Optimizer $ \train _metric student ->
  pure (freezeProgram (knnDemos embedder k train student))

-- | Compile-time fallback: bake the @k@ training examples nearest the training
-- centroid as a fixed demo set on every node, and freeze. A plain @Params@ artifact,
-- no run-time embedder needed, and zero optimizer LM calls are spent.
knnFewShotCentroid ::
  (ToJSON i, ToJSON o, ToPrompt i) =>
  (Text -> Vector Double) ->
  Int ->
  Optimizer i o
knnFewShotCentroid embedder k = Optimizer $ \train _metric student ->
  let exs = datasetExamples train
      c = centroid [embedder (toPrompt i) | Example i _ <- exs]
      ds = nearestDemosByVec embedder k exs c
   in pure (freezeProgram (withDemos ds student))
