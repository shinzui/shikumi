-- | Turn a 'ProgramManifest' into OKF concepts and write them to disk.
--
-- The bundle is one @Shikumi App@ concept that links to one @Shikumi Program@
-- concept per manifest entry. Those Markdown links are the app→program edges the
-- OKF graph extractor reads, so a reader (or the @okf graph@ command) can answer
-- "which programs does this app ship?". Building concepts is pure and can fail
-- only on an invalid concept name (an author error in the manifest), surfaced as
-- 'GenerateError'; writing performs IO through the @okf-core@ producer API.
--
-- Generation is deterministic: the timestamp is an explicit argument, never read
-- from the wall clock, so regenerating an unchanged manifest yields byte-identical
-- output and a "regenerate and diff" check stays meaningful.
module Shikumi.Okf.Generate
  ( GenerateError (..),
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
import Okf.Bundle (BundleError, Concept, conceptFromDocument, writeBundle)
import Okf.ConceptId (ConceptId, ConceptIdError, parseConceptId, renderConceptLink)
import Okf.Document
  ( Frontmatter,
    OKFDocument (..),
    OkfCommon (..),
    okfCommon,
    setResource,
    setTags,
  )
import Okf.Index (writeBundleIndexes)
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

-- | The concept id of a program: @programs/<name>@.
programConceptId :: ProgramDoc -> Either GenerateError ConceptId
programConceptId doc = mkConceptId ("programs/" <> name doc)

-- | The concept id of the application: @apps/<app>@.
appConceptId :: AppInfo -> Either GenerateError ConceptId
appConceptId app = mkConceptId ("apps/" <> appName app)

mkConceptId :: Text -> Either GenerateError ConceptId
mkConceptId raw = first (InvalidConceptName raw) (parseConceptId raw)

-- | Build the @Shikumi Program@ concept for one documented program.
programConcept :: AppInfo -> Maybe Text -> ProgramDoc -> Either GenerateError Concept
programConcept app timestamp doc = do
  cid <- programConceptId doc
  let resource =
        "shikumi://" <> appNamespace app <> "/" <> appName app <> "/programs/" <> name doc
      frontmatter =
        applyTags (tags doc) . setResource resource $
          okfCommon
            OkfCommon
              { commonType = "Shikumi Program",
                commonTitle = Just (fromMaybe (name doc) (title doc)),
                commonDescription = description doc,
                commonTimestamp = timestamp
              }
      okfDoc = OKFDocument {frontmatter, body = renderProgramBody doc}
  pure (conceptFromDocument cid okfDoc)

-- | Build the @Shikumi App@ concept that links to every program.
appConcept :: AppInfo -> Maybe Text -> ProgramManifest -> Either GenerateError Concept
appConcept app timestamp (ProgramManifest docs) = do
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
        setResource resource $
          okfCommon
            OkfCommon
              { commonType = "Shikumi App",
                commonTitle = Just appLabel,
                commonDescription = appDescription app,
                commonTimestamp = timestamp
              }
      okfDoc = OKFDocument {frontmatter, body = T.unlines bodyLines}
  pure (conceptFromDocument cid okfDoc)
  where
    programLink doc = do
      pcid <- programConceptId doc
      pure ("- " <> renderConceptLink pcid (fromMaybe (name doc) (title doc)))

-- | All concepts for a manifest: the app concept first, then one per program.
generateBundle :: AppInfo -> Maybe Text -> ProgramManifest -> Either GenerateError [Concept]
generateBundle app timestamp manifest = do
  appC <- appConcept app timestamp manifest
  programCs <- traverse (programConcept app timestamp) (entries manifest)
  pure (appC : programCs)

-- | Generate the bundle and write it to @root@, then write its @index.md@ files.
-- Returns the first error encountered (an invalid name before any IO, or an index
-- write failure after the concept files are written).
writeProgramBundle ::
  FilePath -> AppInfo -> Maybe Text -> ProgramManifest -> IO (Either GenerateError ())
writeProgramBundle root app timestamp manifest =
  case generateBundle app timestamp manifest of
    Left err -> pure (Left err)
    Right concepts -> do
      writeBundle root concepts
      indexResult <- writeBundleIndexes root
      pure (first IndexWriteError indexResult)

-- | Attach a @tags@ field only when there is at least one tag, so a program with
-- no tags does not emit an empty @tags: []@ list.
applyTags :: [Text] -> Frontmatter -> Frontmatter
applyTags [] frontmatter = frontmatter
applyTags ts frontmatter = setTags ts frontmatter
