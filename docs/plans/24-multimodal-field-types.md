---
id: 24
slug: multimodal-field-types
title: "Multimodal field types"
kind: exec-plan
created_at: 2026-06-09T22:35:42Z
intention: "intention_01ktq812wfebgvf1dtbvg3v826"
master_plan: "docs/masterplans/4-shikumi-richer-io-and-multimodal.md"
---

# Multimodal field types

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shikumi today is a *text-in, text-out* framework. A program's input is a Haskell record
whose fields are all rendered to a single block of prompt text, and the model only ever sees
that text. If you want a model to *look at an image*, there is no way to express it: you would
have to base64-encode the image, paste the gigantic string into a `Text` field, and hope the
model treats it as an image — which it will not, because the provider needs the image in a
dedicated image content block, not in the running prose.

After this change, a Shikumi signature's **input** can contain a typed `Image` field. When the
program runs, that image is lowered into baikai's native image content block
(`Baikai.Content.UserImage`/`ImageContent`), so the provider actually receives the picture as
an image — exactly as if you had attached it in a chat client — while the other (text) fields
continue to render as prompt text as they do now. Concretely, a user will be able to write a
signature like this and have the model genuinely *see* the picture:

```haskell
data Describe = Describe
  { image :: Image,
    question :: Field "What to ask about the image" Text
  }
  deriving stock (Generic, Show)

data Answer = Answer
  { answer :: Field "A short answer to the question" Text
  }
  deriving stock (Generic, Show, Eq)
```

You can see it working in three observable ways, all hermetic (no network):

1. Construct an `Image` from a PNG file on disk (or from a base64 string) and confirm the
   decoded bytes and MIME type round-trip into a baikai `ImageContent`.
2. Render the `Describe` signature with a concrete `Describe` input through the `Adapter`'s
   `render` function and inspect the resulting baikai `Context`: it contains a `UserImage`
   block carrying the exact image bytes and MIME type, *plus* the text for `question` — and
   the existing all-text path is byte-for-byte unchanged.
3. Run a `Describe -> Answer` program against a **stub** language model that records the
   `Context` it was handed. The stub asserts it received an image block, returns a canned JSON
   answer, and the program decodes that JSON into a typed `Answer`.

**Scope decision (honesty about provider limits).** baikai's user-message content type models
exactly two cases today — text and image:

```haskell
data UserContent = UserText !TextContent | UserImage !ImageContent
```

There is **no** audio, video, or document constructor in `Baikai.Content`. Therefore this plan
ships **image** as the fully-delivered medium and **does not** pretend to deliver audio or
documents. Audio/document support is *upstream-gated*: it would require adding a new
constructor to baikai's `UserContent` (a change in the separate baikai repository at
`/Users/shinzui/Keikaku/bokuno/baikai`) before Shikumi could lower such a field to anything the
model can see. The plan documents that upstream path precisely (see "Audio and document:
upstream-gated future work") but does not implement it, because a field that compiles but
cannot be transmitted would be a hollow feature. This matches the parent MasterPlan's Decision
Log entry "Bound multimodal scope by baikai's existing `Content`".


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: `Image` type with `imageFromFile`/`imageFromBase64`/`imageFromBytes` constructors and
      `imageToContent`; hermetic round-trip test (file/base64 -> `ImageContent` bytes + MIME).
      Done: `Shikumi.Multimodal` created; `MultimodalSpec` passes (2/2).
- [x] M2: Generic derivations treat an image field as input-only metadata; `render` lowers an
      image-bearing input to a `Context` containing a `UserImage` block alongside the text fields;
      assertion test on the built `Context`. Done: image collection folded into `ToPrompt`
      (`imageFields`/`imageFieldNames` methods with generic defaults, backed by `GImageFields`/
      `GImageFieldNames` in `Shikumi.Multimodal`); `userTurn` in `Shikumi.Adapter` lowers the first
      image to `userImage`; `MultimodalAdapterSpec` passes (3/3). Whole workspace (`cabal build all`)
      builds with **zero** fixture changes.
- [ ] M3: End-to-end stub test — `Describe { image, question } -> Answer { ... }` runs under a
      stub LM that captures and asserts the image block, then decodes the structured `Answer`;
      regression test that the all-text path's `Context` is unchanged.
- [ ] Docs: "Audio and document: upstream-gated future work" section kept accurate; MasterPlan
      registry row for EP-24 flipped to Complete on completion.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **M1: used `directory`'s `getTemporaryDirectory` + base's `openTempFile`, not `temporary`.**
  `temporary` is not in the global package db (and probing the cabal plan was inconclusive),
  while `directory` (1.3.10.1) and `filepath` (1.5.5.0) are GHC boot libraries already present.
  Using them keeps `MultimodalSpec` hermetic with no new third-party test dependency. Evidence:
  `MultimodalSpec` passes 2/2 with only `bytestring`/`base64-bytestring`/`directory` added to the
  test suite's `build-depends`.
- **M2: image collection lives on `ToPrompt`, not a separate `ImageFields` class (revises the
  Decision Log entry below).** The plan sketched a standalone `ImageFields` class with generic
  defaults plus a blanket `OVERLAPPABLE` instance so `Generic` input fixtures got it free. Two hard
  facts killed that: (1) an `OVERLAPPABLE` blanket *poisons given-resolution* — inside `runPredict`
  the given `ImageFields i` is not used to discharge `adapterFor`'s wanted `ImageFields i`; GHC
  reaches for the blanket and demands `Generic i` (GHC-39999). (2) Polymorphic-field records that
  must be Predict inputs — `Shikumi.Refine.MultiChainInput i o`, `Shikumi.Module.WithReasoning o` —
  cannot be walked generically at all (`ImageLeaf i` is unresolvable for a skolem because `i` might
  be `Image`), so they need a manual instance, which *requires* the blanket to be overlappable,
  which re-triggers (1). The fix: fold `imageFields`/`imageFieldNames` into the existing `ToPrompt`
  class as methods with generic defaults. Because `ToPrompt i` is *already* the constraint threaded
  through `predict`/`Predict`/`adapterFor`, **no new constraint is added anywhere**, and every
  existing `ToPrompt` instance (empty, derived-anyclass, or hand-written on a concrete type) gets the
  generic default for free. The only hand edits are `imageFields _ = []; imageFieldNames _ = []` on
  the two polymorphic-field instances (`WithReasoning`, `MultiChainInput`). Evidence: `cabal build
  all` is green with zero downstream package edits. The text path stays provably untouched (the
  regression invariant): `userTurn` still falls back to `user (toPrompt i)` whenever `imageFields i`
  is `[]`, which it is for every image-free record.
- **M1: `imageToContent` is a plain record build, not a generic-lens update.** Since
  `ImageContent(..)` is exported from `Baikai` and both `Image` and `ImageContent` store decoded
  bytes, `ImageContent {imageData = …, mimeType = …}` is clearer than the `_ImageContent & #… .~ …`
  sketch and sets both fields (no `-Wpartial-fields` risk).


## Decision Log

Record every decision made while working on the plan.

- Decision: Ship image only; document audio/document as upstream-gated (option (a) from the
  MasterPlan brief), not implemented here.
  Rationale: baikai's `UserContent` has only `UserText`/`UserImage`. A non-image media field
  would compile but could never reach the model. Honesty about provider limits beats a hollow
  feature.
  Date: 2026-06-09.
- Decision: An `Image` field is **input-only**. It contributes nothing to the output JSON
  schema (`ToSchema`) and is *not* rendered as a text key/value in the prompt body (`ToPrompt`);
  instead it is lowered to a separate `UserImage` content block in `render`.
  Rationale: a model cannot *emit* raw image bytes through Shikumi's structured-output decode
  path (`FromModel`), and embedding base64 in the running prose defeats the purpose. The image
  belongs in its own content block, the way every provider expects.
  Date: 2026-06-09.
- Decision: The image collector is a new generic traversal (`ImageFields`) living in
  `Shikumi.Multimodal`, kept separate from the existing `ToPrompt`/`ToSchema` walks rather than
  overloading them, so the all-text path is provably untouched.
  Rationale: minimises blast radius and lets the regression test assert byte-for-byte identical
  output for image-free inputs.
  Date: 2026-06-09.
- Decision (SUPERSEDES the entry above, made during M2 implementation): the image collection is
  exposed as two methods on the existing `ToPrompt` class (`imageFields`, `imageFieldNames`) with
  generic defaults, *not* a separate constraint-bearing class. The generic machinery
  (`GImageFields`/`GImageFieldNames`/`ImageLeaf`) still lives in `Shikumi.Multimodal`; only the
  class methods moved onto `ToPrompt`.
  Rationale: a separate `ImageFields` constraint forced a blanket `OVERLAPPABLE` instance to avoid
  per-fixture churn, but that instance poisons given-resolution (GHC-39999: `runPredict`'s given
  `ImageFields i` is not used to discharge `adapterFor`'s wanted one, demanding `Generic i`), and
  polymorphic-field Predict inputs (`MultiChainInput`, `WithReasoning`) cannot be walked generically
  so they need a manual instance that *requires* the poisoning overlap. Folding into `ToPrompt`
  reuses the `ToPrompt i` constraint already threaded everywhere — zero new constraints, zero
  fixture churn (`cabal build all` green untouched) — while preserving the all-text regression
  invariant (`userTurn` falls back to `user (toPrompt i)` when `imageFields i == []`). See the M2
  Surprises entry for the full evidence.
  Date: 2026-06-09.
- Decision: Coordinate with EP-26 (`docs/plans/26-adapter-completeness-and-declarative-field-constraints.md`)
  on the shared schema/adapter seam (MasterPlan Integration Point #1): EP-24 owns the
  *media-field* mechanism; EP-26 owns the *constraint* mechanism. EP-24 adds new code paths
  (the `Image` type, `ImageFields`, image-aware `render`) without altering the existing
  text-field rendering that EP-26 also edits, so neither plan breaks the other.
  Rationale: both plans touch `Shikumi.Schema`/`Shikumi.Adapter`; explicit seam ownership
  prevents collisions.
  Date: 2026-06-09.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

Shikumi is a Haskell framework for writing *typed language-model programs*. A "program" is an
ordinary Haskell value that, when run, calls a language model and returns a typed result. The
work in this plan lives in the `shikumi` package at
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi`. The transport layer it sits on is a separate
library, **baikai**, at `/Users/shinzui/Keikaku/bokuno/baikai`, which knows how to talk to
language-model providers. You will only *read* baikai here; you will not modify it.

### The pieces you will touch, by full path

A **signature** is a record describing a task: its instruction text and the *input* and
*output* record types. It is defined in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Signature.hs`:

```haskell
data Signature i o = Signature
  { instruction :: Text,
    demos :: [Demo i o],
    inputFields :: [FieldMeta],
    outputFields :: [FieldMeta]
  }
```

The type parameters `i` and `o` are the input and output record types. `inputFields` and
`outputFields` are derived metadata (a list of field name + optional description), computed by a
generic traversal `fieldMetasOf`.

The **schema engine** lives in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Schema.hs` and
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Schema/Types.hs`. It has three
type-classes you must understand:

- `ToSchema a` — turns a record type into a provider JSON Schema (used for the *output* type so
  the model knows the shape to return). Generic default walks the record fields.
- `FromModel a` — totally decodes a provider's JSON reply back into a record. Used for the
  *output* type.
- `Validatable a` — a post-decode domain check, defaulting to "always valid".

A field can carry a compile-time description via the `Field` wrapper (in `Schema/Types.hs`):

```haskell
newtype Field (desc :: Symbol) a = Field {unField :: a}
```

So `Field "What to ask about the image" Text` is just a `Text` with an attached description
recovered generically; `field :: a -> Field desc a` is its smart constructor. A bare field with
no description is just the raw type (e.g. `Text`).

The **adapter** lives in
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Adapter.hs`. An adapter is a record
of two functions:

```haskell
data Adapter i o = Adapter
  { render :: Signature i o -> i -> (Context, Options),
    parse :: Signature i o -> Response -> Either ShikumiError o
  }
```

`render` is the function this plan extends. Today it takes the signature and a concrete input
value `i`, and builds a baikai `Context` (the conversation) plus `Options` (per-call knobs). The
class `ToPrompt i` is how the *input* record becomes prompt text:

```haskell
class ToPrompt a where
  toPromptFields :: a -> [(Text, Text)]   -- (fieldName, valueText) pairs
  toPrompt :: a -> Text                   -- joins them as "name: value" lines
```

The two shipped adapters, `nativeAdapter` and `fallbackAdapter`, both build the user turn the
same way, via a single line inside `render`:

```haskell
ctx = buildContext sys (demoMessages sig ++ [user (toPrompt i)])
```

Here `user :: Text -> Message` (from baikai) wraps the text in a one-block user message. **This
is the exact line this plan changes**: instead of always producing one text-only user message,
`render` must produce a user message that *also* contains a `UserImage` block whenever the input
record has an image field.

The **baikai content layer** is at
`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Content.hs`. The relevant types:

```haskell
data ImageContent = ImageContent
  { imageData :: !ByteString,   -- DECODED bytes, not base64
    mimeType :: !Text
  }

data UserContent = UserText !TextContent | UserImage !ImageContent
```

Critically, `ImageContent.imageData` holds **decoded** bytes. baikai handles base64 encoding on
the wire itself (its `ToJSON ImageContent` instance base64-encodes under a `data` key). So when
Shikumi builds an `ImageContent`, it must supply the *raw decoded bytes*, never a base64 string.

baikai's message constructors are at
`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Message.hs`. The ones you need:

```haskell
user      :: Text -> Message                       -- one text block, fixture timestamp
userImage :: ImageContent -> Maybe Text -> Message -- optional leading text + one image block
```

`userImage img (Just "some text")` builds a user message whose `content` vector is
`[UserText (TextContent "some text"), UserImage img]` — exactly the shape this plan needs (the
text fields rendered first, the image attached after). Both `userImage` and `ImageContent(..)`
are re-exported from the top-level `Baikai` module (it re-exports `module Baikai.Content` and
`module Baikai.Message`), so `import Baikai (...)` is enough.

The baikai `Context` is at
`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Context.hs`:

```haskell
data Context = Context
  { systemPrompt :: !(Maybe Text),
    messages :: !(Vector Message),
    tools :: !(Vector Tool)
  }
```

So a `Context` carries a vector of `Message`s; each user `Message` carries a vector of
`UserContent` blocks. To "assert the Context contains the image", a test walks `messages`, finds
the `UserMessage`, and looks for a `UserImage` block inside its content vector.

### The text-only path you must not break (regression invariant)

For an input record with **no** image field, `render` must produce exactly the same `Context` it
produces today: one text-only user message built from `user (toPrompt i)`, preceded by the demo
messages and the system header. The plan achieves this by making the image-aware behaviour a
*conditional*: if the input has zero image fields, fall back verbatim to `user (toPrompt i)`.
The regression test in M3 asserts this by comparing the `Context` for an image-free input
against a snapshot built with the current code path.

### Terms defined

- **Lowering** — translating a high-level Shikumi value (an `Image` field) into the low-level
  baikai wire value (`UserImage`/`ImageContent`) that the provider actually receives.
- **Hermetic test** — a test that runs entirely in-process with no network and no API key, by
  using a stub model that returns canned responses. The existing `StubProvider` and the fake
  `LLM` interpreters in the test suite are examples.
- **Content block** — one element of a message's content vector; a user message can hold text
  blocks (`UserText`) and image blocks (`UserImage`).

### Build and test facts (apply to every milestone)

All builds and tests run inside the project's Nix development shell for GHC 9.12.4. From the
repository root `/Users/shinzui/Keikaku/bokuno/shikumi`:

```bash
nix develop .#ghc9124 --command cabal build shikumi
nix develop .#ghc9124 --command cabal test shikumi
```

To run the whole workspace's tests:

```bash
nix develop .#ghc9124 --command cabal test all
```

Source is formatted with **fourmolu** at two-space indentation (the project default). Format any
file you touch:

```bash
nix develop .#ghc9124 --command fourmolu --mode inplace shikumi/src/Shikumi/Multimodal.hs
```

The `shikumi` package's GHC options include `-Wall -Werror`-adjacent warnings (notably
`-Wmissing-export-lists`, `-Wmissing-deriving-strategies`, `-Wpartial-fields`), so every new
module needs an explicit export list, every `deriving` needs a `stock`/`anyclass`/`newtype`
strategy, and you must avoid partial record fields. The default language is `GHC2024` with
`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings` on by default
(see `shikumi/shikumi.cabal`).

Every commit you make carries three trailers (matching this repository's convention), for
example:

```text
feat(shikumi): add Image multimodal field type (M1)

MasterPlan: docs/masterplans/4-shikumi-richer-io-and-multimodal.md
ExecPlan: docs/plans/24-multimodal-field-types.md
Intention: intention_01ktq812wfebgvf1dtbvg3v826
```

Commit directly to the current branch (`master`); do not open a feature branch.


## Plan of Work

The work is three milestones. M1 introduces the `Image` value type and proves it round-trips
into baikai's `ImageContent`. M2 teaches the schema/adapter seam to recognise an image field and
makes `render` lower it to a `UserImage` block while leaving the text path intact. M3 ties it
together end-to-end against a stub model that inspects the image it received, and locks in the
regression invariant. Each milestone is independently verifiable with the exact commands and
expected outputs given in "Concrete Steps".

### Milestone 1 — the `Image` type and its lowering to `ImageContent`

**Scope.** Create a new module `Shikumi.Multimodal` exporting an `Image` type that carries
decoded bytes plus a MIME type, with smart constructors from a file path, from a base64 string,
and from raw bytes, and a single lowering function to baikai's `ImageContent`. Add a hermetic
test proving a file and a base64 string both produce an `ImageContent` whose `imageData` is the
exact decoded bytes and whose `mimeType` is correct.

**What will exist at the end.** A compiling `Shikumi.Multimodal` module and a `MultimodalSpec`
test that passes, demonstrating the round-trip.

Create `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Multimodal.hs`. The `Image`
type stores decoded bytes (mirroring `ImageContent`, which stores decoded bytes too — base64 is
purely a wire concern handled inside baikai):

```haskell
-- | A typed image usable as a *signature input* field. Stores decoded bytes and
-- a MIME type; base64 is a wire detail handled by baikai when the image is sent.
data Image = Image
  { imageBytes :: !ByteString,
    imageMime :: !Text
  }
  deriving stock (Eq, Show, Generic)
```

Provide three smart constructors. `imageFromBytes` is the primitive; the other two normalise
into it. For `imageFromFile`, read the file's raw bytes and infer the MIME type from the file
extension (a tiny fixed table is sufficient and keeps the function pure-of-dependencies; do not
pull in a MIME database). For `imageFromBase64`, decode the base64 text to bytes, returning a
located error on failure:

```haskell
-- | Build an image from already-decoded bytes and an explicit MIME type.
imageFromBytes :: Text -> ByteString -> Image
imageFromBytes mime bs = Image {imageBytes = bs, imageMime = mime}

-- | Read an image file from disk; infer the MIME type from the extension.
-- Returns 'Left' (a 'ShikumiError') if the extension is unrecognised.
imageFromFile :: FilePath -> IO (Either ShikumiError Image)

-- | Decode a base64 string into an image with the given MIME type.
-- Returns 'Left' (an 'InvalidJSON'-style decode error) if the base64 is malformed.
imageFromBase64 :: Text -> Text -> Either ShikumiError Image  -- mime, base64
```

For MIME inference use a small fixed mapping: `.png -> "image/png"`, `.jpg`/`.jpeg ->
"image/jpeg"`, `.gif -> "image/gif"`, `.webp -> "image/webp"`. An unrecognised extension yields
`Left (SchemaMismatch "unsupported image extension: …")` (reuse `Shikumi.Error.ShikumiError`;
`SchemaMismatch` already carries a `Text`). For base64 decoding use
`Data.ByteString.Base64.decode` from the `base64-bytestring` library (already a transitive
dependency through baikai, which uses `Data.ByteString.Base64`); a `Left` from `decode` becomes
`Left (InvalidJSON "image base64 decode: …")`.

The lowering function turns an `Image` into baikai's `ImageContent`. Because both store decoded
bytes, this is a direct field copy — *no encoding happens here*:

```haskell
-- | Lower an 'Image' into baikai's wire image block. Bytes pass through
-- decoded; baikai base64-encodes them only when serialising to the wire.
imageToContent :: Image -> ImageContent
imageToContent img =
  _ImageContent & #imageData .~ imageBytes img & #mimeType .~ imageMime img
```

(`_ImageContent`, `ImageContent(..)`, and the generic-lens labels are all available via
`import Baikai (...)` and `Data.Generics.Labels`.)

Register the module in `shikumi/shikumi.cabal` under the library's `exposed-modules` (add
`Shikumi.Multimodal`), and add `base64-bytestring` to the library `build-depends` if it is not
already directly listed (baikai depends on it; add it explicitly to be safe since GHC needs the
direct dependency to import `Data.ByteString.Base64`). Also add `directory`/`bytestring` as
needed for file reading — `bytestring` is already a dependency.

Add the test module `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/test/MultimodalSpec.hs` and
register it in the test-suite `other-modules`. The test proves the round-trip with a tiny known
byte string. Write the bytes to a temp file, read them back via `imageFromFile`, and assert
equality; independently base64-encode the same bytes, decode via `imageFromBase64`, and assert
equality; lower both to `ImageContent` and assert `imageData`/`mimeType`:

```haskell
tests :: TestTree
tests =
  testGroup
    "MultimodalSpec"
    [ testCase "imageFromBase64 round-trips decoded bytes into ImageContent" $ do
        let raw = BS.pack [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] -- PNG magic
            b64 = decodeUtf8 (Base64.encode raw)
        img <- either (assertFailure . show) pure (imageFromBase64 "image/png" b64)
        imageBytes img @?= raw
        let ic = imageToContent img
        ic ^. #imageData @?= raw
        ic ^. #mimeType @?= "image/png",
      testCase "imageFromFile reads bytes and infers MIME from .png" $
        withSystemTempFile "shikumi-img.png" $ \fp h -> do
          let raw = BS.pack [0x89, 0x50, 0x4e, 0x47]
          BS.hPut h raw >> hClose h
          res <- imageFromFile fp
          img <- either (assertFailure . show) pure res
          imageBytes img @?= raw
          imageMime img @?= "image/png"
    ]
```

(Use `temporary`'s `withSystemTempFile` — it is already available in the test toolchain; if not,
write to a path under `getTemporaryDirectory` and clean up. Either way the test stays hermetic.)

**Acceptance.** `cabal test shikumi` runs `MultimodalSpec` and it passes; the round-trip
assertions confirm that decoded bytes survive file/base64 ingestion and reach `ImageContent`
unchanged.

### Milestone 2 — generic recognition of an image field and image-aware `render`

**Scope.** Make the schema/adapter seam treat an `Image` field correctly: it is *input-only*
metadata that (a) contributes nothing to the output JSON schema, (b) is *not* emitted as a
prompt text line, and (c) is lowered to a `UserImage` block by `render`. Add a generic
collector that extracts every `Image` value from an input record, and rewire the single
user-message-building line in both adapters to attach those images.

**What will exist at the end.** `render` produces a `Context` whose user message carries a
`UserImage` block (with the right bytes and MIME) plus the text fields, for an image-bearing
input; and the schema/prompt for an image field behave as decided. A new `MultimodalAdapterSpec`
asserts the built `Context` directly.

First, give `Image` the instances it needs to live inside a signature record without breaking the
existing generic walks. The input record type is constrained by `ToPrompt i` (in `predict`/the
adapters). So `Image` needs a `ToPrompt`-compatible *leaf* behaviour, but it must **not** appear
as a text key/value line. The cleanest approach, consistent with the Decision Log, is:

- `Image` gets a `ToPrompt` instance via the existing `PromptValue` leaf mechanism, but the
  image field is *suppressed* from the text rendering. Rather than special-casing `ToPrompt`'s
  generic walk (which EP-26 also edits), introduce a dedicated generic traversal in
  `Shikumi.Multimodal` that (1) collects the images and (2) tells the renderer which field names
  are images so the text path can drop them.

Add to `Shikumi.Multimodal` a class that walks a record's `Rep` and returns the list of `Image`
values it contains, in field order:

```haskell
-- | Collect every 'Image' value from a record, in field order. Used by the
-- adapter to lower image fields into baikai 'UserImage' blocks. Records with no
-- image fields yield @[]@ (the text-only path is then taken verbatim).
class ImageFields a where
  imageFields :: a -> [Image]
  default imageFields :: (Generic a, GImageFields (Rep a)) => a -> [Image]
  imageFields = gImageFields . from
```

Implement the generic helper `GImageFields` mirroring the structure of `GToPromptFields` in
`Shikumi.Adapter` (datatype/constructor/product wrappers recurse; a selector leaf checks whether
its field type is `Image`). Use an overlappable leaf class `ImageLeaf t` that returns `[]` for
non-image leaves and `[img]` for an `Image` leaf, plus a `Field`-unwrapping instance so an
`Image` wrapped in a description (`Field d Image`) is still collected:

```haskell
class ImageLeaf t where
  imageLeaf :: t -> [Image]

instance {-# OVERLAPPABLE #-} ImageLeaf a where imageLeaf _ = []
instance ImageLeaf Image where imageLeaf img = [img]
instance (ImageLeaf a) => ImageLeaf (Field d a) where imageLeaf (Field a) = imageLeaf a
```

Also add the dual: a way to know *which field names* are images, so the text renderer can drop
them. Reuse the same leaf check at the metadata level — add a function in `Shikumi.Multimodal`:

```haskell
-- | The field names of a record that are 'Image' (wrapped or bare). The adapter
-- removes these from the text-rendered prompt fields.
imageFieldNames :: forall a. (GImageFieldNames (Rep a)) => [Text]
```

implemented with a generic walk that, at each selector, emits the selector name **only if** the
field type is `Image` (or `Field d Image`). This is purely type-directed (it uses `Proxy`, no
value), exactly like `fieldMetasOf`.

For `ToPrompt`: give `Image` an instance so it satisfies the `ToPrompt`-leaf constraint if it is
ever reached, but the adapter will have already removed image fields from the text rendering, so
its text value is never used in practice. Define it to render the empty string to be safe:

```haskell
instance ToPrompt Image where
  toPromptFields _ = []   -- an image contributes no text line
```

(Defining `toPromptFields _ = []` means even if an `Image` somehow reaches `toPrompt`, it emits
nothing — a belt-and-braces guarantee complementing the field-name removal.)

For `ToSchema`: an `Image` is input-only and must never appear in an *output* schema. The output
type `o` is what `ToSchema` is derived for; an input type `i` is not schema-derived at all (only
`ToPrompt i` is required). So in practice no `ToSchema Image` instance is needed for the
headline use case, because images live on the *input*. To prevent misuse (someone putting an
`Image` in an output record), do **not** provide a `ToSchema Image` instance: the absence makes
"image in output" a *compile error* with a clear "no instance for ToSchema Image" message, which
is the correct outcome (a model cannot emit raw image bytes through the JSON decode path). Record
this in the Decision Log if a reviewer expects an instance.

Now rewire `render`. In `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Adapter.hs`,
the two adapters each contain the line:

```haskell
ctx = buildContext sys (demoMessages sig ++ [user (toPrompt i)])
```

Replace `[user (toPrompt i)]` with a helper `userTurn i` that builds the user message
image-aware. Add to `Shikumi.Adapter` (importing `imageFields`, `imageFieldNames`,
`imageToContent` from `Shikumi.Multimodal`):

```haskell
-- | Build the final user turn for an input. Image fields are lowered to a
-- 'UserImage' block; the remaining (text) fields render as before. When the
-- input has no images, this is exactly @user (toPrompt i)@ (regression-safe).
userTurn ::
  forall i o.
  (ToPrompt i, ImageFields i, GImageFieldNames (Rep i)) =>
  i ->
  Message
userTurn i =
  case imageFields i of
    [] -> user (toPrompt i)
    (img : _) ->
      let dropped = imageFieldNames @i
          textPairs = [(k, v) | (k, v) <- toPromptFields i, k `notElem` dropped]
          textBody = T.intercalate "\n" [k <> ": " <> v | (k, v) <- textPairs]
          prefix = if T.null textBody then Nothing else Just textBody
       in userImage (imageToContent img) prefix
```

Notes on this helper, all load-bearing:

- It takes the **first** image (`img : _`). The headline signature `Describe` has exactly one
  image field; supporting multiple images would mean building a user message with multiple
  `UserImage` blocks, which baikai's `userImage` does not directly do (it attaches one image).
  Scope this plan to **one image field per input** and document that a multi-image input is
  future work (it would build the content vector by hand via the `UserMessage`/`UserPayload`
  constructors rather than `userImage`). Assert single-image in the type/usage and note it.
- `imageFieldNames @i` removes the image field's name from the text pairs so its (empty) text
  value is not rendered — and so the text body contains *only* the genuine text fields
  (`question` in the `Describe` example).
- When there is no text body (an input that is *only* an image), `prefix` is `Nothing`, and
  `userImage` produces a message with just the image block.

Then widen the two adapters' constraints to require `ImageFields i` and `GImageFieldNames (Rep
i)` on `i`, and replace the message-building line. Because `predict`, `nativeAdapter`,
`fallbackAdapter`, and `adapterFor` already carry `ToPrompt i`, adding the two image constraints
is an additive change to their signatures. Every existing call site already has a `Generic i`
input, so the generic defaults resolve; the only requirement is that each input record type used
with `predict` has `instance ImageFields T` and the `GImageFieldNames` walk is derivable, which
it is generically for any `Generic` record. To avoid forcing every existing input type to write
`instance ImageFields T`, give `ImageFields` and the field-name walk total generic defaults so a
bare `deriving stock Generic` is enough, and add `instance ImageFields Article` (etc.) only where
needed — or, better, make `ImageFields` derivable with `DeriveAnyClass` (the package already
enables it) so existing fixtures get the instance for free by adding `ImageFields` to their
`deriving anyclass` list. Document in the plan that **existing input fixtures must add
`ImageFields` to their derives** (a one-line change per fixture) — confirm by building and fixing
the resulting "no instance" errors.

Add the test `/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/test/MultimodalAdapterSpec.hs`
(register in `other-modules`). Define a small image-bearing input and an output, build a
signature, call `render`, and walk the resulting `Context` to assert the `UserImage` block and
the text field. A helper to extract image blocks:

```haskell
userImageBlocks :: Context -> [ImageContent]
userImageBlocks ctx =
  [ ic
    | UserMessage p <- V.toList (ctx ^. #messages),
      UserImage ic <- V.toList (p ^. #content)
  ]

userTextBlocks :: Context -> [Text]
userTextBlocks ctx =
  [ t
    | UserMessage p <- V.toList (ctx ^. #messages),
      UserText (TextContent t) <- V.toList (p ^. #content)
  ]
```

The assertions: the rendered `Context` contains exactly one `ImageContent` whose `imageData`
equals the original decoded bytes and whose `mimeType` is `"image/png"`; the user text block
contains `"question:"` and the question text but does **not** contain the image field's name; and
for an image-free control input, `userImageBlocks` is empty.

**Acceptance.** `cabal test shikumi` runs `MultimodalAdapterSpec` and it passes; the assertions
directly observe the lowered image bytes inside the baikai `Context`, and observe that the text
fields are preserved while the image field name is absent from the text.

### Milestone 3 — end-to-end stub run and the regression invariant

**Scope.** Drive a `Describe -> Answer` signature through a tiny `predict`-style runner against a
**stub** language model that captures the `Context` it is handed, asserts an image block is
present, and returns a canned JSON answer that decodes into a typed `Answer`. Add a regression
test proving the all-text path's `Context` is byte-for-byte unchanged.

**What will exist at the end.** A `MultimodalEndToEndSpec` that exercises the full render -> stub
-> parse loop with an image input and asserts the captured request carried the image; and a
regression assertion comparing an image-free `Context` against the existing text path.

The existing `EndToEndSpec` (read it at
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/test/EndToEndSpec.hs`) shows the pattern: a fake
`LLM` interpreter and a `runSig` driver that renders, calls the model, and parses. Reuse that
pattern but make the fake interpreter **capture** the `Context` into an `IORef` so the test can
inspect what the model received:

```haskell
runCapturingLLM :: IORef (Maybe Context) -> Response -> Eff (LLM : es) a -> Eff es a
runCapturingLLM capture canned = interpret $ \_ -> \case
  Complete _ ctx _ -> do
    liftIO (writeIORef capture (Just ctx))
    pure canned
  Stream _ _ _ -> pure []
```

(Use `Effectful.liftIO`; the fake interpreter already runs under `IOE` in the suite via
`runEff`.) Define the headline fixtures:

```haskell
data Describe = Describe
  { image :: Image,
    question :: Field "What to ask about the image" Text
  }
  deriving stock (Generic, Show)
  deriving anyclass (ToPrompt, ImageFields, GImageFieldNamesDeriving) -- see note

newtype Answer = Answer
  { answer :: Field "A short answer to the question" Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

instance Validatable Answer
```

(If `GImageFieldNames` cannot be a `deriving anyclass` target because it is a `Rep`-level class,
expose the field-name walk through a value-level helper class on the *type* that *can* be derived
or defaulted; the simplest is to require only `ImageFields` as a derive and have
`imageFieldNames` be a standalone function constrained on `GImageFieldNames (Rep a)`, which any
`Generic` record satisfies without an explicit instance. Adjust the `userTurn` constraint
accordingly. Resolve this concretely during implementation and record the final shape in the
Decision Log.)

The runner mirrors `EndToEndSpec.runSig` but uses `fallbackAdapter` (works without native schema
support and is fully hermetic). The stub returns a canned answer body. For the **fallback**
adapter the canned response is a `[[ ## answer ## ]]` section; for clarity you may instead use a
direct JSON path. Pick the fallback to match the existing hermetic style:

```haskell
cannedAnswer :: Response
cannedAnswer =
  mkResponse $
    T.intercalate "\n"
      [ "[[ ## answer ## ]]",
        "A red bicycle.",
        "[[ ## completed ## ]]"
      ]
```

The test:

```haskell
testCase "Describe with an image: model receives a UserImage block; answer decodes" $ do
  capture <- newIORef Nothing
  let raw = BS.pack [0x89, 0x50, 0x4e, 0x47]
      img = imageFromBytes "image/png" raw
      input = Describe { image = img, question = field "What vehicle is shown?" }
      sig = mkSignature "Answer the question about the image" :: Signature Describe Answer
  out <- runEff . runCapturingLLM capture cannedAnswer $
           runSig fallbackAdapter sig input
  -- the structured answer decodes
  out @?= Right (Answer { answer = field "A red bicycle." })
  -- the captured request carried the image
  Just ctx <- readIORef capture
  userImageBlocks ctx @?= [ImageContent { imageData = raw, mimeType = "image/png" }]
  -- and the text fields are still present
  any (T.isInfixOf "What vehicle is shown?") (userTextBlocks ctx) @?= True
```

Add the **regression** test in the same module proving the text-only path is unchanged. Use the
existing `Article` fixture (an image-free input) and assert its rendered `Context` has no image
blocks and a single text user message identical to what `user (toPrompt sampleArticle)` would
produce:

```haskell
testCase "image-free input renders the unchanged text-only Context" $ do
  let sig = setDemos [] (mkSignature "Summarize" :: Signature Article Summary)
      (ctx, _) = render fallbackAdapter sig sampleArticle
  userImageBlocks ctx @?= []
  -- exactly one user message, and its single block is the toPrompt text
  userTextBlocks ctx @?= [toPrompt sampleArticle]
```

(`Article` must gain `deriving anyclass ImageFields` — a one-line edit in `Fixtures.hs` — for
this to compile; that edit is part of M2's "fix existing fixtures" step.)

**Acceptance.** `cabal test shikumi` runs `MultimodalEndToEndSpec` and it passes: the image test
shows the model received the image and the answer decoded; the regression test shows the
image-free path is unchanged. Running `cabal test all` confirms no other package regressed.

### Audio and document: upstream-gated future work

This plan deliberately stops at image. For the record, here is the precise upstream path a
future plan would take to add, say, audio — it is included so a later contributor does not have
to rediscover it.

baikai's user content type is, today:

```haskell
data UserContent = UserText !TextContent | UserImage !ImageContent
```

To deliver audio, baikai (in the separate repo `/Users/shinzui/Keikaku/bokuno/baikai`) would
first add a constructor and a content record mirroring `ImageContent`, for example
`UserAudio !AudioContent` with `AudioContent { audioData :: ByteString, mimeType :: Text }`, give
it the same base64-on-the-wire `ToJSON`/`FromJSON` treatment `ImageContent` has (see
`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Content.hs` lines 174–187), and add an
`Audio`-aware message constructor next to `userImage`. That is an *upstream baikai change* — the
analogue of V1's EP-2 baikai extension — and must land and be released before Shikumi can lower
an `Audio` field to anything the model can see. Only then would a Shikumi follow-up add an
`Audio` type next to `Image` in `Shikumi.Multimodal`, an `AudioFields` collector, and an
audio-aware branch in `userTurn`. Until baikai grows that constructor, an audio field in a
Shikumi signature could not be transmitted, so this plan does not offer one. The headline
deliverable — image — needs none of that, because baikai already models `UserImage`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shikumi`.

M1:

```bash
nix develop .#ghc9124 --command cabal build shikumi
nix develop .#ghc9124 --command cabal test shikumi --test-options='--pattern MultimodalSpec'
```

Expected (abbreviated):

```text
MultimodalSpec
  imageFromBase64 round-trips decoded bytes into ImageContent: OK
  imageFromFile reads bytes and infers MIME from .png:         OK
All 2 tests passed
```

M2:

```bash
nix develop .#ghc9124 --command fourmolu --mode inplace \
  shikumi/src/Shikumi/Multimodal.hs shikumi/src/Shikumi/Adapter.hs
nix develop .#ghc9124 --command cabal test shikumi --test-options='--pattern MultimodalAdapterSpec'
```

Expected (abbreviated):

```text
MultimodalAdapterSpec
  render lowers an image field to a UserImage block with the right bytes: OK
  render keeps the text fields and drops the image field name:            OK
  image-free input produces no image blocks:                              OK
All 3 tests passed
```

M3 and full suite:

```bash
nix develop .#ghc9124 --command cabal test shikumi
nix develop .#ghc9124 --command cabal test all
```

Expected: every existing test still passes (notably `AdapterSpec`, `EndToEndSpec`, `SchemaSpec`,
`SignatureSpec`), plus the three new `Multimodal*` groups pass. If an existing input fixture
fails to compile with `No instance for (ImageFields …)`, add `ImageFields` to that type's
`deriving anyclass` list (a one-line edit) and rebuild.

After M3, update `docs/masterplans/4-shikumi-richer-io-and-multimodal.md`: flip the EP-24
registry row's Status from `Not Started` to `Complete`, and tick the two EP-24 lines in that
MasterPlan's Progress section. Commit with the three trailers shown in "Build and test facts".


## Validation and Acceptance

The change is effective beyond compilation in three concrete, observable ways, each backed by a
hermetic test that fails before the change and passes after:

1. **Round-trip (M1).** An image read from a file or decoded from base64 yields an
   `ImageContent` whose `imageData` is the exact decoded bytes (not base64) and whose `mimeType`
   matches. Observe via `MultimodalSpec`.

2. **Lowering into the request (M2).** Calling `render` on a signature whose input has an image
   field produces a baikai `Context` whose user message contains a `UserImage` block with those
   exact bytes and MIME, alongside the text fields, with the image field name absent from the
   text. Observe via `MultimodalAdapterSpec` by walking `ctx ^. #messages`.

3. **End-to-end and regression (M3).** A `Describe -> Answer` program run under a capturing stub
   model shows the model genuinely received an image block, and the canned structured answer
   decodes into a typed `Answer`. Separately, an image-free input renders a `Context` identical
   to today's text-only output (`userTextBlocks ctx == [toPrompt input]`, no image blocks).
   Observe via `MultimodalEndToEndSpec`.

The whole-workspace gate is `cabal test all` passing with no regressions to existing specs.


## Idempotence and Recovery

Every step is additive and safe to repeat. The new module `Shikumi.Multimodal` and the new test
modules are created once; re-running the build/test commands is harmless. The only edits to
existing files are: (a) adding `userTurn` and widening two adapter constraints in
`Shikumi.Adapter.hs`; (b) adding `ImageFields` to existing input fixtures' derives; (c) adding
module names to `shikumi.cabal`. Each is a localized, re-runnable change. If a milestone's tests
fail, fix forward — there is no destructive or migration step. If you need to abandon, deleting
the new modules and reverting the three edits restores the prior behaviour exactly, because the
image path is strictly conditional (`imageFields i == []` falls back to the original
`user (toPrompt i)`).


## Interfaces and Dependencies

New module `Shikumi.Multimodal` (full path
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Multimodal.hs`) must export, by the
end of M2:

```haskell
data Image = Image { imageBytes :: !ByteString, imageMime :: !Text }

imageFromBytes  :: Text -> ByteString -> Image
imageFromFile   :: FilePath -> IO (Either ShikumiError Image)
imageFromBase64 :: Text -> Text -> Either ShikumiError Image   -- mime, base64
imageToContent  :: Image -> ImageContent

class ImageFields a where imageFields :: a -> [Image]
imageFieldNames :: forall a. (GImageFieldNames (Rep a)) => [Text]
```

(`GImageFieldNames` and the internal `GImageFields`/`ImageLeaf` classes are implementation
details; export whichever the `userTurn` constraint in `Shikumi.Adapter` needs, or keep the
field-name walk fully internal and expose only `imageFieldNames`.)

Module `Shikumi.Adapter` (full path
`/Users/shinzui/Keikaku/bokuno/shikumi/shikumi/src/Shikumi/Adapter.hs`) gains an internal
`userTurn` helper and its two adapters' input constraints widen from `ToPrompt i` to
`(ToPrompt i, ImageFields i, GImageFieldNames (Rep i))`. The public `Adapter`, `render`, `parse`,
`nativeAdapter`, `fallbackAdapter`, `adapterFor`, and `capabilityFor` signatures are otherwise
unchanged; only the `i` constraint set grows, which is source-compatible for any `Generic` input
record.

Libraries: `base64-bytestring` (for `Data.ByteString.Base64.decode`/`encode`), `bytestring`,
`text`, `vector`, and `baikai` (for `ImageContent(..)`, `UserContent(..)`, `userImage`,
`_ImageContent`, `Context`, `Message`, `UserMessage`, `UserPayload`). For tests:
`tasty`/`tasty-hunit` (already used), `temporary` for `withSystemTempFile` (or
`System.Directory.getTemporaryDirectory` if `temporary` is unavailable), and `effectful` for the
capturing `LLM` interpreter.

baikai contract this plan depends on (verbatim, do not assume more): `UserContent = UserText
!TextContent | UserImage !ImageContent`; `ImageContent { imageData :: ByteString (decoded),
mimeType :: Text }`; `userImage :: ImageContent -> Maybe Text -> Message` placing optional text
before one image block; `Context { systemPrompt, messages :: Vector Message, tools }`. baikai is
**not** modified by this plan. Audio/document remain upstream-gated as described above.


## Revision History

- 2026-06-09: Initial authored plan (from skeleton). Scoped to image (option (a)); audio/document
  documented as upstream-gated. Three milestones: `Image` type + round-trip (M1); generic
  recognition + image-aware `render` (M2); end-to-end stub run + text-path regression (M3).
  Coordinates with EP-26 on the schema/adapter seam per MasterPlan Integration Point #1.
</content>
</invoke>
