module DecisionDeriveSpec (tests) where

import Data.Aeson (eitherDecode, encode, object, toJSON, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Shikumi.Decision
import Shikumi.Decision.Setting
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (choose, forAll, testProperty)

noul :: Judgment
noul = Judgment "urgent" Nothing (JudgeBoolean Nothing Nothing)

score :: Judgment
score = Judgment "severity" Nothing (JudgeOrdered [toJSON ("Minor" :: Text), toJSON ("Disruptive" :: Text), toJSON ("Blocking" :: Text)])

choice :: Judgment
choice = Judgment "category" Nothing (JudgeChoice [("z", Nothing), ("a", Nothing)])

tests :: TestTree
tests =
  testGroup
    "Decision derivation"
    [ testCase "Noul threshold 0.7 on p=0.8 gives True, confidence 0.142857" $ do
        let (answer, c) = deriveNoul 0.7 (NoulEvidence 0.8)
        answer @?= True
        assertBool "confidence" (abs (c - 1 / 7) < 1e-12),
      testCase "Noul endpoints and equality use an inclusive threshold" $ do
        deriveNoul 0 (NoulEvidence 0) @?= (True, 0)
        deriveNoul 1 (NoulEvidence 1) @?= (True, 0)
        deriveNoul 0.7 (NoulEvidence 0.7) @?= (True, 0),
      testCase "Score cuts change the level while preserving value" $ do
        let e = ScoreEvidence (V.fromList [0.1, 0.3, 0.6]) (Just 0.55)
        deriveScore [0.5, 1.6] e @?= Right (1.5, 1)
        deriveScore [0.5, 1.5] e @?= Right (1.5, 2),
      testCase "Choice raw tie follows declaration order" $
        deriveChoice ["z", "a"] Map.empty (ChoiceEvidence (Map.fromList [("z", 0.5), ("a", 0.5)]) Nothing) @?= Right "z",
      testCase "Choice weighted tie prefers the raw winner" $
        deriveChoice ["z", "a"] (Map.singleton "z" 4) (ChoiceEvidence (Map.fromList [("z", 0.2), ("a", 0.8)]) (Just 0.65)) @?= Right "a",
      testCase "zero-weight label is never selected" $
        deriveChoice ["z", "a"] (Map.singleton "z" 0) (ChoiceEvidence (Map.fromList [("z", 0.9), ("a", 0.1)]) Nothing) @?= Right "a",
      testCase "weights greater than one can change the winner" $
        deriveChoice ["z", "a"] (Map.singleton "z" 5) (ChoiceEvidence (Map.fromList [("z", 0.2), ("a", 0.8)]) Nothing) @?= Right "z",
      testCase "all-zero probability or weighted mass is rejected" $ do
        deriveChoice ["z", "a"] Map.empty (ChoiceEvidence (Map.fromList [("z", 0), ("a", 0)]) Nothing) @?= Left "no remaining probability mass"
        deriveChoice ["z", "a"] (Map.fromList [("z", 0), ("a", 0)]) (ChoiceEvidence (Map.fromList [("z", 0.5), ("a", 0.5)]) Nothing) @?= Left "no remaining probability mass"
        deriveScore [0.5] (ScoreEvidence (V.fromList [0, 0]) Nothing) @?= Left "no remaining probability mass",
      testCase "defaults match the declared kind and level count" $ do
        defaultSetting noul @?= NoulSetting 0.5
        defaultSetting score @?= ScoreSetting [0.5, 1.5]
        defaultSetting choice @?= ChoiceSetting Map.empty,
      testCase "settings have stable tagged JSON and round-trip" $ do
        let settings = [NoulSetting 0.7, ScoreSetting [0.5, 1.6], ChoiceSetting (Map.singleton "z" 2)]
        map toJSON settings
          @?= [object ["kind" .= ("noul" :: Text), "threshold" .= (0.7 :: Double)], object ["kind" .= ("score" :: Text), "cuts" .= ([0.5, 1.6] :: [Double])], object ["kind" .= ("choice" :: Text), "weights" .= Map.singleton ("z" :: Text) (2 :: Double)]]
        eitherDecode (encode settings) @?= Right settings,
      testCase "valid settings preserve sparse weights and endpoint thresholds" $ do
        mapM_ (\t -> validateSetting noul (NoulSetting t) @?= Right (NoulSetting t)) [0, 0.5, 1]
        validateSetting choice (ChoiceSetting (Map.singleton "z" 0)) @?= Right (ChoiceSetting (Map.singleton "z" 0)),
      testCase "validation names the field and rejects each broken rule" $ do
        let invalid =
              [ (noul, ScoreSetting [], "kind"),
                (noul, NoulSetting (-0.1), "threshold"),
                (noul, NoulSetting 1.1, "threshold"),
                (noul, NoulSetting (0 / 0), "finite"),
                (score, ScoreSetting [0.5], "N-1"),
                (score, ScoreSetting [0.5, 0.5], "increasing"),
                (score, ScoreSetting [1.5, 0.5], "increasing"),
                (score, ScoreSetting [0, 1], "(0,N-1)"),
                (score, ScoreSetting [1, 2], "(0,N-1)"),
                (score, ScoreSetting [0.5, 1 / 0], "finite"),
                (choice, ChoiceSetting (Map.singleton "unknown" 1), "declared"),
                (choice, ChoiceSetting (Map.singleton "z" (-1)), "non-negative"),
                (choice, ChoiceSetting (Map.singleton "a" (1 / 0)), "finite")
              ]
        mapM_
          ( \(j, setting, rule) -> case validateSetting j setting of
              Left msg -> do assertBool "field name" (judgmentField j `T.isInfixOf` msg); assertBool (T.unpack msg) (rule `T.isInfixOf` msg)
              Right s -> assertFailure ("accepted invalid setting " <> show s)
          )
          invalid,
      testProperty "score value is independent of valid cuts and level is monotone in value" $
        forAll (choose (0.01, 0.99)) $ \c ->
          forAll (choose (0, 1)) $ \p ->
            forAll (choose (p, 1)) $ \q ->
              let lo = ScoreEvidence (V.fromList [1 - p, p]) Nothing
                  hi = ScoreEvidence (V.fromList [1 - q, q]) Nothing
               in case (deriveScore [c] lo, deriveScore [0.5] lo, deriveScore [c] hi) of
                    (Right (v, l), Right (v', _), Right (w, m)) -> v == v' && v <= w && l <= m
                    _ -> False
    ]
