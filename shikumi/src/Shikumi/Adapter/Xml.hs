-- | Bounded model-output XML fragments, not a general XML processor.
module Shikumi.Adapter.Xml (decodeXmlFields, renderXmlFields, xmlSchemaGuide) where

import Data.Aeson (Object, Value (..), eitherDecodeStrict, encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Char (chr, isAlpha, isAlphaNum, ord)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Vector qualified as V
import Shikumi.Error (ShikumiError (..))

-- Offsets count Unicode code points, starting at zero. CDATA provenance matters
-- for the nullable literal string "null".
data Node = Element !Int !Text [Node] | Content !Bool !Text

data Cursor = Cursor !Int !Text

failure :: Int -> Text -> Either ShikumiError a
failure pos msg = Left (SchemaMismatch ("XML: offset " <> T.pack (show pos) <> ": " <> msg))

advance :: Text -> Cursor -> Cursor
advance consumed (Cursor pos rest) = Cursor (pos + T.length consumed) (T.drop (T.length consumed) rest)

xmlSpace :: Char -> Bool
xmlSpace c = c `elem` [' ', '\t', '\r', '\n']

validChar :: Char -> Bool
validChar c = let n = ord c in n == 9 || n == 10 || n == 13 || (n >= 32 && n <= 0xD7FF) || (n >= 0xE000 && n <= 0xFFFD) || (n >= 0x10000 && n <= 0x10FFFF)

-- Siblings accumulate tail-recursively; only element nesting consumes depth.
fragment :: Int -> Maybe Text -> Cursor -> Either ShikumiError ([Node], Cursor)
fragment depth closing = go []
  where
    go acc cur@(Cursor pos rest)
      | T.null rest = case closing of
          Nothing -> Right (reverse acc, cur)
          Just name -> failure pos ("unterminated element " <> name)
      | "<!--" `T.isPrefixOf` rest = do
          (body, next) <- delimited "<!--" "-->" cur
          if "--" `T.isInfixOf` body || "-" `T.isSuffixOf` body then failure pos "invalid comment" else go acc next
      | "<![CDATA[" `T.isPrefixOf` rest = do
          (body, next) <- delimited "<![CDATA[" "]]>" cur
          go (Content True body : acc) next
      | "</" `T.isPrefixOf` rest = do
          (name, selfClosing, next) <- tag True cur
          if closing == Just name && not selfClosing
            then Right (reverse acc, next)
            else failure pos ("unexpected closing tag " <> name)
      | "<!" `T.isPrefixOf` rest || "<?" `T.isPrefixOf` rest = failure pos "unsupported declaration or processing instruction"
      | "<" `T.isPrefixOf` rest = do
          if depth >= 64 then failure pos "depth limit 64 exceeded" else Right ()
          (name, selfClosing, next) <- tag False cur
          (children, after) <- if selfClosing then Right ([], next) else fragment (depth + 1) (Just name) next
          go (Element pos name children : acc) after
      | otherwise = do
          let (raw, _) = T.breakOn "<" rest
          if "]]>" `T.isInfixOf` raw then failure pos "CDATA terminator outside CDATA" else Right ()
          decoded <- if closing == Nothing then Right raw else entities pos raw
          go (Content False decoded : acc) (advance raw cur)

    delimited start end cur@(Cursor pos rest) =
      let (body, suffix) = T.breakOn end (T.drop (T.length start) rest)
       in if T.null suffix
            then failure pos ("unterminated " <> start)
            else Right (body, advance (start <> body <> end) cur)

tag :: Bool -> Cursor -> Either ShikumiError (Text, Bool, Cursor)
tag closing cur@(Cursor pos rest) =
  let prefix = if closing then "</" else "<"
      (name, suffix) = T.span (\c -> isAlphaNum c || c `elem` ['_', '-', '.']) (T.drop (T.length prefix) rest)
      spaces = T.takeWhile xmlSpace suffix
      end = T.dropWhile xmlSpace suffix
      finish token self = Right (name, self, advance (prefix <> name <> spaces <> token) cur)
   in case T.uncons name of
        Just (c, _)
          | isAlpha c || c == '_' ->
              if ">" `T.isPrefixOf` end
                then finish ">" False
                else
                  if not closing && "/>" `T.isPrefixOf` end
                    then finish "/>" True
                    else failure pos "attributes, namespaces, or malformed tag are unsupported"
        _ -> failure pos "invalid element name"

entities :: Int -> Text -> Either ShikumiError Text
entities = go []
  where
    go acc pos raw =
      let (plain, suffix) = T.breakOn "&" raw
          at = pos + T.length plain
       in if T.null suffix
            then Right (T.concat (reverse (plain : acc)))
            else
              let (ref, end) = T.breakOn ";" (T.drop 1 suffix)
               in if T.null end
                    then failure at "unterminated entity"
                    else do
                      value <- case ref of
                        "amp" -> Right "&"
                        "lt" -> Right "<"
                        "gt" -> Right ">"
                        "quot" -> Right "\""
                        "apos" -> Right "'"
                        _
                          | Just digits <- T.stripPrefix "#x" ref -> numeric at 16 digits
                          | Just digits <- T.stripPrefix "#" ref -> numeric at 10 digits
                          | otherwise -> failure at "unknown entity"
                      go (value : plain : acc) (at + T.length ref + 2) (T.drop 1 end)
    numeric pos base digits =
      let digit c
            | c >= '0' && c <= '9' = ord c - ord '0'
            | c >= 'a' && c <= 'f' = 10 + ord c - ord 'a'
            | c >= 'A' && c <= 'F' = 10 + ord c - ord 'A'
            | otherwise = base
          step n c = if n > 0x10FFFF || digit c >= base then 0x110000 else n * base + digit c
          value = T.foldl' step 0 digits
       in if T.null digits || value > 0x10FFFF || not (validChar (chr value))
            then failure pos "invalid Unicode character reference"
            else Right (T.singleton (chr value))

property :: Key.Key -> Value -> Value
property key (Object obj) = maybe Null id (KM.lookup key obj)
property _ _ = Null

properties :: Value -> Object
properties schema = case property "properties" schema of Object p -> p; _ -> KM.empty

nonNull :: Value -> Value
nonNull schema = case property "anyOf" schema of
  Array alts -> case V.toList alts of
    [a, b]
      | property "type" a == String "null" -> nonNull b
      | property "type" b == String "null" -> nonNull a
    _ -> schema
  _ -> schema

nullable :: Value -> Bool
nullable schema =
  property "type" schema == String "null" || case property "anyOf" schema of
    Array alts -> any nullable alts
    _ -> False

jsonText :: Text -> Value
jsonText raw = either (const (String raw)) id (eitherDecodeStrict (encodeUtf8 raw))

-- | Parse the entire fragment before selecting known top-level properties.
decodeXmlFields :: Value -> Text -> Either ShikumiError Value
decodeXmlFields schema body
  | T.length body > 1048576 = failure 0 "input length limit 1048576 exceeded"
  | Just pos <- T.findIndex (not . validChar) body = failure pos "invalid XML character"
  | otherwise = do
      (nodes, _) <- fragment 0 Nothing (Cursor 0 body)
      objectFields schema nodes

objectFields :: Value -> [Node] -> Either ShikumiError Value
objectFields schema nodes = Object . KM.fromList <$> traverse convert selected
  where
    present = KM.fromListWith (\_ first -> first) [(Key.fromText name, node) | node@(Element _ name _) <- nodes]
    selected = [(key, s, node) | (key, s) <- KM.toList (properties schema), Just node <- [KM.lookup key present]]
    convert (key, s, node) = (key,) <$> elementValue s node

elementValue :: Value -> Node -> Either ShikumiError Value
elementValue schema (Element pos _ nodes)
  | null children && nullable schema && raw == "null" && not cdata = Right Null
  | null children = Right $ case kind of
      String "string" -> String raw
      String "object" | T.null raw -> Object KM.empty
      String "array" | T.null raw -> Array V.empty
      _ -> jsonText raw
  | not (T.null raw) = failure pos "non-whitespace text mixed with child elements"
  | kind == String "object" = objectFields inner children
  | kind == String "array" = do
      values <- traverse item children
      Right (Array (V.fromList values))
  | otherwise = failure pos "scalar field contains child elements"
  where
    inner = nonNull schema
    kind = property "type" inner
    children = [node | node@Element {} <- nodes]
    raw = T.strip (T.concat [t | Content _ t <- nodes])
    cdata = or [flag | Content flag _ <- nodes]
    item node@(Element p name _)
      | name == "item" = elementValue (property "items" inner) node
      | otherwise = failure p "array children must be item elements"
    item _ = failure pos "invalid array content"
elementValue _ _ = failure 0 "expected element"

escape :: Text -> Text
escape = T.replace ">" "&gt;" . T.replace "<" "&lt;" . T.replace "&" "&amp;"

json :: Value -> Text
json = decodeUtf8 . LBS.toStrict . encode

wrap :: Text -> Text -> Text
wrap name body = "<" <> name <> ">" <> body <> "</" <> name <> ">"

-- | Signature order at the root, lexical property order within records.
renderXmlFields :: [Text] -> Value -> Value -> Text
renderXmlFields names schema value = T.unlines [renderElement name (property (Key.fromText name) (Object (properties schema))) v | name <- names, Just v <- [lookupValue name value]]
  where
    lookupValue name (Object obj) = KM.lookup (Key.fromText name) obj
    lookupValue _ _ = Nothing

renderElement :: Text -> Value -> Value -> Text
renderElement name schema value = wrap name body
  where
    inner = nonNull schema
    body = case (property "type" inner, value) of
      (_, Null) -> "null"
      (String "object", Object obj) -> T.concat [renderElement (Key.toText k) (property k (Object (properties inner))) v | (k, v) <- sortOn fst (KM.toList obj)]
      (String "array", Array values) -> T.concat [renderElement "item" (property "items" inner) v | v <- V.toList values]
      (String "string", String t)
        | nullable schema && T.strip t == "null" -> "<![CDATA[" <> T.replace "]]>" "]]]]><![CDATA[>" t <> "]]>"
        | otherwise -> escape t
      _ -> escape (json value)

-- | Guide for generated record/array/scalar/nullable schemas. Other hand-written
-- schema forms use escaped JSON values and are checked by the typed decoder.
xmlSchemaGuide :: [Text] -> Value -> Text
xmlSchemaGuide names schema =
  "Reply with these XML fields (no attributes or namespaces). Escape &, < and > in text.\n"
    <> "Arrays use repeated <item> elements; empty containers may self-close. Nullable fields may be omitted or contain null; use <![CDATA[null]]> for a nullable literal string.\n"
    <> T.unlines [guide name (property (Key.fromText name) (Object (properties schema))) | name <- names]
  where
    guide name s = wrap name $ case property "type" (nonNull s) of
      String "object" -> T.concat [guide (Key.toText k) v | (k, v) <- sortOn fst (KM.toList (properties (nonNull s)))]
      String "array" -> guide "item" (property "items" (nonNull s)) <> guide "item" (property "items" (nonNull s))
      String t -> "[" <> t <> "]"
      _ -> "[escaped JSON value]"
