---
type: Architecture Decision Record
title: Derive decision answers from probability evidence
description: Keep closed decision domains, probability evidence, local answer derivation and provider-facing judgment schemas separate.
docId: ADR-15
status: Accepted
date: 2026-10-24
timestamp: 2026-10-25T18:14:37Z
generated:
  by: agent:openai/gpt-6.1-sol
  at: 2026-10-25T04:43:42Z
---

# Derive decision answers from probability evidence

## Context

Decision outputs need both a closed answer domain and the probability evidence
that selected the answer. A provider's chosen answer cannot support local
threshold, cut or weight changes without making another call. Ordinary output
schemas describe answers, while generative evidence schemas describe probability
distributions; the two shapes serve different purposes.

## Decision

`Shikumi.Decision` owns the decision types, evidence records, judgment metadata,
schema reader and pure default derivation. Noul evidence encodes as `{"noul":p}`;
Choice and Score evidence use `probabilities` and optional `confidence`. Score
probabilities have contiguous decimal level keys, with 2 to 10 levels. The
internal `FieldEvidence` wrapper uses a tagged envelope because numeric Choice
labels and Score indices can otherwise have identical JSON shapes.

Decode probabilities and derive the answer locally. Do not copy a provider's
pick into a rich result. Choice ties require declared label order, which a
`Map Text Double` does not retain. `deriveChoice` therefore takes the ordered
labels explicitly, before weights and evidence. Pure calibration settings
live in `Shikumi.Decision.Setting` and are validated against a field's domain.

The judgment schema uses ordinary boolean, string-constant and ordered
integer-constant shapes. Boolean criteria live in the constant branches'
descriptions. The private `x-shikumi-decision` marker identifies decoder behavior
and is removed before transport; it must never contain provider-required
criteria. A complete unique `required` array determines field order, with
ascending property order as the fallback. Unsupported constraints remain
free-form fields rather than silently widening the judgment domain.

Decision state uses `ToPrompt.toPromptJSON` to preserve JSON types, including
strings that resemble JSON literals. Prompt text and existing native demo
rendering keep their existing behavior. Generic primitive, list, optional and
described fields have structured encoders; custom structured leaves supply
`PromptValue.promptValueJSON`, and custom records may override `toPromptJSON`.
Flattened demos contain derived answers, not evidence records. State travels on
the reserved metadata channel and is stripped by routing.

Judgment-only routing uses Baikai's `isJudgmentOnly`, submits exactly one
`UserData` state without a system prompt or tools, and refuses free-form outputs
and streaming before dispatch. `AssistantData` probabilities and confidence feed
the decoder; its provider-selected `value` is ignored. Structured content survives
the response cache codec.

Decision settings serialize in Params and are applied after response retrieval.
They never enter request identity, so cached and replayed evidence can yield new
answers. Missing settings preserve old Params JSON bytes. Parameterized decoding
normalizes evidence with a private derived-answer annotation before rich leaf
decoding; the annotation is constructed locally, never copied from provider data.
The three public evidence codecs remain unchanged.

Generative requests replace rich decision fields with closed evidence objects.
Bare Bool and enum fields opt in only through explicit settings. Probabilities and
confidence must be finite and in [0,1], with exact declared keys; distributions
need not sum to one. Both native JSON and marker replies enter the same derivation.
Free-form fields can coexist with decisions on generative models.

State and evidence schemas have separate private stamps. Judgment-only routing
selects the original answer schema; generative routing selects the evidence schema.
All stamps are stripped before transport. Numeric setting values never enter them.
Streaming is refused at the program and routed LLM boundaries.

The prompt classes live in the leaf module Shikumi.Adapter.Prompt, re-exported
from Shikumi.Adapter, to avoid an Adapter/Decision import cycle. toPromptJSON
preserves typed state with derived demo answers. toEvidenceJSON preserves supplied
rich evidence and derived answers in generative task examples; no probability
mass is invented for labeled demos. Both generative formats omit demo turns.

## Consequences

Generative and provider-backed paths can share evidence and local derivation
without sharing a wire client. The schema reader must later be checked against
the provider-neutral compiler in `mori://shinzui/baikai`; the shared Assessment fixture pins order, domains and criteria against
`Baikai.Judgment.compileJudgments`. No local replacement for upstream structured
content is introduced.

`ToPrompt` gains generic state and evidence JSON methods. Hand-written instances whose generic
fields cannot be traversed must implement it explicitly; this public class
change needs a compatibility review before release. Existing prompt and routed
request regression tests protect callers that do not use decisions.

Per [ADR-9](0009-centralize-offline-harness-and-diverse-fixtures.md), reusable
decision fixtures and their schema/state acceptance tests live in
`shikumi-testing`. Pure setting tests and compiler rejection fixtures remain in
core. Core tests do not depend on the core-dependent harness, and source
distributions do not use source paths outside their package.
