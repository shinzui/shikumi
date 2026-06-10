---
id: 19
slug: grounded-instruction-proposer
title: "Grounded instruction proposer"
kind: exec-plan
created_at: 2026-06-09T22:35:41Z
intention: "intention_01ktq80q01emxtjfxzd3rw4tjs"
master_plan: "docs/masterplans/3-shikumi-dspy-parity-optimizers-and-self-refinement.md"
---

# Grounded instruction proposer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi (the typed language-model programming framework rooted at
`/Users/shinzui/Keikaku/bokuno/shikumi`) lets you build an LM pipeline as a value of type
`Program i o` — a tree of nodes, some of which (`Predict` nodes) call a language model — and
then *optimize* it: search for better per-node instruction strings and few-shot
demonstrations without changing the program's types or structure. An "instruction" here is
the plain-English prompt header that tells the model what the node's job is (for a sentiment
node, e.g. "Classify the sentiment of the sentence as positive or negative"). One of the
shipped optimizers, `instructionSearch`
(`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi-optimize/src/Shikumi/Optimize/Instruction.hs`),
already searches for better instructions, but its *proposer* — the LM call that invents
candidate instructions — is **blind**. It feeds the proposing model only the node's current
instruction, a hardcoded placeholder string `"the task's input and output fields"`, and a
bland `variant:N` marker. It cannot tell the proposing model what the data looks like, what
the program as a whole is trying to do, what the node's actual input/output fields are
called, which instructions were already tried and how they scored, or *how* to write a good
instruction.

After this ExecPlan, Shikumi has a **grounded** instruction proposer: a `proposeInstructions`
surface that gathers rich *signals* about the optimization target and feeds them to the
proposing model so it writes far better candidates. Concretely, a caller (today the existing
instruction search; tomorrow MIPROv2 and COPRO,
`/Users/shinzui/Keikaku/bokuno/shikumi/docs/plans/20-miprov2-optimizer.md` and
`/Users/shinzui/Keikaku/bokuno/shikumi/docs/plans/21-copro-instruction-optimizer.md`) hands
the proposer a program, a dataset, a target node index, the node's current instruction, the
history of instructions tried so far with their scores, and a few bootstrapped demonstrations;
the proposer returns a ranked list of fresh candidate instruction strings for that node — with
the **current instruction always retained as a candidate**, so a node can never be made worse
than where it started. Each signal-gatherer (a dataset summarizer, a program describer, a
module/role describer) is itself an ordinary typed Shikumi `Program`, preserving V1's
foundational pattern that "the optimizer is written in the framework it optimizes" — so every
sub-program is typed, cacheable, traceable, and testable with the same stub-LM machinery as
everything else.

This mirrors DSPy 3.x's `GroundedProposer` (read from a fresh clone at
`/tmp/dspy/dspy/propose/grounded_proposer.py` and
`/tmp/dspy/dspy/propose/dataset_summary_generator.py`), which feeds its proposing model seven
signals: (a) a 2-3 sentence **dataset summary** observing patterns across sampled training
rows, (b) a **program code / pseudo-code summary** describing what the whole pipeline does,
(c) a per-**module role description** explaining one node's job within the pipeline, (d)
bootstrapped **task demonstrations** for that node, (e) the **prior instructions with their
scores** (instruction history), (f) a randomly-chosen **tip** (one of: be creative; keep it
simple; be descriptive; frame a high-stakes scenario; adopt a persona), and (g) the **basic
current instruction**. This plan reproduces each of those signals in Shikumi's typed idiom.

You can see it working through a hermetic test (no network, no API keys): build a fixture
program and dataset, run `proposeInstructions` for a target node under a deterministic stub
LM, and observe that it returns N distinct candidate instructions; that the proposer's
*rendered prompt* (what the stub actually received) contains the dataset summary, the node's
real field names, and the chosen tip; and that the current instruction appears among the
returned candidates. A second test demonstrates the interface compiles and runs against a
documented **MIPROv2-shaped caller** — a tiny driver that loops over a program's nodes and
calls `proposeInstructions` exactly as the real MIPROv2 plan will — proving the shared
contract is usable before MIPROv2 itself exists.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: (2026-06-09) per-node field-metadata accessor `programFieldNames` wired to EP-16's
      `nodeFieldsIndexed` (EP-16 is merged, so the preferred path is used, not the fallback);
      `renderProgramPseudo`; `programDescriber` (typed `Program ProgramDescribeIn
      ProgramDescribeOut`). `Propose.M1` tests prove the field names are recovered (`["text"]`
      → `["sentiment"]`), the pseudo-code is `predict(text) -> sentiment`, and the describer
      prompt carried the pseudo-code.
- [x] M2: (2026-06-09) `datasetSummary` (two-step `datasetDescriber` →
      `observationSummarizer`), the `tipBank`/`tipAt`, and `renderHistory`. `Propose.M2` tests
      prove the summary reaches the describer (sees `good film`), tips select deterministically
      and wrap, and history renders/empties as specified.
- [x] M3: (2026-06-09) `moduleDescriber`, `instructionGenerator`, `GenerateInstructionIn`/
      `GenerateInstructionOut`, `ProposeRequest`/`ProposeResult`, and the `proposeInstructions`
      driver (current instruction always retained, candidates deduped). `Propose.M3` tests prove
      distinct candidates retaining the current one, that the dataset summary + field names + tip
      reach the generator, and that a MIPROv2-shaped caller compiles and runs.
- [x] Final: (2026-06-09) `instructionSearch` re-pointed at `proposeInstructions`; V1's
      `ProposeIn`/`ProposeOut`/`proposeInstruction` **removed** (the grounded
      `GenerateInstructionIn`/`Out` replaces them, still emitting `proposedInstruction`).
      `cabal test shikumi-optimize` (18) and `cabal test all` green inside `nix develop
      .#ghc9124`; living sections updated; committed with MasterPlan/ExecPlan/Intention trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **EP-16 was already merged, so `programFieldNames` uses the preferred path, never the
  fallback.** `programFieldNames = map convert . nodeFieldsIndexed`. One wrinkle: EP-16's
  `NodeFields` record carries field selectors named `inputFieldNames`/`outputFieldNames` —
  identical to this plan's `NodeFieldNames`. Importing `NodeFields (..)` made those selectors
  ambiguous, so the import is `NodeFields (NodeFields)` (constructor only) and `convert` pattern-
  matches positionally. Evidence: the ambiguous-occurrence GHC error, resolved by the
  constructor-only import.
- **The stub routes each grounded sub-program by its output *marker*, not by prose substring.**
  The first cut keyed on substrings like `"observations"`/`"summary"`, but the
  `observationSummarizer` instruction contains *both* words, so it was mis-routed. The fix keys
  on the rendered output-guide marker `[[ ## <field> ## ]]` (e.g. `## summary ##`), which is
  unambiguous because each sub-program's guide names exactly its own output field. The grounded
  `instructionGenerator` keeps DSPy's `proposedInstruction` output field, so the existing
  proposer-recognition still works.
- **The re-point makes `instructionSearch` carry `(ToJSON i, ToJSON o)`.** `proposeInstructions`
  renders dataset rows via `encodeToLazyText`, so it needs `ToJSON i`/`o`; the `Optimizer` type
  itself is unchanged (those constraints live on the `instructionSearch` smart constructor and are
  captured by the closure), matching how `labeledFewShot`/`bootstrapFewShot` already constrain
  their constructors. All callers (`InstructionSpec`, `AcceptanceSpec`) use `Sentence`/`Label`,
  which are `ToJSON`, so nothing downstream broke.
- **Budget accounting for the proposer is a fixed per-node cost, guarded before the call.** The
  grounded proposer makes exactly `4 + proposalsPerNode` LM calls per node. `instructionSearch`
  checks `calls + (4 + proposalsPerNode) <= maxLmCalls` *before* proposing; if it does not fit,
  the node keeps its current instruction (no partial proposal). This preserves the existing
  "respects the LM-call budget" test (`maxLmCalls = 6` → the node skips proposing and only the
  current instruction is scored, so the recorded count stays ≤ 6).


## Decision Log

Record every decision made while working on the plan.

- Decision: Place all new code in `shikumi-optimize` under a new module namespace
  `Shikumi.Optimize.Propose` (a top module re-exporting `Shikumi.Optimize.Propose.Types`,
  `Shikumi.Optimize.Propose.Summarize`, `Shikumi.Optimize.Propose.Tips`, and
  `Shikumi.Optimize.Propose.Grounded`), rather than growing
  `Shikumi.Optimize.Instruction`.
  Rationale: The proposer is the shared contract for MIPROv2 (EP-20) and COPRO (EP-21);
  giving it its own namespace lets both import it without dragging in `instructionSearch`'s
  coordinate-ascent loop, and keeps `Shikumi.Optimize.Instruction` free to become a thin
  caller of the new surface.
  Date: 2026-06-09.
- Decision: Consume per-node field metadata through EP-16's
  `nodeFieldsIndexed :: Program i o -> [NodeFields]` accessor (where
  `NodeFields = NodeFields { inputFieldNames :: ![Text], outputFieldNames :: ![Text] }`,
  defined in `/Users/shinzui/Keikaku/bokuno/shikumi/docs/plans/16-node-correlated-tracing-and-feedback-channel.md`),
  guarded behind a thin local adapter `programFieldNames :: Program i o -> [NodeFields']` so
  the proposer never imports EP-16's module path directly. If EP-16 has not landed, the
  adapter is implemented in-package by the same `programShape`-aligned walk (see M1), deriving
  output-field names from `sigLabel`/`ShapePredict` and supplying empty input-field lists with
  a degraded-but-truthful summary.
  Rationale: MasterPlan integration point #3 mandates that EP-19 "introduce a way to recover
  per-node field metadata" and "document it here so EP-20/EP-21/EP-22 consume the same
  accessor." Routing all reads through one local adapter means the EP-16 hand-off is a
  one-line change and the proposer compiles and tests today regardless of EP-16's status
  (the plan's soft dependency).
  Rationale (field-erasure): A `Predict` node hides its `i`/`o` types existentially (dossier
  section C.1: "There is NO function like `nodeSignature`"), so we recover field *names*
  (plain `Text`), never a typed `Signature`. This matches EP-16's identical decision.
  Date: 2026-06-09.
- Decision: The proposer's output is a *ranked list* of candidate instruction strings for one
  target node (`ProposeResult { rankedCandidates :: [Text] }`), with the node's current
  instruction always present as the first element, deduplicated. The proposer does not score
  candidates itself — scoring belongs to the calling optimizer (which owns the `Metric` and
  the `Budget`).
  Rationale: V1's safety property ("the current instruction is always a candidate so a node
  can never degrade") is preserved by construction. Separating proposal from scoring keeps the
  surface usable by both MIPROv2 (Bayesian/minibatch scoring) and COPRO (coordinate-ascent
  scoring), which score differently.
  Date: 2026-06-09.
- Decision: The tip is selected deterministically by an index the caller supplies
  (`tipIndex :: Int`, taken modulo the tip-bank size), not by a hidden RNG.
  Rationale: DSPy chooses the tip with `rng.choice`; Shikumi's optimizers are reproducible by
  design (dossier E.6/E.7: "deterministic", "no global mutable state"). A caller-supplied
  index keeps tip selection reproducible and lets a search vary tips across rounds by varying
  the index, while a hermetic test can pin it.
  Date: 2026-06-09.
- Decision: **The N candidates are made distinct by varying the tip per candidate**
  (`tip = tipAt (tipIndex + j)` for candidate `j`), and the stub keys its "magic" instruction
  off the *creative* tip. Rationale: under a deterministic stub the proposer must produce
  *distinct* candidates without an RNG; per-candidate tip variation is DSPy's own mechanism and
  is fully reproducible. One candidate per node therefore carries the creative tip and proposes
  the `RULE`-bearing instruction, which is exactly what `InstructionSpec`/`AcceptanceSpec` rely on.
  Date: 2026-06-09.
- Decision: **Remove V1's `ProposeIn`/`ProposeOut`/`proposeInstruction` rather than keep a
  shim.** Rationale: no code outside `Instruction.hs` imported them (verified by grep across the
  workspace), and the grounded `GenerateInstructionIn`/`Out` is a strict superset; a shim would
  be dead surface. `instructionSearch` is now the module's only export.
  Date: 2026-06-09.
- Decision: **The public `Shikumi.Optimize.Propose` re-export lists names explicitly rather than
  re-exporting whole sub-modules.** Rationale: the internal describer records
  (`ProgramDescribeIn`, `ModuleDescribeIn`, …) share field names (`programCode`,
  `programDescription`), so a `module X` wildcard re-export would create conflicting field
  exports. The curated list exposes only the consumer-facing surface (`proposeInstructions`,
  `ProposeRequest`/`ProposeResult`, `programFieldNames`/`NodeFieldNames`, the history vocabulary,
  the tips, and `renderProgramPseudo`/`datasetSummary` for GEPA). Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Completed 2026-06-09.** The blind V1 proposer is replaced by a grounded one. Delivered under
`shikumi-optimize/src/Shikumi/Optimize/Propose/`:

- `Types.hs` — `NodeFieldNames`/`programFieldNames` (integration point #3, via EP-16's
  `nodeFieldsIndexed`), `moduleSignatureAt`, `PastInstruction`/`renderHistory`,
  `ProposeRequest`/`ProposeResult`.
- `Tips.hs` — the deterministic, index-addressable `tipBank`/`tipAt`.
- `Summarize.hs` — `renderProgramPseudo` and the typed sub-programs `programDescriber`,
  `datasetDescriber`, `observationSummarizer` (+ `datasetSummary`), `moduleDescriber`.
- `Grounded.hs` — `instructionGenerator` and the `proposeInstructions` driver.
- `Propose.hs` — the single-import public surface.

`instructionSearch` (`Instruction.hs`) now sources candidates from `proposeInstructions`; V1's
blind predictor is gone. Tests: 3 new `Propose.*` groups (8 cases) and the full
`shikumi-optimize` suite (18) green, plus `cabal test all` across the workspace. The headline
purpose is met — the M3 capture test reads the prompt the final generator received and asserts it
carries the dataset summary, the node's real field names (`predict(text) -> sentiment`), and the
selected tip, proving the proposer is genuinely grounded rather than blind.

Gaps / future enhancements (noted, not blocking): `datasetSummary` uses a single observation batch
(DSPy iterates with prior-observation refinement); the dataset summary is recomputed per node
inside `proposeInstructions` (a caching enhancement the Speed-audit note flags). The downstream
contract for EP-20/EP-21/EP-22 is the `proposeInstructions` surface + `programFieldNames`; the
MIPROv2-shaped caller test demonstrates it compiles and runs before EP-20 exists.


## Context and Orientation

This section describes everything a newcomer needs. Read it fully before editing. It assumes
no prior knowledge of this repository.

### What "optimizing instructions" means here, in plain terms

A Shikumi program is a value of type `Program i o`. Inside it, the nodes that actually call a
language model are `Predict` nodes. Each `Predict` node carries a `Signature i o` (the typed
contract: an instruction string, plus the input- and output-field *metadata* derived from the
Haskell record types `i` and `o`) and a `Params` record holding the node's *optimizable*
state — an optional instruction override and a list of demonstrations. An optimizer improves a
program by rewriting these `Params`. The "instruction" a proposer invents is exactly the
`instructionOverride` text that will be slotted into a node's `Params`.

### The packages and files in play

Everything here lives under `/Users/shinzui/Keikaku/bokuno/shikumi`. The new code goes in the
`shikumi-optimize` package; it reads types from `shikumi` and `shikumi-eval`.

  * `shikumi-optimize/` — the optimizer package. Its cabal file is
    `shikumi-optimize/shikumi-optimize.cabal`; library sources live under
    `shikumi-optimize/src/Shikumi/Optimize/` and tests under `shikumi-optimize/test/`. The
    file we replace the blind proposer in is
    `shikumi-optimize/src/Shikumi/Optimize/Instruction.hs`. Shared search plumbing is in
    `shikumi-optimize/src/Shikumi/Optimize/Search.hs` (`scoreOn`, `selectBest`,
    `freezeProgram`) and the core abstractions in
    `shikumi-optimize/src/Shikumi/Optimize/Types.hs` (`Optimizer`, `Budget`, `Scored`).

  * `shikumi/` — the core package. `shikumi/src/Shikumi/Program.hs` defines the `Program i o`
    GADT, the parameter traversal (`foldParams`, `mapParamsAt`), the shape projection
    (`programShape`, `ProgramShape`, `sigLabel`), and `Params`/`Demo`.
    `shikumi/src/Shikumi/Signature.hs` defines `Signature`, `getInstruction`,
    `inputFields`/`outputFields`. `shikumi/src/Shikumi/Schema/Types.hs` defines `FieldMeta`
    (with `fieldName :: Text`). `shikumi/src/Shikumi/Module.hs` exposes `predict` (build a
    one-node `Program` from a `Signature`). `shikumi/src/Shikumi/Adapter.hs` defines the
    `ToPrompt` class. `shikumi/src/Shikumi/Schema.hs` defines `ToSchema`/`FromModel`/
    `Validatable`.

  * `shikumi-eval/` — evaluation. `shikumi-eval/src/Shikumi/Eval/Types.hs` defines
    `Dataset i o`, `Example i o` (with fields `input :: i`, `expected :: o`),
    `datasetExamples :: Dataset i o -> [Example i o]`, and `datasetSize`.

  * `shikumi-trace/` — tracing. **This is where EP-16 lives.** EP-16
    (`/Users/shinzui/Keikaku/bokuno/shikumi/docs/plans/16-node-correlated-tracing-and-feedback-channel.md`)
    adds `nodeFieldsIndexed :: Program i o -> [NodeFields]` to `Shikumi.Program` (core
    package) and `programNodePaths`/`nodeFields` to a new `Shikumi.Trace.Node` module. This
    plan's *soft* dependency on EP-16 is for that field-metadata accessor.

### The current blind proposer, verbatim

From `shikumi-optimize/src/Shikumi/Optimize/Instruction.hs` (the surface this plan replaces),
the V1 proposer is a single structured-output predictor fed three weak signals:

```haskell
data ProposeIn = ProposeIn
  { currentInstruction :: Text,
    fieldSummary :: Text,     -- hardcoded to "the task's input and output fields"
    examples :: Text          -- in tests, just a "variant:N" marker
  }
  deriving stock (Generic, Show)

newtype ProposeOut = ProposeOut {proposedInstruction :: Text}
  deriving stock (Generic, Show)

proposeInstruction :: Program ProposeIn ProposeOut
proposeInstruction = predict proposeSig
```

And the search drives it with a static summary because no per-node field accessor existed:

```haskell
-- EP-4 ships no per-node signature accessor, so the summary is static.
summary = "the task's input and output fields"
...
ProposeOut p <- runProgram proposeInstruction (ProposeIn curInstr summary ("variant:" <> tshow v))
```

The whole point of EP-19 is to replace `summary` with the node's *real* field names and to
add the dataset/program/role/history/tip/demo signals around it.

### The relevant core accessors, verbatim (from the integration dossier)

These exist today and the plan builds on them directly:

```haskell
-- Shikumi.Program
foldParams        :: Program i o -> [Params]            -- left-to-right depth-first, Predict nodes only
mapParamsAt       :: Int -> (Params -> Params) -> Program i o -> Program i o
programShape      :: Program i o -> ProgramShape
sigLabel          :: Signature i o -> Text              -- output-field names joined with ","

data ProgramShape =
    ShapePredict !Text                                  -- the joined output-field names
  | ShapeCompose !ProgramShape !ProgramShape
  | ShapeFMap !ProgramShape | ShapeMap !Int !ProgramShape
  | ShapeParallel !ProgramShape !ProgramShape
  | ShapeRetry !Int !ProgramShape | ShapeRetryWhen !Int !ProgramShape
  | ShapeValidate !ProgramShape
  | ShapeMajorityVote !Int !TempSchedule !ProgramShape
  | ShapeEnsemble ![ProgramShape] | ShapeEmbed

data Params = Params { instructionOverride :: !(Maybe Text), demos :: ![Demo] }

-- Shikumi.Signature
inputFields  :: Signature i o -> [FieldMeta]
outputFields :: Signature i o -> [FieldMeta]
getInstruction :: Signature i o -> Text

-- Shikumi.Schema.Types
data FieldMeta = FieldMeta { fieldName :: !Text, fieldDesc :: !(Maybe Text) }

-- Shikumi.Eval.Types
datasetExamples :: Dataset i o -> [Example i o]
data Example i o = Example { input :: !i, expected :: !o }
```

**Critical gap (dossier C.1 / J.2):** there is *no* `nodeSignature :: Program i o -> Int ->
Signature` and there cannot be — a `Predict` node hides its `i`/`o` types existentially, so no
single Haskell type can name "the signature of node *n*". We therefore recover field *names*
(plain `Text`), never a typed `Signature`. That is exactly what EP-16's `nodeFieldsIndexed`
returns and what this plan's fallback reproduces.

### The EP-16 contract this plan consumes (integration point #3)

EP-16's Decision Log pins this accessor:

```haskell
-- in Shikumi.Program (added by EP-16):
data NodeFields = NodeFields { inputFieldNames :: ![Text], outputFieldNames :: ![Text] }
nodeFieldsIndexed :: Program i o -> [NodeFields]   -- one per Predict, in foldParams order
```

`nodeFieldsIndexed` returns one `NodeFields` per `Predict` node, index-aligned with
`foldParams`/`mapParamsAt`. So the field metadata for the node `mapParamsAt k` edits is
`nodeFieldsIndexed prog !! k`. **This plan consumes that accessor through a one-function local
adapter** so it works with or without EP-16 (see M1). EP-20/EP-21/EP-22 then consume *this
plan's* `proposeInstructions`, which already carries the field names — they never re-derive
them.

### The hermetic stub-LM pattern (how tests stay offline)

Tests never hit the network. The pattern (see
`shikumi-optimize/test/StubLM.hs`) is a tiny interpreter of the `LLM` effect that inspects the
rendered request `Context` (system prompt + messages) and returns a canned `Response`
constructed with the `[[ ## field ## ]]` marker format the fallback adapter parses:

```haskell
runStubLM :: Eff (LLM : es) a -> Eff es a
runStubLM = interpret $ \_ -> \case
  Complete _ ctx _ -> pure (mkResponse (respondTo ctx))
  Stream {} -> pure []
```

`respondTo ctx` already distinguishes a *proposer* request (its system prompt mentions
`proposedInstruction`) from a *task* request, and reads a `variant:N` marker to choose which
canned instruction to return. This plan extends the stub so it can also (a) answer the new
*dataset-summary*, *program-describe*, and *module-describe* sub-program requests with canned
text, and (b) **echo back into the test the rendered system prompt it received**, so the
acceptance test can assert the prompt contained the dataset summary, the field names, and the
tip. The mechanism for (b) is the same `IORef`-capture trick `runStubLMCounting` already uses
for call counting — write the last-seen system prompt to an `IORef` the test reads afterward.

### Terms defined

  * **Proposer** — the LM-backed step that invents candidate instruction strings for a node.
  * **Grounded** — fed real context about the data, program, node, and history, rather than a
    placeholder. The opposite of the V1 "blind" proposer.
  * **Signal** — one piece of grounding context (dataset summary, program description, module
    role, demos, instruction history, tip, current instruction).
  * **Tip** — a one-sentence stylistic suggestion to the proposing model (be creative / keep
    it simple / be descriptive / high-stakes framing / adopt a persona).
  * **Instruction history** — the list of instructions already tried for a node, paired with
    the score each achieved, so the proposer can avoid repeating poor ones.
  * **Bootstrapped demos** — worked input/output examples for a node, used as in-context
    examples in the proposal prompt (not the same as the demos attached to the node's
    `Params`, though they may overlap).
  * **Target node** — the `Predict` node, identified by its `foldParams` integer index, whose
    instruction we are currently proposing for.
  * **`ToPrompt`** — the Shikumi typeclass that renders a Haskell input record into the prompt
    text sent to the model; every proposer input record derives it.


## Plan of Work

The work is three milestones, each independently verifiable with a hermetic stub LM. The
sequence builds the signal-gatherers first (M1, M2), then assembles them into the public
`proposeInstructions` surface and re-points the existing optimizer at it (M3).

All new modules live under `shikumi-optimize/src/Shikumi/Optimize/Propose/` and are registered
in `shikumi-optimize/shikumi-optimize.cabal`. A top-level re-export module
`shikumi-optimize/src/Shikumi/Optimize/Propose.hs` gives consumers a single import.

### Milestone 1 — per-node field metadata + the program describer

**Scope.** Establish the per-node field-metadata accessor (the EP-16 hand-off, with an
in-package fallback) and build the first signal-gatherer: a `programDescription` summarizer
that, given a pseudo-code rendering of the whole program and a sample of its use, returns a
2-3 sentence description of what the program does. At the end of M1, a hermetic test proves
(a) the field-name accessor returns the right names for each node of a fixture program, and
(b) running `programDescription` under the stub yields a description and that the *rendered
prompt the stub received contained the program's pseudo-code*.

**The field-metadata adapter.** Add `shikumi-optimize/src/Shikumi/Optimize/Propose/Types.hs`
defining a local mirror type and the adapter:

```haskell
-- | A node's input/output field names, recovered structurally (never a typed Signature,
-- because a Predict node hides its i/o existentially — see Context and Orientation).
data NodeFieldNames = NodeFieldNames
  { inputFieldNames  :: ![Text],
    outputFieldNames :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

-- | One NodeFieldNames per Predict node, in foldParams/mapParamsAt order.
programFieldNames :: Program i o -> [NodeFieldNames]
```

Implement `programFieldNames` in one of two ways, chosen at implementation time and recorded
in the Decision Log:

  * **Preferred (EP-16 present):** `programFieldNames = map convert . nodeFieldsIndexed`
    where `convert (NodeFields i o) = NodeFieldNames i o`, importing `nodeFieldsIndexed` and
    `NodeFields` from `Shikumi.Program`. This is the integration-point-#3 contract: the
    accessor is index-aligned with `foldParams`, so `programFieldNames prog !! k` describes the
    node `mapParamsAt k` edits.

  * **Fallback (EP-16 absent):** derive what is reachable from `programShape`. Walk the
    `ProgramShape` in the same left-to-right depth-first order `foldParams` uses, emitting one
    entry per `ShapePredict label`. `label` is the comma-joined *output*-field names
    (`sigLabel`), so split it on `","` to recover `outputFieldNames`; `inputFieldNames` is not
    reachable from the shape, so emit `[]` and let the rendered summary say so truthfully
    ("output fields: …; input fields: (not available)"). This degrades gracefully exactly as
    the MasterPlan's soft-dependency clause requires, and the count still aligns with
    `foldParams` by construction (one `ShapePredict` per `Predict`).

Because the fallback can only see output names, the proposal prompt's field summary is
honest about what it knows; when EP-16 lands, swapping the one-line definition upgrades every
proposal prompt to full input+output names with no other change.

**Rendering a program as pseudo-code.** Add `renderProgramPseudo :: Program i o -> Text` (in
`Shikumi.Optimize.Propose.Summarize`). It walks `programShape` and emits a short, stable,
human-readable outline: one line per node and combinator, with `Predict` nodes shown as
`predict(inputs) -> outputs` using `programFieldNames`, and combinators shown by name
(`compose`, `map`, `parallel`, `majorityVote`, `ensemble`, …). This is Shikumi's analogue of
DSPy's `get_dspy_source_code` / `DescribeProgram.program_code`. It must be deterministic so the
test can assert on it.

**The program describer (a typed sub-program).** In
`shikumi-optimize/src/Shikumi/Optimize/Propose/Summarize.hs`, define a structured-output
predictor mirroring DSPy's `DescribeProgram`:

```haskell
data ProgramDescribeIn = ProgramDescribeIn
  { programCode    :: Text,   -- renderProgramPseudo output
    programExample :: Text    -- a rendered sample row, or "No example provided."
  }
  deriving stock (Generic, Show)
instance FromModel ProgramDescribeIn
instance ToPrompt ProgramDescribeIn

newtype ProgramDescribeOut = ProgramDescribeOut { programDescription :: Text }
  deriving stock (Generic, Show)
instance ToSchema ProgramDescribeOut
instance FromModel ProgramDescribeOut
instance ToPrompt ProgramDescribeOut
instance Validatable ProgramDescribeOut

programDescriber :: Program ProgramDescribeIn ProgramDescribeOut
programDescriber = predict (mkSignature
  "Below is pseudo-code for a pipeline that solves a task with calls to a language \
  \model. Describe, in two or three sentences, what task this program is designed to \
  \solve and how it goes about solving it. Write your answer in the `programDescription` field.")
```

Each instance/derivation follows the existing `ProposeIn`/`ProposeOut` shape in
`Instruction.hs` exactly (same imports: `Shikumi.Module (predict)`, `Shikumi.Schema
(FromModel, ToSchema, Validatable)`, `Shikumi.Adapter (ToPrompt)`,
`Shikumi.Signature (mkSignature)`).

**Commands / acceptance.**

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test shikumi-optimize --test-options='-p Propose.M1'
```

Acceptance: the `Propose.M1` group passes, demonstrating (a) `programFieldNames fixtureProg`
returns the expected output-field names (and, under EP-16, input names) for each node; (b)
`renderProgramPseudo fixtureProg` is the expected deterministic string; (c) running
`programDescriber` under the stub returns a non-empty `programDescription`, and the system
prompt captured by the stub contains a substring of the pseudo-code (proving the signal
reached the model).

### Milestone 2 — dataset summarizer, tip bank, and instruction history

**Scope.** Build the remaining signal-gatherers that do not depend on a target node: the
dataset summarizer (observe patterns across sampled examples), the tip bank, and the
instruction-history renderer. At the end of M2, a hermetic test proves the dataset summarizer
returns a summary whose prompt contained the sampled rows, the tip bank returns the expected
deterministic tips by index, and history rendering produces the expected text.

**The dataset summarizer (a typed sub-program).** Mirror DSPy's
`dataset_summary_generator.py`: DSPy makes "observations" over a batch of sampled rows
(`DatasetDescriptor`) and then condenses them into a 2-3 sentence summary
(`ObservationSummarizer`). Shikumi reproduces this with two structured-output predictors plus
a thin driver. In `Shikumi.Optimize.Propose.Summarize`:

```haskell
data DatasetDescribeIn = DatasetDescribeIn { examples :: Text }   -- rendered sampled rows
  deriving stock (Generic, Show)
instance FromModel DatasetDescribeIn
instance ToPrompt DatasetDescribeIn

newtype DatasetDescribeOut = DatasetDescribeOut { observations :: Text }
  deriving stock (Generic, Show)
instance ToSchema DatasetDescribeOut ...   -- (FromModel, ToPrompt, Validatable too)

datasetDescriber :: Program DatasetDescribeIn DatasetDescribeOut
datasetDescriber = predict (mkSignature
  "Given several examples from a dataset, write observations about trends that hold for \
  \most or all of the samples — topics, content, syntax, brevity — and guess at the task \
  \the dataset enables. Write them in the `observations` field.")

newtype SummarizeIn  = SummarizeIn { observations :: Text }
newtype SummarizeOut = SummarizeOut { summary :: Text }
observationSummarizer :: Program SummarizeIn SummarizeOut
observationSummarizer = predict (mkSignature
  "Summarize the observations below into a brief two-to-three sentence summary highlighting \
  \only the most important details. Write it in the `summary` field.")

-- | Sample up to `viewBatch` examples, render them, observe, then condense.
datasetSummary ::
  (ToJSON i, ToJSON o, LLM :> es, Error ShikumiError :> es) =>
  Int ->                       -- viewBatch: how many rows to sample
  Dataset i o ->
  Eff es Text
```

`datasetSummary viewBatch ds` renders the first `viewBatch` rows of `datasetExamples ds` (each
example as `input => expected` via `Data.Aeson.encode`, so it works for any `ToJSON i`/`o`,
exactly as bootstrap/labeled-few-shot already require `ToJSON` per dossier E.6), runs
`datasetDescriber` on that text, then runs `observationSummarizer` on the observations, and
returns the `summary`. To keep this hermetic and cheap, this plan uses a *single* observation
batch (DSPy iterates batches with a `DatasetDescriptorWithPriorObservations` refinement loop;
we note that as a future enhancement in Surprises/Decision Log and keep M2 to one batch — the
acceptance criterion is that the summary signal *reaches the proposer*, not that it iterates).

**The tip bank.** In `shikumi-optimize/src/Shikumi/Optimize/Propose/Tips.hs`, port DSPy's
`TIPS` verbatim (in meaning), as a deterministic, index-addressable list:

```haskell
-- | The stylistic tips, in a fixed order. `tipAt i` returns `tipBank !! (i `mod` length)`.
tipBank :: [Text]
tipBank =
  [ "",                                                                    -- none
    "Don't be afraid to be creative when creating the new instruction!",   -- creative
    "Keep the instruction clear and concise.",                             -- simple
    "Make sure your instruction is very informative and descriptive.",     -- descriptive
    "The instruction should describe a high-stakes scenario in which the model must solve the task.",
    "Include a persona relevant to the task in the instruction (e.g. \"You are a ...\")."
  ]

tipAt :: Int -> Text
tipAt i = tipBank !! (i `mod` length tipBank)
```

**Instruction history rendering.** In `Shikumi.Optimize.Propose.Types`, define the history
type and renderer the optimizers thread:

```haskell
-- | One past attempt for a node: the instruction text and the score it earned.
data PastInstruction = PastInstruction { pastInstruction :: !Text, pastScore :: !Double }
  deriving stock (Eq, Show, Generic)

-- | Render the history newest-or-best-first as lines "score 0.83 :: <instruction>",
-- capped at `maxInHistory` entries (DSPy caps at 5). Empty history renders as
-- "No previous instructions." so the proposer prompt is always well-formed.
renderHistory :: Int -> [PastInstruction] -> Text
```

**Commands / acceptance.**

```bash
nix develop .#ghc9124 --command cabal test shikumi-optimize --test-options='-p Propose.M2'
```

Acceptance: the `Propose.M2` group passes, demonstrating (a) `datasetSummary 2 trainset` under
the stub returns a non-empty summary and the stub-captured prompt for the *describer* call
contained a rendered training row (e.g. the substring `good film`); (b) `tipAt 1` equals the
"creative" tip and `tipAt 6` wraps to `tipAt 0`; (c) `renderHistory 5 [...]` produces the
expected multi-line text and `renderHistory 5 []` is `"No previous instructions."`.

### Milestone 3 — the assembled `proposeInstructions` surface

**Scope.** Combine M1 and M2 into the public proposer: a module/role describer, the final
instruction-generating predictor (carrying every signal), and the `proposeInstructions`
driver that produces N ranked candidates for a target node with the current instruction always
retained. Then re-point `instructionSearch` at the new surface. At the end of M3, the
acceptance test shows the proposer's rendered prompt carries the dataset summary, the node's
field names, and the tip, and that the interface drives a MIPROv2-shaped caller.

**The module/role describer.** Mirror DSPy's `DescribeModule`. In
`Shikumi.Optimize.Propose.Summarize`:

```haskell
data ModuleDescribeIn = ModuleDescribeIn
  { programCode        :: Text,
    programDescription :: Text,   -- from programDescriber (M1)
    moduleSignature    :: Text     -- e.g. "predict(text) -> sentiment" for the target node
  }
newtype ModuleDescribeOut = ModuleDescribeOut { moduleDescription :: Text }
moduleDescriber :: Program ModuleDescribeIn ModuleDescribeOut
moduleDescriber = predict (mkSignature
  "Below is pseudo-code for a language-model pipeline and a description of what it does. \
  \Describe the role of the one specified module within the broader program. Write it in \
  \the `moduleDescription` field.")
```

The `moduleSignature` string for the target node `k` is built from `programFieldNames prog !!
k`: `"predict(" <> intercalate ", " inputs <> ") -> " <> intercalate ", " outputs`.

**The final instruction generator (the grounded predictor).** This is the heart — DSPy's
`GenerateSingleModuleInstruction`. In
`shikumi-optimize/src/Shikumi/Optimize/Propose/Grounded.hs`:

```haskell
data GenerateInstructionIn = GenerateInstructionIn
  { datasetDescription    :: Text,   -- M2 dataset summary
    programCode           :: Text,   -- M1 pseudo-code
    programDescription    :: Text,   -- M1 describer output
    moduleSignature       :: Text,   -- target node "predict(in) -> out"
    moduleDescription     :: Text,   -- module describer output
    taskDemos             :: Text,   -- rendered bootstrapped demos, or "No task demos provided."
    previousInstructions  :: Text,   -- M2 renderHistory output
    basicInstruction      :: Text,   -- the node's current instruction
    tip                   :: Text     -- M2 tipAt output
  }
  deriving stock (Generic, Show)
instance FromModel GenerateInstructionIn
instance ToPrompt GenerateInstructionIn

newtype GenerateInstructionOut = GenerateInstructionOut { proposedInstruction :: Text }
  deriving stock (Generic, Show)
instance ToSchema GenerateInstructionOut ...   -- FromModel, ToPrompt, Validatable

instructionGenerator :: Program GenerateInstructionIn GenerateInstructionOut
instructionGenerator = predict (mkSignature
  "Use the information below to understand a task we are solving with calls to a language \
  \model, then write a NEW instruction that will prompt the model to solve the task better. \
  \Consider the dataset description, the program pseudo-code and description, the target \
  \module's role and fields, any task demonstrations, the previously-tried instructions and \
  \their scores, the current instruction, and the tip. Write only the new instruction text in \
  \the `proposedInstruction` field.")
```

Because `GenerateInstructionIn` derives `ToPrompt` generically, *every* field is rendered into
the prompt under its field name, so the rendered prompt provably contains the dataset summary,
the module signature (hence the field names), and the tip — which is exactly what the
acceptance test asserts.

**The public proposer record and driver.** In `Shikumi.Optimize.Propose.Types` (the input
record) and `Shikumi.Optimize.Propose.Grounded` (the driver):

```haskell
-- | Everything the grounded proposer needs to propose instructions for one node.
data ProposeRequest i o = ProposeRequest
  { program          :: !(Program i o),
    targetNode       :: !Int,                  -- foldParams index of the node to propose for
    currentInstruction :: !Text,               -- the node's instruction now (always retained)
    history          :: ![PastInstruction],    -- prior attempts + scores for this node
    bootstrappedDemos :: ![Text],              -- rendered demos for this node (may be empty)
    numCandidates    :: !Int,                  -- how many fresh candidates to ask for (N)
    tipIndex         :: !Int,                   -- selects a tip deterministically (mod tipBank)
    viewBatch        :: !Int                    -- dataset rows to sample for the summary
  }

newtype ProposeResult = ProposeResult { rankedCandidates :: [Text] }
  deriving stock (Eq, Show, Generic)

proposeInstructions ::
  (ToJSON i, ToJSON o, LLM :> es, Error ShikumiError :> es) =>
  Dataset i o ->
  ProposeRequest i o ->
  Eff es ProposeResult
```

`proposeInstructions ds req` runs, in order:

  1. `summary <- datasetSummary (viewBatch req) ds` (M2). (Computed once; a future caching
     enhancement is noted but not required.)
  2. `let code = renderProgramPseudo (program req)` (M1).
  3. `desc <- programDescription` via `programDescriber` on `code` + a rendered sample row.
  4. Build `sigStr = moduleSignature` from `programFieldNames (program req) !! targetNode req`.
  5. `modDesc <- moduleDescriber` on `code`, `desc`, `sigStr`.
  6. For each of `numCandidates req` candidates, run `instructionGenerator` with
     `GenerateInstructionIn` assembled from the signals, varying `tip = tipAt (tipIndex req +
     j)` per candidate `j` so the N candidates explore different stylistic tips (this is how we
     get *distinct* candidates deterministically under the stub, mirroring DSPy's per-round tip
     variation).
  7. Collect the proposed strings, prepend `currentInstruction req`, and **deduplicate while
     preserving order** (so the current instruction is always present and first, and the list
     stays distinct). Return `ProposeResult` with that list.

The safety property — current instruction always a candidate — is realized in step 7 by
construction, exactly as V1 guaranteed it.

**Re-pointing `instructionSearch`.** Rewrite the proposer call inside
`shikumi-optimize/src/Shikumi/Optimize/Instruction.hs`'s `instructionSearch` to call
`proposeInstructions` once per node (asking for `proposalsPerNode` candidates) instead of
looping `runProgram proposeInstruction` over `variant:N` markers. The greedy coordinate-ascent
loop, the budget accounting, and the "current instruction always scored" behavior are
unchanged — only the *source* of candidate strings changes (now grounded). Because
`proposeInstructions` already prepends the current instruction, the search's existing
`curInstr : proposed` step is replaced by simply scoring `rankedCandidates`. The threaded
LM-call count now also accounts for the summarizer/describer calls the proposer makes; keep the
budget check conservative (count each sub-program call) so `maxLmCalls` is still never exceeded
— this preserves the existing `InstructionSpec` "respects the LM-call budget" test.

Retain V1's `ProposeIn`/`ProposeOut`/`proposeInstruction` only if some external caller still
imports them; otherwise remove them and update the module's export list and haddock. Record the
choice in the Decision Log. The `StubLM` proposer-recognition logic (system prompt mentions
`proposedInstruction`) keeps working because `GenerateInstructionOut` also has a
`proposedInstruction` output field.

**The MIPROv2-shaped caller (the contract demonstration).** Add a tiny documented driver in
the test suite (not the library) that exercises the surface the way MIPROv2 will:

```haskell
-- A stand-in for MIPROv2's proposal stage: for each node, ask the grounded proposer
-- for N candidates, threading a (here empty) history. Proves the contract is usable.
miproShapedPropose ::
  (ToJSON i, ToJSON o, LLM :> es, Error ShikumiError :> es) =>
  Dataset i o -> Program i o -> Int -> Eff es [[Text]]
miproShapedPropose ds prog n =
  forM [0 .. length (foldParams prog) - 1] $ \k ->
    rankedCandidates <$> proposeInstructions ds
      (ProposeRequest prog k (currentInstrAt k prog) [] [] n 0 2)
```

This caller compiles against `proposeInstructions` exactly as EP-20 will, demonstrating the
shared contract before EP-20 exists.

**Commands / acceptance.**

```bash
nix develop .#ghc9124 --command cabal test shikumi-optimize --test-options='-p Propose.M3'
nix develop .#ghc9124 --command cabal test shikumi-optimize
```

Acceptance: the `Propose.M3` group passes, demonstrating (a) `proposeInstructions` for the
fixture program/dataset returns `numCandidates + 1` (or fewer after dedup) **distinct**
candidates; (b) the current instruction is among them; (c) the stub-captured system prompt for
the final `instructionGenerator` call contains the dataset summary text, the node's field
names (via the module signature), and the selected tip; (d) `miproShapedPropose` returns one
candidate list per node without a type error (the contract compiles and runs). The full
`shikumi-optimize` suite — including the unchanged `InstructionSpec`, `BootstrapSpec`,
`AcceptanceSpec`, etc. — stays green, proving the re-point did not regress the optimizer.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi` inside the
pinned toolchain. Enter it once:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124
```

Inside that shell, the build/test commands are:

```bash
cabal build shikumi-optimize
cabal test shikumi-optimize
cabal test all
```

Formatting uses fourmolu with two-space indentation; format every file you touch:

```bash
fourmolu -i \
  shikumi-optimize/src/Shikumi/Optimize/Propose.hs \
  shikumi-optimize/src/Shikumi/Optimize/Propose/Types.hs \
  shikumi-optimize/src/Shikumi/Optimize/Propose/Summarize.hs \
  shikumi-optimize/src/Shikumi/Optimize/Propose/Tips.hs \
  shikumi-optimize/src/Shikumi/Optimize/Propose/Grounded.hs \
  shikumi-optimize/src/Shikumi/Optimize/Instruction.hs \
  shikumi-optimize/test/ProposeSpec.hs \
  shikumi-optimize/test/StubLM.hs \
  shikumi-optimize/test/Main.hs
```

### Step-by-step

1. **M1 module skeletons.** Create the five `Propose` modules listed above with their cabal
   registration (add them to `exposed-modules` in
   `shikumi-optimize/shikumi-optimize.cabal`; add `bytestring` to the library `build-depends`
   if `Data.Aeson.encode`'s `ByteString` result needs decoding to `Text` — prefer
   `Data.Aeson.Text.encodeToLazyText` to avoid the extra dep). Implement `NodeFieldNames`,
   `programFieldNames` (preferred EP-16 path or fallback), `renderProgramPseudo`, and
   `programDescriber`.

2. **M1 test.** Create `shikumi-optimize/test/ProposeSpec.hs` exporting `tests :: TestTree`,
   and register it in `shikumi-optimize/test/Main.hs`'s test tree and in the cabal
   `other-modules`. Add the `Propose.M1` group. Extend `StubLM.hs` so (i) the stub recognizes
   the new sub-program requests (program-describe / dataset-describe / module-describe — each
   by a distinctive output-field name in the system prompt: `programDescription`,
   `observations`, `summary`, `moduleDescription`) and returns canned text for each, and (ii)
   it records the last-seen system prompt into a test-readable `IORef` via a new
   `runStubLMCapturing :: IORef Text -> Eff (LLM : es) a -> Eff es a` interpreter.

3. **M2.** Implement `datasetDescriber`, `observationSummarizer`, `datasetSummary`, the
   `tipBank`/`tipAt`, and `renderHistory`. Add the `Propose.M2` test group.

4. **M3.** Implement `moduleDescriber`, `instructionGenerator`, `ProposeRequest`,
   `ProposeResult`, and `proposeInstructions`. Re-point `instructionSearch` in
   `Instruction.hs`. Add the `Propose.M3` group and the `miproShapedPropose` caller.

5. **Format, build, test.** Run the fourmolu command above, then `cabal build
   shikumi-optimize` and `cabal test all`. Update this plan's Progress, Surprises, and
   Decision Log. Commit with the trailers.

Expected final test transcript (abridged):

```text
shikumi-optimize
  M1 labeledFewShot: OK
  M2 bootstrapFewShot: OK
  M3 instructionSearch: OK
  M4 ensembleSearch: OK
  optimize façade: OK
  acceptance: OK
  Propose.M1: OK
  Propose.M2: OK
  Propose.M3: OK

All N tests passed
```


## Validation and Acceptance

The headline acceptance is observable and hermetic (no network, no API keys). Build the
fixture program and dataset from `StubLM` (`sentimentProg`, a single `predict` node over
`Sentence -> Label`, and a two-row `trainset` with `good film -> positive` /
`bad film -> negative`). Then:

  * **Grounded candidates.** `proposeInstructions trainset (ProposeRequest sentimentProg 0
    currentInstr history demos N tipIdx viewBatch)` returns a `ProposeResult` whose
    `rankedCandidates` are **distinct** and number `N + 1` before dedup (the N proposals plus
    the retained current instruction), `currentInstr` included. Assert distinctness and
    membership of `currentInstr`.

  * **Signals reached the model.** Using the capturing stub (`runStubLMCapturing`), read the
    `IORef` holding the system prompt the final `instructionGenerator` call received, and
    assert it contains: the dataset-summary text the stub returned for the summarizer; the
    node's field name(s) (e.g. `text` for the input, `sentiment` for the output — under EP-16;
    at least `sentiment` under the fallback) via the rendered `moduleSignature`; and the
    selected tip string `tipAt tipIdx`. This proves the proposer is genuinely *grounded*, not
    blind.

  * **The contract compiles against a MIPROv2-shaped caller.** `miproShapedPropose trainset
    sentimentProg 3` type-checks and runs, returning a list of one candidate list (one node),
    proving EP-20/EP-21 can call the surface as specified.

  * **No regression.** The pre-existing `shikumi-optimize` suite — `InstructionSpec`,
    `BootstrapSpec`, `LabeledFewShotSpec`, `EnsembleSpec`, `OptimizeSpec`, `AcceptanceSpec` —
    stays green after `instructionSearch` is re-pointed. In particular `InstructionSpec`'s
    "selects the best proposed instruction" still picks the `RULE`-bearing instruction and
    "respects the LM-call budget" still bounds calls by `maxLmCalls`.

Run the whole suite to confirm nothing regressed:

```bash
cd /Users/shinzui/Keikaku/bokuno/shikumi
nix develop .#ghc9124 --command cabal test shikumi-optimize
nix develop .#ghc9124 --command cabal test all
```

Success is every group reporting `OK`, including the new `Propose.*` groups and the unchanged
optimizer groups.


## Idempotence and Recovery

Every step is additive and safe to repeat; re-running `cabal build`/`cabal test` is
idempotent. The new code is in new modules under `Shikumi.Optimize.Propose`, so the only
edit to an existing library file is re-pointing `instructionSearch` in `Instruction.hs`; if
that edit is partially applied and fails to compile, the recovery is to restore the original
`genProposals`/`runProgram proposeInstruction` loop (preserved in git) and re-apply the
re-point in one piece. If EP-16 has *not* landed, `programFieldNames` uses the in-package
`programShape` fallback and the suite still passes (with input-field names absent and the
summary honestly saying so); when EP-16 lands, swap the one-line definition to
`map convert . nodeFieldsIndexed` — a purely additive upgrade that strengthens the proposal
prompt without changing any signature. If a stub-capture test asserts on a substring that
fourmolu reflows in the signature instruction, assert on a stable fragment (e.g. `good film`,
`sentiment`, the tip text) rather than the whole prompt.


## Interfaces and Dependencies

Libraries/modules used and why:

  * `effectful` — the effect system. The proposer and its sub-programs run in the `LLM`/`Error
    ShikumiError` row, exactly like `runProgram` (dossier A.4); no new effect is introduced.
  * `shikumi` (`Shikumi.Program`, `Shikumi.Module`, `Shikumi.Signature`, `Shikumi.Schema`,
    `Shikumi.Adapter`) — for `Program`, `predict`, `mkSignature`, the schema/prompt
    typeclasses, `foldParams`/`mapParamsAt`, `programShape`/`sigLabel`, and (when present)
    `nodeFieldsIndexed`/`NodeFields`.
  * `shikumi-eval` (`Shikumi.Eval`) — for `Dataset`, `datasetExamples`, `Example`.
  * `aeson` — `ToJSON` rendering of dataset rows and demos for the summary/demo signals
    (`Data.Aeson.Text.encodeToLazyText`), matching the `ToJSON i`/`ToJSON o` constraints the
    other optimizers already require (dossier E.6).
  * `text`, `containers` — already present; ordinary text assembly and dedup.

Signatures that must exist at the end of each milestone (full module paths):

End of **M1** (`Shikumi.Optimize.Propose.Types`, `Shikumi.Optimize.Propose.Summarize`):

```haskell
-- Shikumi.Optimize.Propose.Types
data NodeFieldNames = NodeFieldNames { inputFieldNames :: ![Text], outputFieldNames :: ![Text] }
programFieldNames :: Program i o -> [NodeFieldNames]

-- Shikumi.Optimize.Propose.Summarize
renderProgramPseudo :: Program i o -> Text
data ProgramDescribeIn  = ProgramDescribeIn  { programCode :: Text, programExample :: Text }
newtype ProgramDescribeOut = ProgramDescribeOut { programDescription :: Text }
programDescriber :: Program ProgramDescribeIn ProgramDescribeOut
```

End of **M2** (`Shikumi.Optimize.Propose.Summarize`, `Shikumi.Optimize.Propose.Tips`,
`Shikumi.Optimize.Propose.Types`):

```haskell
datasetDescriber      :: Program DatasetDescribeIn DatasetDescribeOut
observationSummarizer :: Program SummarizeIn SummarizeOut
datasetSummary ::
  (ToJSON i, ToJSON o, LLM :> es, Error ShikumiError :> es) => Int -> Dataset i o -> Eff es Text

tipBank :: [Text]
tipAt   :: Int -> Text

data PastInstruction = PastInstruction { pastInstruction :: !Text, pastScore :: !Double }
renderHistory :: Int -> [PastInstruction] -> Text
```

End of **M3** (`Shikumi.Optimize.Propose.Grounded`, `Shikumi.Optimize.Propose.Types`,
re-exported from `Shikumi.Optimize.Propose`):

```haskell
data ModuleDescribeIn = ModuleDescribeIn
  { programCode :: Text, programDescription :: Text, moduleSignature :: Text }
newtype ModuleDescribeOut = ModuleDescribeOut { moduleDescription :: Text }
moduleDescriber :: Program ModuleDescribeIn ModuleDescribeOut

data GenerateInstructionIn = GenerateInstructionIn
  { datasetDescription :: Text, programCode :: Text, programDescription :: Text
  , moduleSignature :: Text, moduleDescription :: Text, taskDemos :: Text
  , previousInstructions :: Text, basicInstruction :: Text, tip :: Text }
newtype GenerateInstructionOut = GenerateInstructionOut { proposedInstruction :: Text }
instructionGenerator :: Program GenerateInstructionIn GenerateInstructionOut

data ProposeRequest i o = ProposeRequest
  { program :: !(Program i o), targetNode :: !Int, currentInstruction :: !Text
  , history :: ![PastInstruction], bootstrappedDemos :: ![Text]
  , numCandidates :: !Int, tipIndex :: !Int, viewBatch :: !Int }
newtype ProposeResult = ProposeResult { rankedCandidates :: [Text] }

proposeInstructions ::
  (ToJSON i, ToJSON o, LLM :> es, Error ShikumiError :> es) =>
  Dataset i o -> ProposeRequest i o -> Eff es ProposeResult
```

**Downstream contract summary** for the consuming plans (all under
`/Users/shinzui/Keikaku/bokuno/shikumi/docs/plans/`):

  * `20-miprov2-optimizer.md` calls `proposeInstructions ds (ProposeRequest prog k cur hist
    demos n tipIdx vb)` once per node `k` during its proposal stage, threading per-node
    instruction `history` (with minibatch scores) and per-node `bootstrappedDemos` recovered
    via EP-16's node-correlated traces. It scores the returned `rankedCandidates` with its own
    minibatch/Bayesian search.
  * `21-copro-instruction-optimizer.md` calls the same surface in its coordinate-ascent loop,
    threading the running breadth/depth history; it relies on the retained-current-instruction
    guarantee so a depth step never regresses a node.
  * `22-gepa-reflective-optimizer.md` may reuse `renderProgramPseudo`/`datasetSummary`/
    `programDescriber` as reflection context, and consumes the same `programFieldNames`
    accessor.

**Per-node field metadata contract (integration point #3).** This plan exposes field metadata
as `programFieldNames :: Program i o -> [NodeFieldNames]`, one entry per `Predict` node in
`foldParams`/`mapParamsAt` order, where `NodeFieldNames` carries the input- and output-field
*names* as `[Text]` (never a typed `Signature`, because a `Predict` node hides its `i`/`o`
existentially). When EP-16 is present this delegates to its `nodeFieldsIndexed`; otherwise it
falls back to `programShape`-derived output names. EP-20/EP-21/EP-22 consume *this* accessor
(or the field names already embedded in `ProposeRequest`'s `moduleSignature`), not a
`Signature` accessor.

Build/test facts: all builds and tests run inside `nix develop .#ghc9124` (GHC 9.12.4);
`cabal test shikumi-optimize` runs this package's suite and `cabal test all` runs the
workspace; formatting is fourmolu with two-space indentation; tests are hermetic via the stub
`LLM` interpreters in `shikumi-optimize/test/StubLM.hs` (extended here with
`runStubLMCapturing`). Commits carry `MasterPlan:`, `ExecPlan:`, and `Intention:` trailers
(intention `intention_01ktq80q01emxtjfxzd3rw4tjs`).
