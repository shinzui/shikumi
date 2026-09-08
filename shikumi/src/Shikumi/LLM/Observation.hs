-- | Run-local transport billing. Observations contain identity and accounting,
-- never prompts, outputs, credentials, or provider error messages. Observer IO
-- exceptions propagate outside provider retry classification. Cancellation emits
-- no synthetic terminal. Create a separate collector for each run.
module Shikumi.LLM.Observation
  ( LLMObservation (..),
    CallKind (..),
    LLMObserver,
    noObservation,
    BillingSummary (..),
    emptyBillingSummary,
    newBillingCollector,
    newBillingCollectorWithLimit,
    renderBillingSummary,
    usageUnknown,
    observedModelOf,
    errorClass,
    UsageRecord (..),
  )
where

import Baikai.Cost qualified as C
import Baikai.Error qualified as BE
import Baikai.Evidence qualified as E
import Baikai.Usage qualified as U
import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Shikumi.Error (ShikumiError (..))

-- | A local wrapper avoids adding competing orphan decoders. The exact rational
-- cost is encoded separately from the canonical provider usage JSON.
newtype UsageRecord = UsageRecord {getUsage :: U.Usage}
  deriving stock (Eq, Show)

instance ToJSON UsageRecord where
  toJSON (UsageRecord u) = object ["usage" .= u, "exactCost" .= exactCost (U.cost u)]
    where
      exactCost c = let b = C.breakdown c in [C.usd c, C.inputUsd b, C.outputUsd b, C.cachedInputUsd b, C.cachedWriteUsd b]

instance FromJSON UsageRecord where
  parseJSON = withObject "UsageRecord" $ \o -> do
    v <- o .: "usage"
    ns <- o .: "exactCost" :: Parser [Rational]
    c <- case ns of
      [a, b, c, d, e] -> pure (C.Cost a (C.CostBreakdown b c d e) mempty)
      _ -> fail "exactCost must contain five rational amounts"
    withObject
      "Usage"
      ( \u -> do
          cv <- u .: "cost"
          basis <- withObject "Cost" (\x -> x .:? "basis" .!= mempty) cv
          UsageRecord
            <$> ( U.Usage
                    <$> u .: "input_tokens"
                    <*> u .: "output_tokens"
                    <*> u .: "cache_read_tokens"
                    <*> u .: "cache_write_tokens"
                    <*> u .:? "reasoning_tokens"
                    <*> u .: "total_tokens"
                    <*> u .:? "availability"
                    <*> pure c {C.basis = basis}
                )
      )
      v

data CallKind = CompletionCall | StreamCall
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | callId identifies a logical invocation within this process; attempt is
-- one-based within it. No structural node attribution is implied.
data LLMObservation = LLMObservation
  { callId :: !Text,
    attempt :: !Int,
    callKind :: !CallKind,
    requestedModel :: !Text,
    requestedProvider :: !Text,
    observedModel :: !(Maybe Text),
    terminalError :: !(Maybe Text),
    usage :: !(Maybe UsageRecord),
    startedAt :: !UTCTime,
    endedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

type LLMObserver = LLMObservation -> IO ()

noObservation :: LLMObserver
noObservation _ = pure ()

observedModelOf :: Maybe E.ModelCallEvidence -> Maybe Text
observedModelOf e = e >>= E.observedValue . E.observedModel

-- | Stable classification only: raw messages can include provider output.
errorClass :: ShikumiError -> Text
errorClass = \case
  ProviderError e -> T.pack (show (BE.category e))
  ProviderFailure _ -> "ProviderFailure"
  InvalidJSON _ -> "InvalidJSON"
  MissingField _ -> "MissingField"
  SchemaMismatch _ -> "SchemaMismatch"
  ValidationFailure _ -> "ValidationFailure"
  ContextWindowExceeded _ -> "ContextWindowExceeded"
  Timeout _ -> "Timeout"
  BudgetExceeded _ -> "BudgetExceeded"
  CodeExecFailed _ -> "CodeExecFailed"

-- | Unknown includes absent/legacy quality metadata and partially missing or
-- inconsistent counters. Available numeric components still contribute to sums.
usageUnknown :: Maybe UsageRecord -> Bool
usageUnknown Nothing = True
usageUnknown (Just (UsageRecord u)) = case U.availability u of
  Nothing -> True
  Just a -> not (Set.null (U.missingCategories a)) || U.inconsistent a

data BillingSummary = BillingSummary
  { completedAttempts :: !Int,
    failedAttempts :: !Int,
    unknownUsageAttempts :: !Int,
    observedUsage :: !UsageRecord,
    retainedAttempts :: ![LLMObservation],
    detailTruncated :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

emptyBillingSummary :: BillingSummary
emptyBillingSummary = BillingSummary 0 0 0 (UsageRecord mempty) [] False

-- | Aggregate only by default. Opt in to bounded detail with the other constructor.
newBillingCollector :: IO (LLMObserver, IO BillingSummary)
newBillingCollector = newBillingCollectorWithLimit 0

-- | Negative limits are treated as zero. Counts and sums continue after the
-- detail limit, using an atomic strict update safe for concurrent evaluations.
newBillingCollectorWithLimit :: Int -> IO (LLMObserver, IO BillingSummary)
newBillingCollectorWithLimit limit = do
  ref <- newIORef emptyBillingSummary
  let observe o = atomicModifyIORef' ref $ \s ->
        let n = completedAttempts s + failedAttempts s
            ok = isNothing (terminalError o)
            u = maybe mempty getUsage (usage o)
            totalUsage = getUsage (observedUsage s) <> u
            next =
              BillingSummary
                (completedAttempts s + if ok then 1 else 0)
                (failedAttempts s + if ok then 0 else 1)
                (unknownUsageAttempts s + if usageUnknown (usage o) then 1 else 0)
                (UsageRecord totalUsage)
                (if n < max 0 limit then o : retainedAttempts s else retainedAttempts s)
                (detailTruncated s || n >= max 0 limit)
         in next `seq` (next, ())
  pure (observe, (\s -> s {retainedAttempts = reverse (retainedAttempts s)}) <$> readIORef ref)

renderBillingSummary :: BillingSummary -> Text
renderBillingSummary s =
  "transport billing: completed="
    <> t (completedAttempts s)
    <> " failed="
    <> t (failedAttempts s)
    <> " unknown-usage="
    <> t (unknownUsageAttempts s)
    <> " observed-usd="
    <> t (C.usd (U.cost (getUsage (observedUsage s))))
    <> " detail-truncated="
    <> t (detailTruncated s)
    <> "\ntransport quality: "
    <> TE.decodeUtf8 (BL.toStrict (encode (observedUsage s)))
  where
    t :: (Show a) => a -> Text; t = T.pack . show
