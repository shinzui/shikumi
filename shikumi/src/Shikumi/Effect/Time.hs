{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

-- | A minimal clock effect for shikumi, modeled on the @Clock@ effect from the
-- third-party @time-effectful@ package. We own this module (rather than depend on
-- @time-effectful@) because shikumi needs a monotonic-clock operation
-- ('getMonotonicTimeNSec') that @time-effectful@'s @Clock@ does not provide, and
-- because owning it keeps the dependency surface unchanged.
--
-- The effect is static-dispatch with side effects: each operation performs real
-- 'IO' under the hood via 'unsafeEff_', so callers need only @Time :> es@ rather
-- than the open-ended @IOE :> es@. The real 'IO' permission is required exactly
-- once, at the discharge site 'runTime', which is where the program edge lives.
module Shikumi.Effect.Time
  ( Time,
    runTime,
    getCurrentTime,
    getMonotonicTimeNSec,
    UTCTime,
  )
where

import Data.Time (UTCTime)
import Data.Time qualified as Time
import Data.Word (Word64)
import Effectful
import Effectful.Dispatch.Static
import GHC.Clock qualified as Clock

data Time :: Effect

type instance DispatchOf Time = 'Static 'WithSideEffects

data instance StaticRep Time = TimeRep

-- | The current wall-clock time (UTC). Used for cache-entry metadata and trace
-- span timestamps.
getCurrentTime :: (Time :> es) => Eff es UTCTime
getCurrentTime = unsafeEff_ Time.getCurrentTime

-- | A monotonic nanosecond counter (never runs backwards), suitable for
-- measuring elapsed time. Used by the evaluation framework to compute per-example
-- latency. Wraps 'GHC.Clock.getMonotonicTimeNSec'.
getMonotonicTimeNSec :: (Time :> es) => Eff es Word64
getMonotonicTimeNSec = unsafeEff_ Clock.getMonotonicTimeNSec

-- | Discharge the 'Time' effect against the real system clock.
runTime :: (IOE :> es) => Eff (Time ': es) a -> Eff es a
runTime = evalStaticRep TimeRep
