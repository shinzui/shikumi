-- | The offline prompt-inspection harness every milestone asserts against.
--
-- 'runWithCapture' runs a program through a /capturing stub/ — a fake @LLM@
-- interpreter that records each request's fully-rendered prompt (it intercepts at
-- the @LLM@ boundary, /after/ EP-3's adapter has turned the signature + params +
-- input into a baikai @Context@) and returns scripted canned responses. Because the
-- rendering happens before the @LLM@ call, the captured text is exactly the prompt
-- the model would have seen — which is what a compiler changes. No network, no API
-- key; the whole suite is a deterministic @cabal test@.
--
-- The captured text is the JSON encoding of the whole 'Baikai.Context' (system
-- prompt + messages + tools). The instruction/reasoning cue/retrieved context live
-- in the system prompt; few-shot demos render as user/assistant /messages/ — both
-- are present in the JSON, so a substring assertion finds either.
module Test.Capture
  ( runWithCapture,
  )
where

import Baikai (Context, Response)
import Data.Aeson (encode)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Effectful (liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..))
import Shikumi.Program (Program, runProgram)
import Test.Fixtures (markerBody, mkResponse)

-- | Run @prog@ on @input@, serving the given scripted responses (one per LM-call
-- node, in order), and return @(captured prompts in execution order, the program's
-- decoded result)@. The result is @Left@ if a node's response fails to decode — but
-- the prompt for that node is captured /before/ the response is returned, so prompt
-- assertions hold regardless of decode success.
runWithCapture ::
  [Response] ->
  Program i o ->
  i ->
  IO ([Text], Either ShikumiError o)
runWithCapture responses prog input = do
  captureRef <- newIORef []
  scriptRef <- newIORef responses
  result <-
    runEff
      . runErrorNoCallStack @ShikumiError
      . interpret
        ( \_ -> \case
            Complete _ ctx _ -> do
              liftIO (modifyIORef' captureRef (renderedText ctx :))
              liftIO (pop scriptRef)
            Stream {} -> pure []
        )
      $ runProgram prog input
  captured <- reverse <$> readIORef captureRef
  pure (captured, result)

-- | The full rendered request as text: the JSON encoding of the whole context.
renderedText :: Context -> Text
renderedText = TL.toStrict . TLE.decodeUtf8 . encode

-- | Pop the next scripted response; an exhausted script yields a trivially-empty
-- response (tests script enough that this is unreached on the success path).
pop :: IORef [Response] -> IO Response
pop ref = atomicModifyIORef' ref step
  where
    step (x : xs) = (xs, x)
    step [] = ([], mkResponse (markerBody []))
