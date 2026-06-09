-- | Shared fixtures for the EP-4 program specs: three record-typed signatures
-- (@Topic -> Outline -> Draft@) plus a self-looping @Cell -> Cell@ used to build
-- arbitrarily long pipelines for the ordering-law property; and two network-free
-- 'LLM' interpreters — a /scripted/ one that pops canned responses in order, and a
-- /recording/ one that also captures each rendered request's system prompt so a
-- test can assert what the program actually sent on the wire.
module ProgramFixtures
  ( -- * Records
    Topic (..),
    Outline (..),
    Draft (..),
    Cell (..),

    -- * Signatures
    topicToOutline,
    outlineToDraft,
    cellSig,

    -- * Canned responses
    mkResponse,
    outlineResponse,
    draftResponse,
    cellResponse,
    markerBody,

    -- * Fake LLM interpreters
    runScriptedLLM,
    runRecordingLLM,
  )
where

import Baikai
  ( AssistantContent (..),
    Context,
    Response,
    _Response,
    _TextContent,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', modifyIORef')
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, type (:>))
import Effectful.Dispatch.Dynamic (interpret)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.LLM (LLM (..))
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)

-- ---------------------------------------------------------------------------
-- Records (plain fields — no Field wrappers needed for these tests)
-- ---------------------------------------------------------------------------

newtype Topic = Topic {subject :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Topic

instance FromModel Topic

instance ToPrompt Topic

instance Validatable Topic

newtype Outline = Outline {points :: [Text]}
  deriving stock (Generic, Show, Eq)

instance ToSchema Outline

instance FromModel Outline

instance ToPrompt Outline

instance Validatable Outline

newtype Draft = Draft {prose :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Draft

instance FromModel Draft

instance ToPrompt Draft

instance Validatable Draft

-- | A self-looping record, so @predict cellSig :: Program Cell Cell@ can be
-- composed with itself to make an N-node pipeline.
newtype Cell = Cell {cell :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Cell

instance FromModel Cell

instance ToPrompt Cell

instance Validatable Cell

-- ---------------------------------------------------------------------------
-- Signatures
-- ---------------------------------------------------------------------------

topicToOutline :: Signature Topic Outline
topicToOutline = mkSignature "Outline the topic into points"

outlineToDraft :: Signature Outline Draft
outlineToDraft = mkSignature "Draft prose from the outline"

cellSig :: Signature Cell Cell
cellSig = mkSignature "Echo the cell"

-- ---------------------------------------------------------------------------
-- Canned responses (rendered as the fallback adapter's [[ ## field ## ]] sections)
-- ---------------------------------------------------------------------------

-- | Build a fallback-style response body from @(field, value)@ sections, closing
-- with the @completed@ marker.
markerBody :: [(Text, Text)] -> Text
markerBody fields = T.unlines (concatMap sect fields ++ ["[[ ## completed ## ]]"])
  where
    sect (k, v) = ["[[ ## " <> k <> " ## ]]", v]

-- | An assistant 'Response' carrying @t@ as its single text block.
mkResponse :: Text -> Response
mkResponse t =
  _Response & #message . #content .~ V.singleton (AssistantText (_TextContent & #text .~ t))

outlineResponse :: Response
outlineResponse = mkResponse (markerBody [("points", "[\"intro\", \"body\", \"end\"]")])

draftResponse :: Response
draftResponse = mkResponse (markerBody [("prose", "A fine essay about the outline.")])

-- | Echo a fixed cell value (used by the @Cell -> Cell@ pipelines).
cellResponse :: Response
cellResponse = mkResponse (markerBody [("cell", "echoed")])

-- ---------------------------------------------------------------------------
-- Fake LLM interpreters
-- ---------------------------------------------------------------------------

-- | Pop the next scripted 'Response' for each 'Complete'; an exhausted queue
-- yields an empty response (tests script enough). Ignores the request.
runScriptedLLM :: (IOE :> es) => IORef [Response] -> Eff (LLM : es) a -> Eff es a
runScriptedLLM ref = interpret $ \_ -> \case
  Complete _ _ _ -> liftIO (pop ref)
  Stream _ _ _ -> pure []

-- | Like 'runScriptedLLM', but also append each request's rendered /system prompt/
-- to @capture@, so a test can assert on what the program actually sent.
runRecordingLLM ::
  (IOE :> es) =>
  IORef [Text] ->
  IORef [Response] ->
  Eff (LLM : es) a ->
  Eff es a
runRecordingLLM capture ref = interpret $ \_ -> \case
  Complete _ ctx _ -> do
    liftIO (modifyIORef' capture (++ [renderedPrompt ctx]))
    liftIO (pop ref)
  Stream _ _ _ -> pure []

-- | What we capture from a request: its system prompt (where the instruction and
-- output guide live).
renderedPrompt :: Context -> Text
renderedPrompt ctx = fromMaybe "" (ctx ^. #systemPrompt)

pop :: IORef [Response] -> IO Response
pop ref = atomicModifyIORef' ref step
  where
    step (x : xs) = (xs, x)
    step [] = ([], mkResponse (markerBody []))
