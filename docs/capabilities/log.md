# Bundle Update Log

## 2026-09-08
* **Update**: Added CAP-23 … CAP-36 for the 2026-09-08 multi-package release.
Five records cover new `shikumi` 0.4.0.0 provision (per-attempt transport
billing observation, invocation-scoped request defaults, reasoning continuation
guards, bounded nested XML decoding, opt-in typed prediction capture); three
cover `shikumi-tools` 0.4.0.0 (rich tool outputs with runtime tool registration,
resumable ReAct sessions, bounded recursive language-model sessions); one covers
`shikumi-compile` 0.2.1.0 (typed structure registries); one covers
`shikumi-trace` 0.3.0.0 (isolated node observation with rejection lineage);
four cover `shikumi-optimize` 0.3.0.0 (validated optimizer execution with
lifecycle reports, structure search, failure-aware feedback, and node-local
bootstrap pools).
* **Correction**: CAP-16's body and `interface` had been grown in place by the
two preceding commits to describe `Shikumi.Optimize.Execution`, `.Report`,
`.Feedback` and `.Structure` while its `since` stayed `0.1.0.0` — modules that
ship for the first time in `shikumi-optimize` 0.3.0.0. A consumer pinned to
0.2.1.3 would have read that record as a promise of behavior it does not have.
CAP-16 was returned to its 0.1.0.0 provision and that growth now lives in
CAP-33, CAP-34, CAP-35 (failure-aware optimizer feedback) and CAP-36 (node-local
bootstrap demonstration pools), each `since: 0.3.0.0` and each requiring CAP-16.
* **Update**: Growth was recorded as new records that `require` the older
capability rather than by moving any existing `since` forward, per the profile.
CAP-3, CAP-4, CAP-8, CAP-11, CAP-13, CAP-14, CAP-16, CAP-17, CAP-18 and CAP-19
keep their `since` values; their bodies were refreshed in place where this
release changed a stated limit.
* **Update**: Refreshed the index prose to say that this release raised six
packages to new major versions at once, which the previous "breaking minor
releases" wording understated.
* **No catalog change**: `shikumi-cache-redis` 0.1.3.0, `shikumi-cache-postgres`
0.1.3.0 and `shikumi-okf` 0.2.1.0 ship no consumer-visible provision — they were
released only to widen internal dependency bounds across the breaking core
release, so CAP-9, CAP-10 and CAP-22 are unchanged. `shikumi-trace-otel` 0.1.2.0
adds transport-attempt and billing-quality attributes to existing exported spans
rather than a new adoption surface, so it refined CAP-13 in place.

## 2026-09-07
* **Update**: Document failure-aware GEPA attribution, evidence, and budget limits.
* **Update**: Document node-local bootstrap demonstrations, capture requirements, validated mappings and opaque Embed limits for CAP-16.

## 2026-08-30
* **Adoption**: Authored the initial capability catalog against the shared
`coordination.capabilities` profile from `mori://shinzui/okf-profiles` v0.9.0.
The 22
capabilities (CAP-1 … CAP-22) were derived from public modules, user guides,
hermetic tests, worked examples, package changelogs, git release tags, and
Hackage release history. Every evidence resource was checked to exist, and
the bundle was registered in `mori.dhall`.
* **Release-history note**: All library `since` values name published Hackage
releases. `shikumi-cli` is marked `unreleased` because its package exists and
is tested in the repository but has no Hackage release.
