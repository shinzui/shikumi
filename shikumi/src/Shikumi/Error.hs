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

import Baikai.Error (BaikaiError (..), ErrorCategory (..))
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
  | -- | the prompt exceeded the model's context window
    ContextWindowExceeded !Text
  | -- | the call exceeded its time budget
    Timeout !Text
  | -- | the running cost ceiling was reached; the call was refused
    BudgetExceeded !Text
  | -- | generated code failed after exhausting correction attempts
    CodeExecFailed !Text
  deriving stock (Eq, Show)

-- | Total mapping from baikai's transport-level errors into shikumi's
-- vocabulary. Invalid requests map to 'SchemaMismatch' because in baikai a
-- malformed request is almost always bad schema/parameters; decode failures
-- map to 'InvalidJSON' because baikai's decode failures are JSON parse
-- failures of the provider response.
fromBaikaiError :: BaikaiError -> ShikumiError
fromBaikaiError e = case category e of
  DecodeFailure -> InvalidJSON (message e)
  InvalidRequest -> SchemaMismatch ("invalid request: " <> message e)
  ContextOverflow -> ContextWindowExceeded (message e)
  ProcessFailure ->
    ProviderFailure $
      case exitCode e of
        Just n -> "process exited " <> T.pack (show n) <> ": " <> message e
        Nothing -> message e
  _ -> ProviderFailure (message e)

-- | Which errors are worth retrying. Provider/transport failures and timeouts are
-- transient; decode, schema, validation, budget, and code-execution failures are
-- deterministic and retrying cannot fix them. Centralizing the policy here keeps
-- it auditable (the resilience interpreter in "Shikumi.LLM" consults exactly this
-- predicate).
isTransient :: ShikumiError -> Bool
isTransient = \case
  ProviderFailure {} -> True
  Timeout {} -> True
  _ -> False
