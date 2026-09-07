-- | Experimental finite structure selection using shared operation admission.
module Shikumi.Optimize.Structure (StructureSearchResult (..), structureSearchWith) where

import Control.Monad (forM, unless)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Error.Static (Error, throwError)
import Effectful.Prim (Prim)
import Shikumi.Compile.Structure
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Effect.Time (Time)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval (Dataset, Metric, datasetSize)
import Shikumi.Eval.Report (FailurePolicy)
import Shikumi.LLM (LLM)
import Shikumi.Optimize.Execution
import Shikumi.Optimize.Report
import Shikumi.Optimize.Search (scoringCost)
import Shikumi.Trace.Observation (runProgramObserved)

data StructureSearchResult i o = StructureSearchResult
  { selectedRecipeId :: !RecipeId,
    selectedRecipeRevision :: !RecipeRevision,
    selectedStructure :: !(CompiledProgram i o),
    structureReport :: !OptimizationReport
  }

-- | Training is validated but never evaluated or used for ranking in this finite
-- enumeration. Every supplied recipe is scored on validation only. Callbacks are
-- trusted application code. Width one gives reproducible dispatch scheduling;
-- ties always retain registry order, including with concurrent completion.
structureSearchWith ::
  (LLM :> es, Concurrent :> es, Error ShikumiError :> es, Time :> es, Prim :> es) =>
  RunConfig ->
  Dataset i o ->
  Dataset i o ->
  Metric o ->
  (ShikumiError -> FailurePolicy) ->
  ObjectivePolicy ->
  ObjectiveMetric es o ->
  StructureRegistry i o ->
  Eff es (StructureSearchResult i o)
structureSearchWith cfg training validation metric classify policy objective registry = do
  either throwError pure (validateRunConfig cfg)
  unless
    (datasetSize training > 0 && datasetSize validation > 0)
    (throwError (ValidationFailure "structure search requires nonempty training and validation datasets"))
  either (throwError . ValidationFailure) pure (validateObjectives policy)
  (outcome, report) <- runSearchSession cfg $ \session -> do
    jobs <-
      catMaybes
        <$> forM
          (NE.toList (registryRecipes registry))
          ( \recipe -> do
              reservation <- reserveCandidate session
              forM reservation $ \ident -> do
                annotateCandidate session ident (Map.fromList [("recipeId", recipeIdText (recipeId recipe)), ("recipeRevision", T.pack (show (recipeRevisionNumber (recipeRevision recipe)))), ("registryId", registryIdText (registryId registry))])
                pure (ident, recipe)
          )
    completedRows <-
      evaluateCandidates
        session
        ( \(ident, recipe) -> do
            available <- canStartCandidate session
            if not available
              then pure Nothing
              else do
                addPredictedWork session (scoringCost validation (recipeProgram recipe))
                row <- evaluateCandidate session ident validation (runProgramObserved (recipeProgram recipe)) classify metric policy objective
                pure (Just (recipe, row))
        )
        jobs
    setSelection session "explicit validation; experimental structure search" policy
    let rows = catMaybes completedRows
        winner = selectObjectiveWinner policy (map snd rows)
    pure $ case winner of
      Nothing -> NE.head (registryRecipes registry)
      Just row -> maybe (NE.head (registryRecipes registry)) fst (findRow (candidateId row) rows)
  recipe <- either throwError pure outcome
  pure (StructureSearchResult (recipeId recipe) (recipeRevision recipe) (CompiledProgram (recipeProgram recipe)) report)
  where
    findRow _ [] = Nothing
    findRow ident (x@(_, row) : xs)
      | candidateId row == ident = Just x
      | otherwise = findRow ident xs
