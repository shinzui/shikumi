module StructureSpec (tests) where

import Data.Aeson (Value (Null), eitherDecode, encode)
import Data.Either (isLeft)
import Data.List.NonEmpty qualified as NE
import Shikumi.Compile
import Shikumi.Program (programShape)
import Test.Capture (runWithCapture)
import Test.Fixtures
import Test.Tasty
import Test.Tasty.HUnit

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

tests :: TestTree
tests =
  testGroup
    "typed structures"
    [ testCase "invalid metadata rejected" $ do
        assertBool "empty ID" (isLeft (structureRecipe " " 1 "" qaBase))
        assertBool "revision" (isLeft (structureRecipe "a" 0 "" qaBase))
        a <- right (structureRecipe "a" 1 "" qaBase)
        assertBool "empty registry" (isLeft (structureRegistry "r" ([] :: [StructureRecipe Question Answer])))
        assertBool "registry ID" (isLeft (structureRegistry "" [a]))
        assertBool "duplicate" (isLeft (structureRegistry "r" [a, a])),
      testCase "direct/CoT order and distinct shapes" $ do
        r <- right (directCotRegistry "r" qaBase)
        let rs = NE.toList (registryRecipes r)
        map (recipeIdText . recipeId) rs @?= ["direct", "cot"]
        case rs of
          [direct, cot] -> assertBool "different shapes" (programShape (recipeProgram direct) /= programShape (recipeProgram cot))
          _ -> assertFailure "expected direct and cot",
      testCase "populated helper base rejected; explicit pipelines accepted" $ do
        assertBool "no silent deletion" (isLeft (directCotRegistry "r" (compiledProgram (compile (fewShotTyped demoPairs) qaBase))))
        a <- right (structureRecipe "direct" 1 "" qaBase)
        b <- right (structureRecipe "pipeline" 1 "" qaPipeline)
        r <- right (structureRegistry "r" [a, b])
        length (registryRecipes r) @?= 2,
      testCase "artifact restores compatible demos and requests" $ do
        r <- right (directCotRegistry "r" qaBase)
        let ident = recipeId (NE.head (registryRecipes r))
            original = compile (fewShotTyped demoPairs) qaBase
        bytes <- right (encodeStructureArtifact r ident original)
        restored <- right (decodeStructureArtifact r bytes)
        before <- runWithCapture [answerResponse] (compiledProgram original) (Question "test")
        restoredCapture <- runWithCapture [answerResponse] (compiledProgram restored) (Question "test")
        restoredCapture @?= before,
      testCase "artifact incompatibilities are pure categorized failures" $ do
        r <- right (directCotRegistry "r" qaBase)
        let direct = NE.head (registryRecipes r)
            ident = recipeId direct
        bytes <- right (encodeStructureArtifact r ident (compile identity qaBase))
        artifact <- right (eitherDecode bytes)
        let check change expected = case decodeStructureArtifact r (encode (change artifact)) of
              Left err -> err @?= expected
              Right _ -> assertFailure "unexpected compatible artifact"
        check (\a -> a {formatVersion = 2}) (UnsupportedStructureVersion 2)
        check (\a -> a {artifactKind = "production"}) (WrongArtifactKind "production")
        check (\a -> a {artifactRegistryId = "other"}) (RegistryMismatch "r" "other")
        check (\a -> a {artifactRecipeId = "missing"}) (UnknownRecipe "missing")
        check (\a -> a {artifactRecipeRevision = 2}) (RevisionMismatch "direct" 1 2)
        check (\a -> a {inputSchema = Null}) (InputSchemaMismatch "direct")
        check (\a -> a {outputSchema = Null}) (OutputSchemaMismatch "direct")
        check (\a -> a {selectedShape = programShape qaPipeline}) (StructureShapeMismatch "direct")
        check (\a -> a {orderedParams = []}) (StructureParameterCountMismatch "direct" 1 0)
        check (\a -> a {orderedParams = orderedParams a ++ orderedParams a}) (StructureParameterCountMismatch "direct" 1 2)
        assertBool "malformed" (isLeft (decodeStructureArtifact r "{"))
        assertBool "compiled state is a different envelope" (isLeft (decodeStructureArtifact r (encodeCompiled (compile identity qaBase))))
        assertBool "structure envelope is not compiled state" (isLeft (decodeCompiledOnto qaBase bytes))
        assertBool "encode mismatch" (isLeft (encodeStructureArtifact r ident (compile identity qaPipeline)))
        changed <- right (structureRecipe "direct" 2 "" qaBase)
        changedRegistry <- right (structureRegistry "r" [changed])
        assertBool "registry revision changed" (isLeft (decodeStructureArtifact changedRegistry bytes))
    ]
