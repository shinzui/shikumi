module ObservationSpec (tests) where

import Data.Aeson (ToJSON, toJSON)
import Data.IORef (newIORef)
import Data.Text (Text)
import Effectful (liftIO, runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Concurrent.Async (mapConcurrently)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Prim (runPrim)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError)
import Shikumi.Module (predict, predictCaptured)
import Shikumi.Program (Program (..))
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)
import Shikumi.Trace.Observation
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import TraceFixtures (mkResponse, runSequencedLLM)

newtype Cell = Cell {cell :: Text} deriving stock (Eq, Show, Generic)

instance ToJSON Cell

instance ToSchema Cell

instance FromModel Cell

instance ToPrompt Cell

instance Validatable Cell

leaf :: Program Cell Cell
leaf = predictCaptured (mkSignature "Echo")

run :: Program i o -> i -> [Text] -> IO (Either ShikumiError (Either ShikumiError o, [NodeObservation]))
run p i replies = do
  ref <- newIORef (map mkResponse replies)
  runEff . runPrim . runErrorNoCallStack @ShikumiError . runSequencedLLM ref $ runProgramObserved p i

tests :: TestTree
tests =
  testGroup
    "observations"
    [ testCase "concurrent outer examples retain independent inputs and ordinals" $ do
        results <-
          runEff . runConcurrent $
            mapConcurrently
              (\value -> liftIO (run leaf (Cell value) ["{\"cell\":\"ok\"}"]))
              ["one", "two"]
        let observations = [obs | Right (_, [obs]) <- results]
        map observationInput observations @?= map (Just . toJSON . Cell) ["one", "two"]
        map observationInvocation observations @?= [0, 0],
      testCase "retry keeps evidence but rejects successful leaves in failed validation" $ do
        result <- run (Retry 2 (Validate (\x -> if x == Cell "bad" then Left "reject" else Right x) leaf)) (Cell "input") ["{\"cell\":\"bad\"}", "{\"cell\":\"good\"}"]
        case result of
          Right (out, obs) -> do
            out @?= Right (Cell "good")
            map observationInvocation obs @?= [0, 1]
            map observationEligible obs @?= [False, True]
            map observationOutput obs @?= map (Just . toJSON . Cell) ["bad", "good"]
          Left e -> assertFailure (show e),
      testCase "map repeats a structural path with distinct invocations" $ do
        result <- run (Map 2 leaf) [Cell "a", Cell "b"] ["{\"cell\":\"a\"}", "{\"cell\":\"b\"}"]
        case result of
          Right (_, [a, b]) -> do
            observationPath a @?= observationPath b
            map observationInvocation [a, b] @?= [0, 1]
          other -> assertFailure (show other),
      testCase "root failure returns evidence; missing codec is distinct from failure" $ do
        result <- run (predict (mkSignature "Echo") :: Program Cell Cell) (Cell "a") ["broken"]
        case result of
          Right (Left _, [obs]) -> do
            observationInput obs @?= Nothing
            observationEligible obs @?= False
          other -> assertFailure (show other)
    ]
