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
import Effectful.Error.Static (throwError)
import Fixtures (WeatherReq, WeatherResp, weatherArgs, weatherRegistry)
import MockLLM (runEffMock)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Tool (SomeTool (..), Tool, ToolError (..), mkRegistry, mkTool, runToolCall)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tc :: Text -> Value -> ToolCall
tc nm args = _ToolCall & #name .~ nm & #arguments .~ args

budgetTool :: Tool WeatherReq WeatherResp
budgetTool =
  mkTool "burn_budget" "Always exceeds the budget." $ \_req ->
    throwError (BudgetExceeded "ceiling reached")

flakyTool :: Tool WeatherReq WeatherResp
flakyTool =
  mkTool "flaky" "Always fails validation." $ \_req ->
    throwError (ValidationFailure "nothing to see")

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
          other -> assertFailure ("expected ToolNotFound, got " <> show other),
      testCase "a tool body throwing BudgetExceeded escapes as ShikumiError" $ do
        res <- runEffMock [] (runToolCall (mkRegistry [SomeTool budgetTool]) (tc "burn_budget" weatherArgs))
        case res of
          Left (BudgetExceeded msg) -> msg @?= "ceiling reached"
          other -> assertFailure ("expected escaped BudgetExceeded, got " <> show other),
      testCase "a tool body throwing ValidationFailure becomes ToolRunFailed" $ do
        res <- runEffMock [] (runToolCall (mkRegistry [SomeTool flakyTool]) (tc "flaky" weatherArgs))
        case res of
          Right (Left (ToolRunFailed nm msg)) -> do
            nm @?= "flaky"
            assertBool "message includes validation reason" ("nothing to see" `T.isInfixOf` msg)
          other -> assertFailure ("expected ToolRunFailed, got " <> show other)
    ]
