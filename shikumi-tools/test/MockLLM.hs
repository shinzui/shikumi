-- | A deterministic, network-free interpreter of the @LLM@ effect for the
-- @shikumi-tools@ specs, plus builders for the two kinds of scripted assistant
-- 'Response' a ReAct turn can produce: a plain-text reply (the prompt protocol and
-- the extract step) and a native tool-call block (the native protocol).
--
-- Each 'Shikumi.LLM.Complete' pops the next scripted 'Response' in order; an
-- exhausted script yields an empty text response (specs always script enough).
module MockLLM
  ( runMockLLM,
    runEffMock,
    runAgent,
    mkTextResponse,
    mkToolCallResponse,
  )
where

import Baikai
  ( AssistantContent (..),
    Response,
    _Response,
    _TextContent,
    _ToolCall,
  )
import Control.Lens ((&), (.~))
import Data.Aeson (Value)
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..))
import Shikumi.Program (Program, runProgram)

-- | Interpret @LLM@ by popping scripted 'Response's in order. The streaming op is
-- unused. An exhausted script yields an empty text response.
runMockLLM :: (IOE :> es) => [Response] -> Eff (LLM : es) a -> Eff es a
runMockLLM script act = do
  ref <- liftIO (newIORef script)
  interpret
    ( \_ -> \case
        Complete {} -> liftIO (pop ref)
        Stream {} -> pure []
    )
    act

-- | Discharge a network-free @LLM@ computation against a scripted mock: handle the
-- error channel, then @IO@. The whole stack is exactly the row a ReAct agent runs
-- in (@LLM@ + @Error ShikumiError@), plus @IOE@ at the bottom for the mock's @IORef@.
runEffMock ::
  [Response] ->
  Eff '[LLM, Error ShikumiError, IOE] a ->
  IO (Either ShikumiError a)
runEffMock script = runEff . runErrorNoCallStack . runMockLLM script

-- | Run a 'Program' (e.g. a @react@ agent) against a scripted mock LM.
runAgent ::
  [Response] ->
  Program i o ->
  i ->
  IO (Either ShikumiError o)
runAgent script prog i = runEffMock script (runProgram prog i)

pop :: IORef [Response] -> IO Response
pop ref = atomicModifyIORef' ref step
  where
    step (x : xs) = (xs, x)
    step [] = ([], mkTextResponse "")

-- | An assistant 'Response' carrying @t@ as its single text block.
mkTextResponse :: Text -> Response
mkTextResponse t =
  _Response & #message . #content .~ V.singleton (AssistantText (_TextContent & #text .~ t))

-- | An assistant 'Response' carrying a single native tool-call block.
mkToolCallResponse :: Text -> Text -> Value -> Response
mkToolCallResponse callId nm args =
  _Response
    & #message
      . #content
      .~ V.singleton
        (AssistantToolCall (_ToolCall & #id_ .~ callId & #name .~ nm & #arguments .~ args))
