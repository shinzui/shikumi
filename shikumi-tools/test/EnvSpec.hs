{-# LANGUAGE OverloadedStrings #-}

module EnvSpec (tests) where

import Control.Lens ((^.))
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.List (find)
import Data.Text qualified as T
import MockLLM (runEffMock)
import Shikumi.Tool.Env
  ( DirEntry,
    ExecRequest (..),
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
    "Tool.Env"
    [ testCase "localToolEnv can perform filesystem operations and exec" $ do
        root <- freshTempDir
        let file = T.pack (root </> "hello.txt")
            nested = T.pack (root </> "nested")
        result <-
          runEffMock [] $ do
            envWriteFile localToolEnv file "hello\n"
            bytes <- envReadFile localToolEnv file
            stat <- envStat localToolEnv file
            entries <- envReaddir localToolEnv (T.pack root)
            exists <- envExists localToolEnv file
            envMkdir localToolEnv nested
            nestedExists <- envExists localToolEnv nested
            envRm localToolEnv nested
            nestedGone <- not <$> envExists localToolEnv nested
            execResult <-
              envExec
                localToolEnv
                ExecRequest
                  { command = "echo hello",
                    cwd = Just (T.pack root),
                    stdin = Nothing,
                    timeoutMs = Just 5000
                  }
            cwd <- envCwd localToolEnv
            pure (bytes, stat, entries, exists, nestedExists, nestedGone, execResult, cwd)
        Dir.removePathForcibly root
        case result of
          Left err -> assertFailure ("localToolEnv failed: " <> show err)
          Right (bytes, stat, entries, exists, nestedExists, nestedGone, execResult, cwd) -> do
            bytes @?= "hello\n"
            case stat of
              Just fileStat -> do
                fileStat ^. #isFile @?= True
                fileStat ^. #isDir @?= False
                fileStat ^. #size @?= fromIntegral (BS.length bytes)
              Nothing -> assertFailure "expected stat for written file"
            assertBool "readdir includes written file" (hasEntry "hello.txt" entries)
            exists @?= True
            nestedExists @?= True
            nestedGone @?= True
            execResult ^. #exitCode @?= 0
            assertBool "exec stdout includes hello" ("hello" `T.isInfixOf` (execResult ^. #stdout))
            assertBool "cwd returns an absolute path" ("/" `T.isPrefixOf` cwd)
    ]

freshTempDir :: IO FilePath
freshTempDir = do
  tmp <- Dir.getTemporaryDirectory
  let root = tmp </> "shikumi-tools-envspec"
  Dir.removePathForcibly root
  Dir.createDirectoryIfMissing True root
  pure root

hasEntry :: T.Text -> [DirEntry] -> Bool
hasEntry wanted = maybe False (const True) . find (\entry -> entry ^. #name == wanted)
