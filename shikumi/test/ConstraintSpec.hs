{-# LANGUAGE DataKinds #-}

-- | EP-26 M2: declarative field constraints. A 'Constrained' field carries a
-- type-level constraint list that (a) emits the matching JSON-Schema keywords in
-- the derived schema and (b) is enforced after decode, turning a violation into a
-- located 'ValidationFailure'. The contrast record 'BioUnchecked' (same fields, no
-- constraint) shows the constraint is what rejects an out-of-bounds value.
module ConstraintSpec (tests) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Schema (FromModel, ToSchema, Validatable, deriveSchema, fromModel)
import Shikumi.Schema.Types (Constrained, Constraint (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

-- A small constrained record: a tagline of at least 10 characters and a score in
-- the inclusive range [0, 100].
data Bio = Bio
  { tagline :: !(Constrained '[ 'MinLen 10] Text),
    score :: !(Constrained '[ 'MinVal "0", 'MaxVal "100"] Int)
  }
  deriving stock (Generic, Show, Eq)

instance ToSchema Bio

instance FromModel Bio

instance Validatable Bio

-- The same shape with no constraints, to prove the constraint does the rejecting.
data BioUnchecked = BioUnchecked
  { tagline :: !Text,
    score :: !Int
  }
  deriving stock (Generic, Show, Eq)

instance ToSchema BioUnchecked

instance FromModel BioUnchecked

instance Validatable BioUnchecked

-- | Drill into @properties.<field>@ of a record schema 'Value'.
propOf :: Text -> Value -> Maybe Value
propOf name (Object o) = do
  Object props <- KM.lookup "properties" o
  KM.lookup (Key.fromText name) props
propOf _ _ = Nothing

-- | Look a keyword up inside a property schema object.
keyword :: Text -> Value -> Maybe Value
keyword k (Object o) = KM.lookup (Key.fromText k) o
keyword _ _ = Nothing

tests :: TestTree
tests =
  testGroup
    "ConstraintSpec"
    [ testCase "schema: tagline carries minLength 10" $
        (propOf "tagline" (deriveSchema @Bio) >>= keyword "minLength") @?= Just (Number 10),
      testCase "schema: score carries minimum 0 and maximum 100" $ do
        (propOf "score" (deriveSchema @Bio) >>= keyword "minimum") @?= Just (Number 0)
        (propOf "score" (deriveSchema @Bio) >>= keyword "maximum") @?= Just (Number 100),
      testCase "decode: short tagline -> ValidationFailure" $
        fromModel @Bio (obj "short" 50)
          @?= Left (ValidationFailure "tagline: minLength 10 violated"),
      testCase "decode: conforming value -> Right" $
        case fromModel @Bio (obj "long enough tagline" 50) of
          Right _ -> pure ()
          Left e -> assertFailure ("expected Right, got " <> show e),
      testCase "decode: out-of-range score -> ValidationFailure" $
        fromModel @Bio (obj "long enough tagline" 150)
          @?= Left (ValidationFailure "score: maximum 100 violated"),
      testCase "contrast: the unconstrained record accepts the short value" $
        fromModel @BioUnchecked (obj "short" 50)
          @?= Right (BioUnchecked {tagline = "short", score = 50})
    ]
  where
    obj t s =
      Object
        ( KM.fromList
            [ ("tagline", String t),
              ("score", Number (fromIntegral (s :: Int)))
            ]
        )
