-- | Pins the 'BaikaiError' -> 'ShikumiError' mapping and the 'isTransient'
-- classification. Deliberately breaking the mapping (e.g. mapping 'decodeError'
-- to 'ProviderFailure') makes this group fail.
module ErrorSpec (tests) where

import Baikai.Error (BaikaiError (..), ErrorCategory (..), decodeError, invalidRequest, processError, providerError)
import Shikumi.Error
  ( ShikumiError (..),
    fromBaikaiError,
    isTransient,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ErrorSpec"
    [ testCase "maps providerError -> ProviderFailure" $
        fromBaikaiError (providerError "x") @?= ProviderFailure "x",
      testCase "maps decodeError -> InvalidJSON" $
        fromBaikaiError (decodeError "y") @?= InvalidJSON "y",
      testCase "maps invalidRequest -> SchemaMismatch" $
        fromBaikaiError (invalidRequest "z") @?= SchemaMismatch "invalid request: z",
      testCase "maps processError -> ProviderFailure" $
        fromBaikaiError (processError 2 "boom") @?= ProviderFailure "process exited 2: boom",
      testCase "maps ContextOverflow -> ContextWindowExceeded" $
        fromBaikaiError
          BaikaiError
            { category = ContextOverflow,
              message = "context length exceeded",
              httpStatus = Just 400,
              retryAfterSeconds = Nothing,
              exitCode = Nothing
            }
          @?= ContextWindowExceeded "context length exceeded",
      testCase "isTransient classification" $ do
        isTransient (ProviderFailure "") @?= True
        isTransient (Timeout "") @?= True
        isTransient (ContextWindowExceeded "") @?= False
        isTransient (BudgetExceeded "") @?= False
        isTransient (SchemaMismatch "") @?= False
        isTransient (InvalidJSON "") @?= False
        isTransient (MissingField "") @?= False
        isTransient (ValidationFailure "") @?= False
    ]
