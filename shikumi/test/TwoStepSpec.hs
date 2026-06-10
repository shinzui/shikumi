-- | EP-26 M3: the 'Shikumi.Module.twoStep' combinator. It issues two model calls
-- — a free-form prose answer, then a structured extraction — and returns a typed
-- @o@. Driven against a stub LLM scripted with prose then a marker reply, it must
-- return the expected 'Summary' and consume both scripted responses (the
-- observable that distinguishes it from a single-call adapter).
module TwoStepSpec (tests) where

import Baikai
  ( AssistantContent (..),
    Response,
    _Response,
    _TextContent,
  )
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Fixtures (Article, Author (..), Sentiment (..), Summary (..), sampleArticle, sampleSummary)
import ProgramFixtures (runScriptedLLM)
import Shikumi.Error (ShikumiError)
import Shikumi.Module (twoStep)
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema.Types (field)
import Shikumi.Signature (Demo (..), Signature, mkSignature, setDemos)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

sig :: Signature Article Summary
sig = setDemos [Demo sampleArticle sampleSummary] (mkSignature "Summarize the article")

prog :: Program Article Summary
prog = twoStep sig

-- | Build a response whose single assistant text block carries the given body.
mkResponse :: Text -> Response
mkResponse t =
  _Response & #message . #content .~ V.singleton (AssistantText (_TextContent & #text .~ t))

-- | The first scripted call's reply: free-form prose (no structure requested).
freeFormResponse :: Response
freeFormResponse =
  mkResponse
    "The headline is 'Shikumi types LM programs'. Three points: records in, \
    \records out, errors are typed. Author Ada. Sentiment positive."

-- | The second scripted call's reply: a structured [[ ## field ## ]] marker body,
-- the extraction target the fallback adapter parses.
structuredResponse :: Response
structuredResponse =
  mkResponse $
    T.intercalate
      "\n"
      [ "[[ ## headline ## ]]",
        "Shikumi types LM programs",
        "[[ ## bullets ## ]]",
        "[\"records in\", \"records out\", \"errors are typed\"]",
        "[[ ## author ## ]]",
        "{\"name\": \"Ada\"}",
        "[[ ## sentiment ## ]]",
        "Positive",
        "[[ ## note ## ]]",
        "null",
        "[[ ## completed ## ]]"
      ]

expectedSummary :: Summary
expectedSummary =
  Summary
    { headline = field "Shikumi types LM programs",
      bullets = field ["records in", "records out", "errors are typed"],
      author = Author {name = field "Ada"},
      sentiment = Positive,
      note = Nothing
    }

tests :: TestTree
tests =
  testGroup
    "TwoStepSpec"
    [ testCase "twoStep: free-form then extract yields the expected Summary" $ do
        ref <- newIORef [freeFormResponse, structuredResponse]
        out <-
          runEff . runErrorNoCallStack @ShikumiError . runScriptedLLM ref $
            runProgram prog sampleArticle
        out @?= Right expectedSummary,
      testCase "twoStep: both scripted calls are consumed (two model calls)" $ do
        ref <- newIORef [freeFormResponse, structuredResponse]
        _ <-
          runEff . runErrorNoCallStack @ShikumiError . runScriptedLLM ref $
            runProgram prog sampleArticle
        remaining <- readIORef ref
        length remaining @?= 0
    ]
