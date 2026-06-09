-- | A scripted, deterministic interpreter of the @LLM@ effect for the combinator
-- tests (EP-5). Each 'Shikumi.LLM.Complete' pops the next 'MockReply': a 'MockOk'
-- yields a canned 'Response' (build them with @ProgramFixtures.mkResponse@ /
-- @markerBody@), a 'MockFail' throws a 'ShikumiError' through the error channel —
-- which is exactly what 'Shikumi.Program.Retry' / 'Shikumi.Program.Validate'
-- react to. 'runMockLLMCounting' additionally bumps a caller-supplied counter on
-- every completion, so a retry test can assert the precise attempt count.
--
-- The counter is caller-owned (an 'IORef' in 'IO') rather than returned as a
-- tuple deliberately: a 'MockFail' short-circuits the @Error ShikumiError@
-- channel, so a tuple result would be discarded on the all-fail path — but the
-- 'IORef', mutated before the throw, survives and is read after the run resolves.
--
-- This is the richer sibling of @ProgramFixtures.runScriptedLLM@ (which only
-- scripts successes); it lives in the test tree, not the library.
module Shikumi.LLM.Mock
  ( MockReply (..),
    runMockLLM,
    runMockLLMCounting,
  )
where

import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Effectful (Eff, IOE, liftIO, type (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, throwError)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..), Response)

-- | One scripted reply to a single completion: a canned success or a typed
-- failure.
data MockReply
  = MockOk Response
  | MockFail ShikumiError

-- | Interpret @LLM@ by popping scripted replies in order. A 'MockFail' is thrown
-- through @Error ShikumiError@; the streaming op is unused (returns @[]@). An
-- exhausted script throws a clear 'ProviderFailure' rather than blocking.
runMockLLM ::
  (IOE :> es, Error ShikumiError :> es) =>
  [MockReply] ->
  Eff (LLM : es) a ->
  Eff es a
runMockLLM replies act = do
  ref <- liftIO (newIORef replies)
  interpret
    ( \_ -> \case
        Complete {} -> popReply ref
        Stream {} -> pure []
    )
    act

-- | Like 'runMockLLM', but bumps the caller-supplied counter on every completion
-- (counting every attempt, including those that fail). The bump happens before
-- the reply is consumed, so a thrown 'MockFail' still counts.
runMockLLMCounting ::
  (IOE :> es, Error ShikumiError :> es) =>
  IORef Int ->
  [MockReply] ->
  Eff (LLM : es) a ->
  Eff es a
runMockLLMCounting cnt replies act = do
  ref <- liftIO (newIORef replies)
  interpret
    ( \_ -> \case
        Complete {} -> do
          liftIO (atomicModifyIORef' cnt (\n -> (n + 1, ())))
          popReply ref
        Stream {} -> pure []
    )
    act

-- | Pop and act on the next reply, throwing on failure or an exhausted script.
popReply :: (IOE :> es, Error ShikumiError :> es) => IORef [MockReply] -> Eff es Response
popReply ref = do
  r <- liftIO (atomicModifyIORef' ref step)
  case r of
    MockOk resp -> pure resp
    MockFail e -> throwError e
  where
    step (x : xs) = (xs, x)
    step [] = ([], MockFail (ProviderFailure "mock: script exhausted"))
