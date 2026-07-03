-- | Hand-rolled, network-free baikai providers for the hermetic shikumi tests.
--
-- Every helper builds an isolated 'ProviderRegistry' (never the global one) whose
-- single 'ApiProvider' serves a known 'Custom' 'Api' tag, so the default
-- @cabal test all@ needs no network and no API key. The variants differ only in
-- what @complete@ does: return fixed text, return text with a fixed dollar cost,
-- fail a fixed number of times then succeed, always fail with a non-transient
-- error, or instrument observed concurrency.
module StubProvider
  ( stubModel,
    stubContext,
    stubOptions,
    flattenAssistantText,
    stubRegistry,
    costStubRegistry,
    budgetBarrierStubRegistry,
    failingStubRegistry,
    failingStreamStubRegistry,
    failingStreamCostStubRegistry,
    invalidStubRegistry,
    concurrencyStubRegistry,
  )
where

import Baikai
import Baikai.Prelude
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
  ( TVar,
    atomically,
    modifyTVar',
    readTVar,
    retry,
  )
import Control.Exception (bracket_, throwIO)
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef')
import Data.Text qualified as T
import Data.Vector qualified as V
import Streamly.Data.Stream qualified as Stream

-- | Concatenate the text of every 'AssistantText' block, ignoring thinking and
-- tool-call blocks. baikai has no library equivalent (its own smoke tests define
-- this same helper locally).
flattenAssistantText :: V.Vector AssistantContent -> Text
flattenAssistantText = T.concat . V.toList . V.mapMaybe textOf
  where
    textOf (AssistantText (TextContent t)) = Just t
    textOf _ = Nothing

-- | The 'Api' tag every stub serves. A 'Custom' tag needs no catalog entry.
stubApi :: Api
stubApi = Custom "stub"

-- | A hand-built 'Model' whose 'api' routes to the stub provider.
stubModel :: Model
stubModel =
  _Model
    & #api
    .~ stubApi
    & #modelId
    .~ "stub-model"
    & #name
    .~ "stub"
    & #provider
    .~ "stub"

-- | A minimal request context (one user turn).
stubContext :: Context
stubContext = _Context & #messages .~ V.singleton (user "ping")

-- | Default request options.
stubOptions :: Options
stubOptions = _Options

-- | An assistant payload carrying the given text as its single text block.
stubPayloadWith :: Text -> AssistantPayload
stubPayloadWith t =
  (_Response ^. #message)
    & #content
    .~ V.singleton (AssistantText (_TextContent & #text .~ t))

-- | A fixed assistant response carrying the given text as its single text block.
stubResponse :: Text -> Response
stubResponse t =
  _Response
    & #message
    .~ stubPayloadWith t
    & #model
    .~ stubModel
    & #api
    .~ stubApi
    & #provider
    .~ "stub"

-- | A deterministic, valid event sequence for the given text.
stubEvents :: Text -> [AssistantMessageEvent]
stubEvents t =
  [ EventStart StartPayload {partial = AssistantMessage (_Response ^. #message)},
    TextStart IndexPayload {contentIndex = 0},
    TextDelta DeltaPayload {contentIndex = 0, delta = t},
    TextEnd BlockEndPayload {contentIndex = 0, content = t},
    EventDone (doneTerminal Stop (AssistantMessage (stubPayloadWith t)))
  ]

-- | Build an isolated registry from a @complete@ implementation, reusing the
-- deterministic stub stream for the streaming path.
mkRegistry :: Text -> (Model -> Context -> Options -> IO Response) -> IO ProviderRegistry
mkRegistry streamText completeFn = do
  reg <- newProviderRegistry
  registerApiProviderWith
    reg
    ApiProvider
      { apiTag = stubApi,
        complete = completeFn,
        stream = \_ _ _ -> Stream.fromList (stubEvents streamText)
      }
  pure reg

-- | A registry whose @complete@ returns the given text.
stubRegistry :: Text -> IO ProviderRegistry
stubRegistry t = mkRegistry t (\_ _ _ -> pure (stubResponse t))

-- | A registry whose @complete@ returns the given text with a fixed dollar cost
-- recorded in @Usage.cost.usd@ (so the budget interpreter charges it).
costStubRegistry :: Rational -> Text -> IO ProviderRegistry
costStubRegistry c t =
  mkRegistry t (\_ _ _ -> pure (stubResponse t & #message . #usage . #cost . #usd .~ c))

-- | A registry whose @complete@ blocks until @n@ calls have all arrived (a shared
-- 'TVar' barrier), then returns a cost-carrying response. Guarantees that @n@
-- concurrent calls are all in flight — each already past the budget's optimistic
-- @admitCall@ gate — before any of them records its cost, so a test can pin the
-- documented budget overshoot under concurrency.
budgetBarrierStubRegistry :: TVar Int -> Int -> Rational -> Text -> IO ProviderRegistry
budgetBarrierStubRegistry arrived n cost t =
  mkRegistry t $ \_ _ _ -> do
    atomically (modifyTVar' arrived (+ 1))
    atomically $ do
      a <- readTVar arrived
      if a >= n then pure () else retry
    pure (stubResponse t & #message . #usage . #cost . #usd .~ cost)

-- | A registry whose @complete@ throws 'providerError' (a transient failure) the
-- first @failTimes@ calls, then returns the given text. The 'IORef' records the
-- total number of attempts (used by the retry tests).
failingStubRegistry :: IORef Int -> Int -> Text -> IO ProviderRegistry
failingStubRegistry ref failTimes t =
  mkRegistry t $ \_ _ _ -> do
    n <- atomicModifyIORef' ref (\k -> (k + 1, k + 1))
    if n <= failTimes
      then throwIO (providerError ("stub transient failure #" <> T.pack (show n)))
      else pure (stubResponse t)

-- | A terminal-failing event sequence: an 'EventError' whose assembled message
-- carries @errorMessage@ (and optionally a dollar cost). Shikumi's @LLM@
-- interpreters map this to a transient 'Shikumi.Error.ProviderFailure'.
streamErrorEvents :: Rational -> Text -> [AssistantMessageEvent]
streamErrorEvents cost msg =
  [ EventStart StartPayload {partial = AssistantMessage (_Response ^. #message)},
    EventError (doneTerminal ErrorReason (AssistantMessage errPayload))
  ]
  where
    errPayload =
      (_Response ^. #message)
        & #errorMessage
        .~ Just msg
        & #usage
        . #cost
        . #usd
        .~ cost

-- | A registry whose /stream/ fails (a terminal 'EventError') the first
-- @failTimes@ calls, then streams success. @complete@ is irrelevant (stream-only
-- tests). The 'IORef' records the total number of stream attempts, so a retry test
-- can assert the loop fired.
failingStreamStubRegistry :: IORef Int -> Int -> Text -> IO ProviderRegistry
failingStreamStubRegistry ref failTimes t = do
  reg <- newProviderRegistry
  registerApiProviderWith
    reg
    ApiProvider
      { apiTag = stubApi,
        complete = \_ _ _ -> pure (stubResponse t),
        stream = \_ _ _ -> Stream.concatEffect $ do
          n <- atomicModifyIORef' ref (\k -> (k + 1, k + 1))
          pure $
            Stream.fromList $
              if n <= failTimes
                then streamErrorEvents 0 ("stub stream failure #" <> T.pack (show n))
                else stubEvents t
      }
  pure reg

-- | A registry whose /stream/ always fails with a terminal 'EventError' carrying
-- the given dollar cost, so a test can assert the budget is charged even though the
-- stream failed.
failingStreamCostStubRegistry :: Rational -> IO ProviderRegistry
failingStreamCostStubRegistry cost = do
  reg <- newProviderRegistry
  registerApiProviderWith
    reg
    ApiProvider
      { apiTag = stubApi,
        complete = \_ _ _ -> pure (stubResponse ""),
        stream = \_ _ _ -> Stream.fromList (streamErrorEvents cost "stub stream failure")
      }
  pure reg

-- | A registry whose @complete@ always throws 'invalidRequest' (a non-transient
-- failure that maps to 'Shikumi.Error.SchemaMismatch'). The 'IORef' records the
-- number of attempts (a retry must not increase it).
invalidStubRegistry :: IORef Int -> IO ProviderRegistry
invalidStubRegistry ref =
  mkRegistry "" $ \_ _ _ -> do
    _ <- atomicModifyIORef' ref (\k -> (k + 1, k + 1))
    throwIO (invalidRequest "stub bad request")

-- | A registry whose @complete@ records observed concurrency: it bumps @cur@ on
-- entry (updating the running maximum in @mx@), sleeps briefly, and decrements on
-- exit. Used to assert that a rate limit caps in-flight calls.
concurrencyStubRegistry :: TVar Int -> TVar Int -> Text -> IO ProviderRegistry
concurrencyStubRegistry cur mx t =
  mkRegistry t $ \_ _ _ ->
    bracket_ enter leave (threadDelay 30000 >> pure (stubResponse t))
  where
    enter = atomically $ do
      modifyTVar' cur (+ 1)
      c <- readTVar cur
      modifyTVar' mx (max c)
    leave = atomically (modifyTVar' cur (subtract 1))
