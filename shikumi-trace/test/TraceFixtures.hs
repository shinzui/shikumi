-- | Shared, network-free fixtures for the EP-7 trace tests: a stub 'Model', a
-- request builder, canned responses, and two base @LLM@ interpreters — a /fixed/
-- one that returns the same response for every call, and a /keyed/ one that picks
-- a response from the request 'Context' (so a two-stage pipeline gets distinct
-- responses, hence distinct cache keys).
module TraceFixtures
  ( stubModel,
    ctxFor,
    optsFor,
    mkResponse,
    responseText,
    lastUserText,
    runFixedLLM,
    runKeyedLLM,
    runKeyedCountingLLM,
    runSequencedLLM,
  )
where

import Baikai
  ( Api (Custom),
    AssistantContent (..),
    Context,
    Message (UserMessage),
    Model,
    Options,
    Response,
    TextContent (..),
    UserContent (UserText),
    emptyContext,
    emptyModel,
    emptyOptions,
    emptyResponse,
    emptyTextContent,
    user,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef')
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Shikumi.LLM (LLM (..))

-- | A stub model with real-looking routing identity, so LM-call span labels read
-- @stub/stub-model@.
stubModel :: Model
stubModel =
  emptyModel
    & #provider .~ "stub"
    & #modelId .~ "stub-model"
    & #api .~ Custom "stub"

-- | A one-user-turn request context carrying @t@ (varies the cache key per stage).
ctxFor :: Text -> Context
ctxFor t = emptyContext & #messages .~ V.singleton (user t)

-- | Default options.
optsFor :: Options
optsFor = emptyOptions

-- | A response carrying @t@ as its single assistant text block, with small fixed
-- token counts and latency so span attributes are populated.
mkResponse :: Text -> Response
mkResponse t =
  emptyResponse
    & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ t))
    & #message . #usage . #inputTokens .~ 10
    & #message . #usage . #outputTokens .~ 5
    & #latencyMs .~ 12

-- | Concatenate the assistant text blocks of a response.
responseText :: Response -> Text
responseText resp =
  mconcat [t | AssistantText (TextContent t) <- V.toList (resp ^. #message . #content)]

-- | Concatenate the text of every user message in a request context.
lastUserText :: Context -> Text
lastUserText c =
  mconcat
    [ t
    | UserMessage up <- V.toList (c ^. #messages),
      UserText (TextContent t) <- V.toList (up ^. #content)
    ]

-- | A base @LLM@ interpreter that returns the same response for every completion.
runFixedLLM :: Response -> Eff (LLM : es) a -> Eff es a
runFixedLLM resp = interpret $ \_ -> \case
  Complete {} -> pure resp
  Stream {} -> pure []

-- | A base @LLM@ interpreter that picks a response from the request context.
runKeyedLLM :: (Context -> Response) -> Eff (LLM : es) a -> Eff es a
runKeyedLLM f = interpret $ \_ -> \case
  Complete _ c _ -> pure (f c)
  Stream {} -> pure []

-- | Like 'runKeyedLLM' but bumps a counter on every completion (used to assert how
-- many provider calls a live run made — and that a replay run makes zero).
runKeyedCountingLLM :: (IOE :> es) => IORef Int -> (Context -> Response) -> Eff (LLM : es) a -> Eff es a
runKeyedCountingLLM ref f = interpret $ \_ -> \case
  Complete _ c _ -> liftIO (atomicModifyIORef' ref (\n -> (n + 1, ()))) >> pure (f c)
  Stream {} -> pure []

-- | A base @LLM@ interpreter that returns and removes the next response from an
-- 'IORef' list on each completion. Used for retry tests that need attempt one
-- and attempt two to receive different payloads.
runSequencedLLM :: (IOE :> es) => IORef [Response] -> Eff (LLM : es) a -> Eff es a
runSequencedLLM ref = interpret $ \_ -> \case
  Complete {} ->
    liftIO $
      atomicModifyIORef' ref $ \case
        r : rs -> (rs, r)
        [] -> ([], mkResponse "runSequencedLLM: exhausted")
  Stream {} -> pure []
