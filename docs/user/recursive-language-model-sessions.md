# Experimental recursive language-model sessions

Use `Shikumi.CodeExec.RLM` from `shikumi-tools` to answer questions about documents
that stay outside the model prompt. The agent sees document names and character
lengths, then requests bounded searches and slices. It can store intermediate JSON
values and ask a sub-model about selected excerpts before submitting a typed answer.
This API is experimental; its tests establish bounded mechanics, not live-model
answer quality.

`rlmWithReport config documents signature` constructs a
`Program i (RLMOutcome o, RLMReport)`. Only the ordinary question is rendered through
`ToPrompt`. Supply sources separately with `contextStore`. Each invocation starts
with private variables and counters, including when the same Program is run
concurrently. The context is immutable and grants no host-code, filesystem or
process access.

## Action language

Return one JSON object per outer turn, with quoted keys and no Markdown fences.
Unknown operations, malformed fields and invalid submissions produce recoverable
observations, consuming both the operation and outer-iteration allowance.

| Action | Example | Meaning |
|---|---|---|
| Describe | `{"op":"describe","name":"source"}` | Return name and character length, never source contents. |
| Slice | `{"op":"slice","name":"source","start":10,"count":80}` | Inspect characters in the half-open range `[10,90)`. |
| Find | `{"op":"find","name":"source","needle":"FACT=","start":0,"limit":5}` | Literal search, with overlapping matches, within a bounded scan window. |
| Store | `{"op":"store","name":"memo","value":{"fact":"amber"}}` | Persist a JSON value privately; replacement is atomic. |
| Load | `{"op":"load","name":"memo"}` | Observe a stored value. |
| Query | `{"op":"query","prompt":"Explain this excerpt: ..."}` | Ask the selected sub-model one question. Include the excerpt explicitly. |
| QueryBatch | `{"op":"query_batch","prompts":["first question","second question"]}` | Reserve the entire batch, then execute sequentially in original order. |
| Submit | `{"op":"submit","value":{"answer":"amber"}}` | Decode with `FromModel`, run `Validatable`, and return the validated output. |

Names contain ASCII letters, digits, underscores or hyphens, are nonempty and at
most 128 characters long. Operation names are reserved. Variables cannot shadow
source names. Duplicate document names are rejected by `contextStore`.

Offsets count Unicode characters, including supplementary characters as one,
rather than UTF-8 bytes or grapheme clusters. Negative offsets/counts and ranges
past the end are rejected. An empty slice at the document end is valid. Empty
sources are supported. Find rejects an empty needle, a needle longer than the
scan allowance, and a match limit outside `1..maxMatches`. It returns `matches`,
`scannedEnd`, `nextOffset` and `complete`. Continue at `nextOffset`; scan-window
continuation retains enough overlap to find needles crossing the window boundary.
A match-limited search resumes one character after the last reported match.

Observations include `value`, `error` and optional `truncation` metadata. Truncated
slices keep source-relative `start`/`end` fields and `nextOffset`, so the agent can
request a later slice. Other oversized values become marked prefixes of their JSON
text, with original and displayed character counts; these prefixes are not
necessarily parseable JSON. If a large Find result is displayed as a JSON-text
prefix, repeat it with a smaller match limit. Metadata itself counts against the
observation allowance. An allowance too small to display the envelope causes
exhaustion.

## Limits and outcomes

Start with `defaultRLMConfig` and update its `session` field using
`defaultSessionConfig`. Every numeric limit must be positive; zero does not mean
unlimited. Configuration and total context size are checked before any LLM call.

| Field | Default | What is bounded |
|---|---:|---|
| `maxOuterIterations` | 40 | Outer logical model calls, including corrective responses. |
| `maxRequestChars` | 64000 | Sum of system and user Text characters before every outer and sub-model call. |
| `maxContextChars` | 4000000 | All source characters plus document-name characters. |
| `maxStoredChars` | 16000 | Aggregate JSON-encoded variable values plus their names. |
| `maxActionBytes` | 16000 | UTF-8 bytes in one action, checked before parsing and on typed operations. |
| `maxObservationChars` | 4000 | One serialized observation, including JSON escaping and metadata. |
| `maxObservedChars` | 32000 | Sum of all retained serialized observations. |
| `maxOperations` | 40 | Actions including failures and submissions; a batch is one action. |
| `maxScanChars` | 1000000 | Characters inspected by one Find scan. |
| `maxMatches` | 100 | Maximum requested matches in one Find. |
| `maxSubqueries` | 8 | Reserved logical subquery slots, shared across all actions. |
| `maxSubqueryChars` | 8000 | Characters in each supplied subquery prompt. |

`subModel` defaults to `emptyModel`, using the configured interpreter's model
selection. Set a concrete Baikai model when the sub-model should differ from the
outer model. Both use the same LLM effect interpreter, sharing cost, tracing,
caching and resilience behavior. Queries cannot invoke the outer session loop;
recursion depth is one.

A batch exceeding the remaining slot allowance returns `RLMExhausted Subqueries`
and makes zero calls for that batch. A batch containing an oversized prompt is
rejected recoverably before reserving slots. All batch request sizes are checked
before its first dispatch. Admitted calls run sequentially; each returned result
becomes an observation in prompt order. Observation exhaustion can stop a batch
partway through. Slots are never refunded. Counts describe logical LLM operations;
an interpreter may retry transport attempts within one operation. Actual dollar
spending uses the runtime's existing optimistic admission contract and can overshoot
its ceiling by an admitted call's cost.

`RLMSubmitted output` ends immediately after successful typed validation. Invalid
submissions can be corrected within the remaining iterations. Exhaustion returns
`RLMExhausted` with `OuterIterations`, `Operations`, `Subqueries`,
`RequestCharacters` or `ObservationCharacters`. There is no extra extraction,
summary or repair call. `rlm` is the convenience constructor returning only the
output and maps exhaustion to `BudgetExceeded` with the allowance in its message.

`RLMReport` contains outer-call and operation counts, actual logical subquery
attempts, retained observation characters, chronological audit records, and
termination (`Nothing` for successful submission). Action records and observation
records are separate chronological entries. Rejected oversized actions keep only
a bounded prefix marked by `actionTruncated`. Truncation events appear in the
observations. Infrastructure errors propagate unchanged through `ShikumiError`;
no normal outcome/report is returned on that path, and remaining batch calls stop.
Use the shared LLM tracing interpreter for provider-failure evidence.

Request characters do not measure provider JSON envelopes or tokens. Returned
model text must first be received before it can be bounded for retention, so these
limits are not transport-memory guarantees. No history compaction silently changes
the evidence. If retained history would make the next outer request too large,
the run exhausts instead. Restarting creates a fresh session and can repeat calls.

## Complete offline example

The following module is compiled and run by the package test suite as
[RLMExample.hs](../../shikumi-tools/test/RLMExample.hs). It slices an external
source, asks one subquery, and submits a typed answer. The scripted LLM fails if
any unplanned call occurs. A production caller replaces the scripted interpreter
with its usual [LLM runtime](effects-and-runtime.md).

```bash
nix develop .#ghc9124 -c cabal test shikumi-tools --test-options='-p "documented RLM example"'
```

The example returns `Right ("amber",1)`: the answer and one attempted subquery.

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

module RLMExample (main, example) where

import Baikai qualified as B
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.CodeExec.RLM
import Shikumi.CodeExec.Session
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..))
import Shikumi.Program (runProgram)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)

newtype Question = Question {question :: Text}
  deriving stock (Generic)
  deriving anyclass (ToPrompt)

newtype Answer = Answer {answer :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

instance Validatable Answer

signature :: Signature Question Answer
signature = mkSignature "Inspect the source and answer the question."

example :: IO (Either ShikumiError (Text, Int))
example = do
  replies <-
    newIORef
      [ "{\"op\":\"slice\",\"name\":\"source\",\"start\":0,\"count\":12}",
        "{\"op\":\"query\",\"prompt\":\"What color is named in: Color: amber?\"}",
        "amber",
        "{\"op\":\"submit\",\"value\":{\"answer\":\"amber\"}}"
      ]
  runEff
    . runErrorNoCallStack
    . interpret
      ( \_ -> \case
          Complete {} -> do
            next <-
              liftIO
                ( atomicModifyIORef'
                    replies
                    ( \case
                        [] -> ([], Nothing)
                        x : xs -> (xs, Just x)
                    )
                )
            case next of
              Nothing -> throwError (ProviderFailure "Unexpected extra model call")
              Just text -> pure (B.emptyResponse & #message . #content .~ V.singleton (B.AssistantText (B.emptyTextContent & #text .~ text)))
          Stream {} -> throwError (ProviderFailure "Unexpected streaming call")
      )
    $ do
      -- Only the question is ToPrompt input. The source remains outside it.
      source <-
        either
          (\(SessionError e) -> throwError (ValidationFailure e))
          pure
          (contextStore [("source", "Color: amber")])
      (outcome, report) <-
        runProgram
          (rlmWithReport defaultRLMConfig source signature)
          (Question "Which color is named?")
      case outcome of
        RLMSubmitted (Answer text) -> pure (text, subqueriesAttempted report)
        RLMExhausted limit ->
          throwError
            ( BudgetExceeded
                ( "Session exhausted: " <> case limit of
                    Subqueries -> "subqueries"
                    _ -> "another configured allowance"
                )
            )

main :: IO ()
main = example >>= print
```

The broader [acceptance tests](../../shikumi-tools/test/RLMSpec.hs) run the real loop
over two independent two-megabyte sources concurrently and assert bounded captured
requests, distant fact lookup, stored-value persistence and exact subquery counts.
[ADR-7](../adr/0007-bound-recursive-sessions-at-the-llm-operation-boundary.md) records
the ownership and admission decisions.
