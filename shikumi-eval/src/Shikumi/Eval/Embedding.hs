{-# LANGUAGE TypeApplications #-}

-- | A real embeddings interpreter for the existing 'Embedding' effect (EP-15).
--
-- 'Shikumi.Eval.Metric' ships only the pure 'Shikumi.Eval.Metric.runEmbedding'
-- (a @Text -> Vector Double@ table), so @semanticSimilarity@ has no way to call a
-- real backend. This module adds interpreters that drive the upstream
-- 'Baikai.Embedding' client (an OpenAI-compatible @\/v1\/embeddings@ endpoint),
-- so @semanticSimilarity@ runs end to end. The @Embedding@ effect itself is
-- unchanged (integration point #5); only new interpreters are added.
--
-- 'runEmbeddingBy' injects the effectful boundary (the same batching shape as
-- 'Baikai.Embedding.embed') so the production interpreter ('runEmbeddingWith') and
-- a hermetic stub share identical effect-handling, error-wrapping, and
-- vector-extraction logic — only the embedder differs. A transport failure becomes
-- a typed 'Shikumi.Error.ProviderFailure' (hence the @Error ShikumiError@ row),
-- and @IOE@ is introduced only here, at the bottom of the stack.
module Shikumi.Eval.Embedding
  ( runEmbeddingBy,
    runEmbeddingWith,
    runEmbeddingLLM,
  )
where

import Baikai.Embedding (EmbeddingModel, embed, openAIEmbeddingModel)
import Control.Exception (SomeException, displayException, try)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector (Vector)
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, throwError)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval.Metric (Embedding (..))

-- | Interpret 'Embedding' with an explicit batching embedder (the same shape as
-- 'Baikai.Embedding.embed'). The production interpreter fixes it to the baikai
-- client; a deterministic stub drives it in hermetic tests. A transport exception
-- is caught and rethrown as a typed 'ProviderFailure'.
runEmbeddingBy ::
  (IOE :> es, Error ShikumiError :> es) =>
  ([Text] -> IO (Vector (Vector Double))) ->
  Eff (Embedding : es) a ->
  Eff es a
runEmbeddingBy embedder = interpret $ \_ -> \case
  EmbedText t -> do
    r <- liftIO (try @SomeException (embedder [t]))
    case r of
      Left e -> throwError (ProviderFailure (T.pack (displayException e)))
      Right vs -> case V.toList vs of
        (v : _) -> pure v
        [] -> throwError (ProviderFailure "embedding backend returned no vector")

-- | Interpret 'Embedding' against a concrete embeddings backend.
runEmbeddingWith ::
  (IOE :> es, Error ShikumiError :> es) =>
  EmbeddingModel ->
  Eff (Embedding : es) a ->
  Eff es a
runEmbeddingWith m = runEmbeddingBy (embed m)

-- | Interpret 'Embedding' against OpenAI's @text-embedding-3-small@ (the default).
runEmbeddingLLM ::
  (IOE :> es, Error ShikumiError :> es) =>
  Eff (Embedding : es) a ->
  Eff es a
runEmbeddingLLM = runEmbeddingWith (openAIEmbeddingModel "text-embedding-3-small")
