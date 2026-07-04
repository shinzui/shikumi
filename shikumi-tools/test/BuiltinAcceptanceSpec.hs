{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}

module BuiltinAcceptanceSpec (tests) where

import Baikai (Response)
import Control.Exception (bracket)
import Control.Lens ((&), (.~))
import Data.Aeson (object, (.=))
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import GHC.Generics (Generic)
import MockLLM (mkTextResponse, mkToolCallResponse, runAgent)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Agent.ReAct
  ( Action (..),
    Step (..),
    Termination (..),
    ToolProtocol (..),
    Trajectory (..),
    defaultReActConfig,
    reactWithTrajectory,
  )
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Tool.Builtin (builtinRegistry)
import Shikumi.Tool.Env (localToolEnv)
import Shikumi.Tool.Web (FetchResult (..), SearchResult (..), WebClient (..))
import System.Directory qualified as Dir
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

data WorkTask = WorkTask {task :: !Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToPrompt)

data WorkAnswer = WorkAnswer {done :: !Bool}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

instance Validatable WorkAnswer

tests :: TestTree
tests =
  testGroup
    "BuiltinAcceptance"
    [ testCase "builtinRegistry drives a scripted work cycle" $
        withTempDir "builtin" $ \root -> do
          let file = T.pack (root </> "README.md")
          TIO.writeFile (T.unpack file) "# Old Title\n\nbody\n"
          res <-
            runAgent
              (script (T.pack root) file)
              (reactWithTrajectory workSignature (builtinRegistry localToolEnv stubWebClient) (defaultReActConfig & #protocol .~ ProtocolNative))
              WorkTask {task = "Update the title and verify it."}
          finalContent <- TIO.readFile (T.unpack file)
          case res of
            Left err -> assertFailure ("builtin agent failed: " <> show err)
            Right (answer, traj) -> do
              answer @?= WorkAnswer {done = True}
              termination traj @?= TerminatedFinish
              finalContent @?= "# New Title\n\nbody\n"
              let stepList = V.toList (steps traj)
              V.length (steps traj) @?= 6
              toolNames stepList @?= ["read", "edit", "bash", "grep", "web_fetch"]
              case stepList of
                [readStep, editStep, bashStep, grepStep, fetchStep, finishStep] -> do
                  assertObservation "read observes original content" "Old Title" readStep
                  assertObservation "edit reports replacement" "replacements" editStep
                  assertObservation "bash sees new title" "New Title" bashStep
                  assertObservation "grep sees new title" "New Title" grepStep
                  assertObservation "web_fetch sees stub body" "stub body" fetchStep
                  action finishStep @?= Finish
                _ -> assertFailure "expected five tool steps and one finish step"
    ]

workSignature :: Signature WorkTask WorkAnswer
workSignature = mkSignature "Use the builtin tools to complete the requested repository work."

script :: Text -> Text -> [Response]
script root file =
  [ mkToolCallResponse "call_read" "read" (object ["path" .= file]),
    mkToolCallResponse
      "call_edit"
      "edit"
      ( object
          [ "path" .= file,
            "oldString" .= ("# Old Title" :: Text),
            "newString" .= ("# New Title" :: Text)
          ]
      ),
    mkToolCallResponse
      "call_bash"
      "bash"
      (object ["command" .= ("cat " <> shellQuote file), "timeoutMs" .= (5000 :: Int)]),
    mkToolCallResponse
      "call_grep"
      "grep"
      ( object
          [ "pattern" .= ("New Title" :: Text),
            "path" .= root,
            "glob" .= ("**/*.md" :: Text)
          ]
      ),
    mkToolCallResponse "call_fetch" "web_fetch" (object ["url" .= ("https://example.test/docs" :: Text)]),
    mkTextResponse "The requested work is complete.",
    mkTextResponse "{\"done\": true}"
  ]

stubWebClient :: WebClient
stubWebClient =
  WebClient
    { webFetch = \_ _ ->
        pure FetchResult {status = 200, contentType = "text/plain", body = "stub body", truncated = False},
      webSearch = \_ _ -> pure SearchResult {hits = []}
    }

toolNames :: [Step] -> [Text]
toolNames = foldMap $ \step -> case action step of
  CallTool name _ -> [name]
  Finish -> []
  Summarized -> []

assertObservation :: String -> Text -> Step -> IO ()
assertObservation label needle step =
  assertBool label (needle `T.isInfixOf` fromMaybe "" (observation step))

withTempDir :: FilePath -> (FilePath -> IO a) -> IO a
withTempDir suffix action = do
  tmp <- Dir.getTemporaryDirectory
  let root = tmp </> ("shikumi-tools-" <> suffix)
  bracket
    (Dir.removePathForcibly root >> Dir.createDirectoryIfMissing True root >> pure root)
    Dir.removePathForcibly
    action

shellQuote :: Text -> Text
shellQuote t = "'" <> T.replace "'" "'\\''" t <> "'"
