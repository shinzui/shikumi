# Programs & combinators — the deep embedding

A `Program i o` is the keystone of shikumi: a typed **GADT deep embedding** of an LM program
as inspectable data. This guide covers the GADT itself, the two foundational modules
(`predict`, `chainOfThought`), every combinator, the two executors, and the parameter /
serialization interface that the optimizer is built on.

---

## The GADT

A program is a tree of constructors. The set is deliberately minimal; richer modules are
*derived functions* over these, not new constructors.

```haskell
data Program i o where
  Predict      :: (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o)
               => Signature i o -> Params -> Program i o
  Compose      :: Program a b -> Program b c -> Program a c
  FMap         :: (o -> o') -> Program i o -> Program i o'
  Map          :: Int -> Program a b -> Program [a] [b]
  Parallel     :: Program i a -> Program i b -> Program i (a, b)
  Retry        :: Int -> Program i o -> Program i o
  RetryWhen    :: (ShikumiError -> Bool) -> Int -> Program i o -> Program i o
  Validate     :: (o -> Either Text o) -> Program i o -> Program i o
  MajorityVote :: Eq o => Int -> TempSchedule -> Program i o -> Program i o
  Ensemble     :: [Program i r] -> ([r] -> o) -> Program i o
  Embed        :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o
```

A few things worth noticing:

- **`Predict` captures its dictionaries existentially.** The schema/decode/prompt constraints
  are captured by the constructor, so `runProgram` recovers them by pattern-matching — this is
  what lets a program be rewritten as data while staying type-checked.
- **`Compose`'s intermediate type is existential.** `Compose :: Program a b -> Program b c ->
  Program a c` typechecks only when the middle types line up; mismatched pipelines are compile
  errors.
- **`FMap` and `Embed` carry no `Params`.** Their function/body is an opaque closure, so they
  are leaves to the optimizer's parameter traversal.
- **`Embed`'s body is constrained to exactly `runProgram`'s effect row** (`LLM` + `Error
  ShikumiError`), so an embedded step runs under the ordinary executors without widening the
  framework's constraint. This is the constructor multi-step agents (ReAct) are built on.

### Node parameters

```haskell
data Params = Params
  { instructionOverride :: Maybe Text   -- Nothing = use the signature's default
  , demos               :: [Demo]       -- ordered few-shot demonstrations
  }

data Demo = Demo { input :: Value, output :: Value }   -- stored as JSON

emptyParams :: Params                    -- no override, no demos
```

`Params` is the *uniform, serializable* overlay the compiler and optimizer manipulate
regardless of a node's `i`/`o`. Demos are stored as **type-agnostic JSON** so a single
traversal can edit nodes of differing types; at run time each demo is decoded back into the
node's typed `Sig.Demo i o`.

---

## The two foundational modules

### `predict` — the basic predictor

```haskell
predict :: (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o)
        => Signature i o -> Program i o
predict sig = Predict sig emptyParams
```

A single `Predict` node with empty parameters. This is the program you reach for most.

### Chain of thought

```haskell
chainOfThought    :: (…) => Signature i o -> Program i o
chainOfThoughtRaw :: (…) => Signature i o -> Program i (WithReasoning o)

data WithReasoning o = WithReasoning { reasoning :: Text, value :: o }
```

`chainOfThought` augments the output signature with a leading `reasoning` field (asking the
model to *reason first, then commit*), then projects the answer back out with `FMap` — so your
program type stays `Program i o`. `chainOfThoughtRaw` keeps the reasoning visible.

The important design point: **the reasoning-augmented node is an ordinary `Predict` node.**
Its instruction and demos are visible to the parameter traversal like any other node, so the
optimizer tunes a chain-of-thought node with no special casing. (`WithReasoning`'s
schema/decode/prompt instances are hand-written rather than derived, because its `value` field
is polymorphic in `o`; it nests `o`'s own schema under a `value` key.)

### `twoStep` — free-form answer, then structured extraction

```haskell
twoStep :: (FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o)
        => Signature i o -> Program i o
```

For models that are strong reasoners but weak at producing structured output, `twoStep` makes
**two** model calls: the first asks the question in plain prose and lets the model answer in
free-form text; the second hands that text to an *extraction* call (using the robust
`[[ ## field ## ]]` fallback adapter) that pulls the structured fields out. The caller gets a
normal typed `o`; the two-call dance is hidden inside.

It is built as an [`embed`](#embed-the-escape-hatch) node, not as a third `Adapter` value —
deliberately. An `Adapter`'s `parse` is a *pure* `Response -> Either ShikumiError o` and so
structurally cannot issue the second model call; an embedded body runs in `runProgram`'s effect
row and can. Because `embed` carries no `Params`, `twoStep` composes and serializes exactly like
any other node. (Both calls target the same ambient model; a separate, smaller extraction model
is out of scope — matching DSPy's own limitation.)

---

## The combinators

Every combinator in `Shikumi.Combinator` is a thin surface over a GADT constructor, so the
result stays runnable, inspectable by the optimizer, and serializable. Grouped by purpose:

### Pipeline

```haskell
(>>>) :: Program a b -> Program b c -> Program a c     -- infixr 1
chain :: [Program a a] -> Program a a                  -- n-ary, same-type stages
```

`p >>> q` runs `p`, then feeds its output to `q`. Typechecks only when `p`'s output type
equals `q`'s input type. `chain [p, q, r]` is `p >>> q >>> r`; it requires same-type stages
(the GADT has no identity node to seed an empty fold) and errors on the empty list.

```haskell
pipeline_ :: Program RawEmail Decision
pipeline_ = extract >>> enrich >>> approve   -- reorder → does not compile
```

### Map

```haskell
mapP    :: Int -> Program a b -> Program [a] [b]   -- bounded-concurrent width w
mapSeqP :: Program a b -> Program [a] [b]          -- sequential (width 1)
```

Apply a per-element program across a list. The width is honoured only by the concurrent
executor (see below); output order matches input order.

### Parallel

```haskell
parallel2 :: Program i a -> Program i b -> Program i (a, b)   -- a pair on one input
parallelN :: [Program i o] -> Program i [o]                   -- homogeneous list on one input
```

Run programs on the *same* input. `parallelN` is defined as an `ensemble` with the identity
reducer.

### Retry

```haskell
retry     :: Int -> Program i o -> Program i o
retryWhen :: (ShikumiError -> Bool) -> Int -> Program i o -> Program i o
```

`retry n` re-runs up to `n` total attempts on *any* `ShikumiError`. `retryWhen ok n` retries
only errors matching `ok`; a non-matching error propagates immediately. (At the *program*
level this retries on any/selected `ShikumiError`; the resilience interpreter does its own,
separate transient-only retry at the transport level — see
[Effects & the runtime](./effects-and-runtime.md#resilience).)

### Validate

```haskell
validate      :: (o -> Bool) -> Text -> Program i o -> Program i o
validateRetry :: Int -> (o -> Bool) -> Text -> Program i o -> Program i o
```

`validate ok reason` runs the program, then checks its output; on rejection it surfaces a
`ValidationFailure reason`. `validateRetry n` wraps that in a `retry n`, so a rejected output
triggers a re-run. **This is the program-level seam for enforcing a domain rule** — including
a type's own `Validatable` predicate, if you pass it here.

```haskell
checked = validateRetry 3 (\inv -> total inv > 0) "total must be positive" (predict extractSig)
```

### Majority vote (self-consistency)

```haskell
majorityVote   :: Eq o => Int -> TempSchedule -> Program i o -> Program i o
majorityVoteBy :: Int -> TempSchedule -> ([o] -> o) -> Program i o -> Program i o

data TempSchedule = TempFixed [Double] | TempSpread Double Double
```

`majorityVote k sched` samples the program `k` times and returns the **modal** output (most
frequent under `Eq`, ties broken by first appearance). `majorityVoteBy` folds the `k` outputs
with a custom reducer, for outputs that are not usefully `Eq`.

> **`TempSchedule` is live on the wire** (since the ambient-routing work). Each of the `k`
> samples is run with its scheduled temperature: `TempFixed xs` cycles `xs` to length `k`,
> `TempSpread base spread` fans `k` values evenly across `[base-spread, base+spread]`. The
> temperature is threaded down to the sample's `Predict` nodes and applied by `routeLLM` (so a
> router must be installed — the hermetic stub path and the live path both install one; an
> un-routed run leaves the schedule inert). `runProgram` and `runProgramConc` produce the same
> set of per-sample temperatures. See
> [Effects & the runtime → Ambient model routing](./effects-and-runtime.md#ambient-model-routing).

### Ensemble

```haskell
ensemble :: [Program i r] -> ([r] -> o) -> Program i o
```

Run several *distinct* programs on the same input, collect their (homogeneous) results, and
fold them with a total reducer.

```haskell
panel = ensemble [gpt4Judge, claudeJudge, deepseekJudge] majorityLabel
```

### Embed (the escape hatch)

```haskell
embed :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o
```

Lift an opaque effectful step into a first-class `Program` node. Because its body is
constrained to exactly the executor's effect row, it runs under the ordinary
`runProgram`/`runProgramConc` and composes/traces like any node — but it is opaque to the
parameter traversal (no `Params`) and serializes as `ShapeEmbed`. ReAct agents are built on
this.

### Reward-driven self-refinement

Three **inference-time** modules wrap any `Program i o` to steer its re-runs by *how good the
answer is*. They share a reward vocabulary (`Shikumi.Reward`): a `Reward o` is a function
scoring a single output, built with `mkReward (o -> Double)` or `boolReward (o -> Bool)`. Each
module is itself an ordinary `Program i o` built from `Embed` (no new GADT constructor), so it
runs under the unchanged executors, composes with every combinator, and carries no `Params`.

```haskell
bestOfN :: Int -> Double -> Reward o -> Program i o -> Program i o
refine  :: Int -> Double -> Reward o -> Program i o -> Program i o
multiChainComparison
  :: (…) => Int -> Program i (WithReasoning o) -> Signature (MultiChainInput i o) o2 -> Program i o2
```

- **`bestOfN n threshold reward p`** — run `p` up to `n` times at *spread* sampling temperatures
  (so the attempts genuinely differ), score each output, and return the highest-scoring one —
  short-circuiting as soon as one clears `threshold`.
- **`refine n threshold reward p`** — run `p`; on a sub-threshold output, ask an LM to write a
  textual critique ("advice") and feed it into the next attempt, returning the best seen. Where
  `bestOfN` re-samples, `refine` *learns from the failure*.
- **`multiChainComparison m reasoner synthSig`** — run `m` independent reasoning chains, then make
  one final synthesis call shown all `m` candidates and asked for a single corrected consensus.

```haskell
robust = bestOfN 5 1.0 (boolReward isValid) (predict extractSig)   -- keep the first valid extraction
```

Per-attempt temperature flows through the same `TempSchedule` channel `majorityVote` uses, so
the modules "light up" with distinct per-sample temperatures once a router is installed (see
[Effects & the runtime → Ambient model routing](./effects-and-runtime.md#ambient-model-routing)).
The reward/critique vocabulary is shared with GEPA's `FeedbackMetric`
([Evaluation & optimization](./evaluation-and-optimization.md#optimization-shikumi-optimize)).

---

## The two executors

```haskell
runProgram     :: (LLM :> es, Error ShikumiError :> es)
               => Program i o -> i -> Eff es o
runProgramConc :: (LLM :> es, Error ShikumiError :> es, Concurrent :> es)
               => Program i o -> i -> Eff es o
```

Both have **identical observable semantics**. The difference is concurrency:

- `runProgram` runs everything *sequentially*, regardless of `mapP` widths.
- `runProgramConc` honours the concurrency widths: `Map` (bounded by its width), `Parallel`,
  `MajorityVote`, and `Ensemble` run their independent sub-programs concurrently via
  `effectful`'s `Concurrent` effect.

**Why two?** Concurrency is an *execution choice*, not part of a program's type. Keeping
`Concurrent` off `runProgram`'s constraint means the common path doesn't force a `Concurrent`
handler onto every consumer; you opt into it by choosing `runProgramConc`.

---

## Programs as data: the parameter interface

This is what makes the optimizer possible without runtime reflection. One traversal focuses
every node's `Params`:

```haskell
paramsTraversal :: Applicative f => (Params -> f Params) -> Program i o -> f (Program i o)

foldParams  :: Program i o -> [Params]                          -- read all, in order
mapParams   :: (Params -> Params) -> Program i o -> Program i o -- edit all
mapParamsAt :: Int -> (Params -> Params) -> Program i o -> Program i o   -- edit node n
```

The traversal visits `Params` in **left-to-right depth-first order** (for `Compose f g`, all
of `f`'s come before `g`'s) and obeys the `lens` `Traversal'` laws. Composite nodes
(`Compose`, `FMap`, `Embed`) carry no `Params`, so **a program's parameter count equals its
number of `Predict` nodes**. `mapParamsAt n` is the optimizer's primary edit: "replace node
*n*'s instruction/demos"; the index it addresses is the same index `foldParams` produces.

---

## Programs as data: serialization

You can save a tuned program's *parameter state* — never its closures.

```haskell
data ProgramShape = ShapePredict Text | ShapeCompose … | ShapeFMap … | ShapeMap Int …
                  | ShapeParallel … | ShapeRetry Int … | ShapeRetryWhen Int …
                  | ShapeValidate … | ShapeMajorityVote Int TempSchedule …
                  | ShapeEnsemble [ProgramShape] | ShapeEmbed

programShape     :: Program i o -> ProgramShape                 -- closure-free structure
programParams    :: Program i o -> [Params]                     -- the tuned vector (= foldParams)
setProgramParams :: [Params] -> Program i o -> Either ProgramShapeError (Program i o)
```

The recipe:

- **Save** an optimized program: write `(programShape p, programParams p)` as JSON. `Params`
  and `Demo` are JSON-serializable; `ProgramShape` records the constructor tree and a label per
  `Predict` node. Opaque pieces (an `FMap`'s function, a `Validate`'s predicate, an `Ensemble`'s
  reducer, an `Embed`'s body) are intentionally omitted — they are unserializable.
- **Load**: reconstruct `p` in code (the structural template), read the `[Params]`, then
  `setProgramParams`. A length mismatch is a `ParamCountMismatch` `Left`, never a silent
  corruption.

This is exactly what the compiler's `encodeCompiled` / `decodeCompiledOnto` and the
optimizer's serialization use — see [Evaluation & optimization](./evaluation-and-optimization.md).

---

## A worked tour

```bash
cabal run jitsurei-compose        # extract >>> enrich >>> approve, type-checked hand-offs
cabal run jitsurei-combinators    # retry / validateRetry / majorityVote / mapP / ensemble
```

Both run offline against the deterministic stub LM; the `app/` sources are self-contained.
