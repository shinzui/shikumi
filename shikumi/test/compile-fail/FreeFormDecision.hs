{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}

module FreeFormDecision where

import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Decision (DecisionOutputs)
import Shikumi.Schema (Field)

newtype InvalidDecision = InvalidDecision {summary :: Field "Explain the answer" Text}
  deriving stock (Generic)
  deriving anyclass (DecisionOutputs)
