{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The two foundational /modules/ of shikumi (EP-4): @predict@ and
-- @chainOfThought@. These are ordinary functions that build 'Program' values out
-- of the three core constructors — not new constructors. This is the pattern the
-- combinators in @docs/plans/5-module-combinators-and-control-flow.md@ follow.
--
-- @chainOfThought@ extends the output signature with a leading @reasoning@ field
-- (DSPy's @ChainOfThought@), producing a @Program i (WithReasoning o)@, then
-- projects the reasoning back out with 'FMap' so the caller's program type stays
-- @Program i o@. The reasoning-augmented node is a perfectly ordinary 'Predict'
-- node, so its instruction and demos are visible to @paramsTraversal@ like any
-- other node — the optimizer tunes a chain-of-thought node with no special casing.
--
-- @WithReasoning@'s schema/decode/prompt instances are hand-written rather than
-- @Generic@-derived: its @value@ field is polymorphic in @o@, and the schema
-- classes' overlappable per-field instances cannot be resolved for an abstract
-- type variable. EP-3 exposes no @withReasoningField@, so the (nested) augmentation
-- lives here. See the plan's Decision Log.
module Shikumi.Module
  ( predict,
    chainOfThought,
    chainOfThoughtRaw,
    twoStep,
    WithReasoning (..),
  )
where

import Baikai (emptyContext, emptyModel, emptyOptions, user)
import Control.Lens ((&), (.~))
import Data.Aeson (Object, Value (Object))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful.Error.Static (throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter (Adapter (..), ToPrompt (..), fallbackAdapter, responseText)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (complete)
import Shikumi.Program (Program (FMap, Predict), embed, emptyParams)
import Shikumi.Schema (FromModel (..), ToSchema (..), Validatable (..))
import Shikumi.Schema.Types
  ( FieldMeta (..),
    FieldPath,
    objectSchema,
    pushField,
    renderPath,
    stringSchema,
    withDescription,
  )
import Shikumi.Signature (Signature (..), getInstruction)

-- | The basic predictor over a signature: a single 'Predict' node with default
-- (empty) parameters — no instruction override, no demos. The constraints are
-- exactly those the 'Predict' constructor captures.
predict ::
  (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o) =>
  Signature i o ->
  Program i o
predict sig = Predict sig emptyParams

-- ---------------------------------------------------------------------------
-- Chain of thought
-- ---------------------------------------------------------------------------

-- | An output @o@ wrapped with a leading step-by-step @reasoning@ field. The model
-- emits its reasoning first, then the structured answer nested under @value@ (the
-- order matters: reason, then commit).
data WithReasoning o = WithReasoning
  { reasoning :: !Text,
    value :: !o
  }
  deriving stock (Eq, Show, Generic)

-- A nested object schema: @{reasoning : string, value : <o's schema>}@.
instance (ToSchema o) => ToSchema (WithReasoning o) where
  toSchema _ =
    objectSchema
      [ ("reasoning", withDescription "Step-by-step reasoning, written before the answer" stringSchema),
        ("value", toSchema (Proxy @o))
      ]
      ["reasoning", "value"]

instance (FromModel o) => FromModel (WithReasoning o) where
  fromModelP path = \case
    Object o ->
      WithReasoning
        <$> getField path "reasoning" o
        <*> getField path "value" o
    _ -> Left (SchemaMismatch (renderPath path <> ": expected object"))

-- Render without leaning on @o@'s @Show@: reuse @o@'s own 'ToPrompt'.
instance (ToPrompt o) => ToPrompt (WithReasoning o) where
  toPromptFields wr = ("reasoning", reasoning wr) : toPromptFields (value wr)

  -- @value@ is polymorphic in @o@, so the generic image walk cannot resolve; a
  -- 'WithReasoning' is a text-only output wrapper and carries no image fields.
  imageFields _ = []
  imageFieldNames _ = []

-- | Validation delegates to the wrapped value; the free-form @reasoning@ text
-- carries no user rules.
instance (Validatable o) => Validatable (WithReasoning o) where
  validate wr = (\v -> wr {value = v}) <$> validate (value wr)

-- | Look up a required field in a JSON object, locating a miss precisely.
getField :: (FromModel a) => FieldPath -> Text -> Object -> Either ShikumiError a
getField path nm o = case KM.lookup (Key.fromText nm) o of
  Nothing -> Left (MissingField (renderPath (pushField nm path)))
  Just v -> fromModelP (pushField nm path) v

-- | Chain-of-thought that yields the bare @o@: build the reasoning-augmented node,
-- then 'FMap' out the answer. The user's @Validatable o@ rule fires on the
-- unwrapped answer via the delegating @Validatable (WithReasoning o)@ instance.
chainOfThought ::
  (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o) =>
  Signature i o ->
  Program i o
chainOfThought sig = FMap value (chainOfThoughtRaw sig)

-- | Chain-of-thought that keeps the reasoning visible in the output.
chainOfThoughtRaw ::
  (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o) =>
  Signature i o ->
  Program i (WithReasoning o)
chainOfThoughtRaw sig = Predict (withReasoningField sig) emptyParams

-- | Augment a signature's output with a leading @reasoning@ field and amend its
-- instruction to ask for step-by-step reasoning before the answer. The input
-- field metadata is carried over from the source signature; the output metadata is
-- the two fields of 'WithReasoning' (matching its hand-written schema).
--
-- Note: signature-level demos are /not/ carried onto the reasoning-augmented
-- node (@demos = []@), because a @Demo i o@ cannot be turned into a
-- @Demo i (WithReasoning o)@ without inventing reasoning text — and a fabricated
-- or empty reasoning string would teach the model to skip reasoning, defeating
-- the module's purpose. Demos supplied through the node's optimizer @Params@
-- channel are unaffected: they are stored as JSON and decoded against
-- @WithReasoning o@, so they already include a @reasoning@ field.
withReasoningField :: Signature i o -> Signature i (WithReasoning o)
withReasoningField sig =
  Signature
    { instruction =
        getInstruction sig
          <> "\n\nThink step by step. First write your reasoning, then the answer.",
      demos = [],
      inputFields = inputFields sig,
      outputFields =
        [ FieldMeta {fieldName = "reasoning", fieldDesc = Just "step-by-step reasoning"},
          FieldMeta {fieldName = "value", fieldDesc = Nothing}
        ]
    }

-- ---------------------------------------------------------------------------
-- Two-step extraction (EP-26)
-- ---------------------------------------------------------------------------

-- | A tiny internal input record holding a free-form answer, fed to the
-- extraction call. Not exported.
newtype ExtractIn = ExtractIn {text :: Text}
  deriving stock (Generic, Show)

instance ToPrompt ExtractIn

-- | A two-call adapter expressed as a program combinator: ask the main model for a
-- free-form answer (plain prose, no JSON/marker shape requested), then ask an
-- extraction model to coerce that prose into the typed output @o@. Useful for
-- strong reasoners that are weak at structured output.
--
-- It is an 'Shikumi.Program.embed' node, not an @Adapter@ value: an @Adapter@'s
-- @parse@ is pure (@Response -> Either ShikumiError o@) and cannot issue the second
-- model call, whereas an embedded body runs in 'Shikumi.Program.runProgram'\'s
-- effect row and can. Because it carries no 'Shikumi.Program.Params', the
-- parameter-count invariant (count == number of 'Predict' nodes) holds and the
-- serializers/compilers pass it through unchanged.
--
-- Known limitation (matching DSPy's @TwoStepAdapter@): both calls go to the same
-- ambient model under 'Shikumi.Program.runProgram'. A separate, smaller extraction
-- model would be wired by running the extraction under a different interpreter;
-- that is out of scope here.
twoStep ::
  (FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o) =>
  Signature i o ->
  Program i o
twoStep sig = embed $ \i -> do
  -- 1. Free-form call: plain prose, no structured shape requested.
  let ffCtx =
        emptyContext
          & #systemPrompt .~ Just (freeFormSystem sig)
          & #messages .~ V.fromList [user (toPrompt i)]
  ffResp <- complete emptyModel ffCtx emptyOptions
  -- 2. Extraction call: coerce the prose into the typed output via the marker
  --    fallback adapter (a robust extraction target that already round-trips).
  let exSig = extractSig sig
      (exCtx, exOpts) = render fallbackAdapter exSig (ExtractIn (responseText ffResp))
  exResp <- complete emptyModel exCtx exOpts
  either throwError pure (parse fallbackAdapter exSig exResp)

-- | The plain-prose system prompt for the free-form call (mirrors DSPy's
-- @TwoStepAdapter.format_task_description@): the instruction, the input/output
-- fields named in words, and a request to answer in detail.
freeFormSystem :: Signature i o -> Text
freeFormSystem sig =
  "You are a helpful assistant. "
    <> getInstruction sig
    <> "\n\nAs input you will be provided with: "
    <> namesOf (inputFields sig)
    <> ".\nYour answer must contain: "
    <> namesOf (outputFields sig)
    <> ".\nLay out your answer in detail, in plain prose."
  where
    namesOf = T.intercalate ", " . map fieldName

-- | The extraction signature @ExtractIn -> o@: a single @text@ input holding the
-- free-form answer, reusing the original signature's output-field metadata (so it
-- needs no @GFieldMetas (Rep o)@ constraint).
extractSig :: Signature i o -> Signature ExtractIn o
extractSig sig =
  Signature
    { instruction = "The text below contains the answer. Extract these fields verbatim.",
      demos = [],
      inputFields = [FieldMeta {fieldName = "text", fieldDesc = Nothing}],
      outputFields = outputFields sig
    }
