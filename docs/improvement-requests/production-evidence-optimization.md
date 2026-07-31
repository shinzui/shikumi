---
type: Improvement Request
title: Add production-evidence optimization and promotion reports to Shikumi
description: Produce sealed evidence datasets and auditable candidate-versus-baseline promotion reports.
timestamp: "2026-07-30T00:50:00Z"
requestId: IR-2
status: proposed
origin: mori://shinzui/kikan
---

# Improvement Request: add production-evidence optimization and promotion reports to Shikumi

**Authored by:** `shinzui/kikan` agents following the recursive self-improvement research note and
`mori://shinzui/kikan/okf/use-cases/concepts/UC-7`.
**Addressed to:** `shinzui/shikumi` agents, with Shikigami owning agent lifecycle and Kotei providing
sealed execution.
**Status:** proposed; required for use case 007.
**Contracts:** C1, C5, C7, and C10, plus proposed C16 and C17.
**Created:** 2026-07-26.


## Why

Shikumi already provides the algorithmic center of agent improvement. Its `Optimizer` consumes a typed
training `Dataset`, `Metric`, starting `Program`, and bounded `Budget`, then returns a
`CompiledProgram`. GEPA can reflect on per-example critiques, mutate instructions, and retain a Pareto
frontier. Compiled programs have a structural fingerprint, and the optimizer correctness initiative
establishes budget and never-worse behavior.

What Shikumi does not provide is a production-facing evidence protocol. There is no standard artifact
that says where an evaluation example came from, which examples the optimizer was allowed to see,
which exact baseline and candidate were compared, whether quality improved without violating safety,
cost, or latency constraints, or whether a report is safe for Shikigami to use in promotion.

Without that seam, each agent would build a private trace-to-dataset pipeline and “self-improvement”
would be an optimizer demo rather than an auditable platform capability.


## Requested artifacts

### Sealed evidence dataset

Add a serializable dataset envelope around the existing typed `Dataset`. The envelope must include:

```text
dataset id and schema version
logical agent and eligible behavior versions
input/output schema fingerprints
collection window and selection query/version
example ids and source run/outcome/feedback refs
label kind, label author, label time, and confidence where applicable
redaction and retention policy ids
train, validation, and protected-holdout membership
created-at, created-by, and content digest
```

The content digest covers the ordered examples, split assignment, schemas, selection policy, and
provenance. Once an optimization job begins, the dataset is immutable. Rebuilding from a moving query
creates a new dataset id and digest.

Dataset construction must be adapter-driven. Shikumi defines the artifact and validation rules; it does
not import Kioku, Kawa, Kizashi, Danwa, Kansoku, or a database client into the optimizer core. Kikan
adapters translate permitted run traces, terminal outcomes, explicit human labels, and metrics into the
envelope.


### Candidate artifact

Wrap the resulting `CompiledProgram` in a portable candidate envelope carrying:

- candidate id and parent/baseline artifact digest;
- compiled-program schema and structural fingerprint;
- full serialized parameters required for replay;
- optimizer id and version;
- optimizer configuration, deterministic seed when relevant, and actual budget usage;
- training and validation dataset digest;
- model/provider route identities used during proposal and scoring;
- code/source `RepoRef`s for Shikumi and the program template;
- created-at, created-by, and content digest.

For the first release, loading the candidate onto the baseline template must prove the same structural
fingerprint. A candidate that changes structure or types fails before evaluation and is never emitted as
promotion-compatible.


### Baseline-versus-candidate evaluation report

Add a serializable report that evaluates both artifacts under the same protected comparison protocol.
It must contain:

- baseline, candidate, dataset, evaluator, metric-policy, and code digests;
- per-metric baseline and candidate aggregates plus per-example results or bounded references;
- sample counts, failures, timeouts, and missing-label counts;
- quality, safety, cost, latency, and resource measures named by stable metric ids;
- hard constraints and observed violations;
- improvement, regression, and practical-significance thresholds;
- the deterministic conclusion `Improved`, `Regressed`, `Inconclusive`, or `Invalid`;
- report creation principal, timestamp, trace, and content digest.

Shikumi decides the stated comparison under the supplied metric policy. It does not activate the agent
or grant promotion authority. Shikigami verifies the report and applies lifecycle and approval policy.


## Split and leakage rules

Training examples may be inspected by the optimizer. Validation examples may select among candidates
but may not be passed to a reflective proposer as critiques. The protected holdout is used once for the
final baseline-versus-candidate report and is never exposed to the proposer, candidate-selection loop,
prompt, or tool environment.

If the same source event, conversation, incident, subject, or derived duplicate would cross splits, the
dataset builder must group it into one split. The split policy and grouping key are part of the digest.
An insufficient or contaminated holdout makes the report `Invalid` rather than silently falling back to
training performance.

Repeated evaluation against a holdout consumes a declared exposure counter. Exhaustion requires a new
sealed holdout or explicit human override so iterative proposals cannot overfit the promotion set.


## Multi-objective comparison

Do not collapse every concern into one scalar optimizer score. The optimizer may search on a primary
quality metric, but the promotion report separately enforces hard constraints such as:

- no increase in policy or safety violations;
- maximum absolute and relative cost per successful example;
- latency ceiling and timeout rate;
- minimum completion/success rate;
- minimum labeled samples and maximum missing-data rate;
- minimum quality improvement or non-inferiority margin.

A candidate that gains quality by violating a hard constraint is `Regressed`. A candidate that passes
constraints but lacks enough evidence is `Inconclusive`. Metric direction, units, thresholds, missing
data behavior, and aggregation are declared and hashed; free-form natural-language metrics cannot
silently become promotion gates.


## Execution and reproducibility

Expose a high-level driver that receives the sealed dataset, baseline template and artifact, optimizer,
budget, metric policy, and execution context, then returns the candidate artifact and comparison report.
The driver must use existing `shikumi-eval`, `shikumi-optimize`, and `shikumi-compile` abstractions rather
than introduce a second evaluator or optimizer loop.

The job records predicted and actual model usage, failures, timeouts, model route, and cache/replay mode.
When all provider calls are replayed, rerunning the same job must reproduce artifact and report digests.
When live providers are used, all nondeterministic inputs are recorded and the report is reproducible
from captured responses without contacting the provider again.

Kotei supplies the sealed job environment. Shikumi must not receive deployment credentials or an API
that changes the active Shikigami version.


## Feedback metrics

Generalize GEPA's critique input so an adapter can attach a bounded, redacted critique to a stable
example and node without exposing protected holdout results. Preserve both the numeric score and critique
provenance. Absence of a critique is valid and does not fabricate one.

Explicit human labels such as useful/useless, approved/rejected, corrected output, and resolution reason
must remain distinguishable from model-generated critiques and inferred operational outcomes. The label
kind and author are part of the dataset provenance so evaluation can stratify results rather than treating
all feedback as equally authoritative.


## Required tests

The implementation must add deterministic tests proving:

1. dataset digests change when examples, provenance, split policy, ordering, schema, or redaction policy
   changes;
2. duplicate/group-related examples cannot leak across train, validation, and holdout splits;
3. the protected holdout is absent from optimizer and reflective-proposer inputs;
4. structural-fingerprint mismatch prevents a promotion-compatible candidate;
5. baseline and candidate run under the same evaluator, dataset, routing, and metric policy;
6. a quality gain with a safety, cost, latency, or completion constraint violation reports
   `Regressed`;
7. too few labels, holdout contamination, exhausted exposure, or missing required metrics reports
   `Invalid` or `Inconclusive`, never `Improved`;
8. optimizer budget prediction and actual provider usage appear in the candidate and report;
9. replayed inputs reproduce candidate and report digests;
10. changing any baseline, candidate, dataset, metric-policy, or code digest invalidates report binding;
11. adapters preserve human/model/inferred label kinds and redact prohibited content;
12. use case 007's fixture produces a candidate with a held-out improvement while a deliberately costly
    candidate is rejected by its hard constraint.


## Acceptance

Using a checked-in fixture dataset and replayed provider responses, a user can run one command or test
driver that optimizes a baseline program and writes a candidate artifact plus comparison report. Both
artifacts validate independently, carry complete provenance and digests, and can be decoded without a
live provider. Shikigami can verify that the report binds the exact baseline, candidate, dataset, and
policy before requesting approval. A leaked, structurally different, under-sampled, unsafe, or
over-budget candidate cannot produce an `Improved` report.


## Non-goals

This request does not add an agent registry, decide promotion authority, deploy or activate candidates,
query production stores directly from optimizer core, make Kioku an evaluation ledger, train model
weights, or permit arbitrary source/tool/runtime mutation. It does not replace the existing
`Dataset`, `Metric`, `Optimizer`, `Budget`, `CompiledProgram`, or `Report`; it adds provenance-bearing
operational envelopes and a composed driver around them.
