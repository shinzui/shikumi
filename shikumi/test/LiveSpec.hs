-- | A live, end-to-end demo proving the same 'LLM' effect drives a real provider
-- through the full resilience stack. Gated at runtime on @SHIKUMI_LIVE@: with
-- @SHIKUMI_LIVE=1@ (and a valid @OPENAI_API_KEY@) it registers the OpenAI
-- provider, runs 'complete' through 'runLLMResilient', and asserts a non-empty
-- reply. Without the variable it prints a skip line and stays green, so the
-- default test run remains hermetic.
module LiveSpec (tests) where

import Baikai hiding (complete, flattenAssistantText)
import Baikai.Models.Generated (openai_gpt_4o_mini)
import Baikai.Prelude
import Baikai.Provider.OpenAI.Api qualified as OpenAI
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (complete, defaultLLMConfig, runLLMResilient)
import StubProvider (flattenAssistantText)
import System.Environment (lookupEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "LiveSpec"
    [ testCase "live provider call returns text" $ do
        live <- lookupEnv "SHIKUMI_LIVE"
        case live of
          Just "1" -> do
            OpenAI.register
            let ctx = emptyContext & #messages .~ V.singleton (user "Reply with a single word.")
                opts = emptyOptions & #maxTokens .~ Just 16
                cfg = defaultLLMConfig globalProviderRegistry
            out <-
              runEff . runConcurrent . runErrorNoCallStack @ShikumiError . runLLMResilient cfg $ do
                r <- complete openai_gpt_4o_mini ctx opts
                pure (flattenAssistantText (flattenAssistantBlocks r))
            case out of
              Right t -> do
                putStrLn ("LIVE: " <> T.unpack t)
                assertBool "non-empty reply" (not (T.null t))
              Left e -> assertFailure ("live call failed: " <> show e)
          _ ->
            putStrLn "SHIKUMI_LIVE not set; skipping live test"
    ]
