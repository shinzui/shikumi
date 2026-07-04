-- | M1: the typed tool's argument schema is the Generic-derived schema of its
-- input record, frozen against "Shikumi.Schema"'s real generator output.
module SchemaSpec (tests) where

import Data.Aeson (Value, object, (.=))
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Fixtures (expectedReqSchema, weatherTool)
import Shikumi.Schema (toSchema)
import Shikumi.Tool (toolSchemaOf)
import Shikumi.Tool.Builtin.Fs (GlobReq, GrepReq)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Schema"
    [ testCase "derives WeatherReq argument schema" $
        toolSchemaOf weatherTool @?= expectedReqSchema,
      testCase "pins grep and glob request schemas" $ do
        toSchema (Proxy :: Proxy GrepReq)
          @?= object
            [ "type" .= ("object" :: Text),
              "properties"
                .= object
                  [ "pattern" .= toSchema (Proxy :: Proxy Text),
                    "path" .= toSchema (Proxy :: Proxy (Maybe Text)),
                    "glob" .= toSchema (Proxy :: Proxy (Maybe Text)),
                    "ignoreCase" .= toSchema (Proxy :: Proxy (Maybe Bool))
                  ],
              "required" .= (["pattern"] :: [Text]),
              "additionalProperties" .= False
            ]
        toSchema (Proxy :: Proxy GlobReq) @?= expectedGlobReqSchema
    ]

expectedGlobReqSchema :: Value
expectedGlobReqSchema =
  object
    [ "type" .= ("object" :: Text),
      "properties"
        .= object
          [ "pattern" .= toSchema (Proxy :: Proxy Text),
            "path" .= toSchema (Proxy :: Proxy (Maybe Text))
          ],
      "required" .= (["pattern"] :: [Text]),
      "additionalProperties" .= False
    ]
