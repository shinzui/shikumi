-- | The EP-9 acceptance suite. Every assertion is about the /prompt the model would
-- have seen/ (captured offline via "Test.Capture") or the /parameters now stored on
-- the nodes/ (a pure @foldParams@ read) — never merely "a type was added".
module Main (main) where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (runPureEff)
import Shikumi.Compile
  ( chainOfThoughtCompiler,
    compile,
    compiledProgram,
    decodeCompiledOnto,
    encodeCompiled,
    fewShotTyped,
    identity,
    inMemoryRetriever,
    rag,
    retrieve,
    zeroShot,
  )
import Shikumi.Compile.Retriever (Passage (..))
import Shikumi.Program (Params (..), foldParams)
import Test.Capture (runWithCapture)
import Test.Fixtures
  ( Question (..),
    answerResponse,
    cotAnswerResponse,
    cotDraftResponse,
    demoPairs,
    draftResponse,
    qaBase,
    qaPipeline,
  )
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "shikumi-compile (EP-9)"
    [ m0_identity,
      m1_baseline,
      m2_zeroShot,
      m3_fewShot,
      m4_chainOfThought,
      m5_rag,
      m6_serialize
    ]

-- A question whose words overlap the target RAG passage.
q :: Question
q = Question "what is the shikumi mechanism"

-- | Assert a captured prompt contains a substring.
contains :: Text -> Text -> Bool
contains needle hay = needle `T.isInfixOf` hay

-- ---------------------------------------------------------------------------
-- M0 — the no-op compiler round-trips a program unchanged
-- ---------------------------------------------------------------------------

m0_identity :: TestTree
m0_identity =
  testCase "M0 identity: compiling with `identity` leaves the rendered prompt unchanged" $ do
    (basePrompts, _) <- runWithCapture [answerResponse] qaBase q
    (idPrompts, _) <- runWithCapture [answerResponse] (compiledProgram (compile identity qaBase)) q
    idPrompts @?= basePrompts

-- ---------------------------------------------------------------------------
-- M1 — baseline: the uncompiled program's prompt carries the signature default
-- instruction and no demonstrations
-- ---------------------------------------------------------------------------

m1_baseline :: TestTree
m1_baseline =
  testCase "M1 baseline: uncompiled qaBase carries its default instruction and no demos" $ do
    (prompts, _) <- runWithCapture [answerResponse] qaBase q
    case prompts of
      [p] -> do
        assertBool "default instruction present" (contains "Answer the question." p)
        -- No demo content: the distinctive demo answers must be absent.
        assertBool "no demo content" (not (contains "Paris" p))
      _ -> assertBool ("expected exactly one captured prompt, got " <> show (length prompts)) False

-- ---------------------------------------------------------------------------
-- M2 — zero-shot: set the instruction, clear demos, at every node
-- ---------------------------------------------------------------------------

m2_zeroShot :: TestTree
m2_zeroShot =
  testGroup
    "M2 zero-shot"
    [ testCase "instruction present, no demos (qaBase)" $ do
        let compiled = compile (zeroShot "Answer concisely.") qaBase
        (prompts, _) <- runWithCapture [answerResponse] (compiledProgram compiled) q
        case prompts of
          [p] -> assertBool "instruction present" (contains "Answer concisely." p)
          _ -> assertBool "one prompt" False
        -- pure assertion: every node's demo list is empty
        assertBool "all nodes have no demos" (all (null . demos) (foldParams (compiledProgram compiled))),
      testCase "instruction reaches BOTH nodes (qaPipeline)" $ do
        let compiled = compile (zeroShot "Answer concisely.") qaPipeline
        (prompts, _) <- runWithCapture [draftResponse, answerResponse] (compiledProgram compiled) q
        length prompts @?= 2
        assertBool "instruction in both prompts" (all (contains "Answer concisely.") prompts)
    ]

-- ---------------------------------------------------------------------------
-- M3 — few-shot: inject demos at every node
-- ---------------------------------------------------------------------------

m3_fewShot :: TestTree
m3_fewShot =
  testGroup
    "M3 few-shot"
    [ testCase "injected demos appear in the prompt (qaBase)" $ do
        let compiled = compile (fewShotTyped demoPairs) qaBase
        (prompts, _) <- runWithCapture [answerResponse] (compiledProgram compiled) q
        case prompts of
          [p] -> do
            assertBool "demo input present" (contains "capital of france" p)
            assertBool "demo output present" (contains "Paris" p)
            assertBool "second demo output present" (contains "blue" p)
          _ -> assertBool "one prompt" False,
      testCase "every node carries the injected demos (qaPipeline, pure)" $ do
        -- A pure, no-LM assertion that the parameters changed at every node.
        -- (Running the pipeline is not asserted here: the same demo pool is
        -- type-mismatched at the second node, which DSPy's LabeledFewShot also
        -- permits — see the plan. The reach guarantee is what matters.)
        let compiled = compile (fewShotTyped demoPairs) qaPipeline
        map (length . demos) (foldParams (compiledProgram compiled)) @?= [3, 3]
    ]

-- ---------------------------------------------------------------------------
-- M4 — chain-of-thought: every node reasons step by step first
-- ---------------------------------------------------------------------------

m4_chainOfThought :: TestTree
m4_chainOfThought =
  testGroup
    "M4 chain-of-thought"
    [ testCase "reasoning cue in the prompt (qaBase)" $ do
        let compiled = compile chainOfThoughtCompiler qaBase
        (prompts, _) <- runWithCapture [cotAnswerResponse] (compiledProgram compiled) q
        case prompts of
          [p] -> assertBool "reasoning cue present" (contains "step by step" p)
          _ -> assertBool "one prompt" False,
      testCase "reasoning cue reaches BOTH nodes (qaPipeline)" $ do
        let compiled = compile chainOfThoughtCompiler qaPipeline
        (prompts, _) <- runWithCapture [cotDraftResponse, cotAnswerResponse] (compiledProgram compiled) q
        length prompts @?= 2
        assertBool "reasoning cue in both prompts" (all (contains "step by step") prompts)
    ]

-- ---------------------------------------------------------------------------
-- M5 — RAG: a retrieved passage appears in the rendered prompt
-- ---------------------------------------------------------------------------

corpus :: [Passage]
corpus =
  [ Passage "p1" "Shikumi is the mechanism behind how a system works.",
    Passage "p2" "The Eiffel Tower is in Paris, the capital of France.",
    Passage "p3" "Photosynthesis converts light into chemical energy."
  ]

m5_rag :: TestTree
m5_rag =
  testGroup
    "M5 RAG"
    [ testCase "retriever ranking (pure)" $ do
        let top = runPureEff (retrieve (inMemoryRetriever 1 corpus) "shikumi mechanism")
        map passageId top @?= ["p1"],
      testCase "retrieved passage appears in the prompt, others do not" $ do
        let compiled = compile (rag (inMemoryRetriever 1 corpus) "shikumi mechanism") qaBase
        (prompts, _) <- runWithCapture [answerResponse] (compiledProgram compiled) q
        case prompts of
          [p] -> do
            assertBool "target passage present" (contains "mechanism behind how a system works" p)
            assertBool "non-matching passage absent" (not (contains "Photosynthesis" p))
          _ -> assertBool "one prompt" False
    ]

-- ---------------------------------------------------------------------------
-- M6 — serialization round-trips the parameter state
-- ---------------------------------------------------------------------------

m6_serialize :: TestTree
m6_serialize =
  testGroup
    "M6 serialize"
    [ testCase "round-trip renders an identical prompt (zeroShot over a pipeline)" $ do
        let compiled = compile (zeroShot "Be precise.") qaPipeline
            bytes = encodeCompiled compiled
        case decodeCompiledOnto qaPipeline bytes of
          Left e -> assertBool ("unexpected decode failure: " <> e) False
          Right roundTripped -> do
            (origPrompts, _) <- runWithCapture [draftResponse, answerResponse] (compiledProgram compiled) q
            (rtPrompts, _) <- runWithCapture [draftResponse, answerResponse] (compiledProgram roundTripped) q
            rtPrompts @?= origPrompts,
      testCase "round-trip preserves injected demos (fewShot over a single node)" $ do
        let compiled = compile (fewShotTyped demoPairs) qaBase
            bytes = encodeCompiled compiled
        case decodeCompiledOnto qaBase bytes of
          Left e -> assertBool ("unexpected decode failure: " <> e) False
          Right roundTripped -> do
            (origPrompts, _) <- runWithCapture [answerResponse] (compiledProgram compiled) q
            (rtPrompts, _) <- runWithCapture [answerResponse] (compiledProgram roundTripped) q
            rtPrompts @?= origPrompts,
      testCase "decoding onto a wrong-shaped template returns a shape Left" $ do
        -- a 2-node payload onto a 1-node template
        let bytes = encodeCompiled (compile (zeroShot "x") qaPipeline)
        case decodeCompiledOnto qaBase bytes of
          Left e -> assertBool "shape mismatch mentioned" (contains "shape mismatch" (T.pack e))
          Right _ -> assertBool "expected a shape-mismatch Left" False,
      testCase "legacy bare Params arrays are rejected with a re-encode hint" $ do
        let bytes = Aeson.encode [Params (Just "legacy instruction") []]
        case decodeCompiledOnto qaBase bytes of
          Left e -> do
            assertBool "legacy format mentioned" (contains "legacy bare parameter arrays" (T.pack e))
            assertBool "re-encode hint mentioned" (contains "re-encoded" (T.pack e))
          Right _ -> assertBool "expected a legacy-format Left" False,
      testCase "RAG context survives encode/decode" $ do
        let compiled = compile (rag (inMemoryRetriever 1 corpus) "shikumi mechanism") qaBase
            bytes = encodeCompiled compiled
        case decodeCompiledOnto qaBase bytes of
          Left e -> assertBool ("unexpected decode failure: " <> e) False
          Right roundTripped -> do
            (origPrompts, _) <- runWithCapture [answerResponse] (compiledProgram compiled) q
            (rtPrompts, _) <- runWithCapture [answerResponse] (compiledProgram roundTripped) q
            rtPrompts @?= origPrompts
            case rtPrompts of
              [p] -> assertBool "target passage present after round-trip" (contains "mechanism behind how a system works" p)
              _ -> assertBool "one prompt" False,
      testCase "CoT state does not decode onto the base template" $ do
        let compiled = compile chainOfThoughtCompiler qaBase
            bytes = encodeCompiled compiled
        case decodeCompiledOnto qaBase bytes of
          Left e -> assertBool "shape mismatch mentioned" (contains "shape mismatch" (T.pack e))
          Right _ -> assertBool "expected a shape-mismatch Left" False,
      testCase "CoT round-trips onto the CoT template" $ do
        let compiled = compile chainOfThoughtCompiler qaBase
            bytes = encodeCompiled compiled
        case decodeCompiledOnto (compiledProgram compiled) bytes of
          Left e -> assertBool ("unexpected decode failure: " <> e) False
          Right roundTripped -> do
            (origPrompts, _) <- runWithCapture [cotAnswerResponse] (compiledProgram compiled) q
            (rtPrompts, _) <- runWithCapture [cotAnswerResponse] (compiledProgram roundTripped) q
            rtPrompts @?= origPrompts
    ]
