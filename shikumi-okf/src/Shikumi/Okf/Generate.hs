-- | Turn a 'ProgramManifest' into OKF concepts and write them to disk.
--
-- The bundle is one @Shikumi App@ concept that links to one @Shikumi Program@
-- concept per manifest entry. Those Markdown links are the app→program edges the
-- OKF graph extractor reads, so a reader (or the @okf graph@ command) can answer
-- "which programs does this app ship?". Building concepts is pure and can fail
-- only on an invalid concept name (an author error in the manifest), surfaced as
-- 'GenerateError'; writing performs IO through the @okf-core@ producer API.
--
-- The bundles target __OKF v0.2__: the root @index.md@ declares
-- @okf_version: "0.2"@ and every concept records its producer in the v0.2
-- @generated@ family, which is what strict validation now asks for. Both come
-- from 'GenerateOptions'; start from 'defaultGenerateOptions' and override,
-- rather than building the record literally, so a later field with a default
-- leaves your call site working.
--
-- Generation is deterministic: it never reads the wall clock. @generated.at@ is
-- caller-supplied and absent by default, so regenerating an unchanged manifest
-- yields byte-identical output and a "regenerate and diff" check stays
-- meaningful.
module Shikumi.Okf.Generate
  ( GenerateError (..),
    GenerateOptions (..),
    defaultGenerateOptions,
    defaultGeneratedBy,
    okfVersion02,
    programConceptId,
    appConceptId,
    programConcept,
    appConcept,
    generateBundle,
    writeProgramBundle,
  )
where

import Data.Bifunctor (first)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Okf.Actor (Actor (ProcessActor))
import Okf.Bundle (BundleError, Concept, conceptFromDocument, writeBundle)
import Okf.ConceptId (ConceptId, ConceptIdError, parseConceptId, renderConceptLink)
import Okf.Document
  ( Frontmatter,
    Generated (..),
    OKFDocument (..),
    OkfCommon (..),
    okfCommon,
    setGenerated,
    setResource,
    setTags,
  )
import Okf.Index (OkfVersion (..), writeBundleIndexesWith)
import Shikumi.Okf.Render (renderProgramBody)
import Shikumi.Okf.Types (AppInfo (..), ProgramDoc (..), ProgramManifest (..))

-- | Why bundle generation failed.
data GenerateError
  = -- | A manifest name did not form a valid OKF concept id (carries the raw
    -- @apps/<app>@ or @programs/<name>@ text and the underlying parse error).
    InvalidConceptName Text ConceptIdError
  | -- | Writing the bundle's @index.md@ files failed.
    IndexWriteError BundleError
  deriving stock (Eq, Show)

-- | What the generator records about the bundle itself, as opposed to about the
-- programs in it.
--
-- Build one by overriding 'defaultGenerateOptions' (@defaultGenerateOptions
-- {generatedAt = Just "2026-08-07T00:00:00Z"}@) rather than as a record literal:
-- a field added here in a later release keeps an overriding call site compiling.
data GenerateOptions = GenerateOptions
  { -- | The OKF v0.2 @generated@ family written on every concept: who or what
    -- produced it, and optionally when. 'Nothing' omits the key entirely,
    -- which leaves the bundle without the provenance @okf validate --strict@
    -- asks for.
    generated :: !(Maybe Generated),
    -- | The version declared in the bundle root's @index.md@. 'Nothing'
    -- preserves whatever declaration the destination already carries, so a
    -- bundle hand-migrated to a later version is not silently walked back.
    okfVersion :: !(Maybe OkfVersion)
  }

-- | Declare OKF v0.2 and record @process:shikumi-okf@ as the producer, with no
-- generation time.
--
-- Time is absent by default on purpose: it is the only part of this record that
-- would differ between two runs over the same manifest, and leaving it out is
-- what keeps @regenerate && git diff --exit-code@ usable as a drift check.
defaultGenerateOptions :: GenerateOptions
defaultGenerateOptions =
  GenerateOptions
    { generated = Just Generated {generatedBy = defaultGeneratedBy, generatedAt = Nothing},
      okfVersion = Just okfVersion02
    }

-- | The producer 'defaultGenerateOptions' names: @process:shikumi-okf@.
--
-- Deliberately version-free. A version here would change the bytes of every
-- generated document on every shikumi-okf release, which would make the
-- regenerate-and-diff check report drift that is not drift.
defaultGeneratedBy :: Actor
defaultGeneratedBy = ProcessActor "shikumi-okf"

-- | OKF v0.2, the dialect these bundles are written in.
--
-- Pinned rather than taken from @okf-core@'s 'Okf.Index.supportedOkfVersion':
-- declaring a version is a claim about what this generator emits, so it must
-- move when the generator learns a new dialect's fields, not when the library
-- it links against learns to read one.
okfVersion02 :: OkfVersion
okfVersion02 = OkfVersion {okfVersionMajor = 0, okfVersionMinor = 2}

-- | The concept id of a program: @programs/<name>@.
programConceptId :: ProgramDoc -> Either GenerateError ConceptId
programConceptId doc = mkConceptId ("programs/" <> name doc)

-- | The concept id of the application: @apps/<app>@.
appConceptId :: AppInfo -> Either GenerateError ConceptId
appConceptId app = mkConceptId ("apps/" <> appName app)

mkConceptId :: Text -> Either GenerateError ConceptId
mkConceptId raw = first (InvalidConceptName raw) (parseConceptId raw)

-- | Build the @Shikumi Program@ concept for one documented program.
programConcept :: AppInfo -> GenerateOptions -> ProgramDoc -> Either GenerateError Concept
programConcept app opts doc = do
  cid <- programConceptId doc
  let resource =
        "shikumi://" <> appNamespace app <> "/" <> appName app <> "/programs/" <> name doc
      frontmatter =
        applyTags (tags doc) . applyGenerated opts . setResource resource $
          okfCommon
            OkfCommon
              { commonType = "Shikumi Program",
                commonTitle = Just (fromMaybe (name doc) (title doc)),
                commonDescription = description doc,
                commonTimestamp = Nothing
              }
      okfDoc = OKFDocument {frontmatter, body = renderProgramBody doc}
  pure (conceptFromDocument cid okfDoc)

-- | Build the @Shikumi App@ concept that links to every program.
appConcept :: AppInfo -> GenerateOptions -> ProgramManifest -> Either GenerateError Concept
appConcept app opts (ProgramManifest docs) = do
  cid <- appConceptId app
  links <- traverse programLink docs
  let appLabel = fromMaybe (appName app) (appTitle app)
      resource = "shikumi://" <> appNamespace app <> "/" <> appName app
      bodyLines =
        ["# " <> appLabel]
          <> maybe [] (\d -> ["", d]) (appDescription app)
          <> ["", "## Programs", ""]
          <> links
      frontmatter =
        applyGenerated opts . setResource resource $
          okfCommon
            OkfCommon
              { commonType = "Shikumi App",
                commonTitle = Just appLabel,
                commonDescription = appDescription app,
                commonTimestamp = Nothing
              }
      okfDoc = OKFDocument {frontmatter, body = T.unlines bodyLines}
  pure (conceptFromDocument cid okfDoc)
  where
    programLink doc = do
      pcid <- programConceptId doc
      pure ("- " <> renderConceptLink pcid (fromMaybe (name doc) (title doc)))

-- | All concepts for a manifest: the app concept first, then one per program.
generateBundle :: AppInfo -> GenerateOptions -> ProgramManifest -> Either GenerateError [Concept]
generateBundle app opts manifest = do
  appC <- appConcept app opts manifest
  programCs <- traverse (programConcept app opts) (entries manifest)
  pure (appC : programCs)

-- | Generate the bundle and write it to @root@, then write its @index.md@ files
-- with the OKF version declaration from 'GenerateOptions'. Returns the first
-- error encountered (an invalid name before any IO, or an index write failure
-- after the concept files are written).
writeProgramBundle ::
  FilePath -> AppInfo -> GenerateOptions -> ProgramManifest -> IO (Either GenerateError ())
writeProgramBundle root app opts manifest =
  case generateBundle app opts manifest of
    Left err -> pure (Left err)
    Right concepts -> do
      writeBundle root concepts
      indexResult <- writeBundleIndexesWith (okfVersion opts) root
      pure (first IndexWriteError indexResult)

-- | Attach a @tags@ field only when there is at least one tag, so a program with
-- no tags does not emit an empty @tags: []@ list.
applyTags :: [Text] -> Frontmatter -> Frontmatter
applyTags [] frontmatter = frontmatter
applyTags ts frontmatter = setTags ts frontmatter

-- | Attach the @generated@ family when the caller asked for one. A caller who
-- passed 'Nothing' gets no key rather than an invented producer: OKF §5.2 makes
-- @generated.by@ a claim about who wrote the content, and this generator cannot
-- make that claim on someone else's behalf.
applyGenerated :: GenerateOptions -> Frontmatter -> Frontmatter
applyGenerated opts frontmatter =
  maybe frontmatter (`setGenerated` frontmatter) (generated opts)
