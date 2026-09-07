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
import Data.Aeson (encode, eitherDecode, object, (.=))
import Data.Generics.Labels ()
import Data.IORef (newIORef, atomicModifyIORef')
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (runEff, liftIO)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Agent.History (encodeSession, decodeSession, sessionTurns)
import Shikumi.Agent.ReAct
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..))
import Shikumi.Schema (ToSchema, FromModel, Validatable)
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
      response callId name args = B.emptyResponse & #message . #content .~ V.singleton (B.AssistantToolCall (B.ToolCall callId name args))
      script = [response "call-A" "lookup" (object []), response "final-A" finalToolName (object ["answer" .= ("Paris, France" :: Text)])]
  replies <- newIORef script
  runEff . runErrorNoCallStack . interpret (\_ -> \case
    Complete {} -> do
      next <- liftIO (atomicModifyIORef' replies (\xs -> case xs of
        [] -> ([], Nothing)
        x : rest -> (rest, Just x)))
      maybe (throwError (ProviderFailure "Unexpected extra model call")) pure next
    Stream {} -> pure []) $ do
      initial <- startSession signature registry cfg (Question "Which city is stored?")
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
Images remain native image blocks; text projection includes labeled image JSON.
Current providers may reject image tool results: preservation is not transport
support, and session code does not silently remove images.

`encodeSession` produces version-1 JSON; encode that `Value` with Aeson for storage.
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
