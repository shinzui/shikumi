{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module WebSpec (tests) where

import Baikai (ToolCall, emptyToolCall)
import Control.Lens ((&), (.~))
import Data.Aeson (Value, object, (.=))
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import MockLLM (runEffMock)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Tool (SomeTool (..), ToolRegistry, mkRegistry, runToolCall)
import Shikumi.Tool.Builtin.Web (webFetchTool, webSearchTool)
import Shikumi.Tool.Web
  ( FetchResult (..),
    SearchHit (..),
    SearchResult (..),
    WebClient (..),
    checkFetchUrl,
    defaultFetchPolicy,
    localWebClient,
    newTlsManager,
    readCapped,
  )
import System.Environment (lookupEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tc :: Text -> Value -> ToolCall
tc nm args = emptyToolCall & #name .~ nm & #arguments .~ args

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
      testCase "default fetch policy refuses metadata, loopback, and private hosts" $ do
        checkFetchUrl defaultFetchPolicy "https://example.com/x" @?= Right ()
        assertDenied "ftp://example.com"
        assertDenied "http://localhost:8080/"
        assertDenied "http://127.0.0.1/"
        assertDenied "http://169.254.169.254/latest/meta-data/"
        assertDenied "http://192.168.1.5/"
        assertDenied "http://172.20.0.1/",
      testCase "readCapped stops at the cap without draining the stream" $ do
        countRef <- newIORef (0 :: Int)
        (bytes, wasTruncated) <- readCapped 2048 (countedInfiniteChunk countRef)
        count <- readIORef countRef
        BS.length bytes @?= 2048
        wasTruncated @?= True
        assertBool "consumed at most one chunk past cap" (count <= 3),
      testCase "readCapped reports exact cap as not truncated when stream ends" $ do
        ref <- newIORef [BS.replicate 1024 97, BS.replicate 1024 98, BS.empty]
        (bytes, wasTruncated) <- readCapped 2048 (popChunk ref)
        BS.length bytes @?= 2048
        wasTruncated @?= False,
      testCase "fetch of a denied URL fails fast with ValidationFailure" $ do
        manager <- newTlsManager
        result <-
          runEffMock [] $
            webFetch
              (localWebClient manager Nothing)
              "http://169.254.169.254/latest/meta-data/"
              Nothing
        case result of
          Left (ValidationFailure msg) ->
            assertBool "mentions policy refusal" ("refused by fetch policy" `T.isInfixOf` msg)
          other -> assertFailure ("expected ValidationFailure from fetch policy, got " <> show other),
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

assertDenied :: Text -> IO ()
assertDenied url =
  case checkFetchUrl defaultFetchPolicy url of
    Left _ -> pure ()
    Right () -> assertFailure ("expected fetch policy to deny " <> T.unpack url)

countedInfiniteChunk :: IORef Int -> IO BS.ByteString
countedInfiniteChunk ref = do
  atomicModifyIORef' ref (\n -> (n + 1, ()))
  pure (BS.replicate 1024 120)

popChunk :: IORef [BS.ByteString] -> IO BS.ByteString
popChunk ref =
  atomicModifyIORef' ref $ \case
    [] -> ([], BS.empty)
    x : xs -> (xs, x)

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
