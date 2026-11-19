-- | Holdout exposure: how many times a protected holdout has already been used to
-- judge a candidate.
--
-- Shikumi is a library with no durable store, so the count is input data that the
-- trusted caller supplies with each job, and the lifecycle owner keeps the
-- durable counter. t'ExposureLedger' is a small pure helper for callers and tests
-- that keep the counter themselves; this package never reads or writes it.
module Shikumi.Evidence.Exposure
  ( HoldoutExposure (..),
    ExposureOverride (..),
    noPriorExposure,
    exposureExhausted,
    ExposureLedger,
    emptyLedger,
    recordExposure,
    priorExposures,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Shikumi.Evidence.Digest (Digest)

-- | Who allowed a holdout to be used past its exposure limit, why and when.
data ExposureOverride = ExposureOverride
  { approvedBy :: !Text,
    reason :: !Text,
    approvedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The exposures this holdout has had before the current job, and any override.
-- A replay of an earlier job passes that job's original count.
data HoldoutExposure = HoldoutExposure
  { prior :: !Int,
    override :: !(Maybe ExposureOverride)
  }
  deriving stock (Eq, Show, Generic)

-- | A holdout that has never been used.
noPriorExposure :: HoldoutExposure
noPriorExposure = HoldoutExposure 0 Nothing

-- | Whether a holdout with this limit may not be used again.
exposureExhausted :: Int -> HoldoutExposure -> Bool
exposureExhausted limit e = e.prior >= limit && e.override == Nothing

-- | The reports that consumed an exposure, per dataset digest.
newtype ExposureLedger = ExposureLedger (Map Digest [Digest])
  deriving stock (Eq, Show)

-- | A ledger encodes as an array of @[datasetDigest, [reportDigest]]@ pairs.
instance ToJSON ExposureLedger where
  toJSON (ExposureLedger m) = toJSON (Map.toAscList m)

instance FromJSON ExposureLedger where
  parseJSON v = ExposureLedger . Map.fromList <$> parseJSON v

-- | A ledger with no exposures.
emptyLedger :: ExposureLedger
emptyLedger = ExposureLedger Map.empty

-- | Record that a report consumed an exposure of a dataset's holdout. Recording
-- the same report twice changes nothing.
recordExposure :: Digest -> Digest -> ExposureLedger -> ExposureLedger
recordExposure ds report (ExposureLedger m) = ExposureLedger (Map.alter add ds m)
  where
    add Nothing = Just [report]
    add (Just rs)
      | report `elem` rs = Just rs
      | otherwise = Just (rs ++ [report])

-- | How many exposures a dataset's holdout has had.
priorExposures :: Digest -> ExposureLedger -> Int
priorExposures ds (ExposureLedger m) = maybe 0 length (Map.lookup ds m)
