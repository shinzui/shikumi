{-# LANGUAGE OverloadedStrings #-}

module ShellSpec (tests) where

import Control.Lens ((^.))
import Data.Text qualified as T
import MockLLM (runEffMock)
import Shikumi.Tool (Tool (..))
import Shikumi.Tool.Builtin.Shell (BashReq (..), bashTool)
import Shikumi.Tool.Env (localToolEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Tool.Shell"
    [ testCase "bash captures stdout and zero exit" $ do
        result <-
          runEffMock [] $
            run
              (bashTool localToolEnv)
              BashReq {command = "echo hi", cwd = Nothing, timeoutMs = Just 5000, stdin = Nothing}
        case result of
          Left err -> assertFailure ("bashTool failed: " <> show err)
          Right resp -> do
            resp ^. #exitCode @?= 0
            assertBool "stdout contains hi" ("hi" `T.isInfixOf` (resp ^. #stdout)),
      testCase "bash returns stderr and non-zero exit as a value" $ do
        result <-
          runEffMock [] $
            run
              (bashTool localToolEnv)
              BashReq {command = "echo oops 1>&2; exit 3", cwd = Nothing, timeoutMs = Just 5000, stdin = Nothing}
        case result of
          Left err -> assertFailure ("bashTool failed: " <> show err)
          Right resp -> do
            resp ^. #exitCode @?= 3
            assertBool "stderr contains oops" ("oops" `T.isInfixOf` (resp ^. #stderr))
    ]
