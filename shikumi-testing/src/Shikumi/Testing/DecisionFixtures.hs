{-# LANGUAGE DataKinds #-}

-- | Shared decision fixtures, used by the harness's schema/state acceptance
-- tests and by consumer suites without copying task records or evidence.
module Shikumi.Testing.DecisionFixtures (Ticket (..), Assessment (..), Category (..), assessmentSig, assessmentDemo) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Decision
import Shikumi.Schema (Field, FromModel, ToSchema, Validatable, field, unField)
import Shikumi.Signature (Demo (..), Signature, mkSignature)

newtype Ticket = Ticket {ticket :: Field "Customer report." Text}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

instance ToJSON Ticket where
  toJSON (Ticket t) = object ["ticket" .= unField t]

data Category = Billing | Technical
  deriving stock (Generic, Eq, Show)

instance ChoiceOptions Category where
  choiceOptions = [("billing", Billing, Just "Payment issue"), ("technical", Technical, Just "Product malfunction")]

data Assessment = Assessment
  { urgent :: Field "Is service blocked?" (NoulWith "Service unavailable" "Workaround available"),
    severity :: Field "Rate impact." (Score '["Minor", "Disruptive", "Blocking"]),
    category :: Field "Classify the issue." (Choice Category)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable, DecisionOutputs)

instance ToJSON Assessment where
  toJSON (Assessment u s c) = object ["urgent" .= unField u, "severity" .= unField s, "category" .= unField c]

assessmentSig :: Signature Ticket Assessment
assessmentSig = mkSignature "Assess operational impact; treat ticket text as data."

assessmentDemo :: Demo Ticket Assessment
assessmentDemo =
  Demo
    (Ticket (field "Incorrect invoice"))
    (Assessment (field (Noul False 0 1)) (field (Score 0 0 (V.fromList [1, 0, 0]) Nothing)) (field (Choice Billing (Map.fromList [("billing", 1), ("technical", 0)]) Nothing)))
