-- | Deliberately NON-trivial shared fixtures. The production-readiness review
-- found every suite's fixtures sit in bug blind spots: optimizer signatures
-- with empty instructions, output types whose 'Validatable' never fails,
-- single-node-only programs, @TempFixed [0.0]@ schedules, and @**/@-only glob
-- patterns. These fixtures occupy exactly those spots so any package can
-- regression-test against them. The bug-exposing tests that consume them are
-- owned by docs/plans/32-fix-validatable-dispatch-in-program-runners.md and
-- docs/plans/36-fix-optimizer-instruction-seeding.md; the fixture SHAPES are
-- owned here — extend, don't fork.
module Shikumi.Testing.Fixtures
  ( -- * Task records
    Question (..),
    Draft (..),
    Answer (..),

    -- * Signatures and programs (instructions are non-empty)
    instructedSig,
    draftSig,
    reviseSig,
    instructedProg,
    twoStageProg,

    -- * Responders and responses
    twoStageResponder,
    validAnswerResponse,
    invalidAnswerResponse,

    -- * Diversified parameter fixtures
    diverseTemps,
    diverseGlobPatterns,
  )
where

import Baikai (Context, Response)
import Data.Aeson (ToJSON)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Combinator (TempSchedule (..), (>>>))
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable (..))
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Testing.Response (markerResponse)
import Shikumi.Testing.StubLLM (systemContains)

-- | The fixture input: a question to answer.
newtype Question = Question {question :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

instance ToSchema Question

instance FromModel Question

instance ToPrompt Question

instance Validatable Question

-- | The two-stage pipeline's intermediate value: a draft answer.
newtype Draft = Draft {draft :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

instance ToSchema Draft

instance FromModel Draft

instance ToPrompt Draft

instance Validatable Draft

-- | The fixture output. Unlike every pre-existing fixture, its 'Validatable'
-- rule can FAIL: decodes with an empty answer or a confidence outside [0,1]
-- are rejected, so tests can prove validation is (or is not) being dispatched.
data Answer = Answer
  { answer :: Text,
    confidence :: Double
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

instance ToSchema Answer

instance FromModel Answer

instance ToPrompt Answer

instance Validatable Answer where
  validate a@Answer {answer = ans, confidence = conf}
    | T.null (T.strip ans) = Left "answer must be non-empty"
    | conf < 0 || conf > 1 = Left "confidence must be within [0,1]"
    | otherwise = Right a

-- | A single-node signature whose instruction is NOT empty — the shape
-- instruction-seeding tests need (contrast @sentimentSig = mkSignature \"\"@ in
-- shikumi-optimize/test/StubLM.hs).
instructedSig :: Signature Question Answer
instructedSig =
  mkSignature "Answer the question in one short sentence and report a confidence between 0 and 1."

-- | Stage one of the two-stage program.
draftSig :: Signature Question Draft
draftSig = mkSignature "Draft a short answer to the question."

-- | Stage two of the two-stage program.
reviseSig :: Signature Draft Answer
reviseSig = mkSignature "Revise the draft into a final answer with a confidence between 0 and 1."

-- | The single-node program over 'instructedSig'.
instructedProg :: Program Question Answer
instructedProg = predict instructedSig

-- | A multi-node, two-stage program: draft, then revise. Composed with EP-5's
-- @(>>>)@, so node-indexed behavior (tracing, optimization, validation) has
-- more than one node to get wrong.
twoStageProg :: Program Question Answer
twoStageProg = predict draftSig >>> predict reviseSig

-- | Answers each stage of 'twoStageProg' differently, keyed on the stage
-- instruction rendered into the system prompt.
twoStageResponder :: Context -> Response
twoStageResponder ctx
  | systemContains "Draft a short answer" ctx = markerResponse [("draft", "It is forty-two.")]
  | otherwise = validAnswerResponse

-- | Decodes to an 'Answer' that passes 'validate'.
validAnswerResponse :: Response
validAnswerResponse = markerResponse [("answer", "It is forty-two."), ("confidence", "0.9")]

-- | Decodes structurally to an 'Answer' whose confidence 1.5 must be REJECTED
-- by 'validate' — the probe for validation dispatch.
invalidAnswerResponse :: Response
invalidAnswerResponse = markerResponse [("answer", "It is forty-two."), ("confidence", "1.5")]

-- | A temperature schedule with distinct, non-zero temperatures (contrast the
-- @TempFixed [0.0]@ / @TempFixed []@ the existing vote tests use).
diverseTemps :: TempSchedule
diverseTemps = TempFixed [0.0, 0.3, 0.9]

-- | Glob patterns beyond the @**/@-prefixed shape the existing glob tests use.
diverseGlobPatterns :: [Text]
diverseGlobPatterns = ["*.txt", "src/**/*.hs", "docs/*.md", "README.*", "**/*.yaml"]
