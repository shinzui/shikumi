{-# LANGUAGE RankNTypes #-}

-- | The minimal retrieval interface and the one trivial implementation shikumi
-- ships. Production retrievers (vector stores, search services) are explicitly out
-- of scope for shikumi (MasterPlan "Out of scope"); this defines the /interface/ a
-- real one would later satisfy.
module Shikumi.Compile.Retriever
  ( Passage (..),
    Retriever (..),
    inMemoryRetriever,
  )
where

import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff)

-- | A unit of retrievable text.
data Passage = Passage
  { passageId :: !Text,
    passageText :: !Text
  }
  deriving stock (Eq, Show)

-- | Given a query, return relevant passages ranked best-first. Effect-polymorphic
-- (@forall es@) so the interface is honest about a /real/ retriever running under a
-- program's effect stack — though the trivial implementation below performs no
-- effect, and the RAG compiler runs retrieval purely at compile time (see
-- "Shikumi.Compile.RAG"). A real IO-backed retriever would define its own concrete
-- type with the effects it needs rather than satisfy this @forall es@ signature.
newtype Retriever = Retriever
  { retrieve :: forall es. Text -> Eff es [Passage]
  }

-- | A brute-force in-memory retriever: rank passages by the number of shared
-- (lowercased, whitespace-split) word tokens with the query, and return the top
-- @k@. Not production quality — no embeddings, no stemming, no scoring beyond raw
-- overlap — this is the documented placeholder.
inMemoryRetriever :: Int -> [Passage] -> Retriever
inMemoryRetriever k corpus = Retriever $ \query ->
  let qWords = tokens query
      score p = length (filter (`elem` qWords) (tokens (passageText p)))
   in pure (take k (sortOn (Down . score) corpus))
  where
    tokens = T.words . T.toLower
