-- | The ergonomic combinator surface (EP-5): operators and smart constructors
-- that assemble small typed 'Program's into larger ones. The runtime behaviour
-- lives in the GADT constructors owned by "Shikumi.Program" (so every node stays
-- runnable, traversable by the optimizer, and serializable); this module is the
-- thin, user-facing layer over them.
--
-- The combinators, by group:
--
--   * __Pipeline__ — '>>>' (binary sequential composition) and 'chain' (n-ary,
--     same-type stages). Both are surface over "Shikumi.Program"'s @Compose@.
--   * __Map__ — 'mapP' (bounded-concurrent) \/ 'mapSeqP' (sequential), running a
--     per-element program across a list.
--   * __Parallel__ — 'parallel2' (a pair on one input) and 'parallelN' (a
--     homogeneous list on one input).
--   * __Retry__ — 'retry' (any error) and 'retryWhen' (a chosen class of error).
--   * __Validate__ — 'validate' (predicate + reason) and 'validateRetry'
--     (re-run on rejection).
--   * __MajorityVote__ — 'majorityVote' (modal under 'Eq') and 'majorityVoteBy'
--     (a custom reducer).
--   * __Ensemble__ — 'ensemble' (run distinct members, fold their results).
--
-- Concurrency is an /execution choice/, not part of a program's type: a program
-- built here runs sequentially under 'Shikumi.Program.runProgram' and
-- concurrently (honouring 'mapP' widths) under
-- 'Shikumi.Program.runProgramConc'. See the plan's Decision Log for why
-- 'Concurrent' is kept off @runProgram@'s constraint (MasterPlan integration
-- point #4).
module Shikumi.Combinator
  ( -- * Pipeline
    (>>>),
    chain,

    -- * Map
    mapP,
    mapSeqP,

    -- * Parallel
    parallel2,
    parallelN,

    -- * Retry
    retry,
    retryWhen,

    -- * Validate
    validate,
    validateRetry,

    -- * MajorityVote
    majorityVote,
    majorityVoteBy,
    TempSchedule (..),

    -- * Ensemble
    ensemble,
  )
where

import Data.Text (Text)
import Shikumi.Error (ShikumiError)
import Shikumi.Program
  ( Program (Compose, Ensemble, MajorityVote, Map, Parallel, Retry, RetryWhen, Validate),
    TempSchedule (..),
  )

-- ---------------------------------------------------------------------------
-- Pipeline
-- ---------------------------------------------------------------------------

-- | Sequence two programs left-to-right: @p '>>>' q@ runs @p@, then feeds its
-- output to @q@. Typechecks only when @p@'s output type equals @q@'s input type,
-- so a mismatched pipeline is a compile error.
(>>>) :: Program a b -> Program b c -> Program a c
(>>>) = Compose

infixr 1 >>>

-- | Compose a non-empty list of same-type stages into one program, left-to-right.
-- @'chain' [p, q, r]@ is @p '>>>' q '>>>' r@. (EP-4 owns the /binary/ typed
-- @pipeline@\/@Compose@; this n-ary helper is restricted to a single carried type
-- because the GADT has no identity node to seed an empty fold.)
--
-- Applying it to the empty list is a programmer error (there is no identity
-- 'Program').
chain :: [Program a a] -> Program a a
chain [] = error "Shikumi.Combinator.chain: empty stage list"
chain ps = foldr1 (>>>) ps

-- ---------------------------------------------------------------------------
-- Map
-- ---------------------------------------------------------------------------

-- | Apply a program to every element of a list, with bounded concurrency width
-- @w@ honoured by 'Shikumi.Program.runProgramConc' (sequential under
-- 'Shikumi.Program.runProgram' regardless). Output order matches input order.
mapP :: Int -> Program a b -> Program [a] [b]
mapP = Map

-- | Apply a program to every element of a list, strictly sequentially (width 1).
mapSeqP :: Program a b -> Program [a] [b]
mapSeqP = Map 1

-- ---------------------------------------------------------------------------
-- Parallel
-- ---------------------------------------------------------------------------

-- | Run two programs on the /same/ input and pair their outputs. Concurrent
-- under 'Shikumi.Program.runProgramConc'.
parallel2 :: Program i a -> Program i b -> Program i (a, b)
parallel2 = Parallel

-- | Run a homogeneous list of programs on the same input and collect their
-- outputs in order. Defined as an 'ensemble' with the identity reducer.
parallelN :: [Program i o] -> Program i [o]
parallelN ps = Ensemble ps id

-- ---------------------------------------------------------------------------
-- Retry
-- ---------------------------------------------------------------------------

-- | Re-run a program up to @n@ total attempts, returning the first success or
-- the last error. Retries on any 'ShikumiError'.
retry :: Int -> Program i o -> Program i o
retry = Retry

-- | Like 'retry', but only retries errors matching the predicate; a non-matching
-- error propagates immediately (after a single attempt).
retryWhen :: (ShikumiError -> Bool) -> Int -> Program i o -> Program i o
retryWhen = RetryWhen

-- ---------------------------------------------------------------------------
-- Validate
-- ---------------------------------------------------------------------------

-- | Run a program, then check its output against a predicate; on rejection
-- surface a 'Shikumi.Error.ValidationFailure' carrying @reason@. The accepted
-- output is returned unchanged.
validate :: (o -> Bool) -> Text -> Program i o -> Program i o
validate ok reason = Validate (\o -> if ok o then Right o else Left reason)

-- | 'validate' wrapped in a 'retry': a rejected output triggers re-running the
-- inner program up to @n@ total attempts.
validateRetry :: Int -> (o -> Bool) -> Text -> Program i o -> Program i o
validateRetry n ok reason p = Retry n (validate ok reason p)

-- ---------------------------------------------------------------------------
-- MajorityVote
-- ---------------------------------------------------------------------------

-- | Sample a program @K@ times and return the modal output (most frequent under
-- 'Eq', ties broken by first appearance). The 'TempSchedule' is carried and
-- serialized but not yet applied to the wire — see 'TempSchedule'.
majorityVote :: (Eq o) => Int -> TempSchedule -> Program i o -> Program i o
majorityVote = MajorityVote

-- | Sample a program @K@ times and fold the @K@ outputs with a custom reducer,
-- for outputs that are not usefully 'Eq'. Defined as an 'ensemble' over @K@
-- copies of the program.
majorityVoteBy :: Int -> TempSchedule -> ([o] -> o) -> Program i o -> Program i o
majorityVoteBy k _sched reducer p = Ensemble (replicate (max 1 k) p) reducer

-- ---------------------------------------------------------------------------
-- Ensemble
-- ---------------------------------------------------------------------------

-- | Run several programs on the same input, collect their (homogeneous) results,
-- and fold them with a total reducer.
ensemble :: [Program i r] -> ([r] -> o) -> Program i o
ensemble = Ensemble
