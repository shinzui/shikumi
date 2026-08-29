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
-- Native structured output is wired through a private /metadata channel/ (EP-14).
-- Because a 'Program' renders before the ambient model is known (the model is
-- supplied by an interpreter below 'Shikumi.Program.runProgram' — see
-- "Shikumi.Routing"), 'render' cannot itself decide native-vs-fallback or build the
-- final @responseFormat@. Instead, 'attachSchema' stamps the derived JSON schema
-- under the reserved 'metaResponseSchemaKey' on @Options.metadata@, and
-- 'stampTemperature' stamps a per-sample temperature under 'metaTemperatureKey';
-- the router ("Shikumi.Routing".@routeLLM@) translates those into
-- @responseFormat@\/@temperature@ against the real model and strips the keys before
-- transport.
--
-- The same channel also carries the /native render alternative/ (EP-33). Because
-- the runtime always renders the model-agnostic marker prompt, 'attachNativeRender'
-- additionally stamps the native-format system prompt under 'metaNativePromptKey'
-- and the native (JSON) demo assistant turns under 'metaNativeDemosKey'
-- ('nativeRenderPieces' produces both). For a native-capable model the router swaps
-- these into the @Context@ (so the model is told to reply as JSON and shown JSON
-- demos, not @[[ ## … ## ]]@ markers); for fallback models the marker prompt stands
-- and the keys are stripped. 'renderOutputNative' is the shared demo renderer, also
-- used by 'nativeAdapter' when a caller drives it directly.
module Shikumi.Adapter
  ( -- * Input rendering
    ToPrompt (..),

    -- * The seam
    Adapter (..),
    ModelCapability (..),
    capabilityFor,
    nativeAdapter,
    fallbackAdapter,
    xmlAdapter,
    adapterFor,
    attachSchema,
    responseText,
    assistantJSON,

    -- * The private request-metadata channel (consumed by "Shikumi.Routing")
    stampTemperature,
    metaResponseSchemaKey,
    metaTemperatureKey,
    metaNativePromptKey,
    metaNativeDemosKey,
    attachNativeRender,
    nativeRenderPieces,
    renderOutputNative,
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
    emptyContext,
    emptyOptions,
    flattenAssistantBlocks,
    user,
    userImage,
  )
import Control.Lens (at, (&), (.~), (?~), (^.))
import Data.Aeson (Object, Value (..), eitherDecodeStrict, toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Kind (Type)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Vector qualified as V
import GHC.Generics
import Shikumi.Error (ShikumiError (..))
import Shikumi.Multimodal (GImageFieldNames (..), GImageFields (..), Image, imageToContent)
import Shikumi.Schema (FromModel, ToSchema, Validatable, deriveSchema, fromModelChecked)
import Shikumi.Schema.Types (Constrained (..), FieldMeta (..))
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

  -- | The 'Image' values an /input/ record carries, in field order (EP-24). The
  -- adapter lowers these to baikai @UserImage@ blocks in 'userTurn'. The generic
  -- default walks the record, so any 'Generic' input gets it for free; a record
  -- with no image field yields @[]@ and renders byte-for-byte as before. A
  -- hand-written instance whose fields are polymorphic (e.g.
  -- "Shikumi.Module".@WithReasoning@) cannot be walked generically and overrides
  -- this to @[]@.
  imageFields :: a -> [Image]
  default imageFields :: (Generic a, GImageFields (Rep a)) => a -> [Image]
  imageFields = gImageFields . from

  -- | The names of an input record's image fields, in field order (EP-24). The
  -- text renderer in 'userTurn' drops these so an image is not also rendered as
  -- prose. Same defaulting story as 'imageFields'.
  imageFieldNames :: a -> [Text]
  default imageFieldNames :: (Generic a, GImageFieldNames (Rep a)) => a -> [Text]
  imageFieldNames = gImageFieldNames . from

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

-- | A 'Constrained' field renders as its inner value (the constraint is a
-- compile-time/decode-time concern, not a prompt concern). EP-26.
instance (PromptValue a) => PromptValue (Constrained cs a) where
  promptValue = promptValue . unConstrained

-- ---------------------------------------------------------------------------
-- The seam
-- ---------------------------------------------------------------------------

-- | A record of two functions: format a request, parse a response.
data Adapter i o = Adapter
  { render :: !(Signature i o -> i -> (Context, Options)),
    parse :: !(Signature i o -> Response -> Either ShikumiError o)
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

-- | The reserved 'Options.metadata' key under which 'attachSchema' stamps the
-- derived JSON schema 'Value'. "Shikumi.Routing".@routeLLM@ reads it, turns it into
-- @Options.responseFormat@ for native-capable models, and strips it before
-- transport. Defined here (the lowest module both the adapter and the router share)
-- so it is written and read against a single source of truth.
metaResponseSchemaKey :: Text
metaResponseSchemaKey = "shikumi.responseSchema"

-- | The reserved 'Options.metadata' key under which 'stampTemperature' stamps a
-- per-sample temperature (a JSON number). The router reads it, sets
-- @Options.temperature@, and strips it before transport.
metaTemperatureKey :: Text
metaTemperatureKey = "shikumi.temperature"

-- | Reserved 'Options.metadata' key carrying the full native-format system prompt
-- (instruction + native output guide) as a JSON string. Stamped by
-- 'Shikumi.Program.runPredict'; "Shikumi.Routing".@routeLLM@ swaps it into the
-- 'Context' for native-capable models and strips it before transport. Because
-- @runPredict@ renders model-agnostically (the marker prompt), this carries the
-- native alternative so the router can install it once the real model is known.
metaNativePromptKey :: Text
metaNativePromptKey = "shikumi.native.systemPrompt"

-- | Reserved 'Options.metadata' key carrying the native-format demo assistant
-- turns, in order, as a JSON array of strings. Same lifecycle as
-- 'metaNativePromptKey'.
metaNativeDemosKey :: Text
metaNativeDemosKey = "shikumi.native.demos"

-- | Stamp the derived JSON schema onto a request's private metadata channel. This
-- is no longer a no-op: it records the schema under 'metaResponseSchemaKey' so the
-- router can attach a real @responseFormat@ once the ambient model is known. (The
-- router only honours it for native-capable models; for fallback models it is
-- simply stripped.)
attachSchema :: Value -> Options -> Options
attachSchema schema opts =
  opts & #metadata . at metaResponseSchemaKey ?~ schema

-- | Stamp the native-format system prompt and demo assistant turns onto a
-- request's private metadata channel, under 'metaNativePromptKey' and
-- 'metaNativeDemosKey'. Mirrors 'attachSchema': the router swaps these into the
-- 'Context' for native-capable models and strips the keys before transport.
attachNativeRender :: Text -> [Text] -> Options -> Options
attachNativeRender sys demos opts =
  opts
    & #metadata . at metaNativePromptKey ?~ toJSON sys
    & #metadata . at metaNativeDemosKey ?~ toJSON demos

-- | The native-format render pieces for a signature: the system prompt a
-- native-capable model should see (instruction + native output guide, /not/ the
-- marker guide) and the demo assistant turns rendered as JSON objects, in order.
-- 'Shikumi.Program.runPredict' stamps these via 'attachNativeRender' so the router
-- can install them once the real model is known.
nativeRenderPieces ::
  forall i o. (ToSchema o, ToPrompt o) => Signature i o -> (Text, [Text])
nativeRenderPieces sig =
  ( systemHeader sig <> nativeOutputGuide sig,
    [renderOutputNative @o o | Demo _ o <- getDemos sig]
  )

-- | Stamp a per-sample temperature onto a request's private metadata channel under
-- 'metaTemperatureKey'. Used by 'Shikumi.Program.runProgram' to thread a
-- 'Shikumi.Program.MajorityVote' sample's temperature down to its 'Predict' nodes;
-- the router turns it into @Options.temperature@.
stampTemperature :: Double -> Options -> Options
stampTemperature t opts =
  opts & #metadata . at metaTemperatureKey ?~ toJSON t

-- | The native-schema adapter. @render@ stamps the derived schema onto the request
-- metadata channel (see 'attachSchema'); @parse@ reads the structured JSON from the
-- assistant text.
nativeAdapter ::
  forall i o.
  (ToSchema o, FromModel o, Validatable o, ToPrompt i, ToPrompt o) =>
  Adapter i o
nativeAdapter =
  Adapter
    { render = \sig i ->
        let sys = systemHeader sig <> nativeOutputGuide sig
            ctx = buildContext sys (nativeDemoMessages sig ++ [userTurn i])
            opts = attachSchema (deriveSchema @o) emptyOptions
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
            ctx = buildContext sys (demoMessages sig ++ [userTurn i])
         in (ctx, emptyOptions),
      parse = \_sig resp ->
        let sections = parseMarkers (responseText resp)
            obj = sectionsToObject (deriveSchema @o) sections
         in fromModelChecked obj
    }

-- | The XML adapter (EP-26). A third wire format on the same typed seam: @render@
-- asks the model to wrap each output field in @\<field\>…\</field\>@ tags, and
-- @parse@ reads those tags back. Some models follow an XML shape more reliably than
-- JSON or the @[[ ## … ## ]]@ markers. Reuses the same 'sectionsToObject' +
-- 'fromModelChecked' decode path as 'fallbackAdapter', so nested records and lists
-- in tags coerce the same way.
--
-- Reachability: 'xmlAdapter' is /not/ selectable by the runtime router. The router
-- ("Shikumi.Routing".@routeLLM@) picks between the native and fallback wire shapes
-- from the model's detected 'ModelCapability' (native vs. prompt-fallback); XML is a
-- caller choice, not a detectable capability, so 'adapterFor' never returns it. To
-- use it, hold the 'Adapter' value directly and render/parse with it inside an
-- 'Shikumi.Program.embed' node — the same way 'Shikumi.Module.twoStep' drives
-- 'fallbackAdapter' by hand. A per-node adapter selector through the 'Program' GADT
-- was considered and deferred (see the parent MasterPlan's scope), as it is
-- disproportionate to the need.
xmlAdapter ::
  forall i o.
  (ToSchema o, FromModel o, Validatable o, ToPrompt i, ToPrompt o) =>
  Adapter i o
xmlAdapter =
  Adapter
    { render = \sig i ->
        let sys = systemHeader sig <> xmlOutputGuide sig
            ctx = buildContext sys (xmlDemoMessages sig ++ [userTurn i])
         in (ctx, emptyOptions),
      parse = \sig resp ->
        let names = map fieldName (outputFields sig)
            sections = parseXmlTags names (responseText resp)
            obj = sectionsToObject (deriveSchema @o) sections
         in fromModelChecked obj
    }

-- ---------------------------------------------------------------------------
-- Rendering helpers
-- ---------------------------------------------------------------------------

buildContext :: Text -> [Message] -> Context
buildContext sys msgs =
  emptyContext & #systemPrompt .~ Just sys & #messages .~ V.fromList msgs

-- | Build the final user turn for an input. If the input has an image field, it is
-- lowered to a baikai 'userImage' block, with the remaining (text) fields rendered
-- as a leading text block and the image field name dropped from that text. With no
-- image field this is exactly @user (toPrompt i)@, so the all-text path is
-- byte-for-byte unchanged (the EP-26 coexistence + regression invariant).
--
-- Only the /first/ image is attached: baikai's 'userImage' carries one image block,
-- and the headline use case is one image per input. A multi-image input is future
-- work (it would assemble the @UserPayload@ content vector by hand).
userTurn :: forall i. (ToPrompt i) => i -> Message
userTurn i = case imageFields i of
  [] -> user (toPrompt i)
  (img : _) ->
    let dropped = imageFieldNames i
        textBody =
          T.intercalate "\n" [k <> ": " <> v | (k, v) <- toPromptFields i, k `notElem` dropped]
        prefix = if T.null textBody then Nothing else Just textBody
     in userImage (imageToContent img) prefix

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

-- | Render a demo output as the JSON object a native model is asked to reply
-- with. Reuses 'sectionsToObject' so each field's text coerces against the
-- derived schema exactly as the fallback parse path coerces marker sections —
-- one source of truth for the text-to-typed-JSON coercion (there is no @o ->
-- Value@ inverse to render directly, as 'FromModel' has no dual).
renderOutputNative :: forall o. (ToSchema o, ToPrompt o) => o -> Text
renderOutputNative o =
  decodeUtf8 (LBS.toStrict (Aeson.encode obj))
  where
    obj = sectionsToObject (deriveSchema @o) (Map.fromList (toPromptFields o))

-- | Demo turns for the native path: user prompt as usual, assistant turn as the
-- JSON object (not marker sections), so a native model sees examples in the same
-- shape as the reply it is asked to produce.
nativeDemoMessages ::
  forall i o. (ToSchema o, ToPrompt i, ToPrompt o) => Signature i o -> [Message]
nativeDemoMessages sig = concatMap one (getDemos sig)
  where
    one (Demo i o) = [user (toPrompt i), assistant (renderOutputNative @o o)]

-- | Render a demo output as @[[ ## field ## ]]@ sections (shared by both adapters
-- for demo presentation).
renderOutputSections :: (ToPrompt o) => o -> Text
renderOutputSections o =
  T.unlines [marker k <> "\n" <> v | (k, v) <- toPromptFields o] <> marker "completed"

-- | An XML-output guide: ask for one @\<field\>…\</field\>@ element per output
-- field. Mirrors 'fallbackOutputGuide' with XML tags instead of markers.
xmlOutputGuide :: Signature i o -> Text
xmlOutputGuide sig =
  "Reply with each output field wrapped in an XML tag, on its own lines:\n"
    <> T.unlines [openTag (fieldName f) <> "…" <> closeTag (fieldName f) <> describeSuffix f | f <- outputFields sig]

-- | An XML open tag, @\<name\>@.
openTag :: Text -> Text
openTag name = "<" <> name <> ">"

-- | An XML close tag, @\</name\>@.
closeTag :: Text -> Text
closeTag name = "</" <> name <> ">"

-- | Render a demo output as @\<field\>…\</field\>@ elements (the XML adapter's demo
-- shape, mirroring 'renderOutputSections' for the marker adapters).
renderOutputXml :: (ToPrompt o) => o -> Text
renderOutputXml o =
  T.unlines [openTag k <> "\n" <> v <> "\n" <> closeTag k | (k, v) <- toPromptFields o]

-- | Render the demos as user/assistant message pairs, the assistant turn shaped as
-- XML so the model sees an example consistent with the XML adapter's wire format.
xmlDemoMessages :: (ToPrompt i, ToPrompt o) => Signature i o -> [Message]
xmlDemoMessages sig = concatMap one (getDemos sig)
  where
    one (Demo i o) = [user (toPrompt i), assistant (renderOutputXml o)]

-- ---------------------------------------------------------------------------
-- Parsing helpers (fallback path)
-- ---------------------------------------------------------------------------

-- | Concatenate the text of every assistant text block.
responseText :: Response -> Text
responseText resp =
  T.concat [t | AssistantText (TextContent t) <- V.toList (flattenAssistantBlocks resp)]

-- | Read the assistant text and parse it as a JSON value (native path). Exported
-- for 'Shikumi.Program.parseResponse', which uses it to detect the wire shape: a
-- body that parses as JSON is the native shape and is decoded by the native
-- parser (keeping its located error), while a non-JSON body is the marker shape.
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

-- | Extract @\<name\>…\</name\>@ sections into a name->text map. Only names that
-- appear as output fields are kept (so stray tags are ignored, DSPy parity), and
-- the first match per name wins. The content is whatever lies between the first
-- @\<name\>@ and its next @\</name\>@ — a non-greedy match, the same as DSPy's
-- @\<(?P\<name\>\\w+)\>(?P\<content\>.*?)\</\\1\>@ with DOTALL.
parseXmlTags :: [Text] -> Text -> Map Text Text
parseXmlTags names body =
  Map.fromList [(nm, inner) | nm <- names, Just inner <- [extractTag nm body]]

-- | The text between the first @\<name\>@ and its next @\</name\>@, trimmed;
-- 'Nothing' if either tag is absent.
extractTag :: Text -> Text -> Maybe Text
extractTag nm body =
  let open = openTag nm
      close = closeTag nm
      (_, afterOpen) = T.breakOn open body
   in if T.null afterOpen
        then Nothing
        else
          let rest = T.drop (T.length open) afterOpen
              (inner, afterClose) = T.breakOn close rest
           in if T.null afterClose then Nothing else Just (T.strip inner)

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
