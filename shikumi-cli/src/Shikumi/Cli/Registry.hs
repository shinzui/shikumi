{-# LANGUAGE GADTs #-}

-- | How typed programs reach the name-based CLI.
--
-- A shikumi @Program i o@ is a typed value, so the CLI cannot load one from a
-- string at runtime. Instead a user registers /tasks/ in a 'Registry' keyed by
-- name; each 'Task' bundles a program with its dataset, metric, a canonical input
-- (for trace/replay), the offline stub responder that makes it deterministic, and
-- the named optimizers it supports — all sharing one @i@/@o@ behind an
-- existential. A subcommand looks a task up by name and dispatches with every type
-- recovered by pattern-matching, so there is no cross-existential @Typeable@
-- reunification (the EP-12 sketch's separate program/dataset/metric maps would
-- have needed it; bundling avoids it — see the plan's Decision Log).
module Shikumi.Cli.Registry
  ( Task (..),
    Registry,
    emptyRegistry,
    register,
    lookupTask,
    registryNames,
  )
where

import Baikai (Context, Response)
import Data.Aeson (ToJSON)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Shikumi.Eval (Dataset, Metric)
import Shikumi.Optimize (Optimizer)
import Shikumi.Program (Program)

-- | A self-contained, name-addressable unit of CLI work. The fields are matched
-- positionally (the existential @i@/@o@ would escape a record selector), so handlers
-- write @Task prog ds metric input responder opts@.
data Task where
  Task ::
    (ToJSON i, ToJSON o) =>
    -- | the program to run/evaluate/optimize/replay
    Program i o ->
    -- | its labelled dataset
    Dataset i o ->
    -- | the metric scoring a prediction
    Metric o ->
    -- | a canonical input used by @trace@/@replay@
    i ->
    -- | the deterministic offline stub LM for this task
    (Context -> Response) ->
    -- | named optimizers this task supports (e.g. "bootstrap-fewshot")
    Map Text (Optimizer i o) ->
    Task

-- | A name-keyed set of tasks.
newtype Registry = Registry (Map Text Task)

-- | The empty registry.
emptyRegistry :: Registry
emptyRegistry = Registry Map.empty

-- | Register a task under a name (last registration wins).
register :: Text -> Task -> Registry -> Registry
register nm t (Registry m) = Registry (Map.insert nm t m)

-- | Look a task up by name.
lookupTask :: Text -> Registry -> Maybe Task
lookupTask nm (Registry m) = Map.lookup nm m

-- | The registered task names, in order.
registryNames :: Registry -> [Text]
registryNames (Registry m) = Map.keys m
