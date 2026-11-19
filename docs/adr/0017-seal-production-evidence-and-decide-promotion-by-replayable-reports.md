---
type: Architecture Decision Record
title: Seal production evidence and decide promotion by replayable reports
description: Wrap evidence datasets, programs, policies, recordings and comparison reports in digested envelopes, isolate the protected holdout, and decide comparisons by a fixed order from replayable inputs.
docId: ADR-17
status: Accepted
date: 2026-11-19
timestamp: 2026-11-19T00:33:09Z
generated:
  by: agent:anthropic/claude-opus-5-5
  at: 2026-11-19T00:33:09Z
---

# Seal production evidence and decide promotion by replayable reports

## Context

The optimizer can improve a typed program, but its reports are diagnostic: they do
not seal datasets, evaluate a protected holdout or authorize promotion
([ADR-5](0005-own-optimizer-admission-and-diagnostic-reports-in-search-sessions.md)).
A lifecycle owner in another repository must be able to verify, without having been
present, which examples the optimizer could see, which baseline and candidate were
compared, under which policy, and whether the candidate improved without becoming
unsafe, slower or more expensive. Shikumi is a library with no durable store and must
not activate a candidate or hold a credential that could.

## Decision

`shikumi-evidence` owns five envelopes: dataset, program artifact, metric policy,
recording and comparison report. An envelope's digest is BLAKE3 over the canonical
JSON (`Shikumi.Cache.Key.canonicalJSON`) of the whole envelope with `contentDigest`
removed; a policy has no digest field and its digest is that of its JSON. A digest is
verified on the JSON value exactly as read, and decoding fails unless re-encoding the
typed value yields the same value, so unknown fields and alternative spellings are
rejected. Sealed content is identical in a live run and its replay: whether a job ran
live or replayed is reported only in an unsealed summary.

Dataset splits are deterministic and keep groups whole: records sharing a group key
or an identical canonical input form one component, ordered by the digest of the salt
and the component's smallest key. Validation rejects any group or input crossing
splits, critiques outside training, and a holdout below the declared minimum. The
holdout is reachable only inside the package: the accessor lives in an unexposed
module, optimizers receive only training data, validation data, training ids and
training critiques, and report rows carry ids, outcome classes and numbers, never
inputs, outputs or critique text.

The driver installs the record/replay boundary itself, where cache and trace sit
([ADR-12](0012-apply-request-defaults-before-cache-and-observation.md)): below the
search session's admission, routing and request defaults. A recording keeps, per
request key, the ordered outcomes in issue order, because a retry re-issues the
identical request. An outcome is a response, stored as JSON and returned in its
decoded form so a live run computes from the bytes a replay sees, or one of the typed
errors counted as an example failure. A missing or unconsumed outcome is a
`ReplayDivergence`. Streamed calls and calls requesting provider evidence raise
`UnrecordableCall`, an exception rather than a `ShikumiError`, so no typed boundary
can score a configuration error as a failed example. Evidence jobs are sequential.

Cost, latency and timeouts come from recorded responses, never the wall clock: an
example times out when the provider raised `Timeout` or its summed recorded latency
exceeds the policy's limit. Route identity is the requested route read at the
boundary; observed identity exists only in provider evidence, which recordings omit
([ADR-13](0013-separate-transport-billing-from-logical-usage.md)). The protected
comparison runs baseline then candidate through `evaluateCandidate` in one
two-candidate session, after the candidate is final and in its own recording.

A candidate whose shape differs from the template, or whose state does not load back
onto it, yields an `Invalid` report and no candidate, which keeps the same-structure
gate that experimental structure artifacts may not weaken
([ADR-8](0008-restore-typed-structures-through-trusted-recipe-registries.md)). The
conclusion is decided by a pure total function in a fixed order: `Invalid` for invalid
inputs, a structure mismatch or an unusable holdout; then `Inconclusive` for a
candidate identical to the baseline, decided without spending an exposure; then
`Invalid` for an exhausted exposure, different routes, an unfinished comparison or a
missing required metric; then `Regressed` for any violated constraint or a primary
regression beyond the margin; then `Inconclusive` for too few labels, too many missing
labels or too small an improvement; and only otherwise `Improved`. Promotion-gate
measures are pure functions of output and execution evidence; a language-model judge
cannot be a gate. The holdout exposure count is input supplied by the trusted caller.

Stored critiques keep their label kind into the reflection prompt through the
`Human` and `Inferred` provenance values; none of them implies human approval
([ADR-4](0004-separate-feedback-attribution-from-execution-evidence.md)).

## Consequences

The driver's effect row has no `IOE`, and the public modules export no function from
a sealed dataset to its holdout examples; both are established by inspection.
`verifyReportBinding` plus each envelope's decoder is the whole verification seam for a
lifecycle owner, and a replay of the checked-in recordings must reproduce candidate
and report digests by equality. Bumping the cache key version makes every recording
unreplayable by design. Concurrent evidence jobs, streamed-call recording,
language-model judges as gates and structure-changing candidates remain out of scope.
The package enables `NoFieldSelectors` and nests builder records inside envelopes,
with flat JSON, so consumers can update records without ambiguous fields.
[Plan 70](../plans/70-add-production-evidence-optimization-and-promotion-reports.md)
records the acceptance evidence and the UC-7 fixture.
