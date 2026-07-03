-- | Unit tests for the shared optimizer search helpers.
module SearchSpec (tests) where

import Shikumi.Combinator ((>>>))
import Shikumi.Module (predict)
import Shikumi.Optimize.Search (effectiveInstructionAt, instructionAt, setNodeInstr, setNodeInstrIfNew)
import Shikumi.Program (Program)
import Shikumi.Signature (Signature, mkSignature)
import StubLM (Label, Sentence, ruleInstruction, sentimentProg)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

echoSig :: Signature Label Label
echoSig = mkSignature "Echo the sentiment label unchanged."

twoNode :: Program Sentence Label
twoNode = sentimentProg >>> predict echoSig

ruled :: Program Sentence Label
ruled = predict (mkSignature ruleInstruction)

tests :: TestTree
tests =
  testGroup
    "Search"
    [ testCase "effectiveInstructionAt reads signature base, override, and out-of-range" $ do
        effectiveInstructionAt 0 ruled @?= ruleInstruction
        effectiveInstructionAt 0 (setNodeInstr 0 "override" ruled) @?= "override"
        effectiveInstructionAt 99 ruled @?= "",
      testCase "setNodeInstrIfNew does not write redundant override" $ do
        let kept = setNodeInstrIfNew 0 ruleInstruction ruled
            changed = setNodeInstrIfNew 0 "different" ruled
        instructionAt 0 kept @?= Nothing
        instructionAt 0 changed @?= Just "different",
      testCase "effectiveInstructionAt is index-aligned on a two-node program" $ do
        effectiveInstructionAt 0 twoNode @?= ""
        effectiveInstructionAt 1 twoNode @?= "Echo the sentiment label unchanged."
        effectiveInstructionAt 1 (setNodeInstr 1 "changed" twoNode) @?= "changed"
    ]
