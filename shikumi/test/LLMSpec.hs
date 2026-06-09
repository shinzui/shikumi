-- | Hermetic end-to-end test of the bare 'LLM' interpreter: a value flows
-- @call site -> send -> interpret -> Baikai effect -> baikai (isolated registry)
-- -> Response -> Eff -> caller@, and a genuine baikai dispatch failure surfaces
-- through the 'BaikaiError' -> 'ShikumiError' mapping.
module LLMSpec (tests) where

import Baikai (flattenAssistantBlocks, newProviderRegistry)
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (complete, runLLMWith)
import StubProvider
  ( flattenAssistantText,
    stubContext,
    stubModel,
    stubOptions,
    stubRegistry,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "LLMSpec"
    [ testCase "stub end-to-end returns text" $ do
        reg <- stubRegistry "hello from stub"
        res <-
          runEff . runErrorNoCallStack @ShikumiError . runLLMWith reg $ do
            r <- complete stubModel stubContext stubOptions
            pure (flattenAssistantText (flattenAssistantBlocks r))
        res @?= Right "hello from stub",
      testCase "unregistered tag -> ProviderFailure" $ do
        reg <- newProviderRegistry -- empty registry: no handler for the stub tag
        res <-
          runEff . runErrorNoCallStack @ShikumiError . runLLMWith reg $ do
            r <- complete stubModel stubContext stubOptions
            pure (flattenAssistantText (flattenAssistantBlocks r))
        case res of
          Left (ProviderFailure _) -> pure ()
          other -> assertFailure ("expected Left (ProviderFailure ...), got " <> show other)
    ]
