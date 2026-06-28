{-# LANGUAGE OverloadedStrings #-}

module WebSpec (tests) where

import Baikai (ToolCall, _ToolCall)
import Control.Lens ((&), (.~))
import Data.Aeson (Value, object, (.=))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import MockLLM (runEffMock)
import Shikumi.Tool (SomeTool (..), ToolRegistry, mkRegistry, runToolCall)
import Shikumi.Tool.Builtin.Web (webFetchTool, webSearchTool)
import Shikumi.Tool.Web
  ( FetchResult (..),
    SearchHit (..),
    SearchResult (..),
    WebClient (..),
    localWebClient,
    newTlsManager,
  )
import System.Environment (lookupEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

tc :: Text -> Value -> ToolCall
tc nm args = _ToolCall & #name .~ nm & #arguments .~ args

tests :: TestTree
tests =
  testGroup
    "Tool.Web"
    [ testCase "web_fetch returns a stubbed 200 observation" $ do
        result <-
          runEffMock [] $
            runToolCall
              stubRegistry
              (tc "web_fetch" (object ["url" .= ("https://example.test" :: Text)]))
        case result of
          Right (Right obs) -> do
            assertBool "observation includes status" ("200" `T.isInfixOf` obs)
            assertBool "observation includes body" ("stub body" `T.isInfixOf` obs)
          other -> assertFailure ("expected web_fetch observation, got " <> show other),
      testCase "web_fetch surfaces a 404 status as a value" $ do
        result <-
          runEffMock [] $
            runToolCall
              notFoundRegistry
              (tc "web_fetch" (object ["url" .= ("https://example.test/missing" :: Text)]))
        case result of
          Right (Right obs) -> do
            assertBool "observation includes 404" ("404" `T.isInfixOf` obs)
            assertBool "observation includes missing body" ("missing" `T.isInfixOf` obs)
          other -> assertFailure ("expected 404 as a tool value, got " <> show other),
      testCase "web_search returns stubbed hits" $ do
        result <-
          runEffMock [] $
            runToolCall
              stubRegistry
              (tc "web_search" (object ["query" .= ("shikumi" :: Text)]))
        case result of
          Right (Right obs) -> do
            assertBool "observation includes title" ("Stub Result" `T.isInfixOf` obs)
            assertBool "observation includes url" ("https://example.test/result" `T.isInfixOf` obs)
          other -> assertFailure ("expected web_search observation, got " <> show other),
      testCase "live web_fetch is gated by SHIKUMI_NET_TESTS" $ do
        enabled <- lookupEnv "SHIKUMI_NET_TESTS"
        case enabled of
          Nothing -> pure ()
          Just _ -> do
            manager <- newTlsManager
            result <-
              runEffMock [] $
                runToolCall
                  (mkRegistry [SomeTool (webFetchTool (localWebClient manager Nothing))])
                  (tc "web_fetch" (object ["url" .= ("https://example.com" :: Text)]))
            case result of
              Right (Right obs) -> do
                assertBool "live observation includes 200" ("200" `T.isInfixOf` obs)
                assertBool "live observation has a body" ("Example Domain" `T.isInfixOf` obs)
              Right (Left err) -> assertFailure ("live web_fetch returned tool error: " <> show err)
              Left err -> assertFailure ("live web_fetch failed: " <> show err)
    ]

stubRegistry :: ToolRegistry
stubRegistry = mkRegistry [SomeTool (webFetchTool stubWebClient), SomeTool (webSearchTool stubWebClient)]

notFoundRegistry :: ToolRegistry
notFoundRegistry = mkRegistry [SomeTool (webFetchTool notFoundWebClient)]

stubWebClient :: WebClient
stubWebClient =
  WebClient
    { webFetch = \_ _ ->
        pure FetchResult {status = 200, contentType = "text/plain", body = "stub body", truncated = False},
      webSearch = \_ _ ->
        pure
          SearchResult
            { hits =
                [ SearchHit
                    { title = "Stub Result",
                      url = "https://example.test/result",
                      snippet = "A stubbed search hit."
                    }
                ]
            }
    }

notFoundWebClient :: WebClient
notFoundWebClient =
  WebClient
    { webFetch = \_ _ ->
        pure FetchResult {status = 404, contentType = "text/plain", body = "missing", truncated = False},
      webSearch = \_ _ -> pure SearchResult {hits = []}
    }
