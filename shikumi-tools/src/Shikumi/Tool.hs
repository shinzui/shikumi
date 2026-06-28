{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Typed tools and their lowering to baikai's wire tool — the MasterPlan's
-- integration point #8, owned here and nowhere else.
--
-- A @'Tool' i o@ is a named function from an input record @i@ to an output @o@,
-- runnable in any effect stack that has the @LLM@ and @Error ShikumiError@
-- capabilities (so a tool body may itself call sub-models and may signal failure
-- through the typed error channel — see the plan's Decision Log on why the row is
-- @(LLM, Error ShikumiError)@ rather than @IOE@). From a tool shikumi derives the
-- JSON Schema of @i@ (reusing 'Shikumi.Schema'), lowers it to baikai's untyped
-- @Baikai.Tool { name, description, parameters }@, decodes the model's argument
-- JSON into a typed @i@ (or a 'ToolError', never a crash), runs the body, and
-- encodes the @o@ result back to observation text.
--
-- Heterogeneity is handled by the 'SomeTool' existential: it hides @i@/@o@ while
-- retaining, at wrap time, the schema/decode/encode dictionaries the wire boundary
-- needs. A 'ToolRegistry' is a name-keyed map of 'SomeTool's that a ReAct loop
-- dispatches against by the tool name the model emits at run time.
module Shikumi.Tool
  ( -- * Typed tools
    Tool (..),
    mkTool,
    toolSchemaOf,
    lowerTool,

    -- * Heterogeneous tools and the registry
    SomeTool (..),
    someToolName,
    someToolDescription,
    someToolSchema,
    lowerSomeTool,
    runErased,
    ToolRegistry,
    mkRegistry,
    registryLookup,
    registryBaikai,
    registryNames,
    registryTools,

    -- * The typed error and the wire round-trip
    ToolError (..),
    renderToolError,
    runToolCall,
  )
where

import Baikai (ToolCall, _Tool)
import Baikai qualified as B
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (ToJSON, Value, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Data.Vector (Vector)
import Data.Vector qualified as V
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, catchError)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM)
import Shikumi.Schema (FromModel, ToSchema, Validatable, fromModelChecked, toSchema)

-- ---------------------------------------------------------------------------
-- The typed tool
-- ---------------------------------------------------------------------------

-- | A typed tool: a named function from an input record @i@ to an output @o@. The
-- body is rank-2 over the effect row so the same value can run in any stack that
-- has @LLM@ and @Error ShikumiError@ — the exact row 'Shikumi.Program.runProgram'
-- provides, which is what lets a ReAct agent (built on the @Embed@ program node)
-- execute its tools without widening that row.
data Tool i o = Tool
  { name :: !Text,
    description :: !Text,
    run :: !(forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o)
  }

-- | Build a tool from a name, a description, and an effectful body. A pure tool is
-- just @\\i -> pure (f i)@. The schema/decode/encode dictionaries are not needed
-- here — they are captured later, at 'SomeTool' wrap time.
mkTool ::
  Text ->
  Text ->
  (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) ->
  Tool i o
mkTool = Tool

-- | The JSON Schema of a tool's input record, derived from @i@.
toolSchemaOf :: forall i o. (ToSchema i) => Tool i o -> Value
toolSchemaOf _ = toSchema (Proxy @i)

-- | Lower a typed tool to baikai's untyped wire tool, putting the derived input
-- schema into @parameters@. This is the single sanctioned typed -> wire lowering.
lowerTool :: forall i o. (ToSchema i) => Tool i o -> B.Tool
lowerTool t =
  _Tool
    & #name .~ name t
    & #description .~ description t
    & #parameters .~ toolSchemaOf t

-- ---------------------------------------------------------------------------
-- The existential and the registry
-- ---------------------------------------------------------------------------

-- | A tool with its @i@/@o@ hidden, retaining the dictionaries needed to (a)
-- derive its input schema, (b) decode arguments from JSON into @i@, and (c) encode
-- its @o@ result to text — all captured at wrap time.
data SomeTool where
  SomeTool ::
    (ToSchema i, FromModel i, Validatable i, ToJSON o) =>
    Tool i o ->
    SomeTool

-- | The name of an erased tool.
someToolName :: SomeTool -> Text
someToolName (SomeTool t) = name t

-- | The description of an erased tool.
someToolDescription :: SomeTool -> Text
someToolDescription (SomeTool t) = description t

-- | The derived input JSON Schema of an erased tool.
someToolSchema :: SomeTool -> Value
someToolSchema (SomeTool t) = toolSchemaOf t

-- | Lower an erased tool to baikai's wire tool.
lowerSomeTool :: SomeTool -> B.Tool
lowerSomeTool (SomeTool t) = lowerTool t

-- | Run an erased tool against a raw JSON arguments object: decode to the hidden
-- @i@, run the body, encode the @o@ to text. Total: a decode failure becomes
-- 'ToolArgsInvalid' and a body that throws a 'ShikumiError' becomes 'ToolRunFailed'
-- — it never throws to the caller.
runErased ::
  (LLM :> es, Error ShikumiError :> es) =>
  SomeTool ->
  Value ->
  Eff es (Either ToolError Text)
runErased (SomeTool t) args =
  case fromModelChecked args of
    Left err -> pure (Left (ToolArgsInvalid (name t) (shikumiErrorText err)))
    Right i ->
      (Right . encodeText <$> run t i)
        `catchError` \_cs e -> pure (Left (ToolRunFailed (name t) (shikumiErrorText e)))

-- | A heterogeneous tool set, keyed by tool name for O(log n) dispatch.
newtype ToolRegistry = ToolRegistry (Map Text SomeTool)

-- | Build a registry from a list of erased tools (last wins on a name clash).
mkRegistry :: [SomeTool] -> ToolRegistry
mkRegistry = ToolRegistry . Map.fromList . map (\st -> (someToolName st, st))

-- | Look a tool up by the name the model emitted.
registryLookup :: Text -> ToolRegistry -> Maybe SomeTool
registryLookup nm (ToolRegistry m) = Map.lookup nm m

-- | Every tool lowered to baikai's wire form, for @Context.tools@.
registryBaikai :: ToolRegistry -> Vector B.Tool
registryBaikai (ToolRegistry m) = V.fromList (map lowerSomeTool (Map.elems m))

-- | The names of the registered tools (the tool menu).
registryNames :: ToolRegistry -> [Text]
registryNames (ToolRegistry m) = Map.keys m

-- | The erased tools, in name order.
registryTools :: ToolRegistry -> [SomeTool]
registryTools (ToolRegistry m) = Map.elems m

-- ---------------------------------------------------------------------------
-- The typed error and the wire round-trip
-- ---------------------------------------------------------------------------

-- | A tool-call failure carried as a /value/, never an exception. The agent feeds
-- the rendered text back to the model as an observation so it can recover, and
-- records it in the trajectory; only infrastructure faults bubble up as a
-- 'ShikumiError'.
data ToolError
  = -- | the model named a tool the registry does not have
    ToolNotFound !Text
  | -- | tool name, decode-error message: the arguments did not match @i@
    ToolArgsInvalid !Text !Text
  | -- | tool name, failure message: the body signalled a 'ShikumiError'
    ToolRunFailed !Text !Text
  deriving stock (Show, Eq)

-- | Render a 'ToolError' as the observation text fed back to the model.
renderToolError :: ToolError -> Text
renderToolError = \case
  ToolNotFound nm -> "Error: no such tool \"" <> nm <> "\"."
  ToolArgsInvalid nm msg -> "Error: invalid arguments for \"" <> nm <> "\": " <> msg
  ToolRunFailed nm msg -> "Error: tool \"" <> nm <> "\" failed: " <> msg

-- | Find the named tool, decode, run, encode. The entry point the ReAct loop uses.
runToolCall ::
  (LLM :> es, Error ShikumiError :> es) =>
  ToolRegistry ->
  ToolCall ->
  Eff es (Either ToolError Text)
runToolCall reg tc =
  case registryLookup (tc ^. #name) reg of
    Nothing -> pure (Left (ToolNotFound (tc ^. #name)))
    Just st -> runErased st (tc ^. #arguments)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Compact-encode a JSON-serializable result to text for an observation.
encodeText :: (ToJSON a) => a -> Text
encodeText = decodeUtf8 . LBS.toStrict . encode

-- | The human-readable payload of a 'ShikumiError' (its single 'Text' field).
shikumiErrorText :: ShikumiError -> Text
shikumiErrorText = \case
  InvalidJSON t -> t
  MissingField t -> "missing field " <> t
  SchemaMismatch t -> t
  ValidationFailure t -> t
  ProviderFailure t -> t
  ContextWindowExceeded t -> t
  Timeout t -> t
  BudgetExceeded t -> t
