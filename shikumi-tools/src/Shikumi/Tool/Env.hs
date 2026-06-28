{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RankNTypes #-}

-- | Execution-environment operations for built-in work tools.
--
-- Filesystem and process-backed tools should depend on this record instead of
-- calling the host operating system directly. A future sandbox can provide a
-- different 'ToolEnv' value while the tool definitions stay unchanged.
module Shikumi.Tool.Env
  ( Path,
    EnvRow,
    ExecRequest (..),
    ExecResult (..),
    FileStat (..),
    DirEntry (..),
    ToolEnv (..),
    localToolEnv,
  )
where

import Control.Exception (IOException, try)
import Control.Lens ((^.))
import Data.Aeson (ToJSON)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Dispatch.Static (unsafeEff_)
import Effectful.Error.Static (Error, throwError)
import GHC.Generics (Generic)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM)
import System.Directory qualified as Dir
import System.Exit (ExitCode (..))
import System.Process qualified as Proc
import System.Timeout qualified as Timeout

type Path = Text

type EnvRow es = (LLM :> es, Error ShikumiError :> es)

data ExecRequest = ExecRequest
  { command :: !Text,
    cwd :: !(Maybe Path),
    stdin :: !(Maybe Text),
    timeoutMs :: !(Maybe Int)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

data ExecResult = ExecResult
  { exitCode :: !Int,
    stdout :: !Text,
    stderr :: !Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

data FileStat = FileStat
  { isFile :: !Bool,
    isDir :: !Bool,
    size :: !Integer
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

data DirEntry = DirEntry
  { name :: !Text,
    isDir :: !Bool
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

data ToolEnv = ToolEnv
  { envExec :: forall es. (EnvRow es) => ExecRequest -> Eff es ExecResult,
    envReadFile :: forall es. (EnvRow es) => Path -> Eff es ByteString,
    envWriteFile :: forall es. (EnvRow es) => Path -> ByteString -> Eff es (),
    envStat :: forall es. (EnvRow es) => Path -> Eff es (Maybe FileStat),
    envReaddir :: forall es. (EnvRow es) => Path -> Eff es [DirEntry],
    envExists :: forall es. (EnvRow es) => Path -> Eff es Bool,
    envMkdir :: forall es. (EnvRow es) => Path -> Eff es (),
    envRm :: forall es. (EnvRow es) => Path -> Eff es (),
    envCwd :: forall es. (EnvRow es) => Eff es Path
  }

localToolEnv :: ToolEnv
localToolEnv =
  ToolEnv
    { envExec = localExec,
      envReadFile = \path -> toolIO "readFile" (BS.readFile (T.unpack path)),
      envWriteFile = \path bytes -> toolIO "writeFile" (BS.writeFile (T.unpack path) bytes),
      envStat = localStat,
      envReaddir = localReaddir,
      envExists = \path -> toolIO "exists" (Dir.doesPathExist (T.unpack path)),
      envMkdir = \path -> toolIO "mkdir" (Dir.createDirectoryIfMissing True (T.unpack path)),
      envRm = localRm,
      envCwd = T.pack <$> toolIO "cwd" Dir.getCurrentDirectory
    }

localExec :: (EnvRow es) => ExecRequest -> Eff es ExecResult
localExec req = do
  let effectiveTimeoutMs = timeoutMsOrDefault (req ^. #timeoutMs)
  result <-
    toolIO "exec" $
      Timeout.timeout (effectiveTimeoutMs * 1000) $
        Proc.readCreateProcessWithExitCode process stdinText
  case result of
    Nothing ->
      throwError $
        Timeout
          ("tool env: exec timed out after " <> T.pack (show effectiveTimeoutMs) <> "ms")
    Just (exit, out, err) ->
      pure
        ExecResult
          { exitCode = exitCodeInt exit,
            stdout = T.pack out,
            stderr = T.pack err
          }
  where
    process =
      (Proc.proc "bash" ["-c", T.unpack (req ^. #command)])
        { Proc.cwd = T.unpack <$> (req ^. #cwd)
        }
    stdinText = maybe "" T.unpack (req ^. #stdin)

localStat :: (EnvRow es) => Path -> Eff es (Maybe FileStat)
localStat path = toolIO "stat" $ do
  let fp = T.unpack path
  file <- Dir.doesFileExist fp
  dir <- Dir.doesDirectoryExist fp
  if file
    then do
      size <- Dir.getFileSize fp
      pure (Just FileStat {isFile = True, isDir = False, size})
    else
      if dir
        then pure (Just FileStat {isFile = False, isDir = True, size = 0})
        else pure Nothing

localReaddir :: (EnvRow es) => Path -> Eff es [DirEntry]
localReaddir path = toolIO "readdir" $ do
  let dir = T.unpack path
  names <- Dir.listDirectory dir
  traverse
    ( \entry -> do
        isDir <- Dir.doesDirectoryExist (dir <> "/" <> entry)
        pure DirEntry {name = T.pack entry, isDir}
    )
    names

localRm :: (EnvRow es) => Path -> Eff es ()
localRm path = toolIO "rm" $ do
  let fp = T.unpack path
  file <- Dir.doesFileExist fp
  dir <- Dir.doesDirectoryExist fp
  if file
    then Dir.removeFile fp
    else
      if dir
        then Dir.removeDirectory fp
        else pure ()

toolIO :: (EnvRow es) => Text -> IO a -> Eff es a
toolIO label action = do
  result <- unsafeEff_ (try action)
  case result of
    Right value -> pure value
    Left (err :: IOException) ->
      throwError (ProviderFailure ("tool env: " <> label <> ": " <> T.pack (show err)))

timeoutMsOrDefault :: Maybe Int -> Int
timeoutMsOrDefault = maybe 60000 id

exitCodeInt :: ExitCode -> Int
exitCodeInt ExitSuccess = 0
exitCodeInt (ExitFailure n) = n
