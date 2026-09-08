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
    renderShikumiError,
  )
where

import Baikai.Error (BaikaiError (..), ErrorCategory (..), isRetryable)
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
  | -- | Legacy unclassified failure supplied by callers or scripted interpreters.
    ProviderFailure !Text
  | -- | Structured transport failure, including verbatim refusal metadata.
    ProviderError !BaikaiError
  | -- | the prompt exceeded the model's context window
    ContextWindowExceeded !Text
  | -- | the call exceeded its time budget
    Timeout !Text
  | -- | a configured resource allowance was exhausted (cost, calls or session size)
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
  _ -> ProviderError e

-- | Human-readable detail without dumping the transport record. Baikai's
-- message is its safe-to-log description; opaque request/response data is absent.
renderShikumiError :: ShikumiError -> Text
renderShikumiError = \case
  ProviderError e ->
    "provider "
      <> T.pack (show (category e))
      <> maybe "" (\n -> " (exit " <> T.pack (show n) <> ")") (exitCode e)
      <> ": "
      <> message e
  InvalidJSON t -> t
  MissingField t -> "missing field " <> t
  SchemaMismatch t -> t
  ValidationFailure t -> t
  ProviderFailure t -> t
  ContextWindowExceeded t -> t
  Timeout t -> t
  BudgetExceeded t -> t
  CodeExecFailed t -> t

-- | Retry only typed rate limits and transient failures, using Baikai's
-- classification. Legacy text failures and timeouts retain their retry policy.
-- Unknown/process errors and refusals are terminal; never infer from prose.
isTransient :: ShikumiError -> Bool
isTransient = \case
  ProviderError e -> isRetryable e
  ProviderFailure {} -> True
  Timeout {} -> True
  _ -> False
