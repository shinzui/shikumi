{-# LANGUAGE DataKinds #-}

module TooManyScoreLevels where

import Shikumi.Decision (Score (..))

invalidValue :: Score '["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
invalidValue = Score 0 0 mempty Nothing
