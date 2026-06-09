-- | Pins the 'BaikaiError' -> 'ShikumiError' mapping and the 'isTransient'
-- classification. Deliberately breaking the mapping (e.g. mapping 'DecodeError'
-- to 'ProviderFailure') makes this group fail.
module ErrorSpec (tests) where

import Baikai.Error (BaikaiError (..))
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
    [ testCase "maps ProviderError -> ProviderFailure" $
        fromBaikaiError (ProviderError "x") @?= ProviderFailure "x",
      testCase "maps DecodeError -> InvalidJSON" $
        fromBaikaiError (DecodeError "y") @?= InvalidJSON "y",
      testCase "maps RequestInvalid -> SchemaMismatch" $
        fromBaikaiError (RequestInvalid "z") @?= SchemaMismatch "invalid request: z",
      testCase "maps ProcessError -> ProviderFailure" $
        fromBaikaiError (ProcessError 2 "boom") @?= ProviderFailure "process exited 2: boom",
      testCase "isTransient classification" $ do
        isTransient (ProviderFailure "") @?= True
        isTransient (Timeout "") @?= True
        isTransient (BudgetExceeded "") @?= False
        isTransient (SchemaMismatch "") @?= False
        isTransient (InvalidJSON "") @?= False
        isTransient (MissingField "") @?= False
        isTransient (ValidationFailure "") @?= False
    ]
