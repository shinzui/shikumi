---
id: 34
slug: route-and-unify-program-streaming
title: "Route and Unify Program Streaming"
kind: exec-plan
created_at: 2026-07-02T03:30:15Z
intention: "intention_01kwjfe4dhetqa7m7g3n6zq03a"
master_plan: "docs/masterplans/5-core-runtime-correctness-and-wire-fidelity.md"
---

# Route and Unify Program Streaming

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`streamProgram` is shikumi's streaming executor: it runs a typed program, delivers
incremental events (field chunks, status messages) to a callback, and returns the same
typed output the blocking `runProgram` would. Today it only works in hermetic tests.
Against a real provider it is broken three ways. First, the router that gives every
blocking call its real model (`routeLLM`) rewrites only the `Complete` operation, not
`Stream` — so a routed streaming call sends the inert placeholder model (empty model id)
and shikumi's private metadata stamps straight to the transport, which no real provider
accepts. Second, the streaming predict path re-implements the blocking path privately —
it duplicates the `Params`-overlay logic verbatim, skips the schema stamp, and parses with
only the marker adapter instead of the dual-format parser — so it drifts from the blocking
semantics it promises to mirror. Third, stream failures are invisible to resilience: a
provider failure arrives in-band as a terminal `EventError`, the interpreters return it as
data, retry policies never fire, budget is silently charged from error payloads, and the
caller eventually sees a bogus non-transient decode error instead of the real transport
failure.

After this change, `streamProgram` works under `runRouting … routeLLM` exactly as
`runProgram` does (real model id, translated and stripped metadata), shares the blocking
path's signature overlay and parser (one source of truth), and stream failures surface as
typed, mostly-transient `ShikumiError`s that retry policies catch — with budget charging
defined and documented. Provable offline with capturing stubs and scripted event streams.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1 (2026-07-03): `routeLLM` rewrites `Stream` (ambient model + `translateForWire` + key stripping); routed-streaming test added (`RoutingSpec` "routes the ambient model and strips metadata on Stream", green)
- [x] M2 (2026-07-03): `Shikumi.Program` exports `effectiveSignature` and `parseResponse`; `streamPredict` reuses them, `attachSchema`, and `attachNativeRender`; duplicate `effectiveSig` deleted; JSON-stream decode + parity tests added (`StreamSpec`)
- [x] M3 (2026-07-03): interpreters map terminal `EventError` to an out-of-band `ShikumiError` (`raiseStreamError`; budget charged first); `failingStreamStubRegistry`/`failingStreamCostStubRegistry` added to `StubProvider`; three `ResilienceSpec` cases (retry recovers, permanent failure → transient `ProviderFailure`, budget charged on failure)
- [x] Docs (2026-07-03): `LLM.stream` contract, budget-on-error behavior, `Shikumi.Stream.reassemble` unreachability note, and `Shikumi.Routing` header updated; CHANGELOG entry added


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Pinned-baikai deviation from the plan's Decision Log. The plan assumed
  `TerminalPayload` carries a structured `errorInfo :: Maybe BaikaiError` (so
  `streamTerminalError` could call `fromBaikaiError`). The baikai version shikumi
  actually pins (baikai 0.1.x, resolved as baikai-0.1.2.0) has
  `TerminalPayload { reason :: StopReason, message :: Message }` with /no/
  `errorInfo` field — the failure detail lives in the assembled message's
  `errorMessage :: Maybe Text` and `stopReason = ErrorReason`/`Aborted`. So
  `streamTerminalError` maps every stream failure to a transient `ProviderFailure`
  carrying `errorMessage` (or the stop reason), rather than dispatching through
  `fromBaikaiError`. `ProviderFailure` is transient (`isTransient`), so retries
  still fire — the observable posture the plan wanted is unchanged; only the
  ShikumiError constructor differs. Evidence: `cabal build shikumi` succeeded with
  `tp ^. #message`/`tp ^. #reason` but the field `#errorInfo` does not exist in the
  pinned `TerminalPayload`.
- Stub streaming is not derived from `complete`. The plan expected baikai's default
  provider streaming to wrap `complete`, so `failingStubRegistry`'s exception would
  become a single-`EventError` stream. In fact `StubProvider.mkRegistry` sets the
  `stream` field explicitly to a fixed /success/ sequence independent of `complete`,
  so `failingStubRegistry` fails only blocking calls. New stub builders
  `failingStreamStubRegistry` (fail-N-then-succeed) and `failingStreamCostStubRegistry`
  (always fail, cost-carrying terminal) were added, whose `stream` field yields a
  terminal `EventError` directly (via `Stream.concatEffect` for the per-call
  counter). `Streamly.Data.Stream.concatEffect` is available in the pinned streamly.
- Budget-on-error is pre-existing, now documented and pinned. `eventCostUSD` already
  read `EventError` terminals before this plan; M3 keeps that and documents it on
  `chargeBudgetFromEvents`. The behavioral test ("a failed stream still charges the
  budget") pins it end-to-end through `runLLMResilient` without exporting internals:
  a cost-carrying failing stream charges the ceiling, so the next call's optimistic
  budget gate refuses with `BudgetExceeded`.


## Decision Log

- Decision: Stream-error posture: shikumi's `LLM` interpreters (`bareHandler` and the
  `Stream` case of `runLLMResilient`) inspect the collected event list; a terminal
  `EventError` is converted to an out-of-band `throwError` — using
  `fromBaikaiError` on the payload's structured `errorInfo` when present, else
  `ProviderFailure` carrying the payload's stop reason and any error text. The event list
  returned by `Shikumi.LLM.stream` therefore never ends in `EventError`.
  Rationale: baikai deliberately surfaces stream failures in-band
  (`baikai-effectful/src/Baikai/Effectful.hs:68-71`: "Does not throw on provider failure; a
  terminal EventError appears as the last element"), and the policy-free transport is the
  wrong layer to change. Shikumi's `LLM` effect is the policy layer: its blocking path
  already converts `BaikaiError` to `ShikumiError` out-of-band, and `isTransient` +
  `retrying` + program-level `Retry` all dispatch on `ShikumiError` — so in-band errors
  bypass every resilience mechanism shikumi promises. Mapping at the interpreter seam fixes
  all consumers (`streamComplete`, `streamProgram`, and shikumi-eval's usage accounting) at
  once.
  Date: 2026-07-01

- Decision: Budget is charged from the terminal payload (whether `EventDone` or
  `EventError`) before any throw, and this is documented on `LLMConfig.budget` and
  `chargeBudgetFromEvents`.
  Rationale: a failed stream may still have consumed billable tokens, and the terminal
  payload's assembled message carries the usage/cost baikai computed; not charging would
  undercount real spend, silently. Previously error-payload charging happened but was
  undocumented — the fix is to keep it and say so.
  Date: 2026-07-01

- Decision: Reuse the blocking path by exporting `effectiveSignature` and `parseResponse`
  from `Shikumi.Program` (under the existing "Execution internals" export group) rather
  than moving them to a new shared internal module.
  Rationale: `Shikumi.Program` already exports execution internals for alternative
  executors (`retryWith`, `acceptOrReject`, `modal`, `sampleTemps`, `withSampleTemp` — used
  by `shikumi-trace`); this follows the established seam with zero module churn.
  Date: 2026-07-01

- Decision: Soft dependency on EP-33
  (`docs/plans/33-native-adapter-path-and-strict-mode-schemas.md`) acknowledged, not
  required: this plan calls whatever `translateForWire` and `parseResponse` exist at
  implementation time. If EP-33 has landed, `translateForWire` takes and returns the
  `Context` too and the native-render swap applies to streams for free; if not, the current
  `Model -> Options -> Options` version is used and rebasing later is mechanical.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

All three milestones delivered. `streamProgram` now works under
`runRouting … routeLLM` exactly as `runProgram` does: `routeLLM` rewrites the
`Stream` operation through the same widened `translateForWire` (real model id,
translated + stripped metadata, native `Context` swap for native-capable models),
proven by the new `RoutingSpec` routed-stream case. `streamPredict` shares the
blocking path's `effectiveSignature`, schema/native stamps, and `parseResponse` —
the duplicated private `effectiveSig` and fallback-only parse are gone, so a native
JSON stream decodes correctly (new `StreamSpec` cases), and the two predict call
sites are now textually parallel. Stream failures surface out-of-band as transient
`ProviderFailure`s that retry policies catch, with budget charged from the terminal
before the throw (three new `ResilienceSpec` cases). `cabal build all` is
warning-clean and `cabal test all` is green.

Two deviations from the plan, both recorded in Surprises & Discoveries: the pinned
baikai's `TerminalPayload` has no structured `errorInfo`, so stream errors map to
`ProviderFailure` rather than through `fromBaikaiError` (posture unchanged); and the
test stub's `stream` is a fixed success independent of `complete`, so new
failing-stream stub builders were added rather than reusing `failingStubRegistry`.

Integration points honored: EP-33's widened `translateForWire` was reused (not
forked) for the `Stream` case (integration point 3), and the same four metadata keys
are stripped (integration point 4). Cross-initiative: EP-39 (shikumi-eval usage
accounting) can now build on the routed `Stream` and the documented error posture.


## Context and Orientation

This is a cabal multi-package Haskell repo built with GHC 9.12.4 inside the Nix dev shell:
run `nix develop .#ghc9124` from the repository root before any `cabal` command. All
default tests are hermetic. This plan touches only the core `shikumi/` package (sources and
tests).

The layers, bottom to top. `baikai` is the provider transport;
`baikai-effectful` exposes it as the `Baikai` effect, whose `streamCollect` materializes a
streaming call into `[AssistantMessageEvent]` — a list of typed events ending in exactly
one terminal: `EventDone payload` on success or `EventError payload` on any failure
(baikai catches producer exceptions into that in-band terminal by design). The terminal's
`TerminalPayload` carries the assembled `message` (with usage/cost), a `reason ::
StopReason`, and `errorInfo :: Maybe BaikaiError` — the structured error for `EventError`
(`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Stream/Event.hs`, and locally
re-exported types via `import Baikai` — see `shikumi/src/Shikumi/Stream.hs:42-56`).

Shikumi's `LLM` effect (`shikumi/src/Shikumi/LLM.hs:84-97`) has two operations:
`Complete` (blocking) and `Stream` (returns the event list). Two interpreters exist.
`bareHandler` (lines 125-133), shared by `runLLM`/`runLLMWith`:

```haskell
bareHandler = \case
  Complete m c o -> do
    res <- try @BaikaiError (BE.complete m c o)
    either (throwError . fromBaikaiError) pure res
  Stream m c o -> BE.streamCollect m c o
```

— the `Complete` case maps transport errors into `ShikumiError`
(`shikumi/src/Shikumi/Error.hs`, `fromBaikaiError` at lines 46-56, `isTransient` at 62-66);
the `Stream` case maps nothing. `runLLMResilient` (lines 188-210) wraps each operation in
budget gate → rate limit → retry loop; its `Stream` case (202-206) collects events, charges
the budget from the terminal payload (`chargeBudgetFromEvents`, lines 274-287 — note
`eventCostUSD` reads `EventError` payloads too, lines 283-287, undocumented), and returns
the events. Because failures are in-band data, `retrying` (lines 241-254, driven by
`isTransient`) never fires for streams.

Program-level streaming (`shikumi/src/Shikumi/Stream.hs`). `streamProgram` (lines 210-232)
walks the program; each `Predict` leaf goes to `streamPredict` (lines 238-257):

```haskell
streamPredict sig ps i cb = do
  sig' <- effectiveSig sig ps
  let adapter = adapterFor _Model
      (ctx, opts) = render adapter sig' i
      ...
  resp <- streamComplete fieldNm _Model ctx opts cb
  ...
  either throwError pure (parse adapter sig' resp)
```

Three divergences from the blocking path (`runPredict`,
`shikumi/src/Shikumi/Program.hs:304-321`): it does not call `attachSchema`, so the router
can never attach a native `responseFormat` to a streamed call; it parses with the single
fallback adapter instead of `parseResponse`'s dual-format logic (Program.hs:330-339); and
`effectiveSig` (Stream.hs:279-288) is a verbatim private copy of `Program.hs`'s
`effectiveSignature` (lines 413-423) — neither is exported today. `streamComplete` (lines
139-152) drives one `Stream` call and reassembles a `Response` from the terminal event
(`reassemble`, lines 180-187, which currently also accepts `EventError` payloads as a
response source).

The router (`shikumi/src/Shikumi/Routing.hs:83-88`):

```haskell
routeLLM = interpose $ \env -> \case
  Complete _placeholder ctx opts -> do
    m <- currentModel
    complete m ctx (translateForWire m opts)
  other -> passthrough env other
```

The `other` branch forwards `Stream` untouched — its haddock even says "'Stream' is
forwarded unchanged ('runProgram' never streams)", which stopped being true when
`streamProgram` was added. So a routed `streamProgram` sends `_Model` (empty model id) and
the un-stripped `shikumi.responseSchema` metadata to the transport. `translateForWire`
(lines 94-107) is the metadata-to-wire translation (`responseFormat` for native-capable
models, temperature, key stripping).

Test infrastructure you will reuse: `shikumi/test/RoutingSpec.hs` (capturing stub `LLM`
with `routeLLM . runRouting` on top — its stub's `Stream` case currently returns `[]`),
`shikumi/test/StreamSpec.hs` (scripted event-stream interpreter `runStreamingLLM`,
`streamEventsFor` builder, parity assertions against `runProgram`),
`shikumi/test/StubProvider.hs` (hermetic baikai `ProviderRegistry` stubs used by
`shikumi/test/ResilienceSpec.hs`; `failingStubRegistry` fails a fixed number of times then
succeeds — baikai's default streaming derives from `complete`, turning an exception into a
single-`EventError` stream, which is exactly what M3 needs).

Coordination (master plan integration points 2 and 3): EP-32 adds a `Validatable o`
constraint to `streamPredict` — include it here if EP-32 has not landed yet (the reused
`parseResponse` requires it). EP-33 widens `translateForWire` and changes `parseResponse`'s
error behavior; this plan consumes both surfaces as found. Cross-initiative: master plan
6's EP-39 (`docs/plans/39-evaluation-accounting-and-api-tail.md`) consumes the routed
`Stream` operation and the error posture defined here for shikumi-eval's usage accounting.


## Plan of Work

Milestone 1 — route the `Stream` operation. Scope: `Shikumi.Routing` plus a routing test.
At the end, a streamed call under the router carries the ambient model and translated,
stripped options — observably identical policy to `Complete`.

In `shikumi/src/Shikumi/Routing.hs`: import `stream` from `Shikumi.LLM` (the module already
imports `LLM (..)` and `complete`), and replace the `routeLLM` match with an explicit
`Stream` case mirroring `Complete`:

```haskell
routeLLM = interpose $ \env -> \case
  Complete _placeholder ctx opts -> do
    m <- currentModel
    complete m ctx (translateForWire m opts)
  Stream _placeholder ctx opts -> do
    m <- currentModel
    stream m ctx (translateForWire m opts)
  other -> passthrough env other
```

(If EP-33 has landed, `translateForWire` returns `(Context, Options)`; destructure and pass
both, identically in both cases.) Delete the stale "'Stream' is forwarded unchanged"
sentence from the haddock and describe the real rule: both operations are rewritten
identically. Note there is no `other` left to passthrough once both constructors are
matched — GHC will tell you; drop the wildcard if so.

Test, in `shikumi/test/RoutingSpec.hs`: extend the capturing stub so its `Stream` case
records `(Model, Options)` (and `Context` if EP-33's version already records it) and
returns a scripted event list (reuse `StreamSpec.streamEventsFor`'s shape or a minimal
`[EventDone …]`); add case "routes the ambient model and strips metadata on Stream": run
`streamProgram (predict topicToOutline) (Topic "cats") (\_ -> pure ())` under
`runRouting openai_gpt_4o_mini . runCapturingLLM … . routeLLM`, assert the captured model
id equals `openai_gpt_4o_mini`'s, `metaResponseSchemaKey` is absent from the captured
metadata, and (after M2 lands) `responseFormat` is the strict `JsonSchema`. Before the fix
this test fails with the captured model id `""`.

Milestone 2 — one predict path. Scope: `Shikumi.Program` exports, `Shikumi.Stream` reuse,
parity tests. At the end, `streamPredict` and `runPredict` share the overlay, the schema
stamp, and the parser; the duplicate is gone.

In `shikumi/src/Shikumi/Program.hs`: add `effectiveSignature` and `parseResponse` to the
export list under the "Execution internals" group (lines 61-67), with a haddock note that
`Shikumi.Stream` reuses them so the streamed and blocking wire/decode behavior is defined
once.

In `shikumi/src/Shikumi/Stream.hs`, rewrite `streamPredict` (lines 238-257) to mirror
`runPredict` exactly:

```haskell
streamPredict sig ps i cb = do
  sig' <- effectiveSignature sig ps
  let adapter = adapterFor @i @o _Model
      (ctx, opts0) = render adapter sig' i
      opts = attachSchema (deriveSchema @o) opts0
      fieldNm = ...            -- unchanged first-output-field logic
  cb (StreamStatus (Status LmStart "LM call started"))
  resp <- streamComplete fieldNm _Model ctx opts cb
  cb (StreamStatus (Status LmEnd "LM call finished"))
  either throwError pure (parseResponse sig' resp)
```

Concretely: import `effectiveSignature`, `parseResponse` from `Shikumi.Program`; import
`attachSchema` from `Shikumi.Adapter` and `deriveSchema` (plus `ToSchema`, `Validatable`)
from `Shikumi.Schema`; add `Validatable o` to the constraint row if EP-32 has not already;
delete the private `effectiveSig` (lines 276-288) and now-unused imports
(`setDemos`/`setInstruction`/`getInstruction`/`fromModel`/`Demo` — whatever the compiler
flags). If EP-33 has landed, also stamp the native render pieces exactly as `runPredict`
does (call `attachNativeRender` with `nativeRenderPieces @i @o sig'`) — keeping the two
call sites textually parallel is the point of this milestone. Note the pre-existing scope
honesty in the module header (lines 12-28): field chunks remain honest only for the
marker/raw-text wire shape; a native JSON stream still yields chunks of the raw JSON text.
Keep that caveat, updating it to mention that routed native streams now decode correctly
via `parseResponse` even though chunk attribution stays coarse.

Tests, in `shikumi/test/StreamSpec.hs`:

- "streamPredict decodes a native-shaped (JSON) stream": script
  `streamEventsFor ["{\"ans"] "{\"answer\": \"Hello\"}"` — deltas irrelevant, terminal text
  is a JSON object — and assert `streamProgram (predict qToAnswer) …` returns
  `Right (Answer "Hello")`. Fails before (the fallback-only `parse` finds no markers and
  reports `MissingField`), passes after.
- "streamProgram equals runProgram on the same script" already exists (lines 168-178) and
  must keep passing; add a variant with the JSON-shaped script to pin parity through
  `parseResponse` on both paths.
- All existing StreamSpec cases must pass unchanged (the marker-path behavior is
  untouched: `parseResponse` falls back to the marker parser for non-JSON bodies).

Milestone 3 — stream-error posture. Scope: `Shikumi.LLM`, `StubProvider`,
`ResilienceSpec`. At the end, a failing stream throws a typed transient error, retries
fire, and budget behavior is documented and pinned.

In `shikumi/src/Shikumi/LLM.hs` add a shared helper near `chargeBudgetFromEvents`:

```haskell
-- | Enforce the stream-error posture: a terminal 'EventError' becomes an
-- out-of-band 'ShikumiError' ('fromBaikaiError' on the payload's structured
-- 'errorInfo' when present, else 'ProviderFailure' from the stop reason).
-- Successful event lists pass through unchanged, so 'stream' callers never
-- see an in-band error terminal.
raiseStreamError ::
  (Error ShikumiError :> es) => [AssistantMessageEvent] -> Eff es [AssistantMessageEvent]
raiseStreamError evs = case [tp | EventError tp <- evs] of
  (tp : _) -> throwError (streamTerminalError tp)
  [] -> pure evs

streamTerminalError :: TerminalPayload -> ShikumiError
streamTerminalError tp = case tp ^. #errorInfo of
  Just be -> fromBaikaiError be
  Nothing -> ProviderFailure ("stream terminated with EventError: " <> T.pack (show (tp ^. #reason)))
```

(Import `Data.Text qualified as T` and whatever payload accessors are needed; the payload
fields are `reason`, `message`, `errorInfo` — use the `#errorInfo`/`#reason` labels or
pattern matching, matching the file's existing style.) Wire it in both interpreters:
`bareHandler`'s `Stream` case becomes `BE.streamCollect m c o >>= raiseStreamError`;
`runLLMResilient`'s `Stream` case charges the budget first, then raises:

```haskell
Stream m c o ->
  withBudget mb . withRateLimit mr . retrying rp $ do
    evs <- BE.streamCollect m c o
    liftIO (chargeBudgetFromEvents mb evs)
    raiseStreamError evs
```

Because the raise happens inside `retrying`, a transient failure (e.g. `ProviderFailure`
from a 500) is retried with backoff exactly like a blocking call. Document on
`chargeBudgetFromEvents` (and on `LLMConfig`'s `budget` field) that error terminals are
charged too, and why (tokens were billed). Update the `Stream` operation's haddock (lines
84-86) and the `bareHandler` haddock (lines 120-124, which currently documents the in-band
posture) to the new contract: "the returned event list never terminates with `EventError`;
failures surface as `ShikumiError`". In `shikumi/src/Shikumi/Stream.hs`, `reassemble`'s
`EventError` branch (lines 185-187) becomes unreachable through shikumi's interpreters —
keep it for robustness against third-party interpreters, with a haddock note.

Test infrastructure: `shikumi/test/StubProvider.hs`'s `failingStubRegistry` builds a
provider whose `complete` throws a transient `BaikaiError` a fixed number of times then
succeeds; baikai's default provider streaming wraps `complete`, so an exception becomes a
single-`EventError` stream — no new provider code should be needed. Verify its streamed
success shape carries a terminal `EventDone` (if the stub only implements `complete`,
baikai synthesizes the stream). Tests, in `shikumi/test/ResilienceSpec.hs`, mirroring the
existing blocking cases (lines 43-80):

- "stream retry recovers after 2 failures": `failingStubRegistry` with 2 failures,
  `runLLMResilient` with `maxAttempts = 3`; call `stream stubModel stubContext stubOptions`
  and assert a `Right` event list whose terminal is `EventDone`. Fails before (returns
  `Right` on the first attempt with an `EventError` terminal and never retries), passes
  after.
- "stream failure surfaces a transient ShikumiError": always-failing registry
  (`invalidStubRegistry` is non-transient; use whichever pins the intended mapping — add
  one case for `errorInfo`-carrying failures mapping through `fromBaikaiError`, one for
  the `ProviderFailure` fallback if scriptable).
- "stream failure still charges the budget": cost-carrying failing stub if
  `costStubRegistry` can be combined with failure; if the stub cannot attach cost to an
  error terminal, pin the behavior with a unit test on `chargeBudgetFromEvents` over a
  hand-built `[EventError (errorTerminal …)]` list instead, and record that choice in
  Surprises & Discoveries.

Also update `shikumi/test/StreamSpec.hs` if any scripted stream there relied on an
`EventError` reaching `reassemble` (survey says none do — the scripts all use
`EventDone`).


## Concrete Steps

All commands run from the repository root (`/Users/shinzui/Keikaku/bokuno/shikumi`),
inside the dev shell (GHC 9.12.4 is required and only the shell provides it):

```bash
nix develop .#ghc9124
cabal build shikumi
cabal test shikumi          # or: just test-one shikumi
```

Suggested order: M1 → M2 → M3, each with its tests written first so they fail before the
edit. Expected failing output for M1's routing test before the fix:

```text
  routes the ambient model and strips metadata on Stream: FAIL
    expected: "gpt-4o-mini"
     but got: ""
```

Focused runs while iterating:

```bash
cabal test shikumi --test-options='-p Routing'
cabal test shikumi --test-options='-p Stream'
cabal test shikumi --test-options='-p Resilience'
```

Finish with the full matrix:

```bash
cabal build all && cabal test all
```

Every commit uses a conventional-commit subject and MUST carry these trailers:

```text
MasterPlan: docs/masterplans/5-core-runtime-correctness-and-wire-fidelity.md
ExecPlan: docs/plans/34-route-and-unify-program-streaming.md
Intention: intention_01kwjfe4dhetqa7m7g3n6zq03a
```

Suggested split, one commit per milestone: `fix(routing): rewrite the Stream op like
Complete`, `refactor(stream): reuse effectiveSignature/attachSchema/parseResponse in
streamPredict`, `fix(llm): surface stream failures out-of-band so retries and budget
behave`.


## Validation and Acceptance

Acceptance is behavioral, all offline:

1. Routing: under `runRouting openai_gpt_4o_mini … routeLLM`, a `streamProgram` run issues
   `Stream` calls carrying the ambient model id, no `shikumi.*` metadata keys, and (with
   M2) the strict `JsonSchema` `responseFormat`. Fails before with model id `""` and leaked
   metadata.
2. Parity: for the same scripted events, `streamProgram` returns exactly what `runProgram`
   returns — pinned for both the marker-shaped and the JSON-shaped terminal body. The
   JSON-shaped case fails before M2 with a `MissingField` error.
3. Resilience: through `runLLMResilient` over a stub provider that fails twice then
   succeeds, `stream` returns a successful event list (retries fired — fails before because
   the error was in-band); a permanently failing stream returns
   `Left (ProviderFailure …)`/the mapped `ShikumiError` rather than `Right` events ending
   in `EventError`; budget accounting over error terminals is pinned by test.
4. No regression: `cabal test all` passes; in particular every pre-existing StreamSpec,
   RoutingSpec, ResilienceSpec, and LLMSpec case is green, and `runProgram`'s blocking
   contract is untouched (no signature changes to it).


## Idempotence and Recovery

All edits are additive or local rewrites verified by hermetic tests; re-running builds and
tests is safe. The milestones are independent commits — if M3's posture change surfaces an
unexpected downstream reliance on in-band `EventError` lists (e.g. a consumer in another
package pattern-matching `EventError` from `Shikumi.LLM.stream` — survey with
`grep -rn "EventError" --include='*.hs' shikumi* | grep -v dist-newstyle | grep -v baikai`
before starting), record it in Surprises & Discoveries and adapt that consumer in the same
commit. Each milestone can be reverted independently; M1 and M2 have no behavioral coupling
to M3.


## Interfaces and Dependencies

End state per milestone (full module paths):

- M1 — `Shikumi.Routing.routeLLM :: (Routing :> es, LLM :> es) => Eff es a -> Eff es a`
  (unchanged signature) rewrites both `Complete` and `Stream` through the single
  `translateForWire` (whichever arity EP-33 has left it — do not fork a second
  translation function; master plan integration point 3).
- M2 — `Shikumi.Program` additionally exports
  `effectiveSignature :: (FromModel i, FromModel o, Error ShikumiError :> es) =>
  Signature i o -> Params -> Eff es (Signature i o)` and
  `parseResponse :: (FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o) =>
  Signature i o -> Response -> Either ShikumiError o`.
  `Shikumi.Stream.streamPredict` consumes them; its private `effectiveSig` is deleted; its
  constraint row includes `ToSchema o` and `Validatable o` (coordinate with EP-32, master
  plan integration point 2).
- M3 — `Shikumi.LLM.stream :: (LLM :> es) => Model -> Context -> Options ->
  Eff es [AssistantMessageEvent]` (unchanged signature) with the new documented contract:
  the list never terminates in `EventError`; failures are `ShikumiError`s thrown through
  `Error ShikumiError`. Internal helpers `raiseStreamError` / `streamTerminalError` need
  not be exported.

Dependencies: only existing ones — `baikai` / `baikai-effectful` (event algebra:
`AssistantMessageEvent (..)`, `TerminalPayload` with `reason`/`message`/`errorInfo`;
`streamCollect` semantics as described in Context), `effectful` (`interpose`,
`Error`), and the in-repo test stubs. Consumers to keep in mind: `shikumi-eval`'s
stream-usage accounting (master plan 6, EP-39) builds on this plan's routed `Stream` and
error posture — do not change the `LLM` effect's operation shapes.
