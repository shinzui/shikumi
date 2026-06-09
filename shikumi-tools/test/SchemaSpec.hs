-- | M1: the typed tool's argument schema is the Generic-derived schema of its
-- input record, frozen against "Shikumi.Schema"'s real generator output.
module SchemaSpec (tests) where

import Fixtures (expectedReqSchema, weatherTool)
import Shikumi.Tool (toolSchemaOf)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Schema"
    [ testCase "derives WeatherReq argument schema" $
        toolSchemaOf weatherTool @?= expectedReqSchema
    ]
