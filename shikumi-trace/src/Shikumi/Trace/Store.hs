-- | Persisting a 'TraceTree' to a stable on-disk JSON format, and deriving the
-- replay index from it (EP-7, M2).
--
-- A trace file is a single JSON document — a 'TraceFile' carrying a
-- @formatVersion@ integer and the whole 'TraceTree'. Persisting the tree as a
-- tree (rather than a flat event log) keeps replay a simple key lookup and keeps
-- the file inspectable with @jq@ (e.g. @jq '.tree.spans | length'@).
--
-- 'writeTraceFile' is atomic (write to a sibling @.tmp@ then rename), so a crash
-- mid-write never leaves a half-written file. 'readTraceFile' returns 'Left' on a
-- parse error or a format-version mismatch — replay refuses to start on a file it
-- does not understand rather than producing wrong outputs.
--
-- 'replayIndex' projects the tree into the @Map CacheKey Value@ the replay
-- interpreter ('Shikumi.Trace.Replay') consults: each LM-call span's EP-6
-- 'Shikumi.Cache.Key.CacheKey' mapped to its recorded response JSON.
module Shikumi.Trace.Store
  ( TraceFile (..),
    currentFormatVersion,
    writeTraceFile,
    readTraceFile,
    replayIndex,
  )
where

import Control.Lens ((^.))
import Data.Aeson (FromJSON, ToJSON, Value, eitherDecode, encode)
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Shikumi.Cache.Key (CacheKey (..))
import Shikumi.Trace (SpanKind (LlmCallSpan), TraceTree (..))
import System.Directory (renameFile)

-- | The on-disk wrapper: a format version plus the tree. Bump
-- 'currentFormatVersion' on any breaking schema change so old files are rejected
-- loudly rather than mis-decoded.
data TraceFile = TraceFile
  { formatVersion :: !Int,
    tree :: !TraceTree
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The trace-file schema version this build reads and writes. Bumped 1→2 in
-- EP-16 for the additive optional @SpanAttrs.nodePath@ field.
currentFormatVersion :: Int
currentFormatVersion = 2

-- | Write a tree to @path@ atomically: encode to a sibling @.tmp@ file, then
-- 'renameFile' it into place (an atomic rename on the same filesystem).
writeTraceFile :: FilePath -> TraceTree -> IO ()
writeTraceFile path t = do
  let tmp = path <> ".tmp"
  BL.writeFile tmp (encode (TraceFile currentFormatVersion t))
  renameFile tmp path

-- | Read a tree from @path@. 'Left' on a JSON parse error or a @formatVersion@
-- this build does not understand.
readTraceFile :: FilePath -> IO (Either Text TraceTree)
readTraceFile path = do
  bs <- BL.readFile path
  pure $ case eitherDecode bs of
    Left e -> Left ("trace parse error: " <> T.pack e)
    Right tf
      | formatVersion tf /= currentFormatVersion ->
          Left
            ( "unsupported trace formatVersion "
                <> T.pack (show (formatVersion tf))
                <> " (expected "
                <> T.pack (show currentFormatVersion)
                <> ")"
            )
      | otherwise -> Right (tree tf)

-- | The replay index: every LM-call span's content-addressed key mapped to its
-- recorded response JSON. A span missing either its @cacheKey@ or its @response@
-- contributes nothing.
replayIndex :: TraceTree -> Map CacheKey Value
replayIndex t =
  Map.fromList
    [ (CacheKey ck, v)
    | s <- Map.elems (spans t),
      (s ^. #kind) == LlmCallSpan,
      Just ck <- [s ^. #attrs . #cacheKey],
      Just v <- [s ^. #attrs . #response]
    ]
