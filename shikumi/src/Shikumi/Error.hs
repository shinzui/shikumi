-- | The single error vocabulary the whole shikumi framework shares, plus a total
-- mapping from baikai's transport-level errors into it.
--
-- This module owns part of the MasterPlan's integration point #1: every later
-- ExecPlan (signatures, caching, tracing, tools) MUST surface failures through
-- 'ShikumiError' rather than inventing its own error type.
module Shikumi.Error
  ( ShikumiError (..),
    fromBaikaiError,
    isTransient,
  )
where

import Baikai.Error (BaikaiError (..))
import Data.Text (Text)
import Data.Text qualified as T

-- | The enumerated failure modes named by integration point #1. The decode /
-- schema / validation constructors are produced by higher layers (structured
-- output, program validation); the transport ones are produced here by
-- 'fromBaikaiError'.
data ShikumiError
  = -- | provider returned text that is not valid JSON
    InvalidJSON !Text
  | -- | a required output field was absent (field name)
    MissingField !Text
  | -- | decoded JSON did not match the expected schema
    SchemaMismatch !Text
  | -- | a typed value failed a user/program validation rule
    ValidationFailure !Text
  | -- | the provider/transport failed (mapped from baikai)
    ProviderFailure !Text
  | -- | the call exceeded its time budget
    Timeout !Text
  | -- | the running cost ceiling was reached; the call was refused
    BudgetExceeded !Text
  deriving stock (Eq, Show)

-- | Total mapping from baikai's transport-level errors into shikumi's
-- vocabulary. baikai's constructors are 'ProviderError', 'RequestInvalid',
-- 'DecodeError', and 'ProcessError'.
--
-- 'RequestInvalid' maps to 'SchemaMismatch' because in baikai a malformed request
-- is almost always bad schema/parameters; 'DecodeError' maps to 'InvalidJSON'
-- because baikai's decode failures are JSON parse failures of the provider
-- response. These two judgments are the only non-mechanical choices.
fromBaikaiError :: BaikaiError -> ShikumiError
fromBaikaiError = \case
  ProviderError t -> ProviderFailure t
  RequestInvalid t -> SchemaMismatch ("invalid request: " <> t)
  DecodeError t -> InvalidJSON t
  ProcessError n t -> ProviderFailure ("process exited " <> T.pack (show n) <> ": " <> t)

-- | Which errors are worth retrying. Provider/transport failures and timeouts are
-- transient; decode, schema, validation, and budget errors are deterministic and
-- retrying cannot fix them. Centralizing the policy here keeps it auditable
-- (the resilience interpreter in "Shikumi.LLM" consults exactly this predicate).
isTransient :: ShikumiError -> Bool
isTransient = \case
  ProviderFailure {} -> True
  Timeout {} -> True
  _ -> False
