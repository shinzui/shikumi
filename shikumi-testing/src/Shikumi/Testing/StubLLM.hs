-- | Deterministic, network-free interpreters of shikumi's @LLM@ effect: a
-- responder function, a scripted replay, and counting / error-injecting
-- wrappers, plus ready-made effect stacks for programs, agents, and eval runs.
module Shikumi.Testing.StubLLM
  ( -- * Interpreters
    runStubLLM,
    captureLLMRequests,
    runScriptLLM,
    runCountingLLM,
    runScriptLLMThrowingOn,
    runScriptLLMThrowingOnce,

    -- * Ready-made stacks
    runStub,
    runStubEval,
    runEffScript,
    runAgent,

    -- * Inspecting requests inside a responder
    systemContains,
  )
where

import Baikai
  ( Context,
    Model,
    Options,
    Response,
  )
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Dispatch.Dynamic (interpose, interpret, passthrough)
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Effectful.Prim (Prim, runPrim)
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..))
import Shikumi.Program (Program, runProgram)
import Shikumi.Testing.Response (mkTextResponse)

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
        Complete {} -> liftIO (pop ref)
        Stream {} -> pure []
    )
    act

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

-- | Interpret @LLM@ like 'runScriptLLM', but throw once on the first completion.
runScriptLLMThrowingOnce ::
  (IOE :> es, Error ShikumiError :> es) =>
  ShikumiError ->
  [Response] ->
  Eff (LLM : es) a ->
  Eff es a
runScriptLLMThrowingOnce = runScriptLLMThrowingOn [1]

-- | Interpret @LLM@ like 'runScriptLLM', but throw on selected 1-based completion
-- calls. Useful for bounded-retry tests.
runScriptLLMThrowingOn ::
  (IOE :> es, Error ShikumiError :> es) =>
  [Int] ->
  ShikumiError ->
  [Response] ->
  Eff (LLM : es) a ->
  Eff es a
runScriptLLMThrowingOn throwAt err script act = do
  ref <- liftIO (newIORef script)
  countRef <- liftIO (newIORef (0 :: Int))
  interpret
    ( \_ -> \case
        Complete {} -> do
          n <- liftIO (atomicModifyIORef' countRef (\n0 -> let n1 = n0 + 1 in (n1, n1)))
          if n `elem` throwAt
            then throwError err
            else liftIO (pop ref)
        Stream {} -> pure []
    )
    act

-- | Discharge a network-free @LLM@ computation against a scripted mock: handle the
-- error channel, then @IO@. The whole stack is exactly the row a ReAct agent runs
-- in (@LLM@ + @Error ShikumiError@), plus @IOE@ at the bottom for the mock's @IORef@.
runEffScript ::
  [Response] ->
  Eff '[LLM, Error ShikumiError, IOE] a ->
  IO (Either ShikumiError a)
runEffScript script = runEff . runErrorNoCallStack . runScriptLLM script

pop :: IORef [Response] -> IO Response
pop ref = atomicModifyIORef' ref step
  where
    step (x : xs) = (xs, x)
    step [] = ([], mkTextResponse "")

-- | Answer every completion with a fixed 'Response', bumping a counter — the
-- shape cache MISS/HIT tests assert against. (The cache backend suites carry a
-- private copy; see docs/plans/49-… Decision Log for why they are not migrated here.)
runCountingLLM :: (IOE :> es) => IORef Int -> Response -> Eff (LLM : es) a -> Eff es a
runCountingLLM ref resp = interpret $ \_ -> \case
  Complete {} -> liftIO (modifyIORef' ref (+ 1)) >> pure resp
  Stream {} -> pure []

-- | Record effective requests without changing completion or streaming behavior.
-- Install below routing/defaults to inspect what reaches the base interpreter.
captureLLMRequests :: (IOE :> es, LLM :> es) => IORef [(Model, Context, Options)] -> Eff es a -> Eff es a
captureLLMRequests ref = interpose $ \env op -> do
  case op of
    Complete m c o -> liftIO (atomicModifyIORef' ref (\xs -> (xs ++ [(m, c, o)], ())))
    Stream m c o -> liftIO (atomicModifyIORef' ref (\xs -> (xs ++ [(m, c, o)], ())))
  passthrough env op
