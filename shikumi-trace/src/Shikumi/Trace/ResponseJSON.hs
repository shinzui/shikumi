-- | A faithful JSON round-trip for baikai's 'Baikai.Response.Response' graph.
--
-- This module exists for backward compatibility: it re-exports the baikai
-- 'Response'-graph orphan instances ('ToJSON'/'FromJSON' for @Response@,
-- @AssistantPayload@, @Usage@, @Cost@, @CostBreakdown@) from their single home,
-- "Shikumi.Cache.ResponseJSON" in @shikumi-cache@ (EP-6 owns the cache key that
-- @shikumi-trace@ already depends on, so the dependency direction is natural).
--
-- The instances originally lived here (EP-7). They moved down to @shikumi-cache@
-- when EP-6's persistent backends — which need the same round-trip to store a
-- response as JSON — landed, so that a module importing both the cache and the
-- trace package never sees a duplicate orphan instance. Importing this module
-- (@import Shikumi.Trace.ResponseJSON ()@) still brings the instances into scope
-- exactly as before.
module Shikumi.Trace.ResponseJSON () where

import Shikumi.Cache.ResponseJSON ()
