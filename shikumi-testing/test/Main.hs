module Main (main) where

import Data.Either (isLeft)
import Data.List (nub)
import Data.Text qualified as T
import Shikumi.Combinator (TempSchedule (..))
import Shikumi.Schema (validate)
import Shikumi.Signature (getInstruction)
import Shikumi.Testing
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "shikumi-testing"
      [ testCase "instructedSig has a non-empty instruction" $
          assertBool "instruction" (not (T.null (getInstruction instructedSig))),
        testCase "validate rejects out-of-range confidence" $ do
          assertBool "above range" (isLeft (validate (Answer "x" 1.5)))
          assertBool "below range" (isLeft (validate (Answer "x" (-0.1)))),
        testCase "validate rejects an empty answer" $ do
          assertBool "empty" (isLeft (validate (Answer "" 0.5)))
          assertBool "whitespace" (isLeft (validate (Answer "  " 0.5))),
        testCase "validate accepts a well-formed Answer" $
          validate (Answer "x" 0.9) @?= Right (Answer "x" 0.9),
        testCase "twoStageProg round-trips under twoStageResponder" $ do
          result <- runStub twoStageResponder twoStageProg (Question "What is six times seven?")
          result @?= Right (Answer "It is forty-two." 0.9),
        testCase "diversified temps and globs are non-degenerate" $ do
          case diverseTemps of
            TempFixed ts -> assertBool "distinct temperatures" (length (nub ts) >= 3)
            _ -> fail "expected fixed temperatures"
          assertBool "glob variety" (length (nub diverseGlobPatterns) >= 3)
          assertBool "unprefixed glob" (any (not . T.isPrefixOf "**/") diverseGlobPatterns)
      ]
