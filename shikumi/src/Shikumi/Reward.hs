-- | The reward vocabulary owned by EP-18 (MasterPlan integration point #1): a
-- function that scores a single program output, plus the smart constructors used
-- to build one.
--
-- A 'Reward' returns a plain 'Double' (higher is better; by convention in @[0, 1]@
-- but not clamped — the self-refinement modules only ever /compare/ rewards, so any
-- totally-ordered range works). It lives in the base @shikumi@ package — not in
-- @shikumi-eval@ alongside @Score@/@Metric@/@Prediction@ — because the modules that
-- consume it ('Shikumi.Refine') are first-class 'Shikumi.Program.Program' values
-- and @Program@ lives here; reusing @shikumi-eval@'s @Metric@ would invert the
-- one-way @shikumi-eval -> shikumi@ dependency. A caller who already has a
-- @shikumi-eval@ @Metric@ derives a 'Reward' from it with the one-line
-- @rewardFromMetric@ adapter that lives in @shikumi-eval@ (where both types are in
-- scope), not here.
--
-- A reward at inference time only ever sees the /one/ output it is scoring (not a
-- held-out expected value and not a multi-sample prediction), so the simple
-- @o -> Double@ shape is the honest one. EP-22 (GEPA,
-- @docs/plans/22-gepa-reflective-optimizer.md@) reuses this same vocabulary for its
-- reflective feedback and must not define a parallel reward type.
module Shikumi.Reward
  ( Reward (..),
    mkReward,
    boolReward,
  )
where

-- | Score a single output. Higher is better.
newtype Reward o = Reward {runReward :: o -> Double}

-- | Build a reward from a scoring function.
mkReward :: (o -> Double) -> Reward o
mkReward = Reward

-- | Build a reward from a pass/fail predicate: @True -> 1.0@, @False -> 0.0@.
boolReward :: (o -> Bool) -> Reward o
boolReward p = Reward (\o -> if p o then 1.0 else 0.0)
