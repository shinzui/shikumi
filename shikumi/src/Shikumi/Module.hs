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
    WithReasoning (..),
  )
where

import Data.Aeson (Object, Value (Object))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt (..))
import Shikumi.Error (ShikumiError (..))
import Shikumi.Program (Program (FMap, Predict), emptyParams)
import Shikumi.Schema (FromModel (..), ToSchema (..), Validatable)
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

-- | Look up a required field in a JSON object, locating a miss precisely.
getField :: (FromModel a) => FieldPath -> Text -> Object -> Either ShikumiError a
getField path nm o = case KM.lookup (Key.fromText nm) o of
  Nothing -> Left (MissingField (renderPath (pushField nm path)))
  Just v -> fromModelP (pushField nm path) v

-- | Chain-of-thought that yields the bare @o@: build the reasoning-augmented node,
-- then 'FMap' out the answer.
chainOfThought ::
  (FromModel i, FromModel o, ToSchema o, ToPrompt i, ToPrompt o) =>
  Signature i o ->
  Program i o
chainOfThought sig = FMap value (chainOfThoughtRaw sig)

-- | Chain-of-thought that keeps the reasoning visible in the output.
chainOfThoughtRaw ::
  (FromModel i, FromModel o, ToSchema o, ToPrompt i, ToPrompt o) =>
  Signature i o ->
  Program i (WithReasoning o)
chainOfThoughtRaw sig = Predict (withReasoningField sig) emptyParams

-- | Augment a signature's output with a leading @reasoning@ field and amend its
-- instruction to ask for step-by-step reasoning before the answer. The input
-- field metadata is carried over from the source signature; the output metadata is
-- the two fields of 'WithReasoning' (matching its hand-written schema).
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
