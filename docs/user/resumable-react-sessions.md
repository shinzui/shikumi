# Resumable ReAct sessions

Use the session API when an agent must pause after tools, save its conversation,
and accept another user turn. The legacy `react` and `reactWithTrajectory` APIs
remain ordinary `Program` constructors; they retain their separate extraction call:

```haskell
legacy = react signature registry defaultReActConfig
-- runProgram legacy input runs proposals followed by typed answer extraction.
```

`startSession` builds a validated checkpoint without calling the model.
`advanceSession` completes at most one assistant exchange and returns
`SessionPaused checkpoint` or `SessionFinished answer checkpoint`.
`continueSession` validates compatibility and appends new input without calling the
model or tools. `runSession` advances until final submission or `maxIters`.
These functions can be composed inside `embed` when a `Program` is needed.

## Complete offline example

This example is also compiled and run as
[ReActSessionExample.hs](../../shikumi-tools/test/ReActSessionExample.hs) by the
package test suite. It runs one lookup, encodes and decodes the checkpoint bytes,
appends a follow-up question, and obtains a typed answer. The scripted interpreter
fails on any unexpected extra model call, so extraction would fail the example.
Run it from the repository root with:

```bash
nix develop .#ghc9124 -c cabal test shikumi-tools --test-options='-p "documented continuation example"'
```

The test expects `Right ("Paris, France", 2)`: the answer and two cumulative
assistant exchanges. A production caller can save `bytes` to its own storage and
supply the same tool registry bodies after decoding.

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Offline example compiled and executed by the shikumi-tools test suite.
module ReActSessionExample (main, example) where

import Baikai qualified as B
import Control.Lens ((&), (.~))
import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Agent.History (decodeSession, encodeSession, sessionTurns)
import Shikumi.Agent.ReAct
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM.Continuation (validateRequestContinuation)
import Shikumi.LLM (LLM (..))
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Tool (mkDynTool, mkRegistry)
import Shikumi.Tool.Output (textToolOutput)

newtype Question = Question {question :: Text}
  deriving stock (Generic)
  deriving anyclass (ToPrompt)

newtype Answer = Answer {answer :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

instance Validatable Answer

signature :: Signature Question Answer
signature = mkSignature "Use the lookup tool and answer the question."

-- | Returns the typed answer and cumulative assistant exchange count.
example :: IO (Either ShikumiError (Text, Int))
example = do
  let registry = mkRegistry [mkDynTool "lookup" "Return the stored city." (object []) (\_ -> pure (Right (textToolOutput "Paris")))]
      cfg = defaultReActConfig {protocol = ProtocolNative}
      model = B.mkModel (B.Custom "session-example") "example" "https://example.invalid"
      response callId name args = B.emptyResponse & #model .~ model & #message . #content .~ V.singleton (B.AssistantToolCall (B.ToolCall callId name args))
      script = [response "call-A" "lookup" (object []), response "final-A" finalToolName (object ["answer" .= ("Paris, France" :: Text)])]
  replies <- newIORef script
  runEff
    . runErrorNoCallStack
    . interpret
      ( \_ -> \case
          Complete m ctx opts -> do
            either throwError pure (validateRequestContinuation m ctx opts)
            next <-
              liftIO
                ( atomicModifyIORef'
                    replies
                    ( \xs -> case xs of
                        [] -> ([], Nothing)
                        x : rest -> (rest, Just x)
                    )
                )
            maybe (throwError (ProviderFailure "Unexpected extra model call")) pure next
          Stream {} -> pure []
      )
    $ do
      initial <- startSessionWithModel model signature registry cfg (Question "Which city is stored?")
      first <- advanceSession signature registry cfg initial
      checkpoint <- case first of
        SessionPaused s -> pure s
        _ -> throwError (ValidationFailure "Expected a checkpoint")
      -- Write these bytes to caller-owned storage if persistence is needed.
      let bytes = encode (encodeSession checkpoint)
          decoded = eitherDecode bytes >>= either (Left . show) Right . decodeSession
      saved <- either (throwError . ValidationFailure . T.pack) pure decoded
      resumed <- continueSession signature registry cfg (Question "Include the country too.") saved
      finished <- runSession signature registry cfg resumed
      case finished of
        SessionFinished (Answer text) s -> pure (text, sessionTurns s)
        SessionPaused _ -> throwError (ValidationFailure "Iteration budget exhausted")

main :: IO ()
main = example >>= print
```

## Protocols, validation, and call accounting

Set `protocol = ProtocolNative` to use native assistant and tool-result messages.
`ProtocolAuto` uses the same conservative empty-model resolution as legacy ReAct;
currently this selects the prompt fallback. Native requests preserve the exact
assistant payload, original IDs, thinking signatures, and ordered tool results.

The reserved tool `shikumi_submit_final` receives arguments matching the output
record's `ToSchema`. `FromModel` and `Validatable` must both accept the arguments.
A valid submission returns immediately with no extraction call. A final mixed
with other calls, empty/duplicate IDs, or cut-off arguments rejects the entire
proposal before any tool runs. The original response remains in `auditHistory`;
`promptMessages` instead contains a corrective user message. Ordinary tool errors
produce error-flagged tool results. Infrastructure exceptions propagate.

Prompt sessions request this JSON grammar (including for final submission):

```json
{"calls":[{"tool":"shikumi_submit_final","args":{"answer":"Paris, France"}}]}
```

Prompt actions receive session-local IDs `prompt-<cumulative turn>-<action index>`.
They are stored for validation and audit; prompt requests use textual observations.
Native IDs are never manufactured. The final name must not appear in the registry.

Without compaction or retries, each advance uses one proposal call. Tools can make
their own nested model calls. Each summary adds one model call; context-window
recovery retries the proposal at most once. `maxIters` limits assistant exchanges
per user turn; exhaustion returns a paused checkpoint without extracting a guess.
Continuation resets that limit. Advancing a finished session requires a new user
turn first. `sessionTurns` counts all exchanges, including rejected proposals.

## Rich output and persistence

`mkDynTool` takes a runtime name, description, input schema, and effectful body
returning `Either ToolError ToolOutput`. The body is responsible for validating
its runtime arguments. `ToolOutput` retains `result` (native blocks and error flag),
`structuredContent`, and raw `extensionBlocks`. `runToolCallOutput` preserves these
fields; `runToolCall` projects to text for legacy callers. Structured JSON and
extension blocks become explicitly labeled text blocks in model messages.
Error flags become explicit `Tool error:` labels in text projections.
Images remain native image blocks; text projection includes labeled image JSON.
Current providers may reject image tool results: preservation is not transport
support, and session code does not silently remove images.

`encodeSession` produces version-2 JSON; encode that `Value` with Aeson for storage.
`decodeSession` validates the completed-exchange structure. Unknown versions,
unresolved exchanges, mismatched results, duplicate accepted IDs, and invalid
metadata are rejected. It preserves supported user/assistant blocks, timestamps,
usage, exact rational costs, outputs, and compaction state using local parsers.

Compatibility compares instruction, input-field metadata, output schema, resolved
protocol, and registry names, schemas, and descriptions exactly. A schema or tool
menu change requires an explicit `startSession`; no additional tools are silently
admitted on continuation. Registry bodies, connections, and credentials are never
serialized. The caller must restore compatible implementations; body behavior
cannot be inferred from schemas. Like legacy ReAct, sessions do not use signature
demonstrations.

Compaction replaces only whole completed entries in the request view. Full audit
history remains available, while `promptMessages` exposes the summary and retained
tail. A retained assistant's tool results always stay with that assistant.

## Recovery boundary

A returned checkpoint contains every result of its accepted exchange. Resuming
it never executes those tools again. A crash or exception during dispatch, or
before a completed checkpoint is returned and saved, can leave external effects
without a durable checkpoint. Reconcile those effects before retrying; sessions
do not guarantee exactly-once side effects across that boundary. Checkpoints are
caller-owned conversation data, and structural validation does not authenticate
an edited checkpoint. Store and retain them according to your application's needs.


## Reasoning continuation and checkpoint migration

Version 2 records the resolved request provider, API, model ID and endpoint, plus
an exact protected system/tools/message prefix when the request view contains
opaque reasoning. This is request identity, not an attested provider model:
Baikai responses echo the requested model. Optional observed-model evidence is
separate and an alias need not equal that reported model string. Responses replay
API/model scope must agree with the echoed request identity before tools run.
Headers and API keys are never included in checkpoint origin fields. Endpoints
with userinfo, query strings or fragments remain unknown rather than persisting
potential credentials; use a credential-free endpoint for resumable reasoning.

`startSessionWithModel model signature registry config input` establishes a
requested identity before the first call. It stores only that public identity;
use `runRouting model . runLLMWith providers . routeLLM` around the session action
to supply the full model configuration, including compatibility settings and
credentials. Without routing, subsequent session calls use a minimal model built
from that identity. Select `ProtocolNative` explicitly when needed; this
constructor retains `startSession`'s conservative `ProtocolAuto` behavior.

The supported order from the action toward the provider is routing, continuation
validation, cache/trace, final validation and private-metadata removal, transport.
For example, the wrappers inside the error, routing, cache and time handlers are
`runLLMWith providers . cachedLLM . routeLLM`. `routeLLM` and both cache memoizers
now require `Error ShikumiError` in their effect row. The metadata key
`shikumi.continuation.v1` is reserved and must survive intermediate wrappers.
Custom interpreters that bypass the built-in boundaries must call
`validateRequestContinuation` after resolving their model and before returning
cached output or dispatching transport, then remove private metadata at transport
with `stripContinuationMetadata`. They must echo the resolved request model in a
conforming response. Framework checks cannot enforce a custom interpreter that
ignores this contract.

Version-1 checkpoints still decode. Their origin is explicitly unknown: plain
histories bind only after a resolved request and conforming response. Old opaque
histories require an explicit restart; selecting today's ambient model never
blesses their old signatures. Future unknown checkpoint versions fail locally.
Changing provider, API, model, endpoint, system, tools or protected message order
fails with `ValidationFailure` before the provider or new tools execute. Appending
new user turns is supported; changing message construction timestamps is harmless.

A signed thinking block, redacted block or Responses replay item protects its
prefix even when its visible text is empty. Proactive compaction defers whenever
it would replace the prefix of a retained opaque exchange. Context-overflow
recovery in that situation fails with a restart diagnostic without calling a
summarizer or retrying the invalid request. Plain histories retain bounded
compaction and retry behavior.

`renderSessionSummaryInput old` supplies readable audit text for separately
obtaining a summary: it excludes signatures, encrypted replay, redacted thinking,
images and uninterpreted extension blocks structurally. Readable assistant text,
non-redacted thinking, tool arguments, native text results and structured results
remain. Automatic summaries use the same projection. The original checkpoint
retains every opaque byte.

After reviewing a plain-text summary, create a separate conversation:

```haskell
fresh = restartSessionFromSummary "Caller-approved account of prior work" old
```

This pure operation returns `Either HistoryError ReActSession`, performs no model
or tool calls, and leaves `old` available for audit. The result has no old native
exchanges and no bound origin. Store it separately; restart never silently
rewrites an archive or modifies a signed exchange.
