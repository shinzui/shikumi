{-# LANGUAGE OverloadedStrings #-}

-- | M1: the typed wire round-trip. A valid 'Baikai.ToolCall' decodes, runs, and
-- encodes its result; malformed arguments and an unknown tool name each yield a
-- typed 'ToolError' (a value), never an exception.
module ToolSpec (tests) where

import Baikai (ToolCall, _ToolCall)
import Control.Lens ((&), (.~))
import Data.Aeson (Value, object, (.=))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Fixtures (weatherArgs, weatherRegistry)
import MockLLM (runEffMock)
import Shikumi.Tool (ToolError (..), runToolCall)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tc :: Text -> Value -> ToolCall
tc nm args = _ToolCall & #name .~ nm & #arguments .~ args

tests :: TestTree
tests =
  testGroup
    "Tool"
    [ testCase "decodes valid args and runs the body" $ do
        res <- runEffMock [] (runToolCall weatherRegistry (tc "get_weather" weatherArgs))
        case res of
          Right (Right obs) -> assertBool "observation mentions the forecast" ("mild" `T.isInfixOf` obs)
          other -> assertFailure ("expected a tool result, got " <> show other),
      testCase "returns ToolArgsInvalid for a missing required field" $ do
        res <- runEffMock [] (runToolCall weatherRegistry (tc "get_weather" (object ["city" .= ("Paris" :: Text)])))
        case res of
          Right (Left (ToolArgsInvalid nm _)) -> nm @?= "get_weather"
          other -> assertFailure ("expected ToolArgsInvalid, got " <> show other),
      testCase "returns ToolNotFound for an unknown name" $ do
        res <- runEffMock [] (runToolCall weatherRegistry (tc "nope" (object [])))
        case res of
          Right (Left (ToolNotFound nm)) -> nm @?= "nope"
          other -> assertFailure ("expected ToolNotFound, got " <> show other)
    ]
