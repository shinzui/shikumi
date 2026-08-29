-- | Shared fixtures for the EP-9 compiler tests: a minimal @Question -> Answer@
-- signature pair (plus an intermediate @Draft@ so a two-node pipeline can prove a
-- compiler reaches a nested node), the base programs every milestone rewrites, and
-- canned fallback-adapter 'Response's the capturing stub returns.
--
-- The record instances mirror @ProgramFixtures@ in the @shikumi@ test tree (which
-- lives there and is not importable here): each record derives 'Generic' and gets
-- empty 'ToSchema' / 'FromModel' / 'ToPrompt' / 'Validatable' bodies (Generic
-- defaults), plus 'ToJSON' / 'FromJSON' so 'Shikumi.Compile.fewShotTyped' can build
-- demos from typed pairs.
module Test.Fixtures
  ( -- * Records
    Question (..),
    Answer (..),
    Draft (..),

    -- * Base programs
    qaBase,
    qaPipeline,

    -- * Demo pool
    demoPairs,

    -- * Canned responses
    answerResponse,
    draftResponse,
    cotDraftResponse,
    cotAnswerResponse,
    markerBody,
    mkResponse,
  )
where

import Baikai
  ( AssistantContent (..),
    Response,
    emptyResponse,
    emptyTextContent,
  )
import Control.Lens ((&), (.~))
import Data.Aeson (FromJSON, ToJSON)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Module (predict)
import Shikumi.Program (Program, pipeline)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------

newtype Question = Question {question :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON, FromJSON, ToSchema, FromModel, ToPrompt, Validatable)

newtype Answer = Answer {answer :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON, FromJSON, ToSchema, FromModel, ToPrompt, Validatable)

newtype Draft = Draft {draft :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON, FromJSON, ToSchema, FromModel, ToPrompt, Validatable)

-- ---------------------------------------------------------------------------
-- Signatures and base programs
-- ---------------------------------------------------------------------------

qaSig :: Signature Question Answer
qaSig = mkSignature "Answer the question."

questionToDraft :: Signature Question Draft
questionToDraft = mkSignature "Draft an answer to the question."

draftToAnswer :: Signature Draft Answer
draftToAnswer = mkSignature "Finalize the answer from the draft."

-- | A single-node base program (demos line up exactly for the strong few-shot
-- assertion).
qaBase :: Program Question Answer
qaBase = predict qaSig

-- | A two-node base program: @Question -> Draft -> Answer@, so a compiler can be
-- shown to reach a node nested inside a 'Shikumi.Program.Compose'.
qaPipeline :: Program Question Answer
qaPipeline = pipeline (predict questionToDraft) (predict draftToAnswer)

-- | A small demo pool, as typed pairs (used via 'Shikumi.Compile.fewShotTyped').
-- The answer texts are distinctive so a prompt assertion is unambiguous.
demoPairs :: [(Question, Answer)]
demoPairs =
  [ (Question "what is two plus two", Answer "four"),
    (Question "capital of france", Answer "Paris"),
    (Question "color of the clear sky", Answer "blue")
  ]

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
  emptyResponse & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ t))

-- | Decodes as an @Answer@ under the fallback adapter.
answerResponse :: Response
answerResponse = mkResponse (markerBody [("answer", "forty-two")])

-- | Decodes as a @Draft@ under the fallback adapter.
draftResponse :: Response
draftResponse = mkResponse (markerBody [("draft", "a rough answer")])

-- | Decodes as a @WithReasoning Draft@ (the chain-of-thought augmented output):
-- the @value@ section carries the nested @Draft@ JSON object.
cotDraftResponse :: Response
cotDraftResponse =
  mkResponse (markerBody [("reasoning", "thinking about it"), ("value", "{\"draft\":\"a rough answer\"}")])

-- | Decodes as a @WithReasoning Answer@.
cotAnswerResponse :: Response
cotAnswerResponse =
  mkResponse (markerBody [("reasoning", "thinking about it"), ("value", "{\"answer\":\"forty-two\"}")])
