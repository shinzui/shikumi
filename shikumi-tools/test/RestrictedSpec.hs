-- | EP-27 M1: the hermetic restricted-DSL evaluator behind 'restrictedInterpreter'.
-- Pure unit tests over 'runRestricted': it computes arithmetic/string/list results
-- and returns a @Left@ error message for division by zero, a parse error, or an
-- unknown function — the recoverable errors the @programOfThought@ loop feeds back.
module RestrictedSpec (tests) where

import Data.Text (Text)
import Data.Text qualified as T
import Shikumi.CodeExec.Interpreter (runRestricted)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

assertLeft :: Either Text Text -> IO ()
assertLeft r = assertBool ("expected Left, got " <> show r) (isLeft r)
  where
    isLeft (Left _) = True
    isLeft _ = False

assertLeftMentions :: Text -> Either Text Text -> IO ()
assertLeftMentions needle = \case
  Left msg -> assertBool ("error should mention " <> show needle <> ", got " <> show msg) (needle `T.isInfixOf` msg)
  Right v -> assertBool ("expected Left mentioning " <> show needle <> ", got Right " <> show v) False

tests :: TestTree
tests =
  testGroup
    "RestrictedSpec"
    [ testCase "2 + 3 * 4 evaluates to 14 (precedence)" $
        runRestricted "2 + 3 * 4" @?= Right "14",
      testCase "37 * 19 + 6 evaluates to 709" $
        runRestricted "37 * 19 + 6" @?= Right "709",
      testCase "result = 42 evaluates to 42" $
        runRestricted "result = 42" @?= Right "42",
      testCase "parentheses override precedence" $
        runRestricted "(2 + 3) * 4" @?= Right "20",
      testCase "1 / 0 reports a division error" $
        assertLeftMentions "division" (runRestricted "1 / 0"),
      testCase "len(\"hello\") evaluates to 5" $
        runRestricted "len(\"hello\")" @?= Right "5",
      testCase "upper(\"ab\") ++ \"C\" concatenates to ABC" $
        runRestricted "upper(\"ab\") ++ \"C\"" @?= Right "ABC",
      testCase "sum([1, 2, 3]) evaluates to 6" $
        runRestricted "sum([1, 2, 3])" @?= Right "6",
      testCase "a malformed expression (extra paren) is a parse error" $
        assertLeft (runRestricted "upper(\"ab\") ++ \"C\")"),
      testCase "an unknown function is an error" $
        assertLeftMentions "unknown" (runRestricted "frobnicate(3)")
    ]
