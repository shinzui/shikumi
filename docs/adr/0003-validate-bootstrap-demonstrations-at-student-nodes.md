---
type: Architecture Decision Record
title: Validate bootstrap demonstrations at student nodes
description: Recover accepted teacher invocations into explicit student-node pools with schema preflight and target decoding rather than broadcasting outer examples.
docId: ADR-3
status: Accepted
date: 2026-09-07
timestamp: 2026-09-07T02:33:00Z
generated:
  by: process:codex
  at: 2026-09-07T02:33:00Z
---

# Validate bootstrap demonstrations at student nodes

## Context

A question-to-city-to-country pipeline needs question/city demos at its first
predictor and city/country demos at its second. Broadcasting outer question/country
pairs installs invalid parameters. Positional matching alone also cannot establish
compatibility with a differently structured teacher. See [ADR-2](0002-keep-capture-codecs-in-templates-and-isolate-observations.md)
for typed capture and rejected-attempt lineage.

## Decision

Bootstrap returns an ordered demo pool keyed by student NodePath. Automatic mapping
requires equal program shapes and paths plus equal input/output schema evidence.
Different structures require explicit teacher-to-student path pairs. All paths
and schemas are checked before model calls; duplicate targets require explicit
merge consent. Every recovered input and output must additionally pass the target
leaf's FromModel decoders. Custom codec declarations alone are insufficient.

Only metric-passing completed teacher examples and eligible successful invocations
contribute demos. Caps apply independently per target. Default selection preserves
encounter order and stops when mapped pools are full. Seeded selection collects
within the shared predicted-call budget, then uses independent streams derived
from the seed and stable target path. RandomSearch and MIPRO consume these pools;
MIPRO uses labeled outer examples only for a bare single prediction.

Ordinary single predictions retain a compatibility adapter using outer ToJSON
encoders and statically equal outer types. It does not generalize to composites.
Composite teachers and students require captured leaves. bootstrapKeptDemos keeps
its outer single-predictor meaning and rejects composites. Missing codecs,
incompatible mappings and runtime decode failures never fall back to global demo
broadcast. Embed limits are reported explicitly.

## Consequences

BootstrapConfig remains source compatible; NodeBootstrapConfig adds mappings,
merge consent and seeds. Existing composite callers must opt into capture and
possibly supply explicit mappings. The public low-level node recovery function
can map differently typed teacher/student roots because only leaf schemas and
target decoding govern installation.

Parameter artifacts stay unchanged and restore onto caller-owned templates.
The deterministic city/country fixture runs and restores with exact per-node
demos; mapping, merge, custom-codec and independent-seed tests exercise rejection
and selection. Budget accounting remains predicted calls as before; this change
does not introduce admission accounting for retry or map expansions.
