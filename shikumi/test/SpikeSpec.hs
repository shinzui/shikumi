{-# LANGUAGE GADTs #-}

-- | M0 prototyping spike (EP-4) — THROWAWAY.
--
-- This module de-risks the central type-system bet of
-- @docs/plans/4-typed-program-representation-and-core-modules.md@ before the
-- production module commits to it: a three-constructor GADT (@Predict@,
-- @Compose@, @FMap@) that can be (a) /run/ as a typed function, and (b)
-- /rewritten as data/ via a 'paramsTraversal' — while @Compose@'s intermediate
-- type stays existential and the whole thing stays type-checked.
--
-- It uses a pure stub "model" (no @LLM@ effect, no network, no EP-3 adapter): the
-- stub echoes the /effective instruction/ into its output so a test can observe
-- that rewriting a node's instruction through the traversal actually changes what
-- the program produces. Once M1 promotes the design into @Shikumi.Program@, this
-- module and its 'tests' entry are deleted (see the plan's Idempotence section).
module SpikeSpec (tests) where

import Data.Functor.Const (Const (..))
import Data.Functor.Identity (Identity (..))
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- The optimizable state of a single node.
data Params = Params
  { instructionOverride :: Maybe Text,
    demos :: [Demo]
  }
  deriving stock (Eq, Show)

data Demo = Demo {demoInput :: Text, demoOutput :: Text}
  deriving stock (Eq, Show)

emptyParams :: Params
emptyParams = Params Nothing []

-- A minimal stand-in for EP-3's @Signature@ + adapter: a default instruction and
-- a pure "model" mapping (effective instruction -> input -> output).
data SpikeSig i o = SpikeSig
  { sigDefaultInstruction :: Text,
    sigRun :: Text -> i -> o
  }

data Program i o where
  Predict :: SpikeSig i o -> Params -> Program i o
  Compose :: Program a b -> Program b c -> Program a c
  FMap :: (o -> o') -> Program i o -> Program i o'

-- Run: interpret the tree as a pure function (the real one threads the @LLM@ effect).
runProgram :: Program i o -> i -> o
runProgram (Predict sig ps) i =
  let instr = maybe (sigDefaultInstruction sig) id (instructionOverride ps)
   in sigRun sig instr i
runProgram (Compose f g) i = runProgram g (runProgram f i)
runProgram (FMap k p) i = k (runProgram p i)

-- The crux M0 exists to confirm: in the @Compose@ case the intermediate type @b@
-- is existential, yet the recursion typechecks because each recursive call
-- returns a @Program a b@ / @Program b c@ of the /same/ hidden @b@.
paramsTraversal :: (Applicative f) => (Params -> f Params) -> Program i o -> f (Program i o)
paramsTraversal h (Predict sig ps) = Predict sig <$> h ps
paramsTraversal h (Compose f g) = Compose <$> paramsTraversal h f <*> paramsTraversal h g
paramsTraversal h (FMap k p) = FMap k <$> paramsTraversal h p

foldParams :: Program i o -> [Params]
foldParams = getConst . paramsTraversal (\ps -> Const [ps])

mapParams :: (Params -> Params) -> Program i o -> Program i o
mapParams f = runIdentity . paramsTraversal (Identity . f)

-- ---------------------------------------------------------------------------
-- A tiny scenario: Topic -(outline)-> [Text] -(draft)-> Text
-- ---------------------------------------------------------------------------

outlineSig :: SpikeSig Text [Text]
outlineSig =
  SpikeSig
    { sigDefaultInstruction = "Outline the topic",
      -- the stub echoes the effective instruction so a rewrite is observable
      sigRun = \instr topic -> [instr, "about " <> topic]
    }

draftSig :: SpikeSig [Text] Text
draftSig =
  SpikeSig
    { sigDefaultInstruction = "Draft from the outline",
      sigRun = \instr points -> instr <> ": " <> T.intercalate "; " points
    }

-- A chain-of-thought-style node: extend the output with a leading reasoning
-- string, then project it back out with FMap.
data WithReasoning o = WithReasoning {reasoning :: Text, value :: o}

cotSig :: SpikeSig Text (WithReasoning Text)
cotSig =
  SpikeSig
    { sigDefaultInstruction = "Answer with reasoning",
      sigRun = \instr q -> WithReasoning ("because " <> q) (instr <> " -> answer")
    }

cot :: Program Text Text
cot = FMap value (Predict cotSig emptyParams)

pipeline2 :: Program Text Text
pipeline2 = Compose (Predict outlineSig emptyParams) (Predict draftSig emptyParams)

tests :: TestTree
tests =
  testGroup
    "SpikeSpec (M0, throwaway)"
    [ testCase "runs a single predict node" $
        runProgram (Predict outlineSig emptyParams) "haskell"
          @?= ["Outline the topic", "about haskell"],
      testCase "runs a chain-of-thought-style node" $
        runProgram cot "why" @?= "Answer with reasoning -> answer",
      testCase "runs a two-stage pipeline to a typed result" $
        runProgram pipeline2 "haskell"
          @?= "Draft from the outline: Outline the topic; about haskell",
      testCase "foldParams lists nodes left-to-right depth-first" $
        foldParams pipeline2 @?= [emptyParams, emptyParams],
      testCase "rewriting node 0's instruction via the traversal changes the run" $ do
        -- replace ONLY the first node's instruction, observe it on the wire
        let rewritten =
              mapParamsAt0 (\p -> p {instructionOverride = Just "NEW INSTRUCTION"}) pipeline2
        foldParams rewritten
          @?= [emptyParams {instructionOverride = Just "NEW INSTRUCTION"}, emptyParams]
        runProgram rewritten "haskell"
          @?= "Draft from the outline: NEW INSTRUCTION; about haskell"
    ]
  where
    -- a hand-rolled "edit the 0th node" to prove the rewrite reaches runProgram
    mapParamsAt0 :: (Params -> Params) -> Program i o -> Program i o
    mapParamsAt0 f = snd . go
      where
        go :: Program x y -> (Bool, Program x y)
        go (Predict sig ps) = (True, Predict sig (f ps))
        go (Compose a b) =
          let (donea, a') = go a
           in if donea then (True, Compose a' b) else fmap (Compose a') (go b)
        go (FMap k p) = fmap (FMap k) (go p)
