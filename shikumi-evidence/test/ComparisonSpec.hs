module ComparisonSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Effectful.Dispatch.Dynamic (interpose)
import Fixture
import Shikumi.Evidence
import Shikumi.LLM (LLM (..), complete, stream)
import Shikumi.Testing (systemContains)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "comparison"
    [ testCase "both arms run the same examples under the same evaluator, policy and routes" $ do
        result <- expectRight =<< runJob (respond Good) (uc7Job "uc7-good" RecordLive)
        let rep = result.report
            ids arm = map (.exampleId) (maybe [] (.rows) arm)
            routes arm = map (.route) (maybe [] (.routes) arm)
        ids rep.baselineResult @?= ids rep.candidateResult
        length (ids rep.baselineResult) @?= 8
        routes rep.baselineResult @?= routes rep.candidateResult
        rep.bindings.policyDigest @?= digestPolicy uc7Policy
        rep.bindings.evaluatorDigest @?= digestEvaluator evidenceEvaluator
        rep.conclusion @?= Improved,
      testCase "a pipeline that reroutes the candidate's requests makes the comparison Invalid" $ do
        let reroute act =
              interpose
                ( \_ -> \case
                    Complete m c o
                      | systemContains "RULE" c -> complete (m & #modelId .~ "other-model") c o
                      | otherwise -> complete m c o
                    Stream m c o -> stream m c o
                )
                act
        result <- expectRight =<< runJob (respond Good) ((uc7Job "reroute" RecordLive) {requestPipeline = reroute})
        result.report.conclusion @?= Invalid
        assertBool "routes-differ not reported" ("routes-differ" `elem` map (.code) result.report.reasons)
    ]
