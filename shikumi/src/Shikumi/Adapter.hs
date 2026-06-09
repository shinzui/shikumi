{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}

-- | The 'Adapter' seam between a typed 'Signature' + input and the wire.
-- @render@ builds a baikai @Context@+@Options@; @parse@ decodes a baikai
-- @Response@ into the typed output via "Shikumi.Schema".
--
-- Two adapters ship. The native-schema adapter is the reliable path (the provider
-- enforces the JSON schema); the prompt-based fallback renders @[[ ## field ## ]]@
-- sections and re-parses them, for models without native structured output.
-- 'capabilityFor' selects per model.
--
-- Note on EP-2: baikai's @Options@ does not yet carry a @responseFormat@ field
-- (that is delivered by EP-2). Until it lands, 'attachSchema' is a no-op and the
-- native adapter reads the JSON from the assistant text. Exactly one place
-- ('attachSchema') touches the future baikai field.
module Shikumi.Adapter
  ( -- * Input rendering
    ToPrompt (..),

    -- * The seam
    Adapter (..),
    ModelCapability (..),
    capabilityFor,
    nativeAdapter,
    fallbackAdapter,
    adapterFor,
    attachSchema,
  )
where

import Baikai
  ( Api (..),
    AssistantContent (..),
    Context,
    Message,
    Model,
    Options,
    Response,
    TextContent (..),
    assistant,
    flattenAssistantBlocks,
    user,
    _Context,
    _Options,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Object, Value (..), eitherDecodeStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.Kind (Type)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Vector qualified as V
import GHC.Generics
import Shikumi.Error (ShikumiError (..))
import Shikumi.Schema (FromModel, ToSchema, Validatable, deriveSchema, fromModelChecked)
import Shikumi.Schema.Types (FieldMeta (..))
import Shikumi.Signature (Demo (..), Signature, getDemos, getInstruction, outputFields)

-- ---------------------------------------------------------------------------
-- ToPrompt: render an input record (and demo outputs) as labeled text
-- ---------------------------------------------------------------------------

-- | Render a record as labeled text for the prompt. 'toPromptFields' yields the
-- @(fieldName, valueText)@ pairs; 'toPrompt' joins them as @"name: value"@ lines.
class ToPrompt a where
  toPromptFields :: a -> [(Text, Text)]
  default toPromptFields :: (Generic a, GToPromptFields (Rep a)) => a -> [(Text, Text)]
  toPromptFields = gToPromptFields . from

  toPrompt :: a -> Text
  toPrompt = T.intercalate "\n" . map (\(k, v) -> k <> ": " <> v) . toPromptFields

class GToPromptFields (f :: Type -> Type) where
  gToPromptFields :: f p -> [(Text, Text)]

instance (GToPromptFields cs) => GToPromptFields (D1 d cs) where
  gToPromptFields (M1 x) = gToPromptFields x

instance (GToPromptFields cs) => GToPromptFields (C1 c cs) where
  gToPromptFields (M1 x) = gToPromptFields x

instance (GToPromptFields a, GToPromptFields b) => GToPromptFields (a :*: b) where
  gToPromptFields (a :*: b) = gToPromptFields a ++ gToPromptFields b

instance (Selector s, PromptValue t) => GToPromptFields (S1 s (K1 R t)) where
  gToPromptFields m@(M1 (K1 v)) = [(T.pack (selName m), promptValue v)]

-- | Render a leaf value to text. Text stays as-is; lists join with commas;
-- 'Maybe' renders its contents or @""@; a 'Shikumi.Schema.Types.Field' unwraps;
-- everything else falls back to 'Show'.
class PromptValue a where
  promptValue :: a -> Text

instance {-# OVERLAPPABLE #-} (Show a) => PromptValue a where
  promptValue = T.pack . show

instance PromptValue Text where
  promptValue = id

instance (PromptValue a) => PromptValue [a] where
  promptValue = T.intercalate ", " . map promptValue

instance (PromptValue a) => PromptValue (Maybe a) where
  promptValue = maybe "" promptValue

-- ---------------------------------------------------------------------------
-- The seam
-- ---------------------------------------------------------------------------

-- | A record of two functions: format a request, parse a response.
data Adapter i o = Adapter
  { render :: Signature i o -> i -> (Context, Options),
    parse :: Signature i o -> Response -> Either ShikumiError o
  }

-- | Whether a model supports provider-native structured output.
data ModelCapability = NativeSchema | PromptFallback
  deriving stock (Eq, Show)

-- | A pure capability check over a baikai 'Model'. OpenAI/Anthropic on their
-- non-CLI APIs are native-capable; CLI APIs and unknown @Custom@ hosts use the
-- fallback. Refine as more models gain native support.
capabilityFor :: Model -> ModelCapability
capabilityFor m = case (m ^. #provider, m ^. #api) of
  ("openai", OpenAIChatCompletions) -> NativeSchema
  ("anthropic", AnthropicMessages) -> NativeSchema
  _ -> PromptFallback

-- | Select the adapter for a model from its capability.
adapterFor ::
  forall i o.
  (ToSchema o, FromModel o, Validatable o, ToPrompt i, ToPrompt o) =>
  Model ->
  Adapter i o
adapterFor m = case capabilityFor m of
  NativeSchema -> nativeAdapter
  PromptFallback -> fallbackAdapter

-- | Attach the derived JSON schema to a request. EP-2 is not yet merged into the
-- local baikai checkout, so @Options@ has no @responseFormat@ field: this is a
-- no-op for now. When EP-2 lands, set @#responseFormat .~ Just (JsonSchema …)@
-- here — this is the single place that touches the field.
attachSchema :: Value -> Options -> Options
attachSchema _schema opts = opts

-- | The native-schema adapter. @render@ attaches the derived schema (a no-op
-- until EP-2); @parse@ reads the structured JSON from the assistant text.
nativeAdapter ::
  forall i o.
  (ToSchema o, FromModel o, Validatable o, ToPrompt i, ToPrompt o) =>
  Adapter i o
nativeAdapter =
  Adapter
    { render = \sig i ->
        let sys = systemHeader sig <> nativeOutputGuide sig
            ctx = buildContext sys (demoMessages sig ++ [user (toPrompt i)])
            opts = attachSchema (deriveSchema @o) _Options
         in (ctx, opts),
      parse = \_sig resp -> assistantJSON resp >>= fromModelChecked
    }

-- | The prompt-based fallback adapter. @render@ asks for @[[ ## field ## ]]@
-- sections; @parse@ splits them, coerces each to its schema type, and decodes.
fallbackAdapter ::
  forall i o.
  (ToSchema o, FromModel o, Validatable o, ToPrompt i, ToPrompt o) =>
  Adapter i o
fallbackAdapter =
  Adapter
    { render = \sig i ->
        let sys = systemHeader sig <> fallbackOutputGuide sig
            ctx = buildContext sys (demoMessages sig ++ [user (toPrompt i)])
         in (ctx, _Options),
      parse = \_sig resp ->
        let sections = parseMarkers (responseText resp)
            obj = sectionsToObject (deriveSchema @o) sections
         in fromModelChecked obj
    }

-- ---------------------------------------------------------------------------
-- Rendering helpers
-- ---------------------------------------------------------------------------

buildContext :: Text -> [Message] -> Context
buildContext sys msgs =
  _Context & #systemPrompt .~ Just sys & #messages .~ V.fromList msgs

systemHeader :: Signature i o -> Text
systemHeader sig = getInstruction sig <> "\n\n"

-- | A native-output guide: list the output fields with their descriptions.
nativeOutputGuide :: Signature i o -> Text
nativeOutputGuide sig =
  "Reply with a JSON object containing these fields:\n"
    <> T.unlines [describeField f | f <- outputFields sig]

-- | A fallback-output guide: ask for one @[[ ## field ## ]]@ section per output
-- field, then a final @[[ ## completed ## ]]@ marker (DSPy's convention).
fallbackOutputGuide :: Signature i o -> Text
fallbackOutputGuide sig =
  "Reply using these sections, each marker on its own line:\n"
    <> T.unlines [marker (fieldName f) <> describeSuffix f | f <- outputFields sig]
    <> marker "completed"

describeField :: FieldMeta -> Text
describeField f = "- " <> fieldName f <> maybe "" (": " <>) (fieldDesc f)

describeSuffix :: FieldMeta -> Text
describeSuffix f = maybe "" ("  -- " <>) (fieldDesc f)

marker :: Text -> Text
marker name = "[[ ## " <> name <> " ## ]]"

-- | Render the demos as user/assistant message pairs.
demoMessages :: (ToPrompt i, ToPrompt o) => Signature i o -> [Message]
demoMessages sig = concatMap one (getDemos sig)
  where
    one (Demo i o) = [user (toPrompt i), assistant (renderOutputSections o)]

-- | Render a demo output as @[[ ## field ## ]]@ sections (shared by both adapters
-- for demo presentation).
renderOutputSections :: (ToPrompt o) => o -> Text
renderOutputSections o =
  T.unlines [marker k <> "\n" <> v | (k, v) <- toPromptFields o] <> marker "completed"

-- ---------------------------------------------------------------------------
-- Parsing helpers (fallback path)
-- ---------------------------------------------------------------------------

-- | Concatenate the text of every assistant text block.
responseText :: Response -> Text
responseText resp =
  T.concat [t | AssistantText (TextContent t) <- V.toList (flattenAssistantBlocks resp)]

-- | Read the assistant text and parse it as a JSON value (native path).
assistantJSON :: Response -> Either ShikumiError Value
assistantJSON resp =
  case eitherDecodeStrict (encodeUtf8 (responseText resp)) of
    Left e -> Left (InvalidJSON (T.pack e))
    Right v -> Right v

-- | Split a @[[ ## name ## ]]@-delimited body into a map of section name to its
-- (trimmed) text. The @completed@ marker carries no content.
parseMarkers :: Text -> Map Text Text
parseMarkers body = go (T.lines body) Nothing Map.empty
  where
    go [] cur acc = flush cur acc
    go (l : ls) cur acc = case markerName l of
      Just name -> go ls (Just (name, [])) (flush cur acc)
      Nothing -> case cur of
        Just (name, buf) -> go ls (Just (name, buf ++ [l])) acc
        Nothing -> go ls Nothing acc
    flush Nothing acc = acc
    flush (Just (name, buf)) acc
      | name == "completed" = acc
      | otherwise = Map.insert name (T.strip (T.unlines buf)) acc

-- | Recognize a @[[ ## name ## ]]@ marker line.
markerName :: Text -> Maybe Text
markerName line = do
  a <- T.stripPrefix "[[ ## " (T.strip line)
  b <- T.stripSuffix " ## ]]" a
  pure (T.strip b)

-- | Assemble a JSON object from marker sections, coercing each section to its
-- output-schema type. Missing markers are simply absent (so a required field
-- yields 'MissingField' downstream).
sectionsToObject :: Value -> Map Text Text -> Value
sectionsToObject schema sections =
  Object (KM.fromList [(Key.fromText nm, sectionToValue (propSchema nm) raw) | (nm, raw) <- Map.toList sections])
  where
    props = schemaProps schema
    propSchema nm = KM.lookup (Key.fromText nm) props

-- | The @properties@ object of a record schema (empty if not a record schema).
schemaProps :: Value -> Object
schemaProps (Object o) = case KM.lookup "properties" o of
  Just (Object p) -> p
  _ -> KM.empty
schemaProps _ = KM.empty

-- | Coerce a raw section to a JSON value using its property schema as a guide:
-- literal @null@ becomes JSON null; a string/enum-typed field stays a string;
-- everything else is JSON-parsed (falling back to a string on parse failure).
sectionToValue :: Maybe Value -> Text -> Value
sectionToValue mschema raw
  | T.strip raw == "null" = Null
  | maybe False isStringLike mschema = String stripped
  | otherwise = case eitherDecodeStrict (encodeUtf8 stripped) of
      Right v -> v
      Left _ -> String stripped
  where
    stripped = T.strip raw

-- | Whether a property schema describes a string-like value (plain string or an
-- enum, including a nullable string via @anyOf@).
isStringLike :: Value -> Bool
isStringLike (Object o) =
  KM.lookup "type" o == Just (String "string")
    || KM.member "enum" o
    || case KM.lookup "anyOf" o of
      Just (Array alts) -> any isStringLike (V.toList alts)
      _ -> False
isStringLike _ = False
