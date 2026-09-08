---
title: "Invocation-scoped request defaults"
type: Capability
description: "Apply fill-only thinking, speed, token, and evidence defaults across every language-model call in a scope, without overriding options a call already set."
generated:
  by: claude/opus-5
  at: "2026-09-08T19:15:51Z"
capabilityId: CAP-24
provider: mori://shinzui/shikumi
status: shipped
stability: experimental
since: "0.4.0.0"
packages:
  - shikumi
interface:
  - Shikumi.LLM.Defaults
requires:
  - CAP-4
evidence:
  - kind: test
    resource: shikumi/test/RequestDefaultsSpec.hs
    proves: Defaults fill only unset options for blocking and streaming calls, never override an explicit per-call option, and zero ceilings are rejected with a validation failure.
  - kind: example
    resource: shikumi-jitsurei/app/RequestDefaults.hs
    proves: A runnable program installs scoped defaults over a composed runtime and shows the effective options reaching the provider.
  - kind: guide
    resource: docs/adr/0012-apply-request-defaults-before-cache-and-observation.md
    proves: Records why defaults are applied beneath caching so cache keys reflect effective rather than requested options.
---

# Invocation-scoped request defaults

`withRequestDefaults` wraps a runtime so that every language-model call inside
the scope — blocking or streaming, issued by a program, an agent, or an
optimizer — inherits defaults for thinking budget, inference speed, token
ceilings, and evidence collection.

Precedence is *fill-only*: a default supplies a value only where the call left
that option unset. A call that names its own thinking budget keeps it. This
makes defaults safe to install broadly, because installing one cannot silently
change the meaning of a call that was already explicit.

Placement matters and is part of the contract. Defaults are applied beneath the
cache and observation layers, so a cache key reflects the options that actually
reach the provider rather than the sparser options the caller wrote. Compose
the base interpreter with cache and trace, then `withRequestDefaults`, then
routing.

This refines the runtime composition described in
[CAP-4 ambient routing and resilient runtime policies](resilient-runtime-routing.md)
and changes the key material used by
[CAP-8 content-addressed response caching](content-addressed-response-cache.md).

## Limits

- Fill-only by design. There is no override mode; a scope cannot force an option
  onto a call that set it.
- A zero default ceiling is a `ValidationFailure`, not a silent no-op.
- Wrapper order is significant. Installing defaults above the cache would key
  entries on requested rather than effective options; the documented order is
  the supported one.
- Defaults describe request options only. They do not select a model — that
  remains routing's job.
