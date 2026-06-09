{-# LANGUAGE TypeApplications #-}

-- | M4: ensemble search. Two tests. (a) The value: three members that each answer
-- 3 of 4 held-out items correctly, but err on /different/ items, combine by
-- majority vote (the exact construction 'ensembleSearch' uses —
-- 'Shikumi.Combinator.ensemble' under 'majorityReducer') into a program that
-- answers all 4 correctly — so the ensemble strictly beats its best member. (b)
-- The wiring: @ensembleSearch n@ runs the inner optimizer @n@ times and produces
-- an @n@-member ensemble (checked structurally via 'programShape').
module EnsembleSpec (tests) where

import Data.Aeson (toJSON)
import Data.Text (Text)
import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Shikumi.Combinator (ensemble)
import Shikumi.Compile.Types (compiledProgram)
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Dataset, dataset, exactMatch, example)
import Shikumi.LLM (LLM)
import Shikumi.Optimize
import Shikumi.Program (Demo (..), Program, ProgramShape (..), programShape)
import StubLM (Label (..), Sentence (..), runStubLM, sentimentProg)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

runStub :: Eff '[LLM, Error ShikumiError, Concurrent, Time, IOE] a -> IO (Either ShikumiError a)
runStub act = runEff . runTime . runConcurrent . runErrorNoCallStack @ShikumiError $ runStubLM act

-- | The held-out set: two positives (@good@) and two negatives (@bad@), across two
-- topics, so a member can be fooled on exactly one item by a poisoned demo.
heldout :: Dataset Sentence Label
heldout =
  dataset
    [ example (Sentence "good apple") (Label "positive"),
      example (Sentence "good melon") (Label "positive"),
      example (Sentence "bad apple") (Label "negative"),
      example (Sentence "bad melon") (Label "negative")
    ]

mkMember :: [(Text, Text)] -> Program Sentence Label
mkMember pairs =
  withDemos [Demo (toJSON (Sentence s)) (toJSON (Label l)) | (s, l) <- pairs] sentimentProg

-- Each member is correct on 3/4 held-out items, wrong on a different one (a
-- poisoned demo drags one item to the wrong label under nearest-demo voting).
memberA, memberB, memberC :: Program Sentence Label
memberA = mkMember [("good apple", "positive"), ("bad apple", "negative"), ("bad melon", "positive")]
memberB = mkMember [("good apple", "positive"), ("bad melon", "negative"), ("bad apple", "positive")]
memberC =
  mkMember
    [ ("good apple", "positive"),
      ("good melon", "negative"),
      ("bad apple", "negative"),
      ("bad melon", "negative")
    ]

trainset :: Dataset Sentence Label
trainset =
  dataset
    [ example (Sentence "good film") (Label "positive"),
      example (Sentence "bad film") (Label "negative")
    ]

tests :: TestTree
tests =
  testGroup
    "M4 ensembleSearch"
    [ testCase "majority vote scores at least as high as the best member" $ do
        res <- runStub $ do
          ms <- mapM (scoreOn heldout exactMatch) [memberA, memberB, memberC]
          es <- scoreOn heldout exactMatch (ensemble [memberA, memberB, memberC] majorityReducer)
          pure (ms, es)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right (memberScores, ensembleScore) -> do
            memberScores @?= [0.75, 0.75, 0.75]
            ensembleScore @?= 1.0
            assertBool
              ("ensemble " <> show ensembleScore <> " should beat best member " <> show (maximum memberScores))
              (ensembleScore > maximum memberScores),
      testCase "ensembleSearch n produces an n-member ensemble" $ do
        res <- runStub (optimize (ensembleSearch 3 (labeledFewShot 1)) trainset exactMatch sentimentProg)
        case res of
          Left e -> assertFailure ("unexpected error: " <> show e)
          Right cp -> case programShape (compiledProgram cp) of
            ShapeEnsemble subs -> length subs @?= 3
            other -> assertFailure ("expected a 3-member ShapeEnsemble, got " <> show other)
    ]
