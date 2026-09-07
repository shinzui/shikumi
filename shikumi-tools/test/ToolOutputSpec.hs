module ToolOutputSpec (tests) where

import Baikai qualified as B
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (object, (.=))
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful.Error.Static (throwError)
import Fixtures (weatherArgs, weatherRegistry)
import MockLLM (runEffMock)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Tool
import Shikumi.Tool.Output
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "ToolOutput"
    [ testCase "typed text compatibility" $ do
        let call = B.ToolCall "A" "get_weather" weatherArgs
        rich <- runEffMock [] (runToolCallOutput weatherRegistry call)
        plain <- runEffMock [] (runToolCall weatherRegistry call)
        fmap (fmap renderToolOutput) rich @?= plain,
      testCase "structured-only dynamic output is preserved and visible" $ do
        let value = object ["answer" .= (42 :: Int)]
            output = ToolOutput (B.ToolResult V.empty False) (Just value) [value]
            reg = mkRegistry [mkDynTool "dynamic" "runtime" (object []) (\_ -> pure (Right output))]
            call = B.ToolCall "A" "dynamic" (object [])
        actual <- runEffMock [] (runToolCallOutput reg call)
        actual @?= Right (Right output)
        assertBool "JSON labels" ("Structured JSON:" `T.isInfixOf` renderToolOutput output && "Extension JSON:" `T.isInfixOf` renderToolOutput output)
        case toolOutputMessage call output of
          B.ToolResultMessage p -> do
            p ^. #toolCallId @?= "A"
            V.length (p ^. #content) @?= 2
          _ -> assertFailure "expected tool message",
      testCase "mixed native blocks retain images and error flag" $ do
        let img = B.emptyImageContent & #imageData .~ "bytes" & #mimeType .~ "image/png"
            blocks = V.fromList [B.ToolResultText (B.TextContent "caption"), B.ToolResultImage img]
            output = ToolOutput (B.ToolResult blocks True) Nothing []
        case toolOutputMessage (B.ToolCall "A" "tool" (object [])) output of
          B.ToolResultMessage p -> do
            p ^. #content @?= blocks
            p ^. #isError @?= True
          _ -> assertFailure "expected tool message"
        assertBool "error flag visible in prompt/text projection" ("Tool error:" `T.isPrefixOf` renderToolOutput output)
        assertBool "image not dropped in text projection" ("Image JSON:" `T.isInfixOf` renderToolOutput output),
      testCase "dynamic recoverable failure is model-visible" $ do
        let tool = mkDynTool "bad" "" (object []) (\_ -> throwError (ValidationFailure "bad result"))
        result <- runEffMock [] (runErasedOutput tool (object []))
        result @?= Right (Left (ToolRunFailed "bad" "bad result"))
    ]
