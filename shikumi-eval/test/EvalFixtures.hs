-- | Shared, network-free fixtures for the @evaluate@ / golden specs: a
-- @Question -> Answer@ signature and program, canned fallback-adapter responses,
-- and two mock @LLM@ interpreters — a constant one that returns a fixed response
-- for every call (order-independent, used for the aggregate-score acceptance) and
-- a scripted one that pops replies in order and can inject a typed failure (used
-- for the failure-policy cases under @concurrency = 1@).
module EvalFixtures
  ( -- * Records
    Question (..),
    Answer (..),

    -- * Signature and program
    qaSig,
    qaProg,

    -- * Canned responses
    answerResponse,
    markerResponse,

    -- * Mock LLM interpreters
    MockReply (..),
    runConstLLM,
    runScriptedLLM,
  )
where

import Baikai (AssistantContent (..), Response, _Response, _TextContent)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, type (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..))
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------

newtype Question = Question {question :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Question

instance FromModel Question

instance ToPrompt Question

instance Validatable Question

newtype Answer = Answer {answer :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Answer

instance FromModel Answer

instance ToPrompt Answer

instance Validatable Answer

-- ---------------------------------------------------------------------------
-- Signature and program
-- ---------------------------------------------------------------------------

qaSig :: Signature Question Answer
qaSig = mkSignature "Answer the question."

-- | The simplest program: a single predict node. Its behaviour is fully
-- determined by the mock LLM the test wires underneath it.
qaProg :: Program Question Answer
qaProg = predict qaSig

-- ---------------------------------------------------------------------------
-- Canned responses (rendered as the fallback adapter's [[ ## field ## ]] form)
-- ---------------------------------------------------------------------------

-- | An assistant 'Response' whose body decodes (via the fallback adapter) to
-- @Answer t@.
answerResponse :: Text -> Response
answerResponse t = mkResponse (markerBody [("answer", t)])

-- | An assistant 'Response' whose body decodes (via the fallback adapter) to a
-- record with the given @(field, value)@ sections.
markerResponse :: [(Text, Text)] -> Response
markerResponse = mkResponse . markerBody

-- | Build a fallback-style response body from @(field, value)@ sections.
markerBody :: [(Text, Text)] -> Text
markerBody fields = T.unlines (concatMap sect fields ++ ["[[ ## completed ## ]]"])
  where
    sect (k, v) = ["[[ ## " <> k <> " ## ]]", v]

-- | An assistant 'Response' carrying @t@ as its single text block.
mkResponse :: Text -> Response
mkResponse t =
  _Response & #message . #content .~ V.singleton (AssistantText (_TextContent & #text .~ t))

-- ---------------------------------------------------------------------------
-- Mock LLM interpreters
-- ---------------------------------------------------------------------------

-- | One scripted reply: a canned success or a typed failure.
data MockReply
  = MockOk Response
  | MockFail ShikumiError

-- | Return @resp@ for every completion, ignoring the request. Order-independent,
-- so it is safe under any concurrency.
runConstLLM :: Response -> Eff (LLM : es) a -> Eff es a
runConstLLM resp = interpret $ \_ -> \case
  Complete {} -> pure resp
  Stream {} -> pure []

-- | Pop scripted replies in order; a 'MockFail' is thrown through
-- @Error ShikumiError@. Deterministic only under @concurrency = 1@.
runScriptedLLM ::
  (IOE :> es, Error ShikumiError :> es) =>
  [MockReply] ->
  Eff (LLM : es) a ->
  Eff es a
runScriptedLLM replies act = do
  ref <- liftIO (newIORef replies)
  interpret
    ( \_ -> \case
        Complete {} -> do
          r <- liftIO (atomicModifyIORef' ref pop)
          case r of
            MockOk resp -> pure resp
            MockFail e -> throwError e
        Stream {} -> pure []
    )
    act
  where
    pop (x : xs) = (xs, x)
    pop [] = ([], MockFail (ProviderFailure "mock: script exhausted"))
