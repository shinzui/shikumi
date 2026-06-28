{-# LANGUAGE OverloadedStrings #-}

module FsSpec (tests) where

import Control.Exception (bracket)
import Control.Lens ((^.))
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import MockLLM (runEffMock)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Tool (Tool (..))
import Shikumi.Tool.Builtin.Fs
  ( EditReq (..),
    GlobReq (..),
    GrepMatch (..),
    GrepReq (..),
    ReadReq (..),
    WriteReq (..),
    editTool,
    globTool,
    grepTool,
    readTool,
    writeTool,
  )
import Shikumi.Tool.Env
  ( ExecRequest (..),
    ExecResult (..),
    ToolEnv (..),
    envCwd,
    envExec,
    envExists,
    envMkdir,
    envReadFile,
    envReaddir,
    envRm,
    envStat,
    envWriteFile,
    localToolEnv,
  )
import System.Directory qualified as Dir
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Tool.Fs"
    [ testCase "read/write/edit/grep/glob work through fast and fallback paths" $
        withTempDir "roundtrip" $ \root -> do
          let file = T.pack (root </> "note.txt")
          result <-
            runEffMock [] $ do
              rgPresent <- envExec localToolEnv (presentReq "rg")
              fdPresent <- envExec localToolEnv (presentReq "fd")
              written <- run (writeTool localToolEnv) WriteReq {path = file, content = "alpha\nold title\n"}
              before <- run (readTool localToolEnv) ReadReq {path = file, offset = Nothing, limit = Nothing}
              edited <-
                run
                  (editTool localToolEnv)
                  EditReq {path = file, oldString = "old title", newString = "new title", replaceAll = Nothing}
              after <- run (readTool localToolEnv) ReadReq {path = file, offset = Nothing, limit = Nothing}
              fastGrep <-
                run
                  (grepTool localToolEnv)
                  GrepReq {patternText = "new title", path = Just (T.pack root), glob = Just "**/*.txt", ignoreCase = Nothing}
              fallbackGrep <-
                run
                  (grepTool noFastToolEnv)
                  GrepReq {patternText = "new title", path = Just (T.pack root), glob = Just "**/*.txt", ignoreCase = Nothing}
              fastGlob <- run (globTool localToolEnv) GlobReq {patternText = "**/*.txt", path = Just (T.pack root)}
              fallbackGlob <- run (globTool noFastToolEnv) GlobReq {patternText = "**/*.txt", path = Just (T.pack root)}
              pure (rgPresent, fdPresent, written, before, edited, after, fastGrep, fallbackGrep, fastGlob, fallbackGlob)
          case result of
            Left err -> assertFailure ("fs tools failed: " <> show err)
            Right (rgPresent, fdPresent, written, before, edited, after, fastGrep, fallbackGrep, fastGlob, fallbackGlob) -> do
              rgPresent ^. #exitCode @?= 0
              fdPresent ^. #exitCode @?= 0
              written ^. #bytesWritten @?= BS.length "alpha\nold title\n"
              before ^. #content @?= "alpha\nold title\n"
              edited ^. #replacements @?= 1
              after ^. #content @?= "alpha\nnew title\n"
              normalizeMatches (fastGrep ^. #matches) @?= normalizeMatches (fallbackGrep ^. #matches)
              assertBool "grep finds edited text" (any (\m -> m ^. #text == "new title") (fastGrep ^. #matches))
              assertBool "fast glob finds file" (file `elem` (fastGlob ^. #paths))
              assertBool "fallback glob finds file" (file `elem` (fallbackGlob ^. #paths)),
      testCase "fallback grep skips noisy directories and binary files" $
        withTempDir "hardening" $ \root -> do
          let visible = T.pack (root </> "visible.txt")
              gitFile = T.pack (root </> ".git" </> "packed.txt")
              nodeFile = T.pack (root </> "node_modules" </> "dep.txt")
              binaryFile = T.pack (root </> "binary.bin")
          result <-
            runEffMock [] $ do
              envWriteFile localToolEnv visible "SECRET visible\n"
              envMkdir localToolEnv (T.pack (root </> ".git"))
              envWriteFile localToolEnv gitFile "SECRET git\n"
              envMkdir localToolEnv (T.pack (root </> "node_modules"))
              envWriteFile localToolEnv nodeFile "SECRET node\n"
              envWriteFile localToolEnv binaryFile (BS.pack [0, 83, 69, 67, 82, 69, 84])
              run
                (grepTool noFastToolEnv)
                GrepReq {patternText = "SECRET", path = Just (T.pack root), glob = Nothing, ignoreCase = Nothing}
          case result of
            Left err -> assertFailure ("fallback grep failed: " <> show err)
            Right resp -> do
              normalizeMatches (resp ^. #matches) @?= [GrepMatch {file = visible, line = 1, text = "SECRET visible"}]
              resp ^. #truncated @?= False,
      testCase "fallback grep reports malformed regex as ValidationFailure" $
        withTempDir "bad-regex" $ \root -> do
          let visible = T.pack (root </> "visible.txt")
          result <-
            runEffMock [] $ do
              envWriteFile localToolEnv visible "hello\n"
              run
                (grepTool noFastToolEnv)
                GrepReq {patternText = "[", path = Just (T.pack root), glob = Nothing, ignoreCase = Nothing}
          case result of
            Left (ValidationFailure msg) -> assertBool "mentions invalid regex" ("invalid regex" `T.isInfixOf` msg)
            other -> assertFailure ("expected ValidationFailure, got " <> show other)
    ]

withTempDir :: FilePath -> (FilePath -> IO a) -> IO a
withTempDir suffix action = do
  tmp <- Dir.getTemporaryDirectory
  let root = tmp </> ("shikumi-tools-fsspec-" <> suffix)
  bracket
    (Dir.removePathForcibly root >> Dir.createDirectoryIfMissing True root >> pure root)
    Dir.removePathForcibly
    action

presentReq :: Text -> ExecRequest
presentReq command =
  ExecRequest
    { command = "command -v " <> command,
      cwd = Nothing,
      stdin = Nothing,
      timeoutMs = Just 5000
    }

noFastToolEnv :: ToolEnv
noFastToolEnv =
  ToolEnv
    { envExec = \req ->
        if "command -v rg" `T.isPrefixOf` (req ^. #command) || "command -v fd" `T.isPrefixOf` (req ^. #command)
          then pure ExecResult {exitCode = 1, stdout = "", stderr = ""}
          else envExec localToolEnv req,
      envReadFile = envReadFile localToolEnv,
      envWriteFile = envWriteFile localToolEnv,
      envStat = envStat localToolEnv,
      envReaddir = envReaddir localToolEnv,
      envExists = envExists localToolEnv,
      envMkdir = envMkdir localToolEnv,
      envRm = envRm localToolEnv,
      envCwd = envCwd localToolEnv
    }

normalizeMatches :: [GrepMatch] -> [GrepMatch]
normalizeMatches = sort
