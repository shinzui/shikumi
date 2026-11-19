module ArtifactSpec (tests) where

import Data.Aeson (Value (String))
import Data.Either (isLeft, isRight)
import Fixture
import Shikumi.Combinator (retry)
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Evidence
import Shikumi.Program (programParams)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "artifact"
    [ testCase "a baseline loads onto its template" $
        fmap (programParams . compiledProgram) (loadArtifact codec reviewer baselineArtifact) @?= Right (programParams reviewer),
      testCase "a template with a different shape is rejected" $ do
        let result = loadArtifact codec (retry 2 reviewer) baselineArtifact
        assertBool "differently shaped template accepted" (isLeft result)
        assertBool "structure mismatch not reported" (either (any (\case StructureMismatch {} -> True; _ -> False)) (const False) result),
      testCase "a changed schema digest is rejected" $ do
        let otherCodec = codec {outputSchema = String "a different output schema"}
        assertBool "schema change accepted" (isLeft (loadArtifact otherCodec reviewer baselineArtifact)),
      testCase "an artifact round-trips through its canonical file and refuses edits" $ do
        decodeArtifact (encodeEnvelope baselineArtifact) @?= Right baselineArtifact
        let edited = baselineArtifact {identity = baselineArtifact.identity {artifactId = "renamed"}}
        assertBool "edited artifact accepted" (isLeft (decodeArtifact (encodeEnvelope edited)))
        assertBool "resealed artifact rejected" (isRight (decodeArtifact (encodeEnvelope (resealArtifact edited)))),
      testCase "an invalid RepoRef is refused" $ do
        let bad = ArtifactSpec "x" [SourceRef "program-template" "repo" "main"] fixedTime "fixture"
        assertBool "branch name accepted as a revision" (isLeft (sealBaseline bad codec (CompiledProgram reviewer)))
    ]
