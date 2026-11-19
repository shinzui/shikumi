{-# LANGUAGE DataKinds #-}

-- | The program artifact envelope, shared by baselines and candidates: a
-- promoted candidate is the next baseline.
--
-- An artifact stores the exact JSON object 'Shikumi.Compile.Serialize.encodeCompiled'
-- emits (the program shape and its ordered parameter vector), the structural
-- fingerprint and schema digests that pin it to one program template, the source
-- revisions it came from and, for a candidate, the optimization that produced it.
-- 'loadArtifact' re-applies the stored state to a template held as code, so a
-- successful load is the proof that the artifact's structure equals the
-- template's.
module Shikumi.Evidence.Artifact
  ( -- * The envelope
    ProgramArtifact (..),
    OptimizationRecord (..),
    UsageSummary (..),
    usageSummary,
    renderRational,
    artifactKindProgram,
    compiledSchemaVersionCurrent,

    -- * Building and reading
    ArtifactSpec (..),
    ArtifactError (..),
    sealBaseline,
    sealArtifact,
    resealArtifact,
    decodeArtifact,
    validateArtifact,
    loadArtifact,
    structuralFingerprintOf,
    compiledStateOf,
  )
where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), decode, object, withObject, (.:), (.:?), (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Ratio (denominator, numerator)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import GHC.Records (HasField (..))
import Numeric.Natural (Natural)
import Shikumi.Cache.Key (canonicalJSON)
import Shikumi.Compile.Serialize (decodeCompiledOnto, encodeCompiled)
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Eval.Report (UsageTotals (..))
import Shikumi.Evidence.Dataset (EvidenceCodec (..))
import Shikumi.Evidence.Digest
import Shikumi.Evidence.Recording (RouteCount)
import Shikumi.Evidence.Source (SourceRef, validateSourceRef)
import Shikumi.Optimize.Execution (RunLimits)
import Shikumi.Optimize.Report (RunStatus)
import Shikumi.Program (Program, programShape)

-- | Logical usage: provider-reported tokens, the exact cost as a
-- @numerator/denominator@ string, and the number of calls with unknown usage.
data UsageSummary = UsageSummary
  { inputTokens :: !Natural,
    outputTokens :: !Natural,
    totalTokens :: !Natural,
    costUsd :: !Text,
    unknownUsageCalls :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Summarize usage totals.
usageSummary :: UsageTotals -> UsageSummary
usageSummary u = UsageSummary (u.totalInputTokens) (u.totalOutputTokens) u.totalTokens (renderRational (u.totalCostUsd)) u.unknownUsageCalls

-- | An exact rational as @numerator/denominator@.
renderRational :: Rational -> Text
renderRational r = T.pack (show (numerator r) <> "/" <> show (denominator r))

-- | What produced a candidate. Calls cannot be attributed to proposing or
-- scoring inside an optimizer, so @routes@ is the union over the whole
-- optimization phase.
data OptimizationRecord = OptimizationRecord
  { optimizerId :: !Text,
    optimizerVersion :: !Text,
    optimizerConfig :: !Value,
    seed :: !Int,
    budget :: !RunLimits,
    predictedOperations :: !Int,
    admittedOperations :: !Int,
    usage :: !UsageSummary,
    runStatus :: !RunStatus,
    datasetDigest :: !Digest,
    routes :: ![RouteCount],
    recordingDigest :: !Digest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The program artifact envelope. In JSON the identity's fields
-- (@artifactId@, @sources@, @createdAt@, @createdBy@) sit at the top level, and
-- they are also readable directly, as @artifact.artifactId@.
data ProgramArtifact = ProgramArtifact
  { artifactKind :: !Text,
    schemaVersion :: !Int,
    identity :: !ArtifactSpec,
    -- | the baseline's digest, for a candidate
    parentDigest :: !(Maybe Digest),
    compiledSchemaVersion :: !Int,
    structuralFingerprint :: !Digest,
    inputSchemaDigest :: !Digest,
    outputSchemaDigest :: !Digest,
    compiledState :: !Value,
    optimization :: !(Maybe OptimizationRecord),
    contentDigest :: !Digest
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ProgramArtifact where
  toJSON a =
    mergeObjects
      [ toJSON a.identity,
        object
          ( [ "artifactKind" .= a.artifactKind,
              "schemaVersion" .= a.schemaVersion,
              "compiledSchemaVersion" .= a.compiledSchemaVersion,
              "structuralFingerprint" .= a.structuralFingerprint,
              "inputSchemaDigest" .= a.inputSchemaDigest,
              "outputSchemaDigest" .= a.outputSchemaDigest,
              "compiledState" .= a.compiledState,
              "contentDigest" .= a.contentDigest
            ]
              ++ maybe [] (\d -> ["parentDigest" .= d]) a.parentDigest
              ++ maybe [] (\r -> ["optimization" .= r]) a.optimization
          )
      ]

instance FromJSON ProgramArtifact where
  parseJSON = withObject "ProgramArtifact" $ \o ->
    ProgramArtifact
      <$> o .: "artifactKind"
      <*> o .: "schemaVersion"
      <*> parseJSON (withoutKeys ownKeys o)
      <*> o .:? "parentDigest"
      <*> o .: "compiledSchemaVersion"
      <*> o .: "structuralFingerprint"
      <*> o .: "inputSchemaDigest"
      <*> o .: "outputSchemaDigest"
      <*> o .: "compiledState"
      <*> o .:? "optimization"
      <*> o .: "contentDigest"
    where
      ownKeys =
        [ "artifactKind",
          "schemaVersion",
          "parentDigest",
          "compiledSchemaVersion",
          "structuralFingerprint",
          "inputSchemaDigest",
          "outputSchemaDigest",
          "compiledState",
          "optimization",
          "contentDigest"
        ]

instance HasField "artifactId" ProgramArtifact Text where getField a = a.identity.artifactId

instance HasField "sources" ProgramArtifact [SourceRef] where getField a = a.identity.sources

instance HasField "createdAt" ProgramArtifact UTCTime where getField a = a.identity.createdAt

-- | The @artifactKind@ of a program artifact.
artifactKindProgram :: Text
artifactKindProgram = "shikumi.evidence.program"

-- | The version of the @{shape, params}@ compiled-state layout. The compiled
-- state carries no version of its own, so this package names it.
compiledSchemaVersionCurrent :: Int
compiledSchemaVersionCurrent = 1

-- | Identity and provenance of an artifact.
data ArtifactSpec = ArtifactSpec
  { artifactId :: !Text,
    sources :: ![SourceRef],
    createdAt :: !UTCTime,
    createdBy :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Problems with an artifact.
data ArtifactError
  = MalformedArtifact !Text
  | WrongArtifactKind !Text
  | UnsupportedArtifactVersion !Int
  | UnsupportedCompiledSchema !Int
  | ArtifactDigestMismatch !Digest !Digest
  | EmptyArtifactId
  | InvalidSource !Text
  | ArtifactSchemaMismatch !Text
  | StructureMismatch !Digest !Digest
  | CompiledStateRejected !Text
  deriving stock (Eq, Show)

-- | The digest of a program's shape.
structuralFingerprintOf :: Program i o -> Digest
structuralFingerprintOf = digestValue . toJSON . programShape

-- | The JSON object 'encodeCompiled' emits for a compiled program.
compiledStateOf :: CompiledProgram i o -> Value
compiledStateOf compiled = case decode (encodeCompiled compiled) of
  Just v -> v
  Nothing -> Null

-- | Seal a root artifact for a baseline.
sealBaseline :: ArtifactSpec -> EvidenceCodec i o -> CompiledProgram i o -> Either [ArtifactError] ProgramArtifact
sealBaseline spec codec = sealArtifact spec codec Nothing Nothing

-- | Seal an artifact with an optional parent and optimization record.
sealArtifact ::
  ArtifactSpec -> EvidenceCodec i o -> Maybe Digest -> Maybe OptimizationRecord -> CompiledProgram i o -> Either [ArtifactError] ProgramArtifact
sealArtifact spec codec parent record compiled = do
  let problems = [EmptyArtifactId | T.null spec.artifactId] ++ [InvalidSource e | Left e <- map validateSourceRef spec.sources]
  unless (null problems) (Left problems)
  let artifact =
        resealArtifact
          ProgramArtifact
            { artifactKind = artifactKindProgram,
              schemaVersion = 1,
              identity = spec,
              parentDigest = parent,
              compiledSchemaVersion = compiledSchemaVersionCurrent,
              structuralFingerprint = structuralFingerprintOf (compiledProgram compiled),
              inputSchemaDigest = digestValue codec.inputSchema,
              outputSchemaDigest = digestValue codec.outputSchema,
              compiledState = compiledStateOf compiled,
              optimization = record,
              contentDigest = Digest ""
            }
  artifact <$ validateArtifact artifact

-- | Recompute and store an artifact's digest.
resealArtifact :: ProgramArtifact -> ProgramArtifact
resealArtifact = sealEnvelope (\d a -> a {contentDigest = d})

-- | Decode an artifact: digest on the raw value, exact round trip, validation.
decodeArtifact :: BL.ByteString -> Either [ArtifactError] ProgramArtifact
decodeArtifact bytes = do
  (_, a) <- either (Left . (: []) . MalformedArtifact) Right (decodeEnvelope True bytes)
  a <$ validateArtifact a

-- | Check an artifact's kind, versions, digest and sources.
validateArtifact :: ProgramArtifact -> Either [ArtifactError] ()
validateArtifact a = if null problems then Right () else Left problems
  where
    computed = envelopeDigest (toJSON a)
    problems =
      [WrongArtifactKind a.artifactKind | a.artifactKind /= artifactKindProgram]
        ++ [UnsupportedArtifactVersion a.schemaVersion | a.schemaVersion /= 1]
        ++ [UnsupportedCompiledSchema a.compiledSchemaVersion | a.compiledSchemaVersion /= compiledSchemaVersionCurrent]
        ++ [ArtifactDigestMismatch a.contentDigest computed | a.contentDigest /= computed]
        ++ [EmptyArtifactId | T.null a.artifactId]
        ++ [InvalidSource e | Left e <- map validateSourceRef a.sources]

-- | Validate an artifact against a codec and template and load its state onto
-- the template.
loadArtifact :: EvidenceCodec i o -> Program i o -> ProgramArtifact -> Either [ArtifactError] (CompiledProgram i o)
loadArtifact codec template a = do
  validateArtifact a
  let expectedShape = structuralFingerprintOf template
      problems =
        [ArtifactSchemaMismatch "input" | digestValue (codec.inputSchema) /= a.inputSchemaDigest]
          ++ [ArtifactSchemaMismatch "output" | digestValue (codec.outputSchema) /= a.outputSchemaDigest]
          ++ [StructureMismatch a.structuralFingerprint expectedShape | a.structuralFingerprint /= expectedShape]
  unless (null problems) (Left problems)
  either (Left . (: []) . CompiledStateRejected . T.pack) Right (decodeCompiledOnto template (canonicalJSON a.compiledState))
