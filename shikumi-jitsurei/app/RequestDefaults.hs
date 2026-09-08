-- | A compiled, offline stack: routing -> defaults -> trace -> cache -> base.
module Main (main) where

import Baikai (emptyModel)
import Baikai.Evidence (evidenceRequest)
import Baikai.Speed (Speed (..))
import Baikai.ThinkingLevel (ThinkingLevel (..))
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef)
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Prim (runPrim)
import Shikumi.Cache (cachedLLM)
import Shikumi.Cache.Backend.Memory (newMemoryCache, runCacheMemory)
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM.Defaults
import Shikumi.Program (runProgram)
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Testing (Question (..), captureLLMRequests, instructedProg, runStubLLM, validAnswerResponse)
import Shikumi.Trace (runTrace, tracedLLM)
import System.Exit (die)

main :: IO ()
main = do
  cache <- newMemoryCache
  calls <- newIORef []
  let defaults =
        emptyRequestDefaults
          { defaultThinking = Just ThinkingHigh,
            defaultSpeed = Just SpeedStandard,
            defaultMaxTokens = Just 4096
          }
      question = Question "What do defaults configure?"
  (result, _) <- runEff
    . runPrim
    . runTime
    . runConcurrent
    . runTrace
    . runErrorNoCallStack @ShikumiError
    . runRouting emptyModel
    . runCacheMemory cache
    . runStubLLM (const validAnswerResponse)
    . captureLLMRequests calls
    . cachedLLM
    . tracedLLM
    . withRequestDefaults defaults
    . routeLLM
    $ do
      a <- runProgram instructedProg question
      b <- runProgram instructedProg question
      c <-
        withRequestDefaults (emptyRequestDefaults {defaultEvidence = Just (evidenceRequest "example")}) $
          runProgram instructedProg question
      pure (a, b, c)
  case result of
    Left err -> die (show err)
    Right (a, b, c) | a == b && b == c -> pure ()
    Right _ -> die "inconsistent outputs"
  captured <- readIORef calls
  if length captured == 2 && all (\(_, _, o) -> o ^. #maxTokens == Just 4096) captured
    then putStrLn "Three typed runs, two base calls: ordinary repeat cached; evidence request dispatched."
    else die "unexpected effective requests"
  putStrLn "Requested: high thinking, standard speed, 4096 output tokens. Offline stub supplies no provider evidence."
