-- | Finite, trusted typed implementations. Identity is a caller-owned contract:
-- advance revisions whenever signatures, reducers or opaque code change.
module Shikumi.Compile.Structure
  ( RecipeId,
    recipeIdText,
    RecipeRevision,
    recipeRevisionNumber,
    RegistryId,
    registryIdText,
    StructureRecipe,
    recipeId,
    recipeRevision,
    recipeDescription,
    recipeProgram,
    StructureRegistry,
    registryId,
    registryRecipes,
    registryInputSchema,
    registryOutputSchema,
    StructureRegistryError (..),
    structureRecipe,
    structureRegistry,
    lookupRecipe,
    directCotRegistry,
  )
where

import Control.Monad (unless)
import Data.Aeson (Value)
import Data.List (find, nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Shikumi.Compile.ChainOfThought (chainOfThoughtCompiler)
import Shikumi.Compile.Types (Compiler (..))
import Shikumi.Program (Program, emptyParams, programParams)
import Shikumi.Schema (ToSchema (..))

newtype RecipeId = RecipeId {recipeIdText :: Text} deriving stock (Eq, Ord, Show)

newtype RecipeRevision = RecipeRevision {recipeRevisionNumber :: Int} deriving stock (Eq, Ord, Show)

newtype RegistryId = RegistryId {registryIdText :: Text} deriving stock (Eq, Ord, Show)

-- Constructors and record labels are private, so record updates cannot bypass
-- registry validation or replace its typed schema evidence.
data StructureRecipe i o = StructureRecipe RecipeId RecipeRevision Text (Program i o)

data StructureRegistry i o = StructureRegistry RegistryId Value Value (NonEmpty (StructureRecipe i o))

recipeId :: StructureRecipe i o -> RecipeId
recipeId (StructureRecipe x _ _ _) = x

recipeRevision :: StructureRecipe i o -> RecipeRevision
recipeRevision (StructureRecipe _ x _ _) = x

recipeDescription :: StructureRecipe i o -> Text
recipeDescription (StructureRecipe _ _ x _) = x

recipeProgram :: StructureRecipe i o -> Program i o
recipeProgram (StructureRecipe _ _ _ x) = x

registryId :: StructureRegistry i o -> RegistryId
registryId (StructureRegistry x _ _ _) = x

registryInputSchema :: StructureRegistry i o -> Value
registryInputSchema (StructureRegistry _ x _ _) = x

registryOutputSchema :: StructureRegistry i o -> Value
registryOutputSchema (StructureRegistry _ _ x _) = x

registryRecipes :: StructureRegistry i o -> NonEmpty (StructureRecipe i o)
registryRecipes (StructureRegistry _ _ _ x) = x

data StructureRegistryError
  = EmptyRecipeId
  | InvalidRecipeRevision Text Int
  | EmptyRegistryId
  | EmptyRegistry
  | DuplicateRecipeId Text
  | PopulatedBase
  deriving stock (Eq, Show)

structureRecipe :: Text -> Int -> Text -> Program i o -> Either StructureRegistryError (StructureRecipe i o)
structureRecipe ident revision description program = do
  unless (not (T.null (T.strip ident))) (Left EmptyRecipeId)
  unless (revision > 0) (Left (InvalidRecipeRevision ident revision))
  pure (StructureRecipe (RecipeId ident) (RecipeRevision revision) description program)

structureRegistry :: forall i o. (ToSchema i, ToSchema o) => Text -> [StructureRecipe i o] -> Either StructureRegistryError (StructureRegistry i o)
structureRegistry ident recipes = do
  unless (not (T.null (T.strip ident))) (Left EmptyRegistryId)
  rs <- maybe (Left EmptyRegistry) Right (NE.nonEmpty recipes)
  let ids = map recipeId recipes
  case find (\x -> length (filter (== x) ids) > 1) (nub ids) of
    Just duplicate -> Left (DuplicateRecipeId (recipeIdText duplicate))
    Nothing -> pure (StructureRegistry (RegistryId ident) (toSchema (Proxy @i)) (toSchema (Proxy @o)) rs)

lookupRecipe :: RecipeId -> StructureRegistry i o -> Maybe (StructureRecipe i o)
lookupRecipe ident = find ((== ident) . recipeId) . registryRecipes

-- | Register @direct@ then @cot@, both revision 1. Reject any populated
-- parameters; explicitly use @mapParams (const emptyParams)@ first if desired.
-- Independently optimized variants should use 'structureRecipe' instead.
directCotRegistry :: (ToSchema i, ToSchema o) => Text -> Program i o -> Either StructureRegistryError (StructureRegistry i o)
directCotRegistry ident base = do
  unless (all (== emptyParams) (programParams base)) (Left PopulatedBase)
  direct <- structureRecipe "direct" 1 "Direct base program" base
  cot <- structureRecipe "cot" 1 "Reasoning then projection" (runCompiler chainOfThoughtCompiler base)
  structureRegistry ident [direct, cot]
