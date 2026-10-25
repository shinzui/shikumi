{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}

-- | The t'Adapter' seam between a typed 'Signature' + input and the wire.
-- @render@ builds a baikai @Context@+@Options@; @parse@ decodes a baikai
-- @Response@ into the typed output via "Shikumi.Schema".
--
-- The native-schema adapter uses provider-enforced JSON; the prompt-based fallback
-- renders @[[ ## field ## ]]@ sections for models without native structured output.
-- 'capabilityFor' selects between them per model from baikai's declared
-- structured-output support: first-party HTTP hosts and the subscription CLIs
-- (@claude@, @codex@) are native; third-party and @Custom@ hosts fall back. Two opt-in XML adapters share
-- bounded nested decoding and offer legacy or structured demonstration rendering.
--
-- Native structured output is wired through a private /metadata channel/ (EP-14).
-- Because a t'Shikumi.Program.Program' renders before the ambient model is known (the model is
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
    PromptValue (..),

    -- * The seam
    Adapter (..),
    ModelCapability (..),
    capabilityFor,
    nativeAdapter,
    fallbackAdapter,
    xmlAdapter,
    nestedXmlAdapter,
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
    metaDecisionStateKey,
    metaDecisionSchemaKey,
    metaDecisionEvidenceKey,
    evidenceFields,
    evidenceSchema,
    renderEvidenceRequest,
    responseValue,
    attachDecisionState,
    stripDecisionMarkers,
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
    StructuredOutputSupport (..),
    TextContent (..),
    assistant,
    declaredStructuredOutput,
    emptyContext,
    emptyOptions,
    flattenAssistantBlocks,
    user,
    userImage,
  )
import Baikai.Model (isJudgmentOnly)
import Control.Lens (at, (&), (.~), (?~), (^.))
import Data.Aeson (Object, Value (..), eitherDecodeStrict, toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Vector qualified as V
import Shikumi.Adapter.Prompt
import Shikumi.Adapter.Xml (decodeXmlFields, renderXmlFields, xmlSchemaGuide)
import Shikumi.Decision (Judgment (..), JudgmentKind (..), judgmentsInSchema, questionJSON)
import Shikumi.Decision.Setting (DecisionSetting)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Multimodal (imageToContent)
import Shikumi.Schema (FromModel, ToSchema, Validatable, deriveSchema, fromModelChecked)
import Shikumi.Schema.Types (FieldMeta (..))
import Shikumi.Signature (Demo (..), Signature, getDemos, getInstruction, inputFields, outputFields)

-- ---------------------------------------------------------------------------
-- ToPrompt: render an input record (and demo outputs) as labeled text
-- ---------------------------------------------------------------------------

-- | Render a record as labeled text for the prompt. 'toPromptFields' yields the
-- @(fieldName, valueText)@ pairs; 'toPrompt' joins them as @"name: value"@ lines.
-- ---------------------------------------------------------------------------
-- The seam
-- ---------------------------------------------------------------------------

-- | A record of two functions: format a request, parse a response.
data Adapter i o = Adapter
  { render :: !(Signature i o -> i -> (Context, Options)),
    parse :: !(Signature i o -> Response -> Either ShikumiError o)
  }

-- | Whether a model supports provider-native structured output.
data ModelCapability = NativeSchema | PromptFallback | DecisionOnly
  deriving stock (Eq, Show)

-- | A pure capability check over a baikai t'Model', derived from baikai's
-- per-transport declaration ('declaredStructuredOutput').
--
-- A model is 'NativeSchema' when baikai declares 'NativeJsonSchema' for its
-- @api@ and either:
--
-- * the @api@ is a subscription CLI tag ('AnthropicMessagesCli' for @claude -p
--   --json-schema@, 'OpenAICompletionsCli' for @codex exec --output-schema@) —
--   such a tag is always served by baikai's own CLI provider, so baikai's
--   declaration is authoritative; or
-- * the @(provider, api)@ pair is a first-party HTTP host: @openai@ over Chat
--   Completions or Responses, or @anthropic@ over Messages.
--
-- Third-party hosts speaking a first-party wire format (for example @deepseek@
-- or @openrouter@ over 'OpenAIChatCompletions') stay 'PromptFallback': baikai
-- forwards the schema, but cannot know whether such a host enforces it.
-- @Custom@ transports are 'NoStructuredOutput' in baikai's table and therefore
-- always 'PromptFallback'.
--
-- This answers schema enforcement only. Provider-native /tool calling/ is a
-- separate capability (baikai's CLI providers enforce schemas but drop tools);
-- see "Shikumi.Agent.ReAct".
capabilityFor :: Model -> ModelCapability
capabilityFor m | isJudgmentOnly m = DecisionOnly
capabilityFor m = case declaredStructuredOutput api of
  NoStructuredOutput -> PromptFallback
  NativeJsonSchema
    | cliTransport || firstPartyApi -> NativeSchema
    | otherwise -> PromptFallback
  where
    api = m ^. #api
    cliTransport = api `elem` [AnthropicMessagesCli, OpenAICompletionsCli]
    firstPartyApi =
      (m ^. #provider, api)
        `elem` [ ("openai", OpenAIChatCompletions),
                 ("openai", OpenAIResponses),
                 ("anthropic", AnthropicMessages)
               ]

-- | Select the adapter for a model from its capability.
adapterFor ::
  forall i o.
  (ToSchema o, FromModel o, Validatable o, ToPrompt i, ToPrompt o) =>
  Model ->
  Adapter i o
adapterFor m = case capabilityFor m of
  DecisionOnly -> nativeAdapter
  NativeSchema -> nativeAdapter
  PromptFallback -> fallbackAdapter

-- | The reserved 'Baikai.Options.metadata' key under which 'attachSchema' stamps the
-- derived JSON schema 'Value'. "Shikumi.Routing".@routeLLM@ reads it, turns it into
-- @Options.responseFormat@ for native-capable models, and strips it before
-- transport. Defined here (the lowest module both the adapter and the router share)
-- so it is written and read against a single source of truth.
metaResponseSchemaKey :: Text
metaResponseSchemaKey = "shikumi.responseSchema"

-- | The reserved 'Baikai.Options.metadata' key under which 'stampTemperature' stamps a
-- per-sample temperature (a JSON number). The router reads it, sets
-- @Options.temperature@, and strips it before transport.
metaTemperatureKey :: Text
metaTemperatureKey = "shikumi.temperature"

-- | Reserved 'Baikai.Options.metadata' key carrying the full native-format system prompt
-- (instruction + native output guide) as a JSON string. Stamped by
-- 'Shikumi.Program.runPredict'; "Shikumi.Routing".@routeLLM@ swaps it into the
-- t'Context' for native-capable models and strips it before transport. Because
-- @runPredict@ renders model-agnostically (the marker prompt), this carries the
-- native alternative so the router can install it once the real model is known.
metaNativePromptKey :: Text
metaNativePromptKey = "shikumi.native.systemPrompt"

-- | Reserved 'Baikai.Options.metadata' key carrying the native-format demo assistant
-- turns, in order, as a JSON array of strings. Same lifecycle as
-- 'metaNativePromptKey'.
metaNativeDemosKey :: Text
metaNativeDemosKey = "shikumi.native.demos"

-- | Reserved structured state for judgment routing. Stripped before transport.
metaDecisionStateKey :: Text
metaDecisionStateKey = "shikumi.decision.state"

-- | Attach decision state without changing the native or marker prompt.
attachDecisionState :: Value -> Options -> Options
attachDecisionState state opts = opts & #metadata . at metaDecisionStateKey ?~ state

-- | Remove private decoder metadata recursively before sending a schema.
stripDecisionMarkers :: Value -> Value
stripDecisionMarkers (Object o) = Object (fmap stripDecisionMarkers (KM.delete "x-shikumi-decision" o))
stripDecisionMarkers (Array xs) = Array (fmap stripDecisionMarkers xs)
stripDecisionMarkers v = v

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
-- t'Context' for native-capable models and strips the keys before transport.
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
-- 'Shikumi.Program.MajorityVote' sample's temperature down to its 'Shikumi.Program.Predict' nodes;
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
-- JSON or the @[[ ## … ## ]]@ markers. Both XML adapters decode nested elements
-- and legacy JSON-in-tag containers through 'fromModelChecked'. This adapter
-- retains its historical flattened demonstration rendering.
--
-- Reachability: 'xmlAdapter' is /not/ selectable by the runtime router. The router
-- ("Shikumi.Routing".@routeLLM@) picks between the native and fallback wire shapes
-- from the model's detected 'ModelCapability' (native vs. prompt-fallback); XML is a
-- caller choice, not a detectable capability, so 'adapterFor' never returns it. To
-- use it, hold the t'Adapter' value directly and render/parse with it inside an
-- 'Shikumi.Program.embed' node — the same way 'Shikumi.Module.twoStep' drives
-- 'fallbackAdapter' by hand. A per-node adapter selector through the t'Shikumi.Program.Program' GADT
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
      parse = \_sig resp -> decodeXmlFields (deriveSchema @o) (responseText resp) >>= fromModelChecked
    }

-- | Nested XML guides and faithful structured demonstrations (EP-55). Requires
-- [ToJSON]("Data.Aeson#t:ToJSON") for outputs; inputs still use t'ToPrompt'. Supports generated
-- records, arrays, scalars and nullable schemas; other schema forms render an
-- escaped JSON fallback. Parsing is shared with 'xmlAdapter'. Opt-in only.
nestedXmlAdapter ::
  forall i o.
  (ToSchema o, FromModel o, Validatable o, ToPrompt i, Aeson.ToJSON o) =>
  Adapter i o
nestedXmlAdapter =
  Adapter
    { render = \sig i ->
        let names = map fieldName (outputFields sig)
            schema = deriveSchema @o
            sys = systemHeader sig <> xmlSchemaGuide names schema
            demos = concat [[userTurn di, assistant (renderXmlFields names schema (toJSON o))] | Demo di o <- getDemos sig]
         in (buildContext sys (demos ++ [userTurn i]), emptyOptions),
      parse = \_sig resp -> decodeXmlFields (deriveSchema @o) (responseText resp) >>= fromModelChecked
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
--
-- A field whose derived schema (ignoring nullability) is an object or an array
-- gets one further @JSON shape: …@ line ('renderShape'), so a model without
-- schema enforcement still sees nested keys and closed enum values. Scalar
-- fields, including top-level enums, render exactly as before.
fallbackOutputGuide :: forall i o. (ToSchema o) => Signature i o -> Text
fallbackOutputGuide sig =
  "Reply using these sections, each marker on its own line:\n"
    <> T.unlines (concat [fieldLines f | f <- outputFields sig])
    <> marker "completed"
  where
    schema = deriveSchema @o
    fieldLines f =
      (marker (fieldName f) <> describeSuffix f)
        : [ "JSON shape: " <> renderShape s
          | Just s <- [propertySchema (fieldName f) schema],
            isStructured s
          ]
    isStructured s = case KM.lookup "type" =<< objectOf (stripNullable s) of
      Just (String t) -> t == "object" || t == "array"
      _ -> False

-- | The schema of one top-level property of a derived object schema.
propertySchema :: Text -> Value -> Maybe Value
propertySchema name schema =
  KM.lookup (Key.fromText name) =<< objectOf =<< KM.lookup "properties" =<< objectOf schema

objectOf :: Value -> Maybe Object
objectOf (Object o) = Just o
objectOf _ = Nothing

-- | Strip a nullable @anyOf [s, {"type":"null"}]@ wrapper, if present.
stripNullable :: Value -> Value
stripNullable v = fromMaybe v (nullableInner v)

-- | The inner schema of a nullable @anyOf [s, {"type":"null"}]@ wrapper.
nullableInner :: Value -> Maybe Value
nullableInner (Object o)
  | Just (Array alts) <- KM.lookup "anyOf" o,
    [s, Object n] <- V.toList alts,
    KM.lookup "type" n == Just (String "null") =
      Just s
nullableInner _ = Nothing

-- | A compact, JSON-like rendering of a derived schema for the fallback guide:
-- scalars by type name, string enums as their quoted values joined by @|@,
-- arrays as @[\<item\>, ...]@, objects as @{"k": \<shape\>, …}@ (keys in @required@
-- order, any others sorted after), and nullable values as @\<shape\> | null@.
renderShape :: Value -> Text
renderShape v = case nullableInner v of
  Just s -> renderShape s <> " | null"
  Nothing -> case objectOf v of
    Nothing -> anyValue
    Just o -> case KM.lookup "enum" o of
      Just (Array vs) | not (V.null vs) -> T.intercalate " | " (map jsonText (V.toList vs))
      _ -> case KM.lookup "type" o of
        Just (String "array") -> "[" <> maybe anyValue renderShape (KM.lookup "items" o) <> ", ...]"
        Just (String "object") -> renderObject o
        Just (String t) | t `elem` ["string", "integer", "number", "boolean"] -> t
        _ -> anyValue
  where
    anyValue = "any JSON value"
    jsonText x = decodeUtf8 (LBS.toStrict (Aeson.encode x))
    renderObject o =
      let props = fromMaybe KM.empty (objectOf =<< KM.lookup "properties" o)
          required = case KM.lookup "required" o of
            Just (Array rs) -> [k | String r <- V.toList rs, let k = Key.fromText r, KM.member k props]
            _ -> []
          others = sortOn Key.toText [k | k <- KM.keys props, k `notElem` required]
          entry k = jsonText (String (Key.toText k)) <> ": " <> maybe anyValue renderShape (KM.lookup k props)
       in "{" <> T.intercalate ", " (map entry (required <> others)) <> "}"

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

-- | Evidence mode and its original answer schema are independent of numeric
-- settings. The router chooses the answer schema for judgment-only models.
metaDecisionEvidenceKey, metaDecisionSchemaKey :: Text
metaDecisionEvidenceKey = "shikumi.decision.evidence"
metaDecisionSchemaKey = "shikumi.decision.schema"

evidenceFields :: forall o. (ToSchema o) => Map Text DecisionSetting -> [Judgment]
evidenceFields settings = filter selected (fst (judgmentsInSchema schema))
  where
    schema = deriveSchema @o
    selected j =
      Map.member (judgmentField j) settings || case propertySchema (judgmentField j) schema of
        Just (Object p) -> KM.member "x-shikumi-decision" p
        _ -> False

-- | Replace selected answer properties with closed probability objects.
evidenceSchema :: Value -> [Judgment] -> Value
evidenceSchema (Object root) fields = case KM.lookup "properties" root of
  Just (Object props) -> Object (KM.insert "properties" (Object (foldl replace props fields)) root)
  _ -> Object root
  where
    probability = Aeson.object ["type" Aeson..= ("number" :: Text), "minimum" Aeson..= (0 :: Int), "maximum" Aeson..= (1 :: Int)]
    closed props = Aeson.object ["type" Aeson..= ("object" :: Text), "properties" Aeson..= Object props, "required" Aeson..= map Key.toText (KM.keys props), "additionalProperties" Aeson..= False]
    replace props j =
      let keys = case judgmentKind j of JudgeBoolean {} -> []; JudgeChoice ls -> map fst ls; JudgeOrdered ls -> map (T.pack . show) [0 .. length ls - 1]
          shape = case judgmentKind j of
            JudgeBoolean {} -> closed (KM.singleton "noul" probability)
            _ -> closed (KM.fromList [("probabilities", closed (KM.fromList [(Key.fromText k, probability) | k <- keys])), ("confidence", probability)])
          described = case shape of Object p -> Object (KM.insert "description" (String (jsonText (questionJSON j))) p); _ -> shape
       in KM.insert (Key.fromText (judgmentField j)) described props
evidenceSchema v _ = v

jsonText :: Value -> Text
jsonText = decodeUtf8 . LBS.toStrict . Aeson.encode

-- | Render probability requests without demonstration turns. Task examples keep
-- labels or actual evidence and never invent probability distributions.
renderEvidenceRequest :: forall i o. (ToSchema o, ToPrompt i, ToPrompt o) => Map Text DecisionSetting -> Signature i o -> i -> (Context, Options)
renderEvidenceRequest settings sig input =
  let fields = evidenceFields @o settings
      original = deriveSchema @o
      schema = evidenceSchema original fields
      example (Demo i o) = case (toPromptJSON i, toEvidenceJSON o) of
        (Object a, Object b) -> Object (KM.fromList [(k, v) | (k, v) <- KM.toList (KM.union b a), Key.toText k `elem` map fieldName (inputFields sig ++ outputFields sig)])
        _ -> Null
      examples = if null (getDemos sig) then "" else "\n\nTask examples (labels or evidence):\n" <> jsonText (toJSON (map example (getDemos sig)))
      header = getInstruction sig <> examples <> "\n\nEach probability and confidence must be between 0 and 1. Choice and Score probabilities should sum to one.\n"
      describe f = case filter ((== fieldName f) . judgmentField) fields of
        j : _ -> jsonText (questionJSON j)
        [] -> fromMaybe "" (fieldDesc f)
      native = header <> "Reply with a JSON object containing these fields:\n" <> T.unlines [fieldName f <> ": " <> describe f | f <- outputFields sig]
      markerGuide = header <> "Reply using these sections, each marker on its own line:\n" <> T.unlines [marker (fieldName f) <> "  -- " <> describe f <> maybe "" (\s -> "\nJSON shape: " <> renderShape s) (propertySchema (fieldName f) schema) | f <- outputFields sig] <> marker "completed"
      opts =
        attachNativeRender native [] (attachSchema schema emptyOptions)
          & #metadata . at metaDecisionEvidenceKey ?~ toJSON [Aeson.object ["field" Aeson..= judgmentField j, "kind" Aeson..= (case judgmentKind j of JudgeBoolean {} -> "noul"; JudgeChoice {} -> "choice"; JudgeOrdered {} -> "score" :: Text)] | j <- fields]
          & #metadata . at metaDecisionSchemaKey ?~ original
   in (buildContext markerGuide [userTurn input], opts)

-- | Read either JSON text or marker sections with schema-driven object coercion.
responseValue :: Value -> Response -> Either ShikumiError Value
responseValue schema response = case assistantJSON response of
  Right value -> Right value
  Left _ -> Right (sectionsToObject schema (parseMarkers (responseText response)))
