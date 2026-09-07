-- | Versioned experimental artifacts, restored only through trusted caller code.
-- Schema/shape equality detects declared incompatibility; it does not attest to
-- opaque function identity. Owners must advance revisions for behavioral changes.
module Shikumi.Compile.Structure.Serialize
  ( StructureArtifact (..),
    StructureArtifactError (..),
    encodeStructureArtifact,
    decodeStructureArtifact,
  )
where

import Control.Monad (unless)
import Data.Aeson (FromJSON, ToJSON, Value, eitherDecode, encode)
import Data.ByteString.Lazy (ByteString)
import Data.List (find)
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Compile.Structure
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Program (Params, ProgramShape, programParams, programShape, setProgramParams)

data StructureArtifact = StructureArtifact
  { artifactKind :: !Text,
    formatVersion :: !Int,
    artifactRegistryId :: !Text,
    artifactRecipeId :: !Text,
    artifactRecipeRevision :: !Int,
    inputSchema :: !Value,
    outputSchema :: !Value,
    selectedShape :: !ProgramShape,
    orderedParams :: ![Params]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data StructureArtifactError
  = MalformedStructureArtifact String
  | WrongArtifactKind Text
  | UnsupportedStructureVersion Int
  | RegistryMismatch Text Text
  | UnknownRecipe Text
  | RevisionMismatch Text Int Int
  | InputSchemaMismatch Text
  | OutputSchemaMismatch Text
  | StructureShapeMismatch Text
  | StructureParameterCountMismatch Text Int Int
  deriving stock (Eq, Show)

encodeStructureArtifact :: StructureRegistry i o -> RecipeId -> CompiledProgram i o -> Either StructureArtifactError ByteString
encodeStructureArtifact registry ident (CompiledProgram program) = do
  recipe <- maybe (Left (UnknownRecipe (recipeIdText ident))) Right (lookupRecipe ident registry)
  let artifact =
        StructureArtifact
          "shikumi.experimental.structure"
          1
          (registryIdText (registryId registry))
          (recipeIdText ident)
          (recipeRevisionNumber (recipeRevision recipe))
          (registryInputSchema registry)
          (registryOutputSchema registry)
          (programShape program)
          (programParams program)
  _ <- restore registry artifact
  pure (encode artifact)

decodeStructureArtifact :: StructureRegistry i o -> ByteString -> Either StructureArtifactError (CompiledProgram i o)
decodeStructureArtifact registry bytes = do
  artifact <- either (Left . MalformedStructureArtifact) Right (eitherDecode bytes)
  restore registry artifact

restore :: StructureRegistry i o -> StructureArtifact -> Either StructureArtifactError (CompiledProgram i o)
restore registry artifact = do
  unless (artifactKind artifact == "shikumi.experimental.structure") (Left (WrongArtifactKind (artifactKind artifact)))
  unless (formatVersion artifact == 1) (Left (UnsupportedStructureVersion (formatVersion artifact)))
  let expectedRegistry = registryIdText (registryId registry)
      ident = artifactRecipeId artifact
  unless (artifactRegistryId artifact == expectedRegistry) (Left (RegistryMismatch expectedRegistry (artifactRegistryId artifact)))
  recipe <- maybe (Left (UnknownRecipe ident)) Right (find ((== ident) . recipeIdText . recipeId) (registryRecipes registry))
  let revision = recipeRevisionNumber (recipeRevision recipe)
      template = recipeProgram recipe
      count = length (programParams template)
      actual = length (orderedParams artifact)
  unless (artifactRecipeRevision artifact == revision) (Left (RevisionMismatch ident revision (artifactRecipeRevision artifact)))
  unless (inputSchema artifact == registryInputSchema registry) (Left (InputSchemaMismatch ident))
  unless (outputSchema artifact == registryOutputSchema registry) (Left (OutputSchemaMismatch ident))
  unless (selectedShape artifact == programShape template) (Left (StructureShapeMismatch ident))
  unless (actual == count) (Left (StructureParameterCountMismatch ident count actual))
  either (const (Left (StructureParameterCountMismatch ident count actual))) (Right . CompiledProgram) (setProgramParams (orderedParams artifact) template)
