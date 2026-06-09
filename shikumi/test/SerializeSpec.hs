-- | EP-4 M3: parameter-state serialization (never closures). A program's
-- @programParams@ vector JSON-round-trips and re-applies onto a default-parameter
-- program of the same shape; @programShape@ is stable across parameter changes;
-- a wrong-length vector is rejected.
module SerializeSpec (tests) where

import Data.Aeson (Value (String), decode, encode)
import ProgramFixtures (Draft, Topic, outlineToDraft, topicToOutline)
import Shikumi.Program
  ( Demo (..),
    Params (..),
    Program (Predict),
    ProgramShape (..),
    ProgramShapeError (..),
    emptyParams,
    foldParams,
    mapParamsAt,
    pipeline,
    programParams,
    programShape,
    setProgramParams,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

-- A fresh, default-parameter two-stage program.
defaultProg :: Program Topic Draft
defaultProg = pipeline (Predict topicToOutline emptyParams) (Predict outlineToDraft emptyParams)

-- The same program with distinct parameters on each node.
tunedProg :: Program Topic Draft
tunedProg =
  mapParamsAt 0 (const node0Params)
    . mapParamsAt 1 (const node1Params)
    $ defaultProg

node0Params :: Params
node0Params = Params (Just "outline carefully") [Demo (String "a topic") (String "an outline")]

node1Params :: Params
node1Params = Params (Just "draft fluently") []

tests :: TestTree
tests =
  testGroup
    "SerializeSpec"
    [ testCase "programParams JSON round-trips to an equal vector" $
        decode (encode (programParams tunedProg)) @?= Just [node0Params, node1Params],
      testCase "setProgramParams reapplies a saved vector onto a default program" $
        fmap foldParams (setProgramParams [node0Params, node1Params] defaultProg)
          @?= Right (foldParams tunedProg),
      testCase "programShape is stable across parameter changes" $
        programShape tunedProg @?= programShape defaultProg,
      testCase "programShape records the constructor tree and per-node labels" $
        programShape defaultProg
          @?= ShapeCompose (ShapePredict "points") (ShapePredict "prose"),
      testCase "setProgramParams with a wrong-length vector is rejected" $
        case setProgramParams [emptyParams] defaultProg of
          Left e -> e @?= ParamCountMismatch (2, 1)
          Right _ -> assertFailure "expected Left on a wrong-length vector"
    ]
