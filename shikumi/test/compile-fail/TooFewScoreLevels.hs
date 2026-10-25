{-# LANGUAGE DataKinds #-}

module TooFewScoreLevels where

import Shikumi.Decision (Score (..))

invalidValue :: Score '["Only"]
invalidValue = Score 0 0 mempty Nothing
