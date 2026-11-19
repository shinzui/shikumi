---
id: 70
slug: add-production-evidence-optimization-and-promotion-reports
title: "Add production-evidence optimization and promotion reports"
kind: exec-plan
created_at: 2026-11-05T04:41:53Z
intention: "intention_01m6n06mfhemm85w9ryva6e3f9"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-11-05T04:41:53Z
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-18T23:47:34Z
      mode: "update"
      note: "Pre-implementation review: ordered-outcome recordings, recorded typed errors, deterministic timeouts, raw-value digests, corrected orientation and interfaces"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-19T00:01:48Z
      mode: "implement"
      note: "Implemented milestones and recorded progress"
---

# Add production-evidence optimization and promotion reports

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Shikumi can already improve a typed language-model program: an optimizer takes a training
dataset, a metric, a starting program and a budget, and returns a better-parameterized
program. What it cannot do is prove, to someone who was not there, where the examples came
from, which of them the optimizer was allowed to see, which exact baseline and candidate
were compared, and whether the candidate got better without becoming unsafe, slower or more
expensive. Without that proof each agent would invent its own trace-to-dataset pipeline and
"self-improvement" would be an optimizer demo rather than an auditable capability.

After this change a trusted job can hand Shikumi a sealed dataset of production evidence, a
baseline program, an optimizer with a budget, and a declared metric policy, and receive two
portable JSON artifacts: a candidate program and a baseline-versus-candidate comparison
report whose conclusion is exactly one of `Improved`, `Regressed`, `Inconclusive` or
`Invalid`. Every artifact carries a content digest, so a lifecycle owner in another
repository (Shikigami) can verify that a report is about precisely this baseline, this
candidate, this dataset and this policy before asking a human to approve anything. Shikumi
decides the comparison only. It never activates a candidate and never receives a credential
that could.

You can see it working in two ways. The test suite of the new `shikumi-evidence` package
proves the twelve behaviors the request demands. The runnable example `jitsurei-evidence`
reads a checked-in fixture dataset and checked-in recorded provider responses, optimizes a
baseline, writes `candidate.json` and `report.json`, and prints `Improved` for a good
candidate and `Regressed` for a deliberately costly one, without any network access or API
key.

This plan implements
[IR-2](../improvement-requests/production-evidence-optimization.md), which is required by
the governed self-improvement use case `mori://shinzui/kikan/okf/use-cases/concepts/UC-7`.


## Progress

- [x] M1 (2026-11-18): The `shikumi-evidence` package builds, and sealed dataset envelopes
  can be built from adapter records, validated, digest-checked and opened into typed
  training and validation splits. Accepted when the dataset-digest, split-leakage and
  label-kind test groups pass (required tests 1 and 2, and the label half of 11). Evidence:
  `cabal test shikumi-evidence` passes the `dataset-digest` (5), `split-leakage` (4) and
  `labels` (4) groups.
- [x] M2 (2026-11-18): Program artifacts, metric policies, the pure conclusion function,
  comparison reports and report-binding verification exist as values. Accepted when the
  artifact, conclusion and binding test groups pass (required tests 4, 6, 7 and 10 at the
  value level). Evidence: the `artifact` (5), `conclusion` (6) and `binding` (4) groups
  pass; all 28 tests of the suite pass.
- [x] M3 (2026-11-18): GEPA accepts critiques keyed by a stable example id that keep their
  human, model or inferred provenance. Accepted when the new stored-critique tests pass and
  the existing `shikumi-optimize` suite still passes (the critique half of required test
  11). Evidence: `cabal test shikumi-optimize` reports all 144 tests passed, including the
  three stored-critique cases in `FeedbackSpec`.
- [x] M4 (2026-11-18): `runEvidenceJob` optimizes and then compares on the protected
  holdout under recorded or replayed provider responses. Accepted when the isolation,
  same-protocol, budget and replay test groups pass (required tests 3, 5, 8 and 9, and the
  driver-level halves of 4 and 7). Evidence: all 40 tests of `cabal test shikumi-evidence`
  pass, including `holdout-isolation`, `comparison`, `budget` (optimization predicted and
  admitted 17 with status `BudgetStopped`, comparison 16), `replay` and `driver-gates`.
- [ ] M5: The UC-7 fixture, its golden artifacts and the `jitsurei-evidence` command show an
  `Improved` candidate and a `Regressed` costly candidate from checked-in replay data.
  Accepted when required test 12 passes and the command prints the transcript in Concrete
  Steps.
- [ ] M6: User guide, capability record, ADR, registry metadata, CI example list and
  changelogs describe the shipped behavior, and every repository gate passes.
- [ ] M7: With the operator's explicit authorization at that time, the affected packages are
  released and IR-2 is marked completed.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Put the envelopes and the driver in a new published package, `shikumi-evidence`,
  instead of adding modules to `shikumi-optimize`.
  Rationale: The request says the work "adds provenance-bearing operational envelopes and a
  composed driver around" the existing abstractions and must not turn the optimizer core
  into a production-facing protocol. A separate package keeps hashing, timestamps and
  artifact formats out of the optimizer's build plan and lets the envelopes version
  independently. Only the critique generalization touches `shikumi-optimize`.
  Date: 2026-11-04

- Decision: An artifact's content digest is BLAKE3 over the canonical JSON of the whole
  envelope with its `contentDigest` field removed, reusing
  `Shikumi.Cache.Key.canonicalJSON`.
  Rationale: One rule for all four envelopes is easy to verify by hand and cannot drift
  from a hand-maintained "covered fields" list. The canonical serializer and the hash are
  the ones the cache key and replay already depend on, so no second canonicalization
  exists.
  Date: 2026-11-04

- Decision: Sealed artifacts contain only content that is identical in a live run and in
  its replay. Whether a job ran live or replayed is reported in an unsealed job summary,
  not inside an artifact.
  Rationale: The request requires a replay to reproduce artifact and report digests so an
  auditor can compare by equality. A digested `mode` field would make that impossible.
  Date: 2026-11-04

- Decision: The driver installs the record/replay boundary itself, below the caller's
  routing and request-default wrappers, hands programs the JSON round-tripped form of every
  live response, records the optimization phase and the comparison phase separately, and
  requires sequential execution.
  Rationale: Keys must include the real model route, which exists only after routing.
  Stored responses lose a little precision on non-terminating costs, so a live run must
  compute from the same bytes a replay will see. Separate phase recordings let the
  candidate bind only what produced it. Concurrent identical requests could receive
  different live answers, which a replay could not reproduce. The decisions of 2026-11-18
  below fix what a recording stores and which calls it refuses.
  Date: 2026-11-04

- Decision: Cost and latency measures come from the recorded responses (provider-reported
  usage cost and `latencyMs`), never from the wall clock.
  Rationale: Wall-clock latency differs on every run and would break digest
  reproducibility. The recorded values are the nondeterministic inputs the request says
  must be captured.
  Date: 2026-11-04

- Decision: The protected comparison runs both programs through
  `Shikumi.Optimize.Execution.evaluateCandidate` inside one two-candidate search session.
  Rationale: The request forbids a second evaluator loop. That function already provides
  hard operation admission, per-example usage, typed failure boundaries and a per-example
  callback, and it is built on `shikumi-eval`'s `scoreExecution`.
  Date: 2026-11-04

- Decision: Conclusions are decided in the fixed order `Invalid`, then `Regressed`, then
  `Inconclusive`, then `Improved`. A sealed holdout that is contaminated, empty, or below
  the dataset's own declared minimum is `Invalid`; a comparison that ran but did not meet
  the metric policy's evidence thresholds is `Inconclusive`.
  Rationale: The request says both that an insufficient holdout is `Invalid` and that a
  candidate lacking enough evidence is `Inconclusive`. Splitting the two thresholds between
  the dataset's split policy and the metric policy satisfies both sentences without
  overlap, and the ordering guarantees no failing case can reach `Improved`.
  Date: 2026-11-04

- Decision: The holdout exposure count is input data to the driver, supplied by the trusted
  caller, with a small ledger helper for the example and tests. A replay of an earlier job
  passes the original count and consumes nothing.
  Rationale: Shikumi is a library with no durable store and must not gain one. Making the
  count an input keeps the report reproducible and leaves the durable counter with the
  lifecycle owner.
  Date: 2026-11-04

- Decision: Extend `Shikumi.Optimize.Feedback.Provenance` with `Human` and `Inferred`, and
  admit at most one program-scoped stored critique per example.
  Rationale: Label kinds must stay distinguishable all the way into the reflection prompt,
  which renders the provenance value. Adding constructors is a breaking change, accepted as
  a major version of `shikumi-optimize`. The existing feedback result has one program
  critique slot, and merging several would blur their provenance.
  Date: 2026-11-04

- Decision: Promotion-gate measures are pure functions of the typed output and execution
  evidence. Language-model judges cannot be gates in this release.
  Rationale: The request says free-form natural-language metrics cannot silently become
  promotion gates. A pure, declared, hashed measure is reproducible by construction; a
  judge would add its own model calls to the cost and latency being measured.
  Date: 2026-11-04

- Decision: Dataset examples may be unlabeled. They are stored, counted as missing labels,
  and never executed.
  Rationale: The report must state missing-label counts and enforce a maximum missing-data
  rate, which is only meaningful if the sealed dataset can contain selected-but-unlabeled
  records.
  Date: 2026-11-04

- Decision: The `jitsurei-evidence` example defines its own copy of the fixture program
  template instead of sharing a module with the test suite.
  Rationale: The example then acts as an independent consumer. If its prompts drift from
  the recorded ones, replay fails loudly, and CI runs every example.
  Date: 2026-11-04

- Decision: Publishing to Hackage and marking IR-2 completed are a separate, explicitly
  authorized final milestone.
  Rationale: A release is outward-facing and cannot be undone. Earlier completed requests in
  this repository cite the release that delivered them, so the status changes only then.
  Date: 2026-11-04

- Decision: A recording keeps, for each request key, the ordered list of outcomes in the
  order the calls were issued. It does not memoize one answer per key. In a live run every
  call reaches the provider; in a replay the nth request for a key receives the nth
  recorded outcome, and a missing outcome or an outcome left unconsumed at the end of a
  phase is a divergence. This refines the record/replay decision of 2026-11-04.
  Rationale: `Retry` re-issues the identical request (`retryWith` in
  `shikumi/src/Shikumi/Program.hs`), and so does sampling at one temperature. A memoizing
  boundary would hand every retry the same failing answer, so a template that recovers in
  production would be measured as failing. It would also count cost for calls that were
  never made and let the candidate arm reuse the baseline arm's answers for an unchanged
  node. Evidence jobs execute sequentially (`runProgramObserved` walks a program without
  concurrency, and `evaluationConcurrency` must be one), so issue order is deterministic.
  An optimizer specification that issues identical requests from concurrent threads is
  outside the reproducibility guarantee.
  Date: 2026-11-18

- Decision: A recorded outcome is either a response or one of the typed errors the
  comparison counts as an example failure. Calls that cannot be recorded faithfully (a
  streamed call, or a call whose options request provider evidence) raise a dedicated
  exception that is not a `ShikumiError`.
  Rationale: The provider interpreter raises `InvalidJSON`, `SchemaMismatch`,
  `ContextWindowExceeded` and `Timeout` itself (`fromBaikaiError` in
  `shikumi/src/Shikumi/Error.hs`). If only responses were stored, a live run that counted
  such a failure could not be replayed. A stored response drops the provider evidence
  record, so a program that derives answers from evidence would decode differently from a
  recording. Raising `ValidationFailure` for these cases would be wrong, because both GEPA
  and the comparison score a `ValidationFailure` as an ordinary failed example, which would
  hide a configuration error as a zero score.
  Date: 2026-11-18

- Decision: The policy's `exampleTimeoutMs` is applied to the summed recorded `latencyMs`
  of an example's responses. The driver never races an example against the wall clock.
  Rationale: A wall-clock timeout fires in a live run and never in its replay, where
  answers are instant, so the two would produce different reports. Bounding real elapsed
  time is the job of the sealed environment that runs the driver.
  Date: 2026-11-18

- Decision: Route identity is read from requests at the record/replay boundary, and the
  same-route gate compares the requested routes of the two arms.
  Rationale: ADR-13 states that a response's `model` field is the echoed request model and
  that observed model identity comes only from provider evidence, which evidence jobs do
  not record. A gate on the response field would test nothing.
  Date: 2026-11-18

- Decision: A digest is verified on the JSON value exactly as it was read, and decoding an
  envelope fails unless re-encoding the typed value yields that same JSON value.
  Rationale: Verifying a digest after decoding and re-encoding would silently drop unknown
  fields, so a tampered envelope with extra content could pass. The exact round trip also
  fixes one representation for optional fields.
  Date: 2026-11-18

- Decision: A candidate whose compiled state equals the baseline's is reported
  `Inconclusive` without running the comparison or consuming a holdout exposure.
  Rationale: `optimizeWith` returns the unchanged starting program when a run stops before
  any child is accepted. Comparing a program with itself on independent live calls can only
  measure noise, and spending an exposure on it brings the holdout closer to exhaustion for
  nothing.
  Date: 2026-11-18

- Decision: The exposure ledger is a pure value with JSON instances; the package contains
  no file access. Evidence codecs are built from `FromModel` and `ToSchema`, not from
  `FromJSON`. Custom measures receive `EvaluationEvidence`, not `ExampleMeasurement`.
  Rationale: The first keeps the 2026-11-04 exposure decision honest: the library gains no
  store, and the caller persists the ledger. `FromModel` is the decoder a program already
  uses for its own types, so the dataset cannot decode a value differently from the
  program. `ExampleMeasurement` carries `latencySeconds`, a wall-clock reading that would
  make a custom measure differ between a run and its replay.
  Date: 2026-11-18

- Decision: The package enables `NoFieldSelectors`, and envelopes that share fields with
  their builder input nest it: an `EvidenceExample` holds its `EvidenceRecord` and split, an
  `EvidenceDataset` holds its `DatasetSpec`, a `ProgramArtifact` holds its `ArtifactSpec`
  as `identity`. Their JSON stays flat, and read-only `HasField` instances keep
  `example.exampleId`, `dataset.splitPolicy` and `artifact.artifactId` working. Each
  envelope kind has its own reseal function (`resealDataset`, `resealArtifact`,
  `sealRecording`, `sealReport`). The redaction policy's id field is `redactionId`, and the
  primary comparison's thresholds are `requiredImprovement` and `allowedRegression`.
  Rationale: The plan's field names (`sources`, `codec`, `policy`, `dataset`, `createdAt`)
  collide with consumers' own names and with each other. GHC 9.12 rejects an ambiguous
  record update outright, so with plain fields a consumer could not write
  `spec {splitPolicy = ...}` or `record {critiques = ...}` once the package was imported.
  The field names in the JSON format are unchanged.
  Date: 2026-11-18

- Decision: The policy digest function is `digestPolicy` and the evaluator digest function
  is `digestEvaluator`, because `policyDigest` and `evaluatorDigest` are field names of
  `ReportBindings`.
  Rationale: A field and a function of the same name cannot both be used unqualified.
  Date: 2026-11-18

- Decision: In replay mode the driver recomputes each recording's digest from its content
  instead of trusting the stored field, and `readRecordingForReplay` reads a recording with
  every check of `decodeRecording` except the stored digest.
  Rationale: The acceptance check requires that deleting an entry from a copy of a recording
  makes the example fail with a replay divergence rather than a digest error. A replay
  establishes a recording's integrity itself: a missing or surplus outcome diverges, and any
  other edit changes the recording digest that the candidate and report bind, so their
  digests stop matching the checked-in ones.
  Date: 2026-11-18

- Decision: A stored critique that names a node the template does not have makes the job
  `Invalid` before any model call.
  Rationale: `storedCritiqueFeedback` drops critiques whose node did not execute in one run,
  which is right for a failing rerun, but a node absent from the template means the dataset
  was built for a different program structure. Found when the retry-template replay test
  reused the fixture's `root` critiques on a template whose only node is `retry`.
  Date: 2026-11-18


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The repository and how to build it

Shikumi is a Haskell framework for typed language-model programs. The repository root holds
one directory per package, listed in `cabal.project`. All commands in this plan run from the
repository root inside the Nix development shell, because the correct compiler (GHC 9.12.4)
exists only there; the system `ghc` is the wrong version. Prefix commands with
`nix develop -c`, or enter the shell once with `nix develop`. `cabal build all` builds
everything, `cabal test all` runs every suite, `nix fmt` formats, and the `justfile` holds
`just check-haddock` and `just check-adr`.

### What exists today

A **program** is a value of type `Program i o` (`shikumi/src/Shikumi/Program.hs`): a typed
pipeline from an input `i` to an output `o` whose leaves are language-model calls. Each leaf
carries tunable **parameters** (`Params`: an optional instruction override, few-shot
demonstrations and decision settings). `programShape` returns a `ProgramShape`, a
closure-free description of the pipeline's structure. This plan calls a digest of that shape
the **structural fingerprint**.

The **evaluation** package (`shikumi-eval/src/Shikumi/Eval/`) owns `Dataset i o` (a list of
`Example {input, expected}`), `Metric o` (a pure function from the expected output and a
prediction to a `Score` in `[0, 1]`), `withUsageTotals` (sums provider-reported tokens and
cost of every call in a scope into `UsageTotals`, whose `totalCostUsd` is an exact
`Rational`), and `scoreExecution` (the shared typed-error boundary).

The **compile** package (`shikumi-compile/src/Shikumi/Compile/Serialize.hs`) owns
`CompiledProgram i o` and its persistence. `encodeCompiled` writes a JSON object holding the
shape and the ordered parameter vector. `decodeCompiledOnto template bytes` re-applies saved
parameters to a program held as code and fails when the saved shape differs from the
template's.

The **optimize** package (`shikumi-optimize/src/Shikumi/Optimize/`) owns the search. The
entry point this plan uses is in `Shikumi/Optimize.hs`:

```haskell
optimizeWith ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  RunConfig -> ConfiguredOptimizer i o -> Dataset i o -> Metric o -> Program i o ->
  Eff es (CompiledProgram i o, OptimizationReport)
```

`RunConfig` wraps `RunLimits {operationLimit, candidateLimit, evaluationConcurrency,
deterministicSeed}` (`Execution.hs`), which is the **budget**: a hard ceiling on admitted
language-model operations and on candidates. The returned `OptimizationReport`
(`Report.hs`) records `predictedWork` (the optimizer's own forecast of operations) and
`admittedOperations` (what was actually dispatched). `Execution.hs` also exports
`runSearchSession`, `reserveCandidate` and `evaluateCandidate`, which run one program over
a dataset sequentially with per-example usage and a per-example callback
(`ObjectiveMetric es o = o -> ExampleMeasurement o -> Eff es ObjectiveValues`).
`Shikumi.Optimize` re-exports the strategy modules but not `Shikumi.Optimize.Execution`,
`Shikumi.Optimize.Feedback` or `Shikumi.Optimize.Report`; import those three directly, as
`shikumi-jitsurei/app/GepaObjectives.hs` does. `evaluateCandidate` has no timeout, returns
a `CandidateReport` with status `CandidateIncomplete` instead of throwing when the
operation limit is reached, and still calls the per-example callback for the example that
was denied, so a caller that collects rows in the callback must discard them unless the
status is `CandidateCompleted`. Its `ExampleMeasurement` carries `latencySeconds`, a
wall-clock reading this plan never uses.

**GEPA** (`GEPA.hs`) is the reflective optimizer: it runs a parent program on training
examples, collects textual **critiques** of what went wrong, asks a **reflective proposer**
(itself a small program) to rewrite one node's instruction, and keeps children that score
well. `gepaWith :: GEPAConfig i o -> Program ReflectIn ReflectOut -> ConfiguredOptimizer i o`
already separates the roles this plan needs: it reflects only on a prefix of the training
set (`minibatchSize`) and scores candidates on `validationDataset` when one is supplied.
Critiques reach it through `feedbackCallback`, a function from the expected output and an
`EvaluationEvidence` (the example's position, typed result, node observations and usage) to
a `FeedbackResult` (`Feedback.hs`). A critique names its producer with
`data Provenance = Caller | Model | LegacyProgram`, and `validateFeedback` rejects a node
critique whose target node did not execute in that example. Three details of `gepaWith`
matter here. The feedback callback is only ever run over the minibatch, which is a prefix
of the training set, so an example's index in the callback equals its position in the
training set. A program-scoped critique is rendered, and makes a node eligible for
reflection, only when `includeProgramCritique` is set in `FeedbackConfig`; it defaults to
off. And the search loop ends only when the session halts or the candidate limit is
reached, at which point it sets the run status to `BudgetStopped`, so a successful GEPA
run normally reports `BudgetStopped`, not `Completed`.

**Replay** already exists at the language-model boundary. `Shikumi.Cache.Key`
(`shikumi-cache/src/Shikumi/Cache/Key.hs`) computes `cacheKey`, a BLAKE3 digest of the
canonical JSON of a request, and exports `canonicalJSON` (sorted keys, no insignificant
whitespace). `Shikumi.Cache.ResponseJSON` provides JSON instances for the provider
`Response`; they omit the per-call evidence record, and a cost that is a non-terminating
decimal does not round-trip exactly. `Shikumi.Trace.Replay`
(`shikumi-trace/src/Shikumi/Trace/Replay.hs`) answers calls from a `Map CacheKey Value` and
raises `ReplayDivergence` on a miss rather than calling a provider. `ReplayDivergence` is a
Haskell exception thrown with `Effectful.Exception.throwIO`, not a `ShikumiError`, so it
passes through every typed-error boundary in the optimizer and needs no `IOE`; tests catch
it with `Effectful.Exception.try`.
`shikumi-optimize/src/Shikumi/Optimize/ReAnchor/Replay.hs` shows the memoizing interposer
pattern this plan reuses: `interpose` on the `LLM` effect, look up the key, otherwise call
through and store.

A provider `Response` (from the `baikai` dependency) carries `latencyMs`, the `model` it
was dispatched to, and `message.usage` with a `cost` whose `usd` field is a `Rational`.
`runProgram` issues every call with a placeholder model; the caller's `routeLLM` wrapper
(`shikumi/src/Shikumi/Routing.hs`) rewrites it to the real model, and `withRequestDefaults`
(`shikumi/src/Shikumi/LLM/Defaults.hs`) fills default options. Both are `interpose`
wrappers, and with `interpose` the wrapper applied last to an action handles a call first.
A response's `model` field is the request's model echoed back, not what the provider
observed. The provider interpreter reports failures by throwing a `ShikumiError`
(`shikumi/src/Shikumi/Error.hs`); `fromBaikaiError` maps transport failures onto
`InvalidJSON`, `SchemaMismatch`, `ContextWindowExceeded` and `ProviderError`. Program
types decode from JSON through `Shikumi.Schema.fromModel :: Value -> Either ShikumiError a`
and describe themselves with `deriveSchema`, which returns a JSON `Value`; both classes
have generic defaults for records.

Tests are offline. The internal `shikumi-testing` package provides `runStubEval` (the
effect stack evaluation and optimization need, over a responder function that sees only
the request `Context`, not the model),
`markerResponse` (a well-formed response with 18 input tokens, 5 output tokens and 4 ms
latency), `systemContains`, and `captureLLMRequests`. `shikumi-optimize/test/StubLM.hs`
shows a stub provider whose answers improve when an instruction contains a marker, which is
how optimizer tests demonstrate real improvement.

### Terms this plan introduces

An **envelope** is a JSON object that wraps existing data with identity, provenance and a
content digest. **Sealed** means the envelope's digest has been computed and the value is
treated as immutable. A **split** is one of three disjoint parts of a dataset: **training**
examples the optimizer may inspect, **validation** examples that may only rank candidates,
and the **protected holdout**, used once for the final comparison and shown to nothing
else. A **group key** names examples that must stay together in one split because they come
from the same source event, conversation, incident or subject. An **exposure** is one use
of a holdout to judge a candidate; too many exposures let repeated proposals overfit the
holdout. A **route identity** is the provider, model id, API and base URL a call was
dispatched to. A **recording** is a set of request-key-to-response pairs captured from a
live run. A **measure** is one number per example with a stable id; a **metric** is a
declared aggregate of one measure; a **constraint** is a hard bound on a metric. The four
**conclusions** are defined in Plan of Work.

### Relevant architecture decisions

[ADR-5](../adr/0005-own-optimizer-admission-and-diagnostic-reports-in-search-sessions.md)
makes the search session the owner of admission and diagnostic reports and states that
those reports "do not authorize promotion, seal datasets, or evaluate a protected final
holdout". This plan supplies exactly those missing pieces on top of the session, without
changing its semantics.
[ADR-4](../adr/0004-separate-feedback-attribution-from-execution-evidence.md) requires
explicit node attribution, bounded and redacted reflection evidence, and says that `Caller`
and `Model` provenance do not imply human approval; the provenance extension in M3 follows
it. [ADR-8](../adr/0008-restore-typed-structures-through-trusted-recipe-registries.md)
states that experimental structure artifacts carry no promotion authority and must not
weaken the same-structure gate of this request; the gate in M4 honors that.
[ADR-12](../adr/0012-apply-request-defaults-before-cache-and-observation.md) fixes the
request order as routing, default filling, cache or trace observation, then transport; the
record/replay boundary sits where cache and trace sit.
[ADR-13](../adr/0013-separate-transport-billing-from-logical-usage.md) separates logical
usage from transport billing and requested model identity from provider-observed identity;
this plan reports logical usage and the requested route.
[ADR-2](../adr/0002-keep-capture-codecs-in-templates-and-isolate-observations.md) keeps
codecs in templates rather than artifacts, which is why the dataset codec in M1 is a value
the caller supplies. [ADR-9](../adr/0009-centralize-offline-harness-and-diverse-fixtures.md)
keeps `shikumi-testing` free of consumer packages and usable only from test suites of
published packages. No existing ADR covers evidence envelopes; M6 adds one.

### Upstream context

The request was written by the `shinzui/kikan` portfolio for the use case
`mori://shinzui/kikan/okf/use-cases/concepts/UC-7`, in which a deployed reviewer agent
improves from human-adjudicated outcomes. Shikigami owns versions, approval and rollout
(`mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-5`); Kotei runs the sealed
job. The request cites the portfolio contracts in
`mori://shinzui/kikan/docs/cross-cutting-contracts` (C1, C5, C7, C10) and two contracts
that are still proposals there. One of them defines a **RepoRef** as the pair of a
repository id and a full 40-character commit id, never a branch or tag name
(`mori://shinzui/kikan/plans/25-author-contract-c16-the-repo-content-plane-and-its-provenance-stamp`).
This plan stores RepoRefs as opaque validated data and depends on no Kikan code.


## Plan of Work

The work is seven milestones. The first two are pure values and need no language model.
The third is a small change in the optimizer. The fourth composes everything. The fifth
proves it with checked-in data. The last two finish and release.

### Milestone 1: the package and the sealed dataset

Create the package directory `shikumi-evidence/` with `shikumi-evidence.cabal`,
`CHANGELOG.md`, `src/` and `test/`, copying the `common common-options` stanza and
`default-extensions` from `shikumi-optimize/shikumi-optimize.cabal`. Version it `0.1.0.0`.
The library depends on `aeson`, `base`, `blake3`, `bytestring`, `containers`, `effectful`,
`text`, `time`, `shikumi`, `shikumi-cache`, `shikumi-compile`, `shikumi-eval`,
`shikumi-optimize` and `shikumi-trace`, with the same bound style the sibling packages
use. The test suite adds `shikumi-testing`, `tasty`, `tasty-hunit` and `tasty-golden`. Add
`shikumi-evidence` to the `packages:` list in `cabal.project`.

`Shikumi.Evidence.Digest` defines `newtype Digest = Digest Text`, rendered as `blake3:`
followed by 64 lowercase hexadecimal characters, `digestValue :: Value -> Digest` (BLAKE3
of `canonicalJSON`), and a helper that seals any envelope by encoding it to a JSON object,
deleting the `contentDigest` key, and digesting the rest. Numbers that are not finite must
be rejected on the typed value before it is encoded, because aeson encodes them as `null`
and they can no longer be told apart afterwards.

Every envelope is read through one decoding function per kind (`decodeDataset`,
`decodeArtifact`, `decodePolicy`, `decodeReport`, `decodeRecording`), each from a
`ByteString`. It parses the bytes to a JSON value, recomputes the digest over that value
with `contentDigest` removed, decodes the typed envelope, and fails unless encoding the
typed envelope again gives the same JSON value. Unknown fields and alternative spellings
of an absent optional field are therefore rejected rather than ignored. Encode an absent
optional field by omitting its key.

`Shikumi.Evidence.Dataset` defines the envelope. Its JSON fields are `artifactKind`
(always `shikumi.evidence.dataset`), `schemaVersion` (1), `datasetId`, `agent` (the logical
agent), `behaviorVersions` (the eligible behavior versions, non-empty), `inputSchemaDigest`
and `outputSchemaDigest`, `collection` (`windowStart`, `windowEnd`, `selectionQuery`,
`selectionVersion`), `splitPolicy` (`splitPolicyId`, `groupingKey` naming the grouping
dimension, `salt`, `validationPerMille`, `holdoutPerMille`, `minHoldoutExamples`,
`holdoutExposureLimit`), `redactionPolicyId`, `retentionPolicyId`, the ordered `examples`,
`createdAt`, `createdBy` and `contentDigest`. Each example has `exampleId`, `split`
(`train`, `validation` or `holdout`), `groupKey`, `input`, an optional `expected`, an
optional `label` (`kind` of `human`, `model` or `inferred`, `author`, `labeledAt`, optional
`confidence`, optional `disposition` such as `approved`, `rejected`, `corrected` or
`useful`, optional `resolutionReason`), `source` (`runRef`, optional `outcomeRef`,
`feedbackRefs`), and `critiques` (each with an optional `node` path, `text`, `kind`,
`author` and `at`).

An adapter is any function that produces `EvidenceRecord` values: the same fields as an
example without a split. `sealDataset` takes a `DatasetSpec` (every envelope field except
the examples and digest), a `RedactionPolicy` (its id plus a text rewriting function and a
predicate naming prohibited content) and the records. It applies the rewriting function to
every text leaf of inputs, expected outputs, critiques and label fields, fails if the
predicate still matches anything, assigns splits, validates, and seals. Split assignment is
deterministic and keeps groups whole. Records that share a group key, or whose canonical
inputs are identical, belong to one component, so a derived duplicate cannot land in a
different split from its original. Components are ordered by the BLAKE3 digest of the salt
and the component's smallest group key, then assigned to the holdout until it holds at least
the per-mille share of all examples (rounded up), then to validation likewise, and the rest
to training.

`validateDataset` runs on every decoded envelope, whether or not this builder produced it.
It checks the kind and version, recomputes the digest, and rejects duplicate example ids, a
group key or an identical input that appears in more than one split, a label without an
expected output or an expected output without a label, a critique on any example outside
the training split, more than one program-scoped critique on one example, an empty
`behaviorVersions`, and a holdout smaller than `minHoldoutExamples`. It returns every
problem found, not only the first.

`openDataset` turns a valid envelope into typed data using a caller-supplied
`EvidenceCodec i o` holding `decodeInput`, `decodeExpected`, `inputSchema` and
`outputSchema`; `modelEvidenceCodec` builds one from the `FromModel` and `ToSchema`
instances of both types, so the dataset decodes values exactly as the program does. An
input type usually has no `ToSchema` instance yet; the generic default supplies one.
`openDataset` fails if the digests of the codec's schemas differ from the envelope's. The
result is an abstract `SealedDataset i o`. The public module exports accessors for the
training and validation `Dataset i o`, the training example ids in order, and the training
critiques. Those datasets hold only labeled examples, and the id list is aligned with the
training dataset position for position, because GEPA identifies an example by its index.
The holdout accessor lives in a module listed under `other-modules`, so code outside the
package cannot obtain holdout examples from a sealed dataset.

Tests in `shikumi-evidence/test/` cover this milestone. `DatasetDigestSpec` changes, one at
a time, an example's input, a source reference, a split-policy field, the order of two
examples, a schema digest and the redaction policy id, and asserts each produces a
different digest while an untouched re-seal produces the same one. `SplitSpec` builds
records where A and B share an identical input under different group keys and B and C share
a group key, asserts all three land in one split, and asserts that hand-edited envelopes
which move one of them are rejected. `LabelSpec` runs a fixture adapter over rows that
carry a human adjudication, a model critique and an inferred operational outcome, and
asserts the kinds and authors survive sealing, that prohibited text is rewritten, and that
content the rewriter misses fails the build.

### Milestone 2: artifacts, policy, conclusion and report

`Shikumi.Evidence.Artifact` defines one envelope for both baselines and candidates, since a
promoted candidate is the next baseline. Its fields are `artifactKind`
(`shikumi.evidence.program`), `schemaVersion`, `artifactId`, an optional `parentDigest`
(the baseline's digest for a candidate), `compiledSchemaVersion`, `structuralFingerprint`
(the digest of the JSON of `programShape`), the two schema digests, `compiledState` (the
exact JSON object `encodeCompiled` emits), an optional `optimization` record, `sources`
(RepoRefs, each a `role`, `repoId` and 40-character `revision`), `createdAt`, `createdBy`
and `contentDigest`. The `optimization` record holds the optimizer id, version and declared
configuration, the seed, the budget, predicted and admitted operations, a usage summary
(tokens, the exact cost as a `numerator/denominator` string, and the count of calls with
unknown usage), the run status, the dataset digest, the route identities with call counts
observed during optimization, and the digest of the optimization-phase recording.
`sealBaseline` builds a root artifact from a compiled program and fails on an invalid
RepoRef or id. `loadArtifact codec template artifact` validates the digest and schema
digests and then calls `decodeCompiledOnto`, so a successful load is the proof that the
artifact's structure equals the template's. `encodeCompiled` and `decodeCompiledOnto` work
on bytes, so the artifact stores the parsed JSON object and re-encodes it to load. The
compiled state carries no version of its own; `compiledSchemaVersion` is a constant this
package defines (1) to name the `{shape, params}` layout. The
record cannot attribute an individual call to proposing or scoring inside an optimizer, so
it stores the union of routes used by the whole optimization phase.

`Shikumi.Evidence.Policy` defines the metric policy: `policyId`, `policyVersion`,
`metrics`, `primaryMetric`, `constraints`, `minImprovement`, `regressionMargin`,
`minLabeledSamples`, `maxMissingRate`, an optional `exampleTimeoutMs` and
`maxComparisonOperations`. A metric names its `metricId`, the `measure` it aggregates, its
`unit`, its `direction` (reusing `Maximize` and `Minimize` from
`Shikumi.Optimize.Report`), its `aggregation`, and its missing-data behavior (reusing
`Required` and `Substitute`). The aggregations are a mean over labeled examples, a mean
over completed examples, a total over labeled examples, a total divided by the number of
completed examples, and the worst value over completed examples. The built-in measures,
produced for every executed example, are `quality` (the caller's metric score, zero when
execution failed), `completed` and `timed_out` (one or zero), `cost_usd`, `latency_ms`,
`operations` and `tokens`. Custom measures come from one caller-supplied pure function. A
constraint names a metric and one of three bounds, each read in the metric's direction: an
absolute limit, a ratio to the baseline's value, or "not worse than the baseline by more
than a margin". Between them these express no increase in safety violations, absolute and
relative cost per successful example, a latency ceiling, a timeout rate, and a minimum
completion rate. `timed_out` is one when the example raised `Timeout` or when
`exampleTimeoutMs` is set and the example's summed recorded latency exceeds it; a timed-out
example is not completed and scores zero quality. A custom measure value that is not
finite counts as missing. Custom measures are code, not data: the policy hashes their ids,
and the function itself is identified by the `program-template` RepoRef. `validatePolicy`
rejects duplicate ids, a constraint or primary metric that is not declared, a custom
measure id that collides with a built-in, and non-finite thresholds. The policy's digest
is the digest of its JSON.

`Shikumi.Evidence.Report` defines the report envelope and the pure decision. The decision
function takes the policy and a record of facts and returns a conclusion with
machine-readable reasons. It is total and ordered. It returns `Invalid` when the dataset or
an artifact failed validation, the candidate's structure differs, the holdout is
contaminated or below the dataset's declared minimum or has no labeled example, the
exposure limit is exhausted without an override, the two arms observed different routes,
the comparison did not finish within its operation limit, or a required metric has no
value. Otherwise it returns `Inconclusive` with the reason `candidate-identical` when the
candidate's compiled state equals the baseline's; the driver skips the comparison in that
case, so no metric exists to judge. Otherwise it returns `Regressed` when any constraint is violated or the primary
metric is worse than the baseline by more than `regressionMargin`. Otherwise it returns
`Inconclusive` when labeled samples are fewer than `minLabeledSamples`, the missing-label
rate exceeds `maxMissingRate`, or the primary improvement is smaller than `minImprovement`.
Only otherwise does it return `Improved`.

The report's fields are `artifactKind` (`shikumi.evidence.report`), `schemaVersion`,
`reportId`, `bindings` (the baseline, candidate, dataset, policy and evaluator digests and
the source RepoRefs), the embedded `policy`, an `evaluator` descriptor (an id, this
package's version and the cache key version), one result per arm (sample count, completed,
failures, timeouts, missing labels, each metric's value, per-example rows, routes, usage
and admitted operations), each constraint's observed values and verdict, the primary
comparison with its thresholds, the exposure limit and ordinal with any override, predicted
and admitted comparison operations, the digest of the comparison-phase recording, an
optional `traceRef`, the `conclusion` and `reasons`, `createdAt`, `createdBy` and
`contentDigest`. Per-example rows hold only the example id, an outcome class and numbers;
they never contain inputs, outputs or critique text, so a report cannot carry holdout
content back to a proposer. A report sealed before a candidate exists has no candidate
digest, no arm results and no comparison recording digest; those fields are optional.
`verifyReportBinding` takes a report and the baseline, candidate, dataset, policy and
RepoRefs a verifier holds, and fails with every mismatch it finds. Besides the five
bindings it checks the report's own digest, that the embedded policy hashes to the bound
policy digest, that the candidate's `parentDigest` is the baseline's digest, and that the
candidate's optimization record names the dataset's digest.

`ArtifactSpec` asserts that loading a candidate onto a template with a different shape
fails and that changing a schema digest fails. `ConclusionSpec` feeds the decision function
facts where quality rises while, in turn, a safety, cost, latency and completion constraint
is violated, and asserts `Regressed` each time; then facts with too few labels, a
contaminated holdout, an exhausted exposure and a missing required metric, and asserts
`Invalid` or `Inconclusive` and never `Improved`. `BindingSpec` changes each of the
baseline, candidate, dataset, policy and source digests and asserts verification fails each
time.

### Milestone 3: stored critiques in GEPA

In `shikumi-optimize/src/Shikumi/Optimize/Feedback.hs`, add `Human` and `Inferred` to
`Provenance`, and add `StoredCritique` (a stable example id, an optional node path, the
text, the provenance and an author) with `storedCritiqueFeedback`. That function takes the
example ids in the order of the dataset being captured, the stored critiques and a metric,
and returns a callback of the same shape as `legacyFeedback`. For each example it scores
with the metric, attaches every stored node critique whose node actually executed in this
run as a `NodeFeedback`, places the single program-scoped critique in `programCritique`,
and attaches nothing when no critique is stored. A stored critique whose node did not
execute is dropped rather than raising, since production evidence can refer to a node a
failing rerun never reached. An index beyond the id list attaches nothing. When execution
failed the score is zero and stored critiques still attach, since a failing example is the
one most worth reflecting on. Existing bounds and redaction in `FeedbackConfig` apply
unchanged, because the callback's output still passes through `validateFeedback` and
`mutateFromEvidence`. Export the additions from `Shikumi.Optimize.Feedback`, which
consumers import directly. The new constructors break no code in this repository: nothing
outside that module matches on `Provenance` exhaustively.

Bump `shikumi-optimize` to `0.4.0.0`, record the change under `Unreleased` in its
`CHANGELOG.md`, and update the bound in its own test suite stanza. Extend
`shikumi-optimize/test/FeedbackSpec.hs`: a stored human critique reaches the proposer
request text labeled `Human`, a model critique labeled `Model`, an example with no stored
critique produces no critique, and a critique longer than `critiqueCharacters` is
truncated.

### Milestone 4: recording, exposure and the driver

Start with a thin end-to-end slice before any variant: a one-example job recorded against a
stub and then replayed, asserting equal digests. It proves the three interactions the
design depends on, namely that a JSON round-tripped response preserves `latencyMs`, usage
and cost, that the admission interposer inside `optimizeWith` composes with an outer
record/replay interposer, and that the phases produce separate recordings. If the response
round trip loses a field the measures need, record the finding and fix the instance in
`shikumi-cache` rather than working around it here.

`Shikumi.Evidence.Recording` defines the recording envelope (`artifactKind`
`shikumi.evidence.recording`, the cache key version, entries sorted by key, and a digest)
and two interposers on the `LLM` effect. An entry maps one request key to the list of that
request's outcomes in the order the calls were issued. An outcome is either a response or
a typed error: the error's constructor name and message, for exactly the constructors the
comparison counts as an example failure (listed below under the driver). The recording
interposer always calls through. It encodes a response to JSON, appends it to the key's
list, and returns the decoded form of what it stored, so a live run computes from the same
bytes a replay will see. When the call raises a recordable error it appends that error and
re-raises it; any other error propagates unrecorded. The replaying interposer never calls
through. It keeps a cursor per key, returns or re-raises the next outcome, and throws
`ReplayDivergence` when the key is absent or its list is used up. After each phase the
driver also throws `ReplayDivergence` if any outcome was left unconsumed. Both interposers
throw `UnrecordableCall`, a new exception type that is not a `ShikumiError`, on a streamed
call and on a call whose options request provider evidence. The module also collects, from
the requests it sees, each route identity with its call count.

`Shikumi.Evidence.Exposure` defines `HoldoutExposure` (prior exposures and an optional
override naming who allowed it, why and when) and a pure `ExposureLedger` value with JSON
instances, keyed by dataset digest, that records a report's digest at most once. The
package reads and writes no files; the example and the tests persist the ledger.

`Shikumi.Evidence.Driver` defines `runEvidenceJob`. Its job record holds the dataset, the
codec, the baseline template and artifact, an optimizer specification, the limits, the
search metric, the custom measures, the policy, an execution context (principal, creation
time, job id, trace reference, RepoRefs and exposure), the caller's request pipeline
(routing and defaults, or the identity), and the mode: record live, or replay a given pair
of recordings. Its effect row is the one `optimizeWith` needs and contains no `IOE`, so the
driver cannot read credentials or touch a deployment. It proceeds as follows.

It validates everything first: the dataset, the baseline artifact loaded onto the template,
the policy, the presence of RepoRefs for the roles `shikumi` and `program-template`, and
that `evaluationConcurrency` is one. Any failure yields a sealed `Invalid` report and no
model call. It then opens the dataset and runs the optimization phase: the optimizer
specification is given the validation split, the training ids and the training critiques,
and returns a `ConfiguredOptimizer` that `optimizeWith` applies to the training split and
the baseline program. Each phase is composed as the phase's record or replay interposer
applied to the request pipeline applied to the phase's action, which is the order ADR-12
prescribes: a call passes through the session's admission, then routing, then defaults,
and reaches the recording boundary last, carrying its real route and effective options.
`gepaEvidenceOptimizer` is the supplied specification; it wires the validation split into
`validationDataset` and the stored critiques into `feedbackCallback`, and turns on
`includeProgramCritique` when any stored critique is program-scoped. A run status of
`BudgetStopped` is the normal end of a GEPA search and is copied into the candidate's
optimization record as it is; only a thrown error fails the phase.

Next comes the structural gate. If the returned program's shape differs from the
template's, or its encoded state does not load back onto the template, the driver seals an
`Invalid` report, emits no candidate, and does not touch the holdout. Otherwise it seals
the candidate. If the candidate's compiled state equals the baseline's, it seals an
`Inconclusive` report and stops. It then checks exposure and, if exhausted without an
override, seals an `Invalid` report without executing the holdout.

The comparison phase runs once, after the candidate is final, in its own recording. It
opens a search session limited to `maxComparisonOperations` and two candidates, and
evaluates the baseline and then the candidate over the labeled holdout examples with
`evaluateCandidate`. The runner wraps `runProgramObserved` in an interposer that sums the
`latencyMs` of the example's responses into a cell; the per-example callback reads that
cell and turns the example's `EvaluationEvidence` into a row of measures, which the driver
collects itself because `CandidateReport` keeps only the score. Rows of an arm whose
status is not `CandidateCompleted` are discarded. No wall-clock timeout is applied.
Output-shaped failures (`InvalidJSON`, `MissingField`, `SchemaMismatch`,
`ValidationFailure`, `Timeout`, `ContextWindowExceeded`, `CodeExecFailed`) are counted
failures scored zero, and these are the constructors a recording stores as error outcomes.
Infrastructure failures (`ProviderError`, `ProviderFailure`, `BudgetExceeded` from a cost
ceiling) abort the job with the original error and no report. The driver
aggregates each arm, evaluates constraints, calls the decision function, seals the report,
and returns the candidate, the report, both recordings and an unsealed summary stating the
mode.

`HoldoutIsolationSpec` gives holdout and validation examples unique sentinel words,
captures every request of the optimization phase, and asserts no request contains a
holdout sentinel, no proposer request contains a validation sentinel, and the candidate's
parameters contain neither. `ComparisonSpec` asserts both arms saw the same example ids,
policy digest and routes, and that a request pipeline which rewrites the model of requests
carrying the candidate's instruction yields `Invalid`. `BudgetSpec` asserts the candidate's
predicted and admitted operations and usage equal the optimizer report's and the summed
stub usage, and that the report carries the comparison's. `ReplaySpec` records a job,
replays it over an interpreter that fails if reached, and asserts equal candidate and
report digests; removes one outcome and asserts `ReplayDivergence`; adds a surplus outcome
and asserts `ReplayDivergence`; and records a template wrapped in `Retry` against a stub
that answers badly once and then well, asserting that the retry recovers in the live run
and in the replay, and that a provider-raised `Timeout` on one example is counted as a
timeout in both. It also asserts that an example whose recorded latency exceeds
`exampleTimeoutMs` is counted as timed out, and that a streamed call raises
`UnrecordableCall`. `DriverGateSpec` uses an optimizer that returns the baseline unchanged
and asserts an `Inconclusive` report with zero comparison operations. It uses an optimizer that returns a
differently shaped program and asserts no candidate and an `Invalid` report with zero
comparison operations, and repeats the insufficient-evidence cases of M2 through the real
driver.

### Milestone 5: the UC-7 fixture and the runnable example

The fixture is a miniature of the reviewer agent in UC-7. The program is one `predict`
node with a non-empty instruction that classifies how a changed decision record relates to
cited guidance, from an input with a `summary` to an output with a `disposition` of
`consistent`, `adr-suspect` or `guidance-suspect`. The dataset has 24 synthetic,
non-sensitive records in six groups of four. Every group holds one consistent record, one
whose summary says the record contradicts the guidance, one that says the guidance is
outdated, and one ambiguous contradiction that even the improved program gets wrong.
Because every group has the same mix, the result does not depend on which groups the hash
places where. Give every record a distinct summary, since identical inputs would merge
their groups. With `holdoutPerMille` 333 and `validationPerMille` 160 the splits are 12
training, 4 validation and 8 holdout examples. All labels are human, and training records
labeled `adr-suspect` carry a human critique at the root node asking the program to name
the conflict.

The test suite owns the stub provider that generates the recordings. Without a rule in its
instruction the reviewer always answers `consistent`; with one it answers correctly except
on ambiguous summaries. The proposer returns an instruction containing the rule when its
feedback mentions naming the conflict. Every reviewer response carries a small fixed cost
that is a terminating decimal such as 1/1000, because a stored cost survives the JSON
round trip exactly only then. It is
set on the stub response at `message.usage.cost.usd`; `usageTotalsFromUsage` in
`shikumi-eval/src/Shikumi/Eval/Report.hs` shows how it is read back. A second, costly
provider returns a verbose rule, and answers under a verbose instruction cost four times as
much. The policy requires a quality improvement of at least 0.1, full completion, no
increase in false actionable signals (a custom measure that is one when the program
answers something other than `consistent` for a record labeled `consistent`), cost per
successful example within 1.15 of the baseline, latency within 1.10, and eight labeled
samples. With limits of 60 operations, two candidates, concurrency one and seed one, the
optimization phase should be predicted and admitted at 17 operations (4 to score the
baseline on validation, 9 for one proposal over a four-example minibatch, 4 to score the
child) and the comparison at 16 (two programs over eight examples). If the real counts
differ, find out why before changing the expectation. The optimization run status is
`BudgetStopped`, because the candidate limit of two is reached. Keep each group's four
records adjacent in the record list, so the four-example minibatch, which is the first
four training examples, is one whole group and contains a critiqued `adr-suspect` record. The expected outcome is baseline
quality 0.25 and candidate quality 0.75 with conclusion `Improved`, and for the costly
provider the same quality with a cost ratio of 4 and conclusion `Regressed` naming the
cost constraint.

`Uc7Spec` generates everything live against the stubs and compares it, with `tasty-golden`,
to checked-in files under `shikumi-evidence/fixtures/uc7/`: `dataset.json`,
`baseline.json`, `policy.json`, `good/recording-optimization.json`,
`good/recording-comparison.json`, `good/candidate.json`, `good/report.json` and the same
four under `costly/`. It then replays from those files and asserts the same digests. List
the fixture files under `extra-source-files` in the cabal file. Artifact files are
canonical JSON followed by a newline; read them with `jq`.

Add `shikumi-jitsurei/app/Evidence.hs` and an `executable jitsurei-evidence` stanza
modeled on `jitsurei-gepa-objectives`. It defines its own copy of the fixture program,
codec, measures and optimizer specification, reads the checked-in dataset, baseline, policy
and recordings from `shikumi-evidence/fixtures/uc7` relative to the working directory
(which is the repository root, as for every example in CI), runs both jobs in replay mode
over `runStubEval` with a responder that fails if reached,
verifies each report's binding, checks its digests against the checked-in ones, writes the
artifacts under an output directory (default `dist-newstyle/jitsurei-evidence`, or its
first argument), and prints the transcript below. Add the executable to the example list
in `.github/workflows/ci.yml` and update the count in that step's name, and to the index
printed by `shikumi-jitsurei/app/Main.hs`.

### Milestone 6: documentation and durable records

Add a section on production-evidence optimization to
`docs/user/evaluation-and-optimization.md` covering the three artifacts, the split rules,
the four conclusions and the example command. Add a capability record under
`docs/capabilities/`, modeled on `docs/capabilities/validated-gepa-execution.md`, with a
handle allocated by `okf id next` against that bundle's profile. Add the package to the
table in `README.md`, to the `packages` list in `mori.dhall` (modeled on the
`shikumi-optimize` entry), and to the publish-order table in
`agents/skills/release/SKILL.md` after `shikumi-optimize`. Write the package's
`CHANGELOG.md`.

Distill the Decision Log into one new ADR following `agents/skills/exec-plan/ADR.md`:
allocate the handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`,
record the envelope and digest rule, mode-independent sealed content, the record/replay
boundary, holdout isolation, the conclusion order and the exposure input, link ADR-4,
ADR-5, ADR-8, ADR-12 and ADR-13, add a line to `docs/adr/log.md` with `okf log add`,
regenerate the index with `okf index` (its `--help` shows how to write rather than
preview), and run `just check-adr`. Add one sentence to ADR-5's consequences
pointing at the new ADR.

In `docs/improvement-requests/log.md` note that the implementation has landed and release
is pending; leave IR-2's `status` unchanged until M7. Strict validation of that bundle
already reports missing review metadata on older requests
([FRIC-1](../friction-log/1-strict-improvement-request-validation-requires-historical-review-metadata.md));
do not invent reviews to silence it.

### Milestone 7: release

Only after the operator explicitly authorizes it, follow the repository's `release` skill
(`agents/skills/release/SKILL.md`) to publish `shikumi-optimize 0.4.0.0` and
`shikumi-evidence 0.1.0.0` in dependency order, plus any package whose bounds had to move.
Then set IR-2 to `completed` with `completedAt` and a `resolution` naming this plan and
the released versions, in the same form as
`docs/improvement-requests/support-streamed-judgment-programs-with-typed-result-parity.md`,
and add the log entry. Without authorization, stop after M6 and say so in Outcomes &
Retrospective.


## Concrete Steps

Run everything from the repository root.

Build and test the new package while developing; a single group can be selected with a
tasty pattern:

```bash
nix develop -c cabal build shikumi-evidence
nix develop -c cabal test shikumi-evidence
nix develop -c cabal test shikumi-evidence --test-options='-p "/dataset-digest/"'
```

After M3, confirm the optimizer suite still passes:

```bash
nix develop -c cabal test shikumi-optimize
```

Create or refresh the golden fixture files in M5, then review the diff before keeping it:

```bash
nix develop -c cabal test shikumi-evidence --test-options=--accept
git status --short shikumi-evidence/fixtures
```

Run the example:

```bash
nix develop -c cabal run -v0 exe:jitsurei-evidence
```

The transcript should have this shape. Replace the elided digests here with the real ones
once the fixture exists, so later readers can compare exactly:

```text
dataset    blake3:…  train=12 validation=4 holdout=8
baseline   blake3:…
good       candidate blake3:…  Improved   quality 0.2500 -> 0.7500  cost ratio 1.0000
costly     candidate blake3:…  Regressed  violated: cost-per-success (ratio 4.0000 > 1.1500)
replay reproduced the checked-in candidate and report digests
bindings verified for good and costly reports
wrote dist-newstyle/jitsurei-evidence/good/candidate.json
wrote dist-newstyle/jitsurei-evidence/good/report.json
wrote dist-newstyle/jitsurei-evidence/costly/candidate.json
wrote dist-newstyle/jitsurei-evidence/costly/report.json
```

Run the repository gates before M6 is accepted:

```bash
nix fmt
nix develop -c cabal build all
nix develop -c cabal test all
just check-haddock shikumi-evidence shikumi-optimize
just check-adr
```

Every commit made under this plan ends with both trailers:

```text
ExecPlan: docs/plans/70-add-production-evidence-optimization-and-promotion-reports.md
Intention: intention_01m6n06mfhemm85w9ryva6e3f9
```


## Validation and Acceptance

The request lists twelve deterministic tests. Each is a named group in the
`shikumi-evidence` suite unless noted, and each must fail if the behavior it guards is
removed.

1. Dataset digests change with examples, provenance, split policy, ordering, schema or
   redaction policy: `dataset-digest` (M1).
2. Duplicates and grouped examples cannot cross splits: `split-leakage` (M1).
3. The holdout is absent from optimizer and proposer inputs: `holdout-isolation` (M4).
4. A structural-fingerprint mismatch prevents a promotion-compatible candidate:
   `artifact` (M2) and `driver-gates` (M4).
5. Both arms run under the same evaluator, dataset, routing and policy: `comparison` (M4).
6. A quality gain with a safety, cost, latency or completion violation is `Regressed`:
   `conclusion` (M2).
7. Too few labels, contamination, exhausted exposure or missing required metrics are
   `Invalid` or `Inconclusive`, never `Improved`: `conclusion` (M2) and `driver-gates`
   (M4).
8. Budget prediction and actual usage appear in the candidate and report: `budget` (M4).
9. Replayed inputs reproduce candidate and report digests: `replay` (M4).
10. Changing any bound digest invalidates report binding: `binding` (M2).
11. Adapters preserve label kinds and redact prohibited content: `labels` (M1) and the
    stored-critique cases in `shikumi-optimize/test/FeedbackSpec.hs` (M3).
12. The UC-7 fixture yields a held-out improvement and rejects the costly candidate:
    `uc7` (M5).

The plan is accepted when `nix develop -c cabal test all` passes, the example prints the
transcript above with real digests and exits zero, and the following hold when checked by
hand on the written files. `jq -r .conclusion` on the good report prints `Improved` and on
the costly report prints `Regressed`. Each written artifact's `contentDigest` equals the
checked-in one. Deleting any entry from a copy of a recording makes the example fail with
a replay divergence instead of contacting a provider. Editing any one of the baseline,
candidate, dataset or policy files makes binding verification fail.

Two properties are established by inspection and should be stated in the ADR: the driver's
type has no `IOE` constraint, and the public modules export no function from a sealed
dataset to its holdout examples.

Anything beyond this list, such as a `shikumi` CLI subcommand, a language-model judge as a
gate, streamed-call recording, concurrent evidence jobs or structure-changing candidates,
is a proposal for later scope and is not required here.


## Idempotence and Recovery

Every step is additive and repeatable. Builds and tests can be rerun freely. The example
writes only under its output directory inside `dist-newstyle/`, which is ignored by git,
and overwrites its own files. Golden files change only when the suite is run with
`--accept`; if an unintended change appears, restore them with
`git checkout -- shikumi-evidence/fixtures` and find the cause, because a changed digest
means sealed content changed. If the cache key version in `shikumi-cache` is ever bumped,
every recording becomes unreplayable by design; regenerate the fixtures with `--accept` in
the same change. The `Provenance` extension is the one breaking change; if it must be
backed out, revert the M3 commit and the stored-critique wiring in the driver together.
Allocating an ADR or capability handle is not repeatable, so allocate once, immediately
before writing the file. Nothing in M1 through M6 publishes anything; M7 is the only
irreversible step and is gated on explicit authorization.


## Interfaces and Dependencies

The new package depends on `shikumi`, `shikumi-cache` (canonical JSON, cache keys, response
JSON), `shikumi-compile` (compiled-state serialization), `shikumi-eval` (datasets, metrics,
usage), `shikumi-optimize` (search sessions, GEPA, feedback) and `shikumi-trace` (node
paths, observed execution, `ReplayDivergence`), plus `blake3`, `aeson` and `time`. It must
not depend on any Kikan, Shikigami or Kotei package, on a database client, or on
`shikumi-testing` outside its test suite.

The signatures other work will depend on are these. Names inside records may be adjusted
during implementation; the functions, their inputs and their guarantees may not change
without a Decision Log entry.

```haskell
-- Shikumi.Evidence.Digest
newtype Digest = Digest Text
digestValue :: Value -> Digest

-- Shikumi.Evidence.Dataset
sealDataset :: DatasetSpec -> RedactionPolicy -> [EvidenceRecord] -> Either [DatasetError] EvidenceDataset
decodeDataset :: ByteString -> Either [DatasetError] EvidenceDataset -- digest on the raw value, exact round trip
validateDataset :: EvidenceDataset -> Either [DatasetError] ()
modelEvidenceCodec :: (FromModel i, ToSchema i, FromModel o, ToSchema o) => EvidenceCodec i o
openDataset :: EvidenceCodec i o -> EvidenceDataset -> Either [DatasetError] (SealedDataset i o)
sealedTraining, sealedValidation :: SealedDataset i o -> Dataset i o
sealedTrainingIds :: SealedDataset i o -> [Text] -- aligned with sealedTraining

-- Shikumi.Evidence.Artifact
sealBaseline :: ArtifactSpec -> EvidenceCodec i o -> CompiledProgram i o -> Either [ArtifactError] ProgramArtifact
decodeArtifact :: ByteString -> Either [ArtifactError] ProgramArtifact
loadArtifact :: EvidenceCodec i o -> Program i o -> ProgramArtifact -> Either [ArtifactError] (CompiledProgram i o)

-- Shikumi.Evidence.Recording
data UnrecordableCall = UnrecordableCall Text -- an Exception, never a ShikumiError
decodeRecording :: ByteString -> Either [RecordingError] Recording

-- Shikumi.Evidence.Exposure
recordExposure :: Digest -> Digest -> ExposureLedger -> ExposureLedger -- dataset, report; idempotent
priorExposures :: Digest -> ExposureLedger -> Int

-- Shikumi.Evidence.Policy and Shikumi.Evidence.Report
validatePolicy :: MetricPolicy -> Either [PolicyError] ()
conclude :: MetricPolicy -> ComparisonFacts -> (Conclusion, [Reason])
data Conclusion = Improved | Regressed | Inconclusive | Invalid
verifyReportBinding ::
  ComparisonReport -> ProgramArtifact -> ProgramArtifact -> EvidenceDataset -> MetricPolicy -> [SourceRef] ->
  Either [BindingError] ()

-- Shikumi.Evidence.Driver
data OptimizerSpec i o = OptimizerSpec
  { optimizerId :: Text,
    optimizerVersion :: Text,
    optimizerConfig :: Value, -- declared configuration, copied into the candidate
    buildOptimizer :: OptimizerInputs i o -> ConfiguredOptimizer i o
  }

data OptimizerInputs i o = OptimizerInputs
  { validation :: Dataset i o,
    trainingExampleIds :: [Text],
    trainingCritiques :: [StoredCritique],
    searchMetric :: Metric o
  }

gepaEvidenceOptimizer :: GepaEvidenceConfig -> Program ReflectIn ReflectOut -> OptimizerSpec i o

data ExecutionMode = RecordLive | Replay JobRecordings

data EvidenceJob es i o = EvidenceJob
  { dataset :: EvidenceDataset,
    codec :: EvidenceCodec i o,
    template :: Program i o,
    baseline :: ProgramArtifact,
    optimizer :: OptimizerSpec i o,
    limits :: RunLimits,
    searchMetric :: Metric o,
    customMeasures :: o -> EvaluationEvidence o -> Map Text Double, -- expected output, evidence
    policy :: MetricPolicy,
    context :: ExecutionContext, -- principal, createdAt, jobId, traceRef, sources, exposure
    requestPipeline :: forall a. Eff es a -> Eff es a, -- e.g. withRequestDefaults d . routeLLM, or id
    mode :: ExecutionMode
  }

runEvidenceJob ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  EvidenceJob es i o -> Eff es EvidenceJobResult

data EvidenceJobResult = EvidenceJobResult
  { candidate :: Maybe ProgramArtifact,
    report :: ComparisonReport,
    recordings :: JobRecordings,
    summary :: JobSummary
  }
```

Several of these field names (`dataset`, `candidate`, `policy`, `searchMetric`) collide
with existing functions or with each other. The sibling packages enable
`DuplicateRecordFields`, which covers the record-to-record collisions; rename a field when
it shadows a function the module needs, such as `Shikumi.Eval.dataset`.

```haskell
-- Shikumi.Optimize.Feedback (shikumi-optimize 0.4.0.0)
data Provenance = Caller | Model | LegacyProgram | Human | Inferred
storedCritiqueFeedback ::
  (Applicative m) => [Text] -> [StoredCritique] -> Metric o -> o -> EvaluationEvidence o -> m FeedbackResult
```

Shikigami's side of the seam is `verifyReportBinding` plus each envelope's decoder and
validator. Kotei's side is supplying the job's inputs, the provider interpreter, the
exposure count, and any bound on real elapsed time. Neither needs anything else from this
package.


## Revision Notes

2026-11-18: Reviewed against the working tree before implementation. The orientation was
corrected where it disagreed with the code (what `Shikumi.Optimize` re-exports, that
`ReplayDivergence` is an exception, that GEPA normally ends `BudgetStopped`, that a
response's model is an echo). Six design points changed because the original would have
produced wrong or unreproducible results: recordings now keep ordered outcomes per request
instead of memoizing, provider-raised typed errors are recorded, unrecordable calls raise
an exception that cannot be scored as a failed example, timeouts are decided from recorded
latency, the same-route gate and its test use requested routes, and digests are verified
on the raw JSON value. An unchanged candidate is now `Inconclusive` without spending a
holdout exposure, which is the one exception to the fixed conclusion order: it is decided
after the `Invalid` checks and before `Regressed`. The interface list gained the decoders,
`modelEvidenceCodec`, the pure exposure ledger and `UnrecordableCall`, and `customMeasures`
now takes `EvaluationEvidence`. Scope, milestones and the twelve acceptance tests are
unchanged.
