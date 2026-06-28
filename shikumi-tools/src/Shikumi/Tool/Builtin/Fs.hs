{-# LANGUAGE RankNTypes #-}

-- | Built-in filesystem tools over 'ToolEnv'.
--
-- The search tools prefer host-provided @rg@/@fd@ through 'ToolEnv.exec' when
-- available, and fall back to a bounded in-process traversal through the same
-- environment record. The fallback skips noisy directories, binary files, and
-- large files, and caps traversal depth and result count.
module Shikumi.Tool.Builtin.Fs
  ( ReadReq (..),
    ReadResp (..),
    WriteReq (..),
    WriteResp (..),
    EditReq (..),
    EditResp (..),
    GrepReq (..),
    GrepMatch (..),
    GrepResp (..),
    GlobReq (..),
    GlobResp (..),
    readTool,
    writeTool,
    editTool,
    grepTool,
    globTool,
  )
where

import Control.Lens ((^.))
import Data.Aeson (ToJSON, Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseJSON, parseMaybe)
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Maybe (mapMaybe)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Effectful (Eff)
import Effectful.Error.Static (throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Schema (FromModel (..), ToSchema (..), fromModel)
import Shikumi.Tool (Tool, mkTool)
import Shikumi.Tool.Env
  ( EnvRow,
    ExecRequest (..),
    ToolEnv (..),
  )
import Text.Regex.TDFA
  ( CompOption (..),
    Regex,
    defaultCompOpt,
    defaultExecOpt,
    makeRegexOptsM,
    matchTest,
    (=~),
  )

data ReadReq = ReadReq
  { path :: !Text,
    offset :: !(Maybe Int),
    limit :: !(Maybe Int)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data ReadResp = ReadResp
  { content :: !Text,
    lineCount :: !Int,
    truncated :: !Bool
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

data WriteReq = WriteReq
  { path :: !Text,
    content :: !Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data WriteResp = WriteResp
  { path :: !Text,
    bytesWritten :: !Int
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

data EditReq = EditReq
  { path :: !Text,
    oldString :: !Text,
    newString :: !Text,
    replaceAll :: !(Maybe Bool)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data EditResp = EditResp
  { path :: !Text,
    replacements :: !Int
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

data GrepReq = GrepReq
  { patternText :: !Text,
    path :: !(Maybe Text),
    glob :: !(Maybe Text),
    ignoreCase :: !(Maybe Bool)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToPrompt)

instance ToSchema GrepReq where
  toSchema _ =
    toolInputSchema
      [ ("pattern", toSchema (Proxy :: Proxy Text)),
        ("path", toSchema (Proxy :: Proxy (Maybe Text))),
        ("glob", toSchema (Proxy :: Proxy (Maybe Text))),
        ("ignoreCase", toSchema (Proxy :: Proxy (Maybe Bool)))
      ]

instance FromModel GrepReq where
  fromModelP _ = \case
    Object obj ->
      GrepReq
        <$> requiredField "pattern" obj
        <*> optionalField "path" obj
        <*> optionalField "glob" obj
        <*> optionalField "ignoreCase" obj
    v -> Left (SchemaMismatch ("grep request must be an object, got " <> T.pack (show v)))

data GrepMatch = GrepMatch
  { file :: !Text,
    line :: !Int,
    text :: !Text
  }
  deriving stock (Generic, Show, Eq, Ord)
  deriving anyclass (ToJSON)

data GrepResp = GrepResp
  { matches :: ![GrepMatch],
    truncated :: !Bool
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

data GlobReq = GlobReq
  { patternText :: !Text,
    path :: !(Maybe Text)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToPrompt)

instance ToSchema GlobReq where
  toSchema _ =
    toolInputSchema
      [ ("pattern", toSchema (Proxy :: Proxy Text)),
        ("path", toSchema (Proxy :: Proxy (Maybe Text)))
      ]

instance FromModel GlobReq where
  fromModelP _ = \case
    Object obj ->
      GlobReq
        <$> requiredField "pattern" obj
        <*> optionalField "path" obj
    v -> Left (SchemaMismatch ("glob request must be an object, got " <> T.pack (show v)))

data GlobResp = GlobResp
  { paths :: ![Text],
    truncated :: !Bool
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

readTool :: ToolEnv -> Tool ReadReq ReadResp
readTool env =
  mkTool "read" "Read a file's contents." $ \req -> do
    bs <- envReadFile env (req ^. #path)
    let allLines = T.lines (decodeUtf8 bs)
        start = max 0 (maybe 0 id (req ^. #offset))
        afterOffset = drop start allLines
        selected = maybe afterOffset (`take` afterOffset) (req ^. #limit)
        wasTruncated = start > 0 || length selected < length afterOffset
    pure ReadResp {content = T.unlines selected, lineCount = length selected, truncated = wasTruncated}

writeTool :: ToolEnv -> Tool WriteReq WriteResp
writeTool env =
  mkTool "write" "Write UTF-8 text to a file." $ \req -> do
    let bytes = TE.encodeUtf8 (req ^. #content)
    envWriteFile env (req ^. #path) bytes
    pure WriteResp {path = req ^. #path, bytesWritten = BS.length bytes}

editTool :: ToolEnv -> Tool EditReq EditResp
editTool env =
  mkTool "edit" "Replace text in a UTF-8 file." $ \req -> do
    let old = req ^. #oldString
    if T.null old
      then throwValidation "edit: oldString must not be empty"
      else do
        original <- decodeUtf8 <$> envReadFile env (req ^. #path)
        (edited, count) <-
          if maybe False id (req ^. #replaceAll)
            then pure (replaceAllCount old (req ^. #newString) original)
            else pure (replaceFirstCount old (req ^. #newString) original)
        if count == 0
          then throwValidation "edit: oldString not found"
          else do
            envWriteFile env (req ^. #path) (TE.encodeUtf8 edited)
            pure EditResp {path = req ^. #path, replacements = count}

grepTool :: ToolEnv -> Tool GrepReq GrepResp
grepTool env =
  mkTool "grep" "Search files with a regex and return structured matches." $ \req -> do
    root <- maybe (envCwd env) pure (req ^. #path)
    fast <- commandPresent env "rg"
    if fast
      then do
        resp <- grepFast env root req
        case resp of
          Just value -> pure value
          Nothing -> grepFallback env root req
      else grepFallback env root req

globTool :: ToolEnv -> Tool GlobReq GlobResp
globTool env =
  mkTool "glob" "Find files matching a glob pattern and return structured paths." $ \req -> do
    root <- maybe (envCwd env) pure (req ^. #path)
    fast <- commandPresent env "fd"
    let pat = req ^. #patternText
    if fast
      then do
        resp <- globFast env root pat
        case resp of
          Just value -> pure value
          Nothing -> globFallback env root pat
      else globFallback env root pat

grepFast :: (EnvRow es) => ToolEnv -> Text -> GrepReq -> Eff es (Maybe GrepResp)
grepFast env root req = do
  result <-
    envExec
      env
      ExecRequest
        { command =
            T.unwords
              [ "rg --json --color never --max-filesize 5M",
                if maybe False id (req ^. #ignoreCase) then "-i" else "",
                maybe "" (\g -> "-g " <> shellQuote g) (req ^. #glob),
                "--",
                shellQuote (req ^. #patternText),
                shellQuote root
              ],
          cwd = Nothing,
          stdin = Nothing,
          timeoutMs = Just 30000
        }
  if result ^. #exitCode == 0 || result ^. #exitCode == 1
    then pure (Just (parseRgJson (result ^. #stdout)))
    else pure Nothing

globFast :: (EnvRow es) => ToolEnv -> Text -> Text -> Eff es (Maybe GlobResp)
globFast env root pat = do
  result <-
    envExec
      env
      ExecRequest
        { command =
            T.unwords
              [ "fd --glob --color never --exclude .git --exclude node_modules --exclude dist-newstyle --exclude .stack-work",
                "--",
                shellQuote pat,
                shellQuote root
              ],
          cwd = Nothing,
          stdin = Nothing,
          timeoutMs = Just 30000
        }
  if result ^. #exitCode == 0
    then do
      let found = take maxResults (filter (not . T.null) (T.lines (result ^. #stdout)))
      pure (Just GlobResp {paths = sort found, truncated = length found >= maxResults})
    else pure Nothing

grepFallback :: (EnvRow es) => ToolEnv -> Text -> GrepReq -> Eff es GrepResp
grepFallback env root req = do
  regex <- compileRegex (req ^. #patternText) (maybe False id (req ^. #ignoreCase))
  paths <- walkFiles env root
  let globOk p = maybe True (`globMatches` p) (req ^. #glob)
  matches <-
    fmap concat $
      traverse
        ( \filePath -> do
            if globOk filePath
              then grepFile env regex filePath
              else pure []
        )
        paths
  let limited = take maxResults matches
  pure GrepResp {matches = limited, truncated = length matches > maxResults}

globFallback :: (EnvRow es) => ToolEnv -> Text -> Text -> Eff es GlobResp
globFallback env root pat = do
  paths <- walkFiles env root
  let found = sort (take maxResults (filter (globMatches pat) paths))
  pure GlobResp {paths = found, truncated = length found >= maxResults}

grepFile :: (EnvRow es) => ToolEnv -> Regex -> Text -> Eff es [GrepMatch]
grepFile env regex filePath = do
  stat <- envStat env filePath
  case stat of
    Just s | s ^. #isFile && s ^. #size <= maxFileSize -> do
      bs <- envReadFile env filePath
      if isBinary bs
        then pure []
        else do
          let lineMatches = regexMatches regex
          pure
            [ GrepMatch {file = filePath, line = n, text = lineText}
            | (n, lineText) <- zip [1 ..] (T.lines (decodeUtf8 bs)),
              lineMatches lineText
            ]
    _ -> pure []

walkFiles :: (EnvRow es) => ToolEnv -> Text -> Eff es [Text]
walkFiles env root = go 0 root
  where
    go depth dir
      | depth > maxDepth = pure []
      | otherwise = do
          entries <- envReaddir env dir
          fmap concat $
            traverse
              ( \entry -> do
                  let child = joinPathText dir (entry ^. #name)
                  if entry ^. #isDir
                    then
                      if skipDirName (entry ^. #name)
                        then pure []
                        else go (depth + 1) child
                    else pure [child]
              )
              entries

parseRgJson :: Text -> GrepResp
parseRgJson output =
  let matches = take maxResults (mapMaybe parseLine (T.lines output))
   in GrepResp {matches, truncated = length matches >= maxResults}
  where
    parseLine line = do
      Object obj <- either (const Nothing) Just (eitherDecodeStrict (TE.encodeUtf8 line))
      String "match" <- KM.lookup "type" obj
      Object dat <- KM.lookup "data" obj
      Object pathObj <- KM.lookup "path" dat
      String file <- KM.lookup "text" pathObj
      Object linesObj <- KM.lookup "lines" dat
      String text <- KM.lookup "text" linesObj
      Number lineNo <- KM.lookup "line_number" dat
      n <- parseMaybe parseJSON (Number lineNo)
      pure GrepMatch {file, line = n, text = T.dropWhileEnd (== '\n') text}

compileRegex :: (EnvRow es) => Text -> Bool -> Eff es Regex
compileRegex pat ignoreCase =
  case makeRegexOptsM defaultCompOpt {caseSensitive = not ignoreCase} defaultExecOpt (T.unpack pat) of
    Just regex -> pure regex
    Nothing -> throwValidation ("grep: invalid regex pattern " <> pat)

regexMatches :: Regex -> Text -> Bool
regexMatches regex haystack = matchTest regex (T.unpack haystack)

globMatches :: Text -> Text -> Bool
globMatches pat candidate =
  T.unpack candidate =~ ("^" <> T.unpack (globToRegex pat) <> "$" :: String)

globToRegex :: Text -> Text
globToRegex = go . T.unpack
  where
    go [] = ""
    go ('*' : '*' : rest) = ".*" <> go rest
    go ('*' : rest) = "[^/]*" <> go rest
    go ('?' : rest) = "[^/]" <> go rest
    go (c : rest) = T.pack (escapeRegex c) <> go rest

replaceFirstCount :: Text -> Text -> Text -> (Text, Int)
replaceFirstCount old new src =
  let (before, after) = T.breakOn old src
   in if T.null after
        then (src, 0)
        else (before <> new <> T.drop (T.length old) after, 1)

replaceAllCount :: Text -> Text -> Text -> (Text, Int)
replaceAllCount old new src =
  let pieces = T.splitOn old src
      count = length pieces - 1
   in (T.intercalate new pieces, count)

commandPresent :: (EnvRow es) => ToolEnv -> Text -> Eff es Bool
commandPresent env cmd = do
  result <-
    envExec
      env
      ExecRequest
        { command = "command -v " <> cmd,
          cwd = Nothing,
          stdin = Nothing,
          timeoutMs = Just 5000
        }
  pure (result ^. #exitCode == 0)

decodeUtf8 :: BS.ByteString -> Text
decodeUtf8 = TE.decodeUtf8With lenientDecode

isBinary :: BS.ByteString -> Bool
isBinary = BS.elem 0 . BS.take 8192

skipDirName :: Text -> Bool
skipDirName name =
  name `elem` [".git", ".hg", ".svn", "node_modules", "dist-newstyle", ".stack-work", ".direnv"]

joinPathText :: Text -> Text -> Text
joinPathText base name
  | T.null base = name
  | "/" `T.isSuffixOf` base = base <> name
  | otherwise = base <> "/" <> name

shellQuote :: Text -> Text
shellQuote t = "'" <> T.replace "'" "'\\''" t <> "'"

escapeRegex :: Char -> String
escapeRegex c
  | isAlphaNum c || c == '/' || c == '_' || c == '-' = [c]
  | otherwise = ['\\', c]

throwValidation :: (EnvRow es) => Text -> Eff es a
throwValidation = throwError . ValidationFailure

toolInputSchema :: [(Text, Value)] -> Value
toolInputSchema fields =
  object
    [ "type" .= ("object" :: Text),
      "properties" .= object (map (\(key, value) -> Key.fromText key .= value) fields),
      "required" .= (["pattern"] :: [Text]),
      "additionalProperties" .= False
    ]

requiredField :: (FromModel a) => Text -> KM.KeyMap Value -> Either ShikumiError a
requiredField key obj =
  case KM.lookup (Key.fromText key) obj of
    Nothing -> Left (MissingField key)
    Just value -> fromModel value

optionalField :: (FromModel a) => Text -> KM.KeyMap Value -> Either ShikumiError (Maybe a)
optionalField key obj =
  case KM.lookup (Key.fromText key) obj of
    Nothing -> Right Nothing
    Just Null -> Right Nothing
    Just value -> Just <$> fromModel value

maxResults :: Int
maxResults = 1000

maxFileSize :: Integer
maxFileSize = 5 * 1024 * 1024

maxDepth :: Int
maxDepth = 25
