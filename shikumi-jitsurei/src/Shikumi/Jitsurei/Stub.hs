-- | The shared offline harness for the @shikumi-jitsurei@ examples.
--
-- Every example in this package runs against a deterministic, in-process /stub/
-- LM — no API key, no network — so each one is a believable, executable
-- demonstration rather than a sketch. This is the framework's standard hermetic
-- pattern (the same one the test suites and the @shikumi@ CLI use): the @LLM@
-- effect is the only seam to the outside world, so we discharge it with a pure
-- @interpret@ that answers every completion from a fixed function of the request.
--
-- Two response shapes cover every example:
--
--   * 'markerResponse' builds the prompt-fallback adapter's @[[ ## field ## ]]@
--     sections, the wire shape the provider-neutral run path decodes. Most
--     examples hand a constant 'markerResponse' to 'runStub' / 'runStubEval'.
--
--   * 'mkTextResponse' / 'mkToolCallResponse' build the turns a multi-step agent
--     loop consumes; 'runAgent' replays a /script/ of them in order.
module Shikumi.Jitsurei.Stub
  ( -- * Building stub responses
    markerResponse,
    mkTextResponse,
    mkToolCallResponse,

    -- * Running a program offline
    runStub,
    runStubEval,
    runStubLLM,

    -- * Running an agent against a scripted LM
    runAgent,
    runScriptLLM,

    -- * Inspecting the request inside a responder
    systemContains,
  )
where

import Baikai
  ( AssistantContent (..),
    Context,
    Response,
    _Response,
    _TextContent,
    _ToolCall,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value)
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (Prim, runPrim)
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..))
import Shikumi.Program (Program, runProgram)

-- ---------------------------------------------------------------------------
-- Building stub responses
-- ---------------------------------------------------------------------------

-- | Build a 'Response' as the prompt-fallback adapter's @[[ ## field ## ]]@
-- sections — one per @(fieldName, value)@ pair — terminated by the
-- @[[ ## completed ## ]]@ marker. Carries small fixed token usage so traces and
-- reports show non-zero counts. This is exactly the body the provider-neutral
-- decode path expects, so the typed output decodes cleanly.
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

-- | A plain assistant text turn (a ReAct propose/finish reply, or the agent's
-- final extract turn).
mkTextResponse :: Text -> Response
mkTextResponse t =
  _Response & #message . #content .~ V.singleton (AssistantText (_TextContent & #text .~ t))

-- | A native tool-call turn: the assistant asks to invoke @name@ with @args@.
mkToolCallResponse :: Text -> Text -> Value -> Response
mkToolCallResponse callId name args =
  _Response
    & #message . #content
      .~ V.singleton (AssistantToolCall (_ToolCall & #id_ .~ callId & #name .~ name & #arguments .~ args))

-- ---------------------------------------------------------------------------
-- Running a program offline
-- ---------------------------------------------------------------------------

-- | The base @LLM@ interpreter: answer every completion from a deterministic
-- function of the request 'Context'. Stateless, so it needs no @IOE@. Pass
-- @const r@ for a constant answer, or branch on the request (see 'systemContains')
-- to give a multi-stage pipeline a different answer per stage.
runStubLLM :: (Context -> Response) -> Eff (LLM : es) a -> Eff es a
runStubLLM responder = interpret $ \_ -> \case
  Complete _ c _ -> pure (responder c)
  Stream {} -> pure []

-- | Run a single 'Program' against the stub LM, returning the typed output or a
-- typed 'ShikumiError'.
runStub :: (Context -> Response) -> Program i o -> i -> IO (Either ShikumiError o)
runStub responder prog input =
  runEff . runErrorNoCallStack . runStubLLM responder $ runProgram prog input

-- | Run an evaluation/optimization action offline against the stub LM. Provides
-- exactly the effect row @evaluate@ / @optimize@ require
-- (@LLM@, @Concurrent@, @Error ShikumiError@, @Time@, @IOE@). @Time@ is shikumi's
-- own clock effect ('Shikumi.Effect.Time'), discharged here by 'runTime' against
-- the real system clock — fine for an offline stub run because only latency
-- timing reads it.
runStubEval ::
  (Context -> Response) ->
  Eff '[LLM, Concurrent, Error ShikumiError, Time, Prim, IOE] a ->
  IO (Either ShikumiError a)
runStubEval responder =
  runEff . runPrim . runTime . runErrorNoCallStack . runConcurrent . runStubLLM responder

-- ---------------------------------------------------------------------------
-- Running an agent against a scripted LM
-- ---------------------------------------------------------------------------

-- | An @LLM@ interpreter that replays a fixed /script/ of responses, one per
-- completion, in order. A multi-step agent loop consumes one turn per round;
-- once the script is exhausted it returns an empty text turn.
runScriptLLM :: (IOE :> es) => [Response] -> Eff (LLM : es) a -> Eff es a
runScriptLLM script act = do
  ref <- liftIO (newIORef script)
  interpret
    ( \_ -> \case
        Complete {} -> liftIO (atomicModifyIORef' ref pop)
        Stream {} -> pure []
    )
    act
  where
    pop (x : xs) = (xs, x)
    pop [] = ([], mkTextResponse "")

-- | Run a 'Program' (typically a ReAct agent) against a scripted LM.
runAgent :: [Response] -> Program i o -> i -> IO (Either ShikumiError o)
runAgent script prog input =
  runEff . runErrorNoCallStack . runScriptLLM script $ runProgram prog input

-- ---------------------------------------------------------------------------
-- Inspecting the request inside a responder
-- ---------------------------------------------------------------------------

-- | Whether the request's system prompt contains a substring. A stub responder
-- branches on this to answer each stage of a composed pipeline differently (each
-- stage's instruction is rendered into the system prompt).
systemContains :: Text -> Context -> Bool
systemContains needle c = maybe False (needle `T.isInfixOf`) (c ^. #systemPrompt)
