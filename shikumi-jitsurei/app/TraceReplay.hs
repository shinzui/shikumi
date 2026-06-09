-- | (8) Caching, tracing, and deterministic replay.
--
-- Each is an @interpose@ over the same @LLM@ effect, so you opt into them by
-- stacking interpreters. This example runs one typed program three ways:
--
--   1. /cached/ — the in-memory cache serves a repeated identical call, so the
--      provider is contacted once for two runs;
--   2. /traced/ — @tracedLLM@ + @runTrace@ capture a hierarchical span tree with
--      timings and token usage, which we render and persist to disk;
--   3. /replayed/ — @runLLMReplay@ re-runs the program from the stored trace
--      alone, fail-closed, contacting no provider.
module Main (main) where

import Baikai (Context, Response)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Cache (cachedLLM)
import Shikumi.Cache.Backend.Memory (newMemoryCache, runCacheMemory)
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Jitsurei.Stub (markerResponse, runStubLLM)
import Shikumi.LLM (LLM (..))
import Shikumi.Module (predict)
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema (FromModel, ToSchema)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Trace (SpanKind (ProgramSpan), renderTree, runTrace, tracedLLM, withSpan)
import Shikumi.Trace.Replay (runLLMReplay)
import Shikumi.Trace.Store (readTraceFile, replayIndex, writeTraceFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

newtype Question = Question {question :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype Answer = Answer {answer :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

qa :: Program Question Answer
qa = predict (mkSignature "Answer the question concisely." :: Signature Question Answer)

input :: Question
input = Question "What does shikumi turn LM calls into?"

responder :: Context -> Response
responder = const (markerResponse [("answer", "typed, traceable, replayable programs")])

main :: IO ()
main = withSystemTempDirectory "shikumi-jitsurei" $ \dir -> do
  putStrLn "jitsurei-trace-replay: cache, trace, and replay one program\n"

  -- (1) Caching: two identical runs, one provider call.
  cache <- newMemoryCache
  calls <- newIORef (0 :: Int)
  let counting :: forall es a. (IOE :> es) => Eff (LLM : es) a -> Eff es a
      counting = interpret $ \_ -> \case
        Complete _ c _ -> do
          liftIO (atomicModifyIORef' calls (\n -> (n + 1, ())))
          pure (responder c)
        Stream {} -> pure []
  cached <-
    runEff . runTime . runCacheMemory cache . counting . cachedLLM . runErrorNoCallStack @ShikumiError $ do
      a <- runProgram qa input
      b <- runProgram qa input
      pure (a, b)
  n <- readIORef calls
  putStrLn $ "[cache]  two identical runs -> " <> show cached
  putStrLn $ "[cache]  provider calls     -> " <> show n <> " (served the repeat from cache)"

  -- (2) Tracing: capture, render, and persist a hierarchical span tree.
  (traced, tree) <-
    runEff . runTrace . runStubLLM responder . tracedLLM $
      runErrorNoCallStack @ShikumiError (withSpan ProgramSpan "qa" (runProgram qa input))
  putStrLn "\n[trace]  span tree:"
  TIO.putStr (renderTree tree)
  putStrLn $ "[trace]  result -> " <> show traced
  let tracePath = dir </> "qa-trace.json"
  writeTraceFile tracePath tree

  -- (3) Replay: re-run from the stored trace alone, zero provider calls.
  loaded <- readTraceFile tracePath
  case loaded of
    Left err -> TIO.putStrLn ("[replay] could not read trace: " <> err)
    Right tree' -> do
      replayed <-
        runEff . runErrorNoCallStack @ShikumiError . runLLMReplay (replayIndex tree') $
          runProgram qa input
      putStrLn $ "\n[replay] from trace only -> " <> show replayed
