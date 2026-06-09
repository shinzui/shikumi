---
id: 16
slug: node-correlated-tracing-and-feedback-channel
title: "Node-correlated tracing and feedback channel"
kind: exec-plan
created_at: 2026-06-09T22:35:41Z
intention: "intention_01ktq80610e6nbe3d7yrct59an"
master_plan: "docs/masterplans/2-shikumi-substrate-routing-completion.md"
---

# Node-correlated tracing and feedback channel

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi (the typed LM-programming framework rooted at
`/Users/shinzui/Keikaku/bokuno/shikumi`) lets you build an LM pipeline as a value of
type `Program i o` — a tree of nodes, some of which (`Predict` nodes) actually call a
language model. Shikumi can already *trace* a run: running a program inside the `Trace`
effect produces a `TraceTree`, a tree of timed, attributed spans, where every individual
model call becomes a leaf span recording the model, the prompt, the response, token
counts, and cost. You can pretty-print that tree, save it to disk, and replay it offline.

What you **cannot** do today is ask the trace *which node in the program issued a given
model call*. The trace records that "a call to `stub/stub-model` happened, here is its
prompt and response," but it does not record "this call came from the second `Predict`
node in the program." There is no backward mapping from a span to the `Program` node that
produced it, and there is no single entry point that runs a program and tags each span
with the node's structural position. This blocks two whole families of downstream work:

  * **Per-node demonstration recovery.** An optimizer that wants to harvest worked
    examples ("demos") for a *specific* internal node — say, the reasoning step in a
    two-stage chain — needs to know which model call belonged to which node. Today the
    bootstrap optimizer can only recover demos at the whole-program input/output level and
    attaches the same demo set to every node (a documented limitation in
    `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/Bootstrap.hs`).

  * **Reflective optimization (GEPA-style).** A reflective optimizer reads a *textual
    critique* of how each node performed on an example ("this node's instruction is too
    vague; it confused the date format") and rewrites *that node's* instruction in
    response. To do that it needs (a) a stable name for each node and (b) a place to store
    the critique keyed by that name. Neither exists today.

After this ExecPlan, a user (and, more importantly, a downstream optimizer) can:

  1. Run any `Program i o` through a new additive entry point
     `runProgramTraced` and get back a `TraceTree` in which **every model-call span is
     tagged with a `NodePath`** — a stable identifier for the structural position of the
     `Predict` node that issued the call. That `NodePath` is guaranteed to agree with the
     integer index that the existing parameter-editing functions (`foldParams`,
     `mapParamsAt`) use, so "the node `NodePath` *p* points at" and "the node parameter
     edit *n* touches" are *the same node*.

  2. Attach a short textual critique to a specific node by `NodePath` (the **feedback
     channel**), and later read back all critiques attached to that node. A metric or
     LM-judge writes feedback during evaluation; an optimizer reads it during a proposal
     step.

  3. Recover, for any `NodePath`, the input-field and output-field *names* of the node it
     points at (its field metadata), which the grounded instruction proposer
     (`/Users/shinzui/Keikaku/bokuno/shikumi/docs/plans/19-grounded-instruction-proposer.md`)
     needs to write node-specific proposal prompts.

You can see all of this working through a hermetic test (no network, no API keys) that
builds a two-node program, runs it under `runProgramTraced` with a stub model, and asserts
that each model-call span's `NodePath` equals the expected structural path *and* matches
the `foldParams` index of that node — plus a feedback round-trip that attaches a critique
to a node and reads it back.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `NodePath` type + `programNodePaths` enumeration + `nodePath` field added to
      `SpanAttrs`; unit test proving `programNodePaths` agrees with `foldParams` order and
      bumps the trace-file `formatVersion`.
- [ ] M1: per-node field-metadata accessor `nodeFields :: Program i o -> [(NodePath, NodeFields)]`.
- [ ] M2: `runProgramTraced` (additive entry point) opening a node span per node and a
      `Reader`-style current-`NodePath` thread that `tracedLLM`'s replacement reads to tag
      each model-call span; hermetic test asserting span `nodePath` equals expected path and
      matches `foldParams` index.
- [ ] M3: `Feedback` channel (`FeedbackLog` sibling structure + write/read API); hermetic
      round-trip test (attach critique to node N, read it back).
- [ ] Final: `cabal test shikumi-trace` green inside `nix develop .#ghc9124`; plan's
      living sections updated; commit with MasterPlan/ExecPlan/Intention trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Represent a node's structural position as a `NodePath` (a list of structural
  steps from the program root) **and** define a single function `programNodePaths` that
  enumerates the `NodePath` of every `Predict` node in exactly the order `foldParams`
  yields their `Params`. The integer correspondence is then *derived*, not asserted:
  `programNodePaths p !! n` is the node `mapParamsAt n` edits.
  Rationale: The MasterPlan integration point #3 requires the node ordering to "agree with
  `foldParams`/`mapParamsAt` integer indexing so that a `NodePath` maps to the same node a
  parameter edit would touch." Defining the enumeration by reusing the *same left-to-right
  depth-first walk* `paramsTraversal` uses makes the agreement structural and testable
  rather than a coincidence two functions must independently maintain.
  Date: 2026-06-09.
- Decision: `runProgramTraced` is an **additive, separate** entry point. `runProgram` and
  `runProgramConc` in `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Program.hs`
  are not modified, preserving MasterPlan integration point #4 (the pinned
  `runProgram :: (LLM :> es, Error ShikumiError :> es) => Program i o -> i -> Eff es o`
  signature).
  Rationale: V1 pinned `runProgram`'s row and every consumer inherits it; widening it would
  break eval, optimize, tools, and the CLI. Tracing is opt-in.
  Date: 2026-06-09.
- Decision: Correlation is threaded by a dedicated `effectful` reader-style effect
  (`CurrentNode`) carrying the active `NodePath`, set by `runProgramTraced` as it descends
  into each `Predict`, and read by a node-aware LM-capture interpose (`tracedNodeLLM`) that
  writes the `NodePath` onto each model-call span. We do **not** reuse `Effectful.Reader`
  directly because the value must change as execution descends the program tree without the
  caller having to thread it; a tiny dedicated effect with a `localNode` operation makes the
  scoping explicit and keeps `runProgram`'s row untouched.
  Rationale: An interpose that needs "the node I am currently inside" needs a dynamically
  scoped value. The alternative — passing the `NodePath` as an extra argument through a
  re-implemented program interpreter — is also acceptable and is described as the fallback,
  but the effect keeps the new code small and reuses the existing `withSpan` machinery.
  Date: 2026-06-09.
- Decision: Feedback lives in a **sibling** structure (`FeedbackLog`, a
  `Map NodePath [Text]`) carried by its own `Feedback` effect, not inside `TraceTree`.
  Rationale: `TraceTree` is serialized with a pinned `formatVersion` and is consumed by
  replay; feedback is written *after* a run by metrics/judges and read by optimizers, has a
  different lifecycle, and would otherwise force a trace-format change on every feedback
  tweak. A sibling keeps the trace immutable-once-captured and lets feedback evolve freely.
  The `SpanAttrs.nodePath` field is the *only* trace-format change, and it is additive
  (optional) so old code keeps compiling; the trace `formatVersion` is bumped to 2.
  Date: 2026-06-09.
- Decision: Per-node field metadata is exposed as
  `nodeFields :: Program i o -> [(NodePath, NodeFields)]` where
  `NodeFields = NodeFields { inputFieldNames :: [Text], outputFieldNames :: [Text] }`,
  rather than a `nodeSignature :: Program i o -> Int -> Signature` accessor.
  Rationale: A `Predict` node captures its `Signature i o` *existentially* (the per-node
  `i`/`o` are hidden inside the GADT constructor — see
  `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Program.hs` lines 160–164), so
  no single Haskell type can name "the signature of node n." But the *field names* are plain
  `Text` reachable from `inputFields`/`outputFields` of the captured signature, so a
  type-erased projection to `[Text]` escapes the existential cleanly. This is exactly what
  the grounded proposer (`docs/plans/19-grounded-instruction-proposer.md`) consumes.
  Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section describes everything a newcomer needs. Read it fully before editing.

### Where the code lives

There are two packages in play, both under `/Users/shinzui/Keikaku/bokuno/shikumi`:

  * `shikumi/` — the core package. The file that matters here is
    `shikumi/src/Shikumi/Program.hs`, which defines the `Program i o` GADT, the parameter
    traversal (`paramsTraversal`, `foldParams`, `mapParamsAt`), and the executors
    (`runProgram`, `runProgramConc`). Its cabal file is `shikumi/shikumi.cabal`. The
    signature type lives in `shikumi/src/Shikumi/Signature.hs` and field metadata in
    `shikumi/src/Shikumi/Schema/Types.hs`.

  * `shikumi-trace/` — the tracing package. The file that matters is
    `shikumi-trace/src/Shikumi/Trace.hs`, which defines the `Trace` effect, the span types
    (`Span`, `SpanAttrs`, `TraceTree`), the interpreter `runTrace`, and the LM-call capture
    `tracedLLM`. Persistence lives in `shikumi-trace/src/Shikumi/Trace/Store.hs`. The test
    suite is `shikumi-trace/test/Main.hs` with shared fixtures in
    `shikumi-trace/test/TraceFixtures.hs`, and a stub-LM demo in
    `shikumi-trace/src/Shikumi/Trace/Demo.hs`. The cabal file is
    `shikumi-trace/shikumi-trace.cabal`. Note `shikumi-trace` already depends on `shikumi`.

`shikumi-trace` is the right home for `NodePath`, `runProgramTraced`, and the feedback
channel: it already depends on `shikumi` (so it can pattern-match the `Program` GADT) and
on `effectful`, and it owns `SpanAttrs`. The one change inside the `shikumi` core package is
adding the field-metadata projection to `Shikumi.Program`, because that needs to look inside
the existential `Predict` constructor where the captured `Signature` lives.

### The `Program` GADT, verbatim

From `shikumi/src/Shikumi/Program.hs` (lines 159–199), the full constructor set you must
handle in every recursive walk:

```haskell
data Program i o where
  Predict ::
    (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o) =>
    Signature i o ->
    Params ->
    Program i o
  Compose :: Program a b -> Program b c -> Program a c
  FMap :: (o -> o') -> Program i o -> Program i o'
  Map :: Int -> Program a b -> Program [a] [b]
  Parallel :: Program i a -> Program i b -> Program i (a, b)
  Retry :: Int -> Program i o -> Program i o
  RetryWhen :: (ShikumiError -> Bool) -> Int -> Program i o -> Program i o
  Validate :: (o -> Either Text o) -> Program i o -> Program i o
  MajorityVote :: (Eq o) => Int -> TempSchedule -> Program i o -> Program i o
  Ensemble :: [Program i r] -> ([r] -> o) -> Program i o
  Embed :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o
```

The constructors `Predict`, `Compose`, `FMap`, `Map`, `Parallel`, `Retry`, `RetryWhen`,
`Validate`, `MajorityVote`, `Ensemble`, `Embed` are all exported (pattern synonyms in the
module export list), so the `shikumi-trace` package can pattern-match them.

### The parameter traversal order — the law you must obey

`foldParams` and `mapParamsAt` define the canonical node ordering. From
`shikumi/src/Shikumi/Program.hs` (lines 353–366), the traversal is **left-to-right
depth-first**, visiting only `Predict` nodes (every other constructor carries no `Params`
and just recurses):

```haskell
paramsTraversal :: (Applicative f) => (Params -> f Params) -> Program i o -> f (Program i o)
paramsTraversal h (Predict sig ps) = Predict sig <$> h ps
paramsTraversal h (Compose f g) = Compose <$> paramsTraversal h f <*> paramsTraversal h g
paramsTraversal h (FMap k p) = FMap k <$> paramsTraversal h p
paramsTraversal h (Map w p) = Map w <$> paramsTraversal h p
paramsTraversal h (Parallel pa pb) = Parallel <$> paramsTraversal h pa <*> paramsTraversal h pb
paramsTraversal h (Retry n p) = Retry n <$> paramsTraversal h p
paramsTraversal h (RetryWhen ok n p) = RetryWhen ok n <$> paramsTraversal h p
paramsTraversal h (Validate v p) = Validate v <$> paramsTraversal h p
paramsTraversal h (MajorityVote k sched p) = MajorityVote k sched <$> paramsTraversal h p
paramsTraversal h (Ensemble ps reduce) = Ensemble <$> traverse (paramsTraversal h) ps <*> pure reduce
paramsTraversal _ (Embed f) = pure (Embed f)
```

`foldParams = getConst . paramsTraversal (\ps -> Const [ps])` collects each node's `Params`
in this order. `mapParamsAt n f` edits the `n`-th `Predict` node in this same order (lines
380–421). **Whatever node ordering this ExecPlan introduces must reproduce this exact
sequence**, because the whole point of integration point #3 is that the trace's node
identity agrees with the optimizer's parameter index.

The cleanest way to guarantee agreement is to *reuse the same walk*. The enumeration we add
(`programNodePaths`) does not invent a new traversal — it threads a `NodePath` through the
identical depth-first descent so that the `k`-th `NodePath` it emits names the same node as
the `k`-th `Params` `foldParams` emits.

### The trace span types, verbatim

From `shikumi-trace/src/Shikumi/Trace.hs` (lines 114–134), `SpanAttrs` is the attribute bag
on a span; this is the one trace-format type we extend:

```haskell
data SpanAttrs = SpanAttrs
  { model :: !(Maybe Text),
    provider :: !(Maybe Text),
    prompt :: !(Maybe Value),
    response :: !(Maybe Value),
    latencyMs :: !(Maybe Integer),
    inputTokens :: !(Maybe Natural),
    outputTokens :: !(Maybe Natural),
    costUsd :: !(Maybe Scientific),
    retries :: !Int,
    toolCalls :: ![ToolCallRecord],
    cacheKey :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
```

The `Trace` effect and its operations (lines 188–217):

```haskell
data Trace :: Effect where
  WithSpan :: SpanKind -> Text -> m a -> Trace m a
  CurrentSpanId :: Trace m (Maybe SpanId)
  BumpRetry :: Trace m ()
  RecordToolCall :: ToolCallRecord -> Trace m ()
  AnnotateSpan :: (SpanAttrs -> SpanAttrs) -> Trace m ()

withSpan :: (Trace :> es) => SpanKind -> Text -> Eff es a -> Eff es a
currentSpanId :: (Trace :> es) => Eff es (Maybe SpanId)
annotateSpan :: (Trace :> es) => (SpanAttrs -> SpanAttrs) -> Eff es ()
```

`annotateSpan` is the key operation: it applies a function to the *currently-active* span's
attributes. The existing `tracedLLM` uses it to fill a model-call span after the response
arrives (lines 313–339):

```haskell
tracedLLM :: (Trace :> es, LLM :> es) => Eff es a -> Eff es a
tracedLLM = interpose $ \_ -> \case
  Complete m c o -> withSpan LlmCallSpan (llmLabel m) $ do
    resp <- complete m c o
    annotateSpan (const (llmAttrs m c o resp))
    pure resp
  Stream m c o -> withSpan LlmCallSpan (llmLabel m) (stream m c o)
```

Note `llmAttrs m c o resp` builds a *fresh* `SpanAttrs` (it starts from `emptyAttrs`) and
overwrites the span. That matters: a naive node-tagging that runs *before* this `const`
would be clobbered. The plan handles this (M2) by writing the `NodePath` in a *separate*
`annotateSpan (\a -> a { nodePath = ... })` call issued *after* the `Complete` op returns —
i.e. by interposing one layer *above* `tracedLLM`, or by extending `llmAttrs` to read the
current node. We choose the layered interpose so `tracedLLM` itself is unchanged.

### The trace store and `formatVersion`

From `shikumi-trace/src/Shikumi/Trace/Store.hs`, the on-disk file carries a
`currentFormatVersion :: Int` (currently `1`) and `readTraceFile` rejects any other version.
Adding the optional `nodePath` field to `SpanAttrs` changes the JSON shape (a new key
appears), so we bump `currentFormatVersion` to `2`. Because `nodePath` is a `Maybe`, Aeson
omits it when `Nothing` and tolerates its absence on read, so version-1 files written by old
code would still decode field-wise — but we still bump the version per the project's "reject
loudly" stance, and update the round-trip test accordingly.

### The hermetic stub-LM pattern

Tests never hit the network. The pattern (see `shikumi-trace/test/TraceFixtures.hs` and
`shikumi-trace/src/Shikumi/Trace/Demo.hs`) is to write a tiny interpreter of the `LLM`
effect that returns a canned `Response` derived from the request `Context`:

```haskell
runKeyedLLM :: (Context -> Response) -> Eff (LLM : es) a -> Eff es a
runKeyedLLM f = interpret $ \_ -> \case
  Complete _ c _ -> pure (f c)
  Stream {} -> pure []
```

A full traced run is assembled by stacking interpreters at the program edge, e.g.
`runEff . runPrim . runTime . runTrace . runKeyedLLM responder . tracedLLM $ ...`. The new
tests follow this exact shape, swapping the body for `runProgramTraced program input` and
adding the node-aware capture and current-node interpreters.

### Terms defined

  * **Span** — one timed, attributed node in the trace tree (a program, module,
    combinator, or single LM call).
  * **`NodePath`** — the identifier this plan introduces for a node's structural position
    inside a `Program`. It is a list of structural steps from the root (defined precisely in
    M1). Two programs with the same shape produce the same `NodePath`s.
  * **Feedback** — a short textual critique of how one node performed, attached to that
    node's `NodePath`, written by a metric/judge and read by an optimizer.
  * **Interpose** — `effectful`'s mechanism for wrapping an existing effect's operations
    with extra behavior without changing the effect's type (used by `tracedLLM`).


## Plan of Work

The work is three milestones, each independently verifiable.

### Milestone 1 — `NodePath` identity, the `SpanAttrs.nodePath` field, and field metadata

**Scope.** Introduce the `NodePath` type and the enumeration that ties it to `foldParams`
order; add the optional `nodePath` field to `SpanAttrs`; expose the per-node field-metadata
accessor. No execution changes yet — this milestone is pure data plumbing plus the laws that
make M2 meaningful. At the end of M1, a test proves the enumeration agrees with `foldParams`,
and the trace serializes round-trip with the new field.

**The `NodePath` type.** Add a new module `Shikumi.Trace.Node` in
`shikumi-trace/src/Shikumi/Trace/Node.hs`. (Placing it in `shikumi-trace` is correct: it
needs the `Program` GADT from `shikumi`, which `shikumi-trace` already depends on, and it is
consumed alongside the trace types.) Define:

```haskell
-- | One structural step from a parent node to a child, naming which branch was taken.
-- The branch labels mirror the 'Program' constructors so a path is human-readable and
-- shape-stable: two programs of the same shape yield identical paths.
data NodeStep
  = StepComposeL          -- into the left side of 'Compose'
  | StepComposeR          -- into the right side of 'Compose'
  | StepFMap              -- through an 'FMap'
  | StepMap               -- through a 'Map'
  | StepParallelL         -- into the left side of 'Parallel'
  | StepParallelR         -- into the right side of 'Parallel'
  | StepRetry             -- through a 'Retry'
  | StepRetryWhen         -- through a 'RetryWhen'
  | StepValidate          -- through a 'Validate'
  | StepMajorityVote      -- through a 'MajorityVote'
  | StepEnsemble !Int     -- into the i-th member of an 'Ensemble' (0-based)
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The structural position of a node within a 'Program', as the list of steps from the
-- program root to that node, outermost first. The root node itself has the empty path.
newtype NodePath = NodePath [NodeStep]
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)
```

`Embed` carries an opaque body and no `Params`, so it is a leaf with no path of its own (it
is never a `Predict`); we do not descend into it. `Predict` is the only node that *holds* a
path that ends a model call, and its path is the sequence of steps taken to reach it.

**The enumeration (the law-bearing function).** Add, in the same module:

```haskell
-- | Enumerate the 'NodePath' of every 'Predict' node, in the SAME left-to-right
-- depth-first order as 'Shikumi.Program.foldParams'. The k-th element of
-- @programNodePaths p@ is the path to the same node whose 'Params' is the k-th element of
-- @foldParams p@ and which @mapParamsAt k@ edits. This is the integration-point-#3 law.
programNodePaths :: Program i o -> [NodePath]
```

Implement it by the identical depth-first descent `paramsTraversal` performs, accumulating
the path prefix and emitting one `NodePath` per `Predict`:

```haskell
programNodePaths prog = go [] prog
  where
    -- prefix is the reversed list of steps taken so far (outermost last); we reverse on emit.
    go :: forall x y. [NodeStep] -> Program x y -> [NodePath]
    go prefix (Predict _ _)            = [NodePath (reverse prefix)]
    go prefix (Compose a b)            = go (StepComposeL : prefix) a ++ go (StepComposeR : prefix) b
    go prefix (FMap _ p)               = go (StepFMap : prefix) p
    go prefix (Map _ p)                = go (StepMap : prefix) p
    go prefix (Parallel a b)           = go (StepParallelL : prefix) a ++ go (StepParallelR : prefix) b
    go prefix (Retry _ p)              = go (StepRetry : prefix) p
    go prefix (RetryWhen _ _ p)        = go (StepRetryWhen : prefix) p
    go prefix (Validate _ p)           = go (StepValidate : prefix) p
    go prefix (MajorityVote _ _ p)     = go (StepMajorityVote : prefix) p
    go prefix (Ensemble ps _)          = concat (zipWith (\i p -> go (StepEnsemble i : prefix) p) [0 ..] ps)
    go _      (Embed _)                = []
```

Because this descent visits the constructors in the exact order `paramsTraversal` does and
emits exactly at `Predict` leaves, `programNodePaths p` and `foldParams p` have the same
length and the same node order *by construction*. The M1 test makes this explicit by
checking `length (programNodePaths p) == length (foldParams p)` on several shapes and by
checking that editing `mapParamsAt k` changes the node at `programNodePaths p !! k` (via the
field-metadata accessor below as a witness, or via a marker instruction).

**The `SpanAttrs.nodePath` field.** In `shikumi-trace/src/Shikumi/Trace.hs`, add one field
to `SpanAttrs`:

```haskell
data SpanAttrs = SpanAttrs
  { model :: !(Maybe Text),
    -- ... existing fields unchanged ...
    cacheKey :: !(Maybe Text),
    -- | The structural path of the 'Program' node that issued this span's LM call.
    -- Present only on model-call spans produced by 'runProgramTraced'; 'Nothing' for
    -- spans opened by bare 'withSpan' or by a non-node-correlated run.
    nodePath :: !(Maybe NodePath)
  }
```

Update `emptyAttrs` to set `nodePath = Nothing`. Add `NodePath` (re-exported from
`Shikumi.Trace.Node`) to the `Shikumi.Trace` export list, and import `Shikumi.Trace.Node`
into `Shikumi.Trace`. Bump `currentFormatVersion` in
`shikumi-trace/src/Shikumi/Trace/Store.hs` from `1` to `2`, and register the new module in
`shikumi-trace/shikumi-trace.cabal` under `exposed-modules`.

**The per-node field-metadata accessor.** This is the piece the grounded proposer
(`docs/plans/19-grounded-instruction-proposer.md`) needs. Because a `Predict` node hides its
`i`/`o` types existentially, we cannot return its `Signature`; we *can* return the field
*names*, which are plain `Text`. Add to `shikumi/src/Shikumi/Program.hs` (so it can read the
existential signature) and export:

```haskell
-- | The input- and output-field names of a single node, recovered structurally.
data NodeFields = NodeFields
  { inputFieldNames :: ![Text],
    outputFieldNames :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

-- | For every 'Predict' node, in 'foldParams' order, its index-aligned field metadata.
-- Pairs the node's parameter index with its input/output field names. A consumer that has
-- a 'NodePath' (from the trace) zips this against 'programNodePaths' to map path -> fields.
nodeFieldsIndexed :: Program i o -> [NodeFields]
nodeFieldsIndexed = ... -- same depth-first walk, emitting at each Predict:
  --   NodeFields (map fieldName (inputFields sig)) (map fieldName (outputFields sig))
```

Here `inputFields`/`outputFields`/`fieldName` come from `Shikumi.Signature` and
`Shikumi.Schema.Types` (both already imported by `Shikumi.Program`). `nodeFieldsIndexed`
returns one `NodeFields` per `Predict` in `foldParams` order, so it index-aligns with both
`foldParams` and `programNodePaths`. The `shikumi-trace` side then offers the convenience
that ties path to fields:

```haskell
-- | In Shikumi.Trace.Node: associate each Predict node's NodePath with its field names.
nodeFields :: Program i o -> [(NodePath, NodeFields)]
nodeFields p = zip (programNodePaths p) (nodeFieldsIndexed p)
```

Document for `docs/plans/19-grounded-instruction-proposer.md`: it can call `nodeFields p`,
or — if it already has a node index `n` from the optimizer — just `nodeFieldsIndexed p !! n`,
to obtain the input/output field names it needs for a node-specific proposal prompt. This is
the agreed contract: **field metadata is recovered by `NodePath` (or equivalently by the
`foldParams` index), not by a `Signature` accessor**, because the signature's types cannot
escape the GADT.

**Commands / acceptance.** Build and run the M1 tests (added to
`shikumi-trace/test/Main.hs`, see Concrete Steps):

```bash
nix develop .#ghc9124 --command cabal test shikumi-trace --test-options='-p node'
```

Acceptance: the `node` group passes, demonstrating (a) `programNodePaths` has the same
length as `foldParams` on a chain, a majority-vote, an ensemble, and a parallel program;
(b) the `NodePath` JSON round-trips; (c) `nodeFields` returns the expected field-name lists
for each node of a two-node chain; (d) a `TraceTree` carrying a `nodePath`-bearing span
round-trips through `writeTraceFile`/`readTraceFile` at `formatVersion = 2`.

### Milestone 2 — `runProgramTraced` correlating model-call spans to nodes

**Scope.** Add the additive entry point `runProgramTraced` that runs a program (like
`runProgram`) while opening a span per node and threading the active node's `NodePath` so
that each model-call leaf span is tagged with it. `runProgram`/`runProgramConc` are not
touched. At the end of M2, a hermetic test runs a two-node program under `runProgramTraced`
and asserts each model-call span's `nodePath` equals the expected structural path *and*
matches the node's `foldParams` index.

**How correlation is threaded.** Introduce a tiny dedicated effect in
`shikumi-trace/src/Shikumi/Trace/Node.hs` (or a new `Shikumi.Trace.Program` module —
implementer's choice, kept in `shikumi-trace`) that carries the *current* `NodePath`:

```haskell
data CurrentNode :: Effect where
  AskNode   :: CurrentNode m (Maybe NodePath)
  LocalNode :: NodePath -> m a -> CurrentNode m a

askNode :: (CurrentNode :> es) => Eff es (Maybe NodePath)
localNode :: (CurrentNode :> es) => NodePath -> Eff es a -> Eff es a

-- A trivial interpreter holding the current path in a Reader-like cell.
runCurrentNode :: Eff (CurrentNode : es) a -> Eff es a
```

`runProgramTraced` is a node-walking interpreter that mirrors `runProgram`'s recursion but
(1) descends with a path prefix exactly as `programNodePaths` does, (2) wraps each node in a
trace span (program/module/combinator span as appropriate), and (3) at each `Predict` leaf,
calls `localNode path` around the actual `runProgram (Predict sig ps) i` so the model call
issued by that `Predict` runs *inside* the `LocalNode` scope. Sketch:

```haskell
runProgramTraced ::
  (LLM :> es, Trace :> es, CurrentNode :> es, Error ShikumiError :> es) =>
  Program i o ->
  i ->
  Eff es o
runProgramTraced = go []
  where
    go :: forall x y. [NodeStep] -> Program x y -> x -> Eff es y
    go prefix p@(Predict {}) i =
      let path = NodePath (reverse prefix)
       in withSpan ModuleSpan (nodeLabel p) (localNode path (runProgram p i))
    go prefix (Compose f g) i =
      withSpan CombinatorSpan "Compose" $
        go (StepComposeL : prefix) f i >>= go (StepComposeR : prefix) g
    go prefix (FMap k p) i = withSpan CombinatorSpan "FMap" (k <$> go (StepFMap : prefix) p i)
    -- ... one arm per constructor, mirroring runProgram's semantics and
    --     programNodePaths' prefix discipline ...
    go _ (Embed f) i = withSpan CombinatorSpan "Embed" (f i)
```

The crucial guarantee: at a `Predict`, the prefix accumulated by `go` is the *same* sequence
of steps `programNodePaths` accumulates, so `path` here equals the `NodePath` M1 assigns that
node. (The M2 test asserts exactly this by comparing against `programNodePaths`.)

**Tagging the span.** The model call inside `runProgram (Predict ...) i` flows through the
`LLM` effect, captured by a *node-aware* capture interpose layered above `tracedLLM`:

```haskell
-- | Like 'tracedLLM' but also stamps the active 'NodePath' onto each model-call span.
-- Layered ABOVE 'tracedLLM' so 'tracedLLM' fills model/prompt/response/cost first and this
-- adds the node path without clobbering them.
tracedNodeLLM :: (Trace :> es, CurrentNode :> es, LLM :> es) => Eff es a -> Eff es a
tracedNodeLLM = interpose $ \_ -> \case
  Complete m c o -> do
    r <- complete m c o
    mp <- askNode
    annotateSpan (\a -> a { nodePath = mp })
    pure r
  Stream m c o -> stream m c o
```

The stacking order at the program edge is therefore:

```haskell
runEff . runPrim . runTime . runCurrentNode . runTrace
  . runKeyedLLM responder      -- base LLM interpreter (stub or real)
  . tracedLLM                  -- opens the LlmCallSpan, fills model/prompt/response/cost
  . tracedNodeLLM              -- adds nodePath to the just-filled span
  $ runProgramTraced program input
```

Because `tracedNodeLLM` is interposed *outermost* relative to `tracedLLM`, its `Complete`
handler runs first, delegates down to `tracedLLM` (which opens the span, runs the base
`complete`, and fills the LM attributes), then on the way back issues
`annotateSpan (\a -> a { nodePath = mp })`. Since `tracedLLM` is *inside* the `withSpan
LlmCallSpan`, the active span when `tracedNodeLLM` annotates is exactly that LM-call span.
(If implementation reveals the annotation lands on the wrong active span because the
interpose ordering closes the span too early, the fallback is to fold the node tag into
`tracedLLM` itself — extend `llmAttrs` to take an extra `Maybe NodePath` read via `askNode`
inside the same `withSpan`. The Decision Log will record whichever ordering proves correct;
both produce the same observable result, a model-call span whose `nodePath` is the issuing
node's path.)

**Fallback mechanism (documented, not preferred).** If the layered-interpose proves fragile,
`runProgramTraced` can instead pass the `NodePath` explicitly: re-implement the `Predict`
arm to render and `complete` directly (as `runPredict` does) and call
`annotateSpan (\a -> a { nodePath = Just path })` *inside* the `withSpan LlmCallSpan` opened
for that call, dropping `tracedNodeLLM` and `CurrentNode` entirely. This is more code but has
no cross-interpreter ordering subtlety. Choose during implementation; record the choice.

**Cooperation with EP-14 routing.** EP-14
(`docs/plans/14-ambient-model-routing-and-live-native-structured-output.md`) introduces an
ambient `Routing` effect read *below* the `LLM` effect by `runProgram`'s `Predict` path.
`runProgramTraced` delegates each `Predict` to `runProgram (Predict sig ps) i`, so it inherits
EP-14's routing automatically with no change: the routing effect, when present, is simply
another interpreter lower in the stack, exactly like `LLM` and `Error`. If EP-14 is *not*
present, `runProgram` uses the neutral `_Model` and the demonstration uses a stub LM, which is
the hermetic path this plan ships against. No edits here depend on EP-14; the soft dependency
is only that the most convincing live demo routes a real model.

**Commands / acceptance.**

```bash
nix develop .#ghc9124 --command cabal test shikumi-trace --test-options='-p correlate'
```

Acceptance: the `correlate` group passes, demonstrating that running a two-`Predict` chain
under `runProgramTraced` with a stub LM yields exactly two `LlmCallSpan`s, the first carrying
`nodePath == programNodePaths chain !! 0` and the second `== programNodePaths chain !! 1`,
and that each equals the path of the node `mapParamsAt 0` / `mapParamsAt 1` edits (witnessed
by `nodeFields`).

### Milestone 3 — the per-node feedback channel

**Scope.** Add a typed channel that lets a metric or judge attach a short textual critique
keyed by `NodePath`, and lets an optimizer read all critiques for a node. At the end of M3,
a hermetic round-trip test attaches a critique to a node and reads it back.

**Where feedback lives.** Per the Decision Log, feedback is a **sibling** structure, not part
of `TraceTree`. Add a module `Shikumi.Trace.Feedback` in
`shikumi-trace/src/Shikumi/Trace/Feedback.hs`:

```haskell
-- | All feedback gathered during a run: critiques keyed by the node they target. A node may
-- accumulate several critiques (e.g. one per example), kept in attach order.
newtype FeedbackLog = FeedbackLog (Map NodePath [Text])
  deriving stock (Eq, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

emptyFeedback :: FeedbackLog

-- | All critiques attached to a node, in attach order (empty if none).
feedbackFor :: NodePath -> FeedbackLog -> [Text]

-- | The effect a metric/judge uses to attach feedback during a run.
data Feedback :: Effect where
  AttachFeedback :: NodePath -> Text -> Feedback m ()

attachFeedback :: (Feedback :> es) => NodePath -> Text -> Eff es ()

-- | Run the feedback effect, returning the result paired with the collected log.
runFeedback :: (Prim :> es) => Eff (Feedback : es) a -> Eff es (a, FeedbackLog)
```

`runFeedback` accumulates into an `IORef (Map NodePath [Text])` via the `Prim` effect (the
same mechanism `runTrace` uses for its state), appending each critique to its node's list.
`feedbackFor` is the optimizer's read API: GEPA
(`docs/plans/22-gepa-reflective-optimizer.md`) calls `feedbackFor path log` to fetch the
critiques for a node before rewriting that node's instruction; the grounded proposer
(`docs/plans/19-grounded-instruction-proposer.md`) may read it as an extra proposal signal.

**How a metric writes feedback in practice.** A judge metric that has the trace in hand finds
the model-call span(s) for a node by filtering `spans tree` for `nodePath == Just path`,
forms a critique, and calls `attachFeedback path critique`. Because a metric runs in an
`Eff` row, adding `Feedback :> es` to its constraints is additive and does not touch the
pinned program-execution row. The contract for downstream consumers: **write with
`attachFeedback path text`, read with `feedbackFor path log`, where `path` is a `NodePath`
obtained from `programNodePaths`/`nodeFields` or from a span's `nodePath` field.**

Register `Shikumi.Trace.Feedback` in `shikumi-trace.cabal` `exposed-modules`.

**Commands / acceptance.**

```bash
nix develop .#ghc9124 --command cabal test shikumi-trace --test-options='-p feedback'
```

Acceptance: the `feedback` group passes, demonstrating that after running under `runFeedback`
and attaching two critiques to one node and one to another, `feedbackFor` returns the two
critiques (in order) for the first node and the single critique for the second, the empty
list for an untargeted node, and that `FeedbackLog` round-trips through JSON.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` inside the
pinned toolchain. Enter it once:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124
```

Inside that shell, the build/test commands are:

```bash
cabal build shikumi shikumi-trace
cabal test shikumi-trace
cabal test all
```

Formatting uses fourmolu with two-space indentation; format any file you touch:

```bash
fourmolu -i shikumi/src/Shikumi/Program.hs \
            shikumi-trace/src/Shikumi/Trace.hs \
            shikumi-trace/src/Shikumi/Trace/Node.hs \
            shikumi-trace/src/Shikumi/Trace/Feedback.hs \
            shikumi-trace/test/Main.hs
```

### Step-by-step

1. **M1 data.** Create `shikumi-trace/src/Shikumi/Trace/Node.hs` with `NodeStep`,
   `NodePath`, `programNodePaths`, and `nodeFields`. Add `nodeFieldsIndexed` and `NodeFields`
   to `shikumi/src/Shikumi/Program.hs` and export them. Add the `nodePath` field to
   `SpanAttrs` in `shikumi-trace/src/Shikumi/Trace.hs`, update `emptyAttrs`, re-export
   `NodePath`. Bump `currentFormatVersion` to `2` in `Shikumi/Trace/Store.hs`. Register the
   new module(s) in `shikumi-trace.cabal`.

2. **M1 test.** In `shikumi-trace/test/Main.hs`, add a `node` test group asserting
   `length (programNodePaths p) == length (foldParams p)` for: a two-node `chain` (use the
   combinators from `Shikumi.Combinator` / `Shikumi.Module` — `predict` and `chain`/`>>>`),
   a `majorityVote` wrapping a single predict, an `Ensemble` of two predicts, and a
   `parallel2`; assert `nodeFields` returns expected input/output field-name lists; assert
   `NodePath` and a `nodePath`-bearing `TraceTree` JSON round-trip. Build a `Predict` node
   for tests with a small record type that derives the schema/prompt/model instances, mirror
   the existing fixtures' style.

3. **M2 execution.** Add `CurrentNode` (with `askNode`/`localNode`/`runCurrentNode`),
   `runProgramTraced`, and `tracedNodeLLM` (in `Shikumi.Trace.Node` or a sibling
   `Shikumi.Trace.Program` module — register it in the cabal file). Re-export
   `runProgramTraced` from `Shikumi.Trace` if convenient for consumers.

4. **M2 test.** Add a `correlate` group running a two-`Predict` chain under
   `runProgramTraced` with a stub `LLM` interpreter (keyed responder, as in
   `TraceFixtures`), collecting the tree, filtering `LlmCallSpan`s in start order, and
   asserting each span's `nodePath` equals the corresponding `programNodePaths` element and
   the corresponding `mapParamsAt` node (witnessed via `nodeFields`).

5. **M3 feedback.** Create `shikumi-trace/src/Shikumi/Trace/Feedback.hs` with `FeedbackLog`,
   `Feedback` effect, `attachFeedback`, `feedbackFor`, `runFeedback`, `emptyFeedback`.
   Register in the cabal file.

6. **M3 test.** Add a `feedback` group attaching critiques and asserting `feedbackFor`
   returns them in order, plus a JSON round-trip of `FeedbackLog`.

7. **Format, build, test.** Run the fourmolu command above, then
   `cabal build shikumi shikumi-trace` and `cabal test all`. Update this plan's Progress,
   Surprises, and Decision Log. Commit.

Expected final test transcript (abridged):

```text
shikumi-trace
  spike: OK
  tree: OK
  store: OK
  replay: OK
  e2e: OK
  node: OK
  correlate: OK
  feedback: OK

All N tests passed
```


## Validation and Acceptance

The headline acceptance is observable and hermetic (no network, no API keys):

  * **Node correlation.** Build a two-node program — a `chain` of two `predict`s, optionally
    wrapped in `majorityVote` to prove paths descend through combinators — run it through
    `runProgramTraced` with a stub `LLM`, and confirm: there are exactly as many
    `LlmCallSpan`s as model calls; each span's `nodePath` is `Just p` where `p` equals the
    corresponding element of `programNodePaths program`; and that element names the same node
    `mapParamsAt k` edits (proved by editing node `k`'s instruction and observing the change
    via `nodeFields`/the run, or by asserting `programNodePaths program !! k` equals the path
    on the `k`-th call). This is the concrete realization of MasterPlan integration point #3.

  * **Feedback round-trip.** Under `runFeedback`, attach a critique to node N's `NodePath`,
    read it back with `feedbackFor`, and confirm equality; confirm an untargeted node returns
    `[]`; confirm `FeedbackLog` JSON round-trips. This realizes integration point #4.

  * **Field metadata.** `nodeFields program` returns, for each node, its input- and
    output-field names; this is the contract `docs/plans/19-grounded-instruction-proposer.md`
    consumes.

Run the whole suite to confirm nothing regressed:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test shikumi-trace
nix develop .#ghc9124 --command cabal test all
```

Success is every group reporting `OK`, including the existing `spike`/`tree`/`store`/
`replay`/`e2e` groups (proving the additive change did not break capture, persistence, or
replay) and the new `node`/`correlate`/`feedback` groups.


## Idempotence and Recovery

Every step is additive and safe to repeat. Re-running `cabal build`/`cabal test` is
idempotent. The only format-level change is `SpanAttrs` gaining an optional `nodePath` field
and `currentFormatVersion` bumping to `2`; because `nodePath` is a `Maybe` and the version is
bumped, old trace files are handled deterministically (rejected by version check, which is
the project's intended "reject loudly" behavior — re-capture to regenerate). If a partially
edited `SpanAttrs` fails to compile (e.g. `emptyAttrs` not updated), the fix is local: add
`nodePath = Nothing` to `emptyAttrs`. If the M2 interpose ordering tags the wrong span, switch
to the documented fallback (tag inside `runProgramTraced`'s own `withSpan LlmCallSpan`), which
has no cross-interpreter ordering dependency, and record the switch in the Decision Log.


## Interfaces and Dependencies

Libraries/modules used and why:

  * `effectful` — the effect system. New effects `CurrentNode` and `Feedback` are dynamic
    effects (like `Trace`), interpreted with `interpret`; `tracedNodeLLM` uses `interpose`
    (like `tracedLLM`). State is held in `IORef`s reached through `Effectful.Prim` (like
    `runTrace`).
  * `shikumi` (`Shikumi.Program`) — pattern-matched to walk the `Program` GADT and read each
    `Predict` node's existential `Signature` field names.
  * `aeson` — `ToJSON`/`FromJSON` for `NodeStep`, `NodePath`, and `FeedbackLog`.
  * `containers` — `Map NodePath [Text]` for `FeedbackLog`.

Signatures that must exist at the end of each milestone (full module paths):

End of **M1** (`Shikumi.Trace.Node` in `shikumi-trace/src/Shikumi/Trace/Node.hs`;
`Shikumi.Program` in `shikumi/src/Shikumi/Program.hs`; `Shikumi.Trace` in
`shikumi-trace/src/Shikumi/Trace.hs`):

```haskell
data NodeStep = StepComposeL | StepComposeR | StepFMap | StepMap
              | StepParallelL | StepParallelR | StepRetry | StepRetryWhen
              | StepValidate | StepMajorityVote | StepEnsemble !Int
newtype NodePath = NodePath [NodeStep]
programNodePaths :: Program i o -> [NodePath]
nodeFields :: Program i o -> [(NodePath, NodeFields)]

-- in Shikumi.Program:
data NodeFields = NodeFields { inputFieldNames :: ![Text], outputFieldNames :: ![Text] }
nodeFieldsIndexed :: Program i o -> [NodeFields]

-- in Shikumi.Trace, SpanAttrs gains:
--   nodePath :: !(Maybe NodePath)
-- and Shikumi.Trace.Store.currentFormatVersion == 2
```

End of **M2** (`Shikumi.Trace.Node` or `Shikumi.Trace.Program`):

```haskell
data CurrentNode :: Effect
askNode      :: (CurrentNode :> es) => Eff es (Maybe NodePath)
localNode    :: (CurrentNode :> es) => NodePath -> Eff es a -> Eff es a
runCurrentNode :: Eff (CurrentNode : es) a -> Eff es a
tracedNodeLLM :: (Trace :> es, CurrentNode :> es, LLM :> es) => Eff es a -> Eff es a
runProgramTraced ::
  (LLM :> es, Trace :> es, CurrentNode :> es, Error ShikumiError :> es) =>
  Program i o -> i -> Eff es o
```

Note the public contract from MasterPlan integration point #3 names
`runProgramTraced :: (LLM :> es, Trace :> es, Error ShikumiError :> es) => Program i o -> i
-> Eff es o`. The `CurrentNode` constraint is an *internal* threading detail discharged by
`runCurrentNode` at the program edge (exactly as `Prim`/`Time` are discharged for `runTrace`).
If a single-constraint public signature is preferred, wrap the body so `runProgramTraced`
itself calls `runCurrentNode` internally and exposes only `(LLM, Trace, Error ShikumiError)`;
record the chosen surface in the Decision Log. Either way the observable behavior — model-call
spans tagged with node paths — is identical.

End of **M3** (`Shikumi.Trace.Feedback` in `shikumi-trace/src/Shikumi/Trace/Feedback.hs`):

```haskell
newtype FeedbackLog = FeedbackLog (Map NodePath [Text])
emptyFeedback :: FeedbackLog
feedbackFor   :: NodePath -> FeedbackLog -> [Text]
data Feedback :: Effect
attachFeedback :: (Feedback :> es) => NodePath -> Text -> Eff es ()
runFeedback :: (Prim :> es) => Eff (Feedback : es) a -> Eff es (a, FeedbackLog)
```

Downstream contract summary for the consuming plans (all under
`/Users/shinzui/Keikaku/bokuno/shikumi/docs/plans/`):

  * `20-miprov2-optimizer.md` and bootstrap recover per-node demos by filtering trace spans on
    `nodePath`, then attaching recovered demos to the node `mapParamsAt k` edits, where `k` is
    that path's index in `programNodePaths`.
  * `19-grounded-instruction-proposer.md` calls `nodeFields`/`nodeFieldsIndexed` to obtain a
    node's input/output field names for a grounded proposal prompt.
  * `22-gepa-reflective-optimizer.md` writes critiques with `attachFeedback path text` during
    evaluation and reads them with `feedbackFor path log` before mutating that node's
    instruction.

Build/test facts: all builds and tests run inside `nix develop .#ghc9124` (GHC 9.12.4);
`cabal test shikumi-trace` runs this package's suite and `cabal test all` runs the workspace;
formatting is fourmolu with two-space indentation; tests are hermetic via a stub `LLM`
interpreter (the pattern in `Shikumi.Trace.Demo`/`TraceFixtures`). Commits carry `MasterPlan:`,
`ExecPlan:`, and `Intention:` trailers (intention `intention_01ktq80610e6nbe3d7yrct59an`).
