module ObjectiveSpec (tests) where

import Data.Aeson (eitherDecode, encode)
import Data.Map.Strict qualified as Map
import Shikumi.Optimize.Report
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Named objectives"
    [ testCase "quality/cost frontier and hard ceiling" $ do
        map candidateId (objectiveFrontier policy rows) @?= [0, 1]
        fmap candidateId (selectObjectiveWinner policy rows) @?= Just 0
        let bounded = policy {objectives = [quality, cost {upperBound = Just 2}]}
        fmap candidateId (selectObjectiveWinner bounded rows) @?= Just 1,
      testCase "directions and creation-order ties" $ do
        fmap candidateId (selectObjectiveWinner (policy {primaryObjective = "cost"}) rows) @?= Just 1
        fmap candidateId (selectObjectiveWinner policy [a {candidateId = 9}, a]) @?= Just 0,
      testCase "required values, nonfinite values, duplicates fail" $ do
        assertBool "missing" (isLeft (aggregateObjectives policy [Map.singleton "quality" 1]))
        assertBool "NaN" (isLeft (aggregateObjectives policy [Map.fromList [("quality", 0 / 0), ("cost", 1)]]))
        assertBool "duplicates" (isLeft (validateObjectives (policy {objectives = [quality, quality]}))),
      testCase "substitution and aggregation" $ do
        let p = policy {objectives = [quality, cost {missingPolicy = Substitute 2, aggregation = Total}]}
        aggregateObjectives p [Map.singleton "quality" 1, Map.fromList [("quality", 0), ("cost", 3)]] @?= Right (Map.fromList [("quality", 0.5), ("cost", 5)]),
      testCase "configuration JSON" $ eitherDecode (encode policy) @?= Right policy
    ]
  where
    quality = ObjectiveSpec "quality" "score" Maximize Mean Required (Just 0) (Just 1)
    cost = ObjectiveSpec "cost" "operations" Minimize Mean Required (Just 0) Nothing
    policy = ObjectivePolicy [quality, cost] "quality" []
    a = row 0 1 3
    rows = [a, row 1 0.9 1, row 2 0.8 4]
    row ix q c = CandidateReport ix CandidateCompleted 1 1 [(0, q)] (Map.fromList [("quality", q), ("cost", c)]) 0 Nothing
    isLeft (Left _) = True
    isLeft _ = False
