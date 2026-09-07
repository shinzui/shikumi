-- | The offline effect stacks the subcommands run in, plus the deterministic stub
-- LM and a trace recorder.
--
-- EP-6's persistent cache backend was deferred (only the in-memory STM cache
-- shipped), so the EP-12 sketch's "cache fixture on disk" offline story does not
-- exist. Determinism instead comes from a deterministic in-process /stub/ LM
-- (the framework's standard hermetic pattern — see "Shikumi.Trace.Demo"): eval and
-- optimize run against the stub; @record@ captures a real 'TraceTree' from a stub
-- run and persists it (EP-7); @replay@ re-runs purely from that trace via
-- 'runLLMReplay' (fail-closed, zero provider calls). No network, ever.
module Shikumi.Cli.Runtime
  ( runStubEval,
    runStubProgram,
    runReplayProgram,
    recordTrace,
    markerResponse,
  )
where

import Baikai (Context, Response)
import Control.Monad (void)
import Data.Text (Text)
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Prim (runPrim)
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Program (Program, runProgram)
import Shikumi.Testing (markerResponse, runStub, runStubEval, runStubLLM)
import Shikumi.Trace (SpanKind (ProgramSpan), TraceTree, runTrace, tracedLLM, withSpan)
import Shikumi.Trace.Replay (runLLMReplay)
import Shikumi.Trace.Store (replayIndex)

-- | Run a single program against the stub LM (the reference "recorded run" used by
-- @replay@'s identity check).
runStubProgram ::
  (Context -> Response) ->
  Program i o ->
  i ->
  IO (Either ShikumiError o)
runStubProgram = runStub

-- | Re-run a program using only the responses recorded in a trace, via EP-7's
-- fail-closed replay interpreter. Contacts no provider (structurally:
-- 'runLLMReplay' has no registry).
runReplayProgram ::
  TraceTree ->
  Program i o ->
  i ->
  IO (Either ShikumiError o)
runReplayProgram tree prog input =
  case replayIndex tree of
    Left err -> pure (Left (InvalidJSON ("replay index error: " <> err)))
    Right idx -> runEff . runErrorNoCallStack . runLLMReplay idx $ runProgram prog input

-- | Record a trace: run the program on its canonical input under the stub LM and
-- EP-7's capturing interpose, wrapping the whole run in a named program span.
-- Returns whether the run succeeded and the captured tree (the tree is captured
-- regardless, so a failing run still yields an inspectable trace).
recordTrace ::
  (Context -> Response) ->
  Text ->
  Program i o ->
  i ->
  IO (Either ShikumiError (), TraceTree)
recordTrace responder name prog input =
  runEff . runPrim . runTime . runTrace . runStubLLM responder . tracedLLM $
    runErrorNoCallStack (withSpan ProgramSpan name (void (runProgram prog input)))
