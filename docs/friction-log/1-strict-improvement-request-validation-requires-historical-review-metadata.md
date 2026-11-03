---
type: Friction Entry
title: "Strict improvement-request validation requires historical review metadata"
description: "Strict validation of the improvement-request bundle fails on missing recommended review provenance in existing requests, beyond the runtime changes being implemented."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-03T04:46:51Z"
frictionId: FRIC-1
status: "accepted"
impact: nuisance
kind: documentation
origin: "mori://shinzui/shikumi"
affects: "mori://shinzui/shikumi/okf/improvement-requests"
plan: "docs/plans/68-support-streamed-judgment-programs-with-typed-result-parity.md"
workaround: "Preserve historical provenance; record current IR-5 technical verification without inventing old reviews, and report the remaining baseline diagnostics"
resolution: "Preserve historical review provenance rather than invent reviews for unchanged requests; IR-5 now records the current technical verification, and the three baseline diagnostics remain visible."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-03T04:47:10Z"
    change: "Accepted the pre-existing strict review-metadata diagnostics outside the runtime and release gates"
---
# Strict improvement-request validation requires historical review metadata

## Attempted

Validate updated IR-3 and IR-5 with strict profile and log enforcement

## Encountered

Existing IR-1, IR-2 and IR-4 lack the profile-recommended reviews field; IR-5 also had no review record at creation

```text
profile: enforce-typed-output-schemas-on-cli-providers: missing profile-recommended field: reviews
```

## Workaround

Preserve historical provenance; record current IR-5 technical verification without inventing old reviews, and report the remaining baseline diagnostics
