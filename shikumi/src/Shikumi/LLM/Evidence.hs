-- | Acknowledged, provider-built evidence for actual transport attempts.
module Shikumi.LLM.Evidence
  ( AttemptReceipt (..),
    EvidenceObserver,
    EvidenceObserverFailed (..),
  )
where

import Baikai.Evidence (ModelCallEvidence)
import Control.Exception (Exception)
import Data.Text (Text)
import Effectful (Eff)
import GHC.Generics (Generic)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM.Observation (CallKind)

-- | The original provider record, delivered before retry, error propagation or
-- successful return. No record is fabricated for cancellation. Installing an
-- observer does not request evidence: use request options or scoped defaults.
-- Best-effort requests may produce no record; Baikai enforces required evidence.
--
-- There are deliberately no JSON instances. Provider error messages inside
-- 'ModelCallEvidence' can include provider response text; applications must choose
-- what is appropriate to persist rather than serializing this envelope blindly.
data AttemptReceipt = AttemptReceipt
  { -- | Process-local identity, shared with billing observations across retries.
    -- Persist the enclosed evidence's callId as the durable attempt identity.
    logicalCallId :: !Text,
    -- | One-based attempt ordinal, shared with billing observations.
    attemptOrdinal :: !Int,
    callKind :: !CallKind,
    -- | The exact record built by Baikai, including its own per-attempt callId.
    evidence :: !ModelCallEvidence
  }
  deriving stock (Eq, Show, Generic)

-- | Normal return acknowledges the record. Runs after budget charging and billing
-- observation. Must be safe for concurrent use: concurrent programs invoke it on
-- worker threads, and worker-local State changes do not reach the parent.
-- Install the observer's effects outside the LLM interpreter.
type EvidenceObserver es = AttemptReceipt -> Eff es ()

-- | Typed observer failures become exceptions so transport retries and Program
-- Retry nodes cannot turn a persistence failure into another provider invocation.
-- Other exceptions, including cancellation, propagate unchanged.
newtype EvidenceObserverFailed = EvidenceObserverFailed ShikumiError
  deriving stock (Show)
  deriving anyclass (Exception)
