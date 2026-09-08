-- | Pins the 'BaikaiError' -> 'ShikumiError' mapping and the 'isTransient'
-- classification. Deliberately breaking the mapping (e.g. mapping 'decodeError'
-- to 'ProviderFailure') makes this group fail.
module ErrorSpec (tests) where

import Baikai.Error (BaikaiError (..), ErrorCategory (..), decodeError, invalidRequest, processError, providerError)
import Shikumi.Error
  ( ShikumiError (..),
    fromBaikaiError,
    isTransient,
    renderShikumiError,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ErrorSpec"
    [ testCase "maps providerError -> ProviderError" $
        fromBaikaiError (providerError "x") @?= ProviderError (providerError "x"),
      testCase "maps decodeError -> InvalidJSON" $
        fromBaikaiError (decodeError "y") @?= InvalidJSON "y",
      testCase "maps invalidRequest -> SchemaMismatch" $
        fromBaikaiError (invalidRequest "z") @?= SchemaMismatch "invalid request: z",
      testCase "maps processError -> ProviderError" $
        fromBaikaiError (processError 2 "boom") @?= ProviderError (processError 2 "boom"),
      testCase "maps ContextOverflow -> ContextWindowExceeded" $
        fromBaikaiError
          BaikaiError
            { category = ContextOverflow,
              message = "context length exceeded",
              httpStatus = Just 400,
              retryAfterSeconds = Nothing,
              refusalCategory = Nothing,
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
        isTransient (CodeExecFailed "") @?= False,
      testGroup
        "released categories"
        [ testCase (show cat) $ do
            let e = (providerError "detail") {category = cat, httpStatus = Just 403, retryAfterSeconds = Just 7, exitCode = Just 2, refusalCategory = Just "future_policy"}
                expected = case cat of
                  DecodeFailure -> InvalidJSON "detail"
                  InvalidRequest -> SchemaMismatch "invalid request: detail"
                  ContextOverflow -> ContextWindowExceeded "detail"
                  _ -> ProviderError e
            fromBaikaiError e @?= expected
            isTransient expected @?= (cat `elem` [RateLimited, TransientError])
        | cat <- [AuthError, RateLimited, ContextOverflow, InvalidRequest, ContentFiltered, TransientError, DecodeFailure, ProcessFailure, ProviderUnavailable, OtherError]
        ],
      testGroup
        "refusal categories retained verbatim"
        [ testCase (show rc) $ do
            let e = (providerError "refused") {category = ContentFiltered, refusalCategory = rc}
            fromBaikaiError e @?= ProviderError e
        | rc <- [Nothing, Just "policy_example", Just "future_category"]
        ],
      testCase "readable structured error" $ do
        renderShikumiError (ProviderError (processError 2 "boom")) @?= "provider ProcessFailure (exit 2): boom"
        renderShikumiError (ProviderFailure "legacy") @?= "legacy"
    ]
