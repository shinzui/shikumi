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

import Baikai
  ( AssistantContent (..),
    Context,
    Response,
    _Response,
    _TextContent,
  )
import Control.Lens ((&), (.~))
import Control.Monad (void)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (Prim, runPrim)
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..))
import Shikumi.Program (Program, runProgram)
import Shikumi.Trace (SpanKind (ProgramSpan), TraceTree, runTrace, tracedLLM, withSpan)
import Shikumi.Trace.Replay (runLLMReplay)
import Shikumi.Trace.Store (replayIndex)

-- | A base @LLM@ interpreter that answers every completion from a deterministic
-- responder. Stateless, so it needs no @IOE@.
runStubLLM :: (Context -> Response) -> Eff (LLM : es) a -> Eff es a
runStubLLM responder = interpret $ \_ -> \case
  Complete _ c _ -> pure (responder c)
  Stream {} -> pure []

-- | Run an evaluation/optimization action offline against the stub LM. Provides
-- exactly the row @evaluate@/@optimize@ require (@LLM@, @Concurrent@,
-- @Error ShikumiError@, @Time@, @IOE@). @Time@ is shikumi's own clock effect
-- ('Shikumi.Effect.Time'), discharged by 'runTime' against the real system clock.
runStubEval ::
  (Context -> Response) ->
  Eff '[LLM, Concurrent, Error ShikumiError, Time, Prim, IOE] a ->
  IO (Either ShikumiError a)
runStubEval responder =
  runEff . runPrim . runTime . runErrorNoCallStack . runConcurrent . runStubLLM responder

-- | Run a single program against the stub LM (the reference "recorded run" used by
-- @replay@'s identity check).
runStubProgram ::
  (Context -> Response) ->
  Program i o ->
  i ->
  IO (Either ShikumiError o)
runStubProgram responder prog input =
  runEff . runErrorNoCallStack . runStubLLM responder $ runProgram prog input

-- | Re-run a program using only the responses recorded in a trace, via EP-7's
-- fail-closed replay interpreter. Contacts no provider (structurally:
-- 'runLLMReplay' has no registry).
runReplayProgram ::
  TraceTree ->
  Program i o ->
  i ->
  IO (Either ShikumiError o)
runReplayProgram tree prog input =
  runEff . runErrorNoCallStack . runLLMReplay (replayIndex tree) $ runProgram prog input

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

-- | Build a stub 'Response' as the prompt-fallback adapter's @[[ ## field ## ]]@
-- sections (the path the neutral @_Model@ exercises), carrying small fixed usage so
-- the recorded trace shows token counts.
markerResponse :: [(Text, Text)] -> Response
markerResponse fields =
  _Response
    & #message . #content .~ V.singleton (AssistantText (_TextContent & #text .~ body))
    & #message . #usage . #inputTokens .~ 18
    & #message . #usage . #outputTokens .~ 5
    & #latencyMs .~ 4
  where
    body = T.unlines (concatMap sect fields ++ ["[[ ## completed ## ]]"])
    sect (k, v) = ["[[ ## " <> k <> " ## ]]", v]
