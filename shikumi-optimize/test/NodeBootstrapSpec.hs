module NodeBootstrapSpec (tests) where

import Baikai (AssistantContent (..), emptyResponse, emptyTextContent)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (ToJSON, object, toJSON, (.=))
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (Prim, runPrim)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Compile.Serialize (decodeCompiledOnto, encodeCompiled)
import Shikumi.Compile.Types (compiledProgram)
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval (Dataset, dataset, exactMatch, example)
import Shikumi.LLM (LLM (..))
import Shikumi.Module (predict, predictCaptured)
import Shikumi.Optimize
import Shikumi.Program (CaptureCodec (..), Demo (..), Params (..), Program (..), emptyParams, mapParamsAt, programParams, runProgram)
import Shikumi.Schema (FromModel, ToSchema, Validatable, deriveSchema)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Trace.Node (NodePath (..), NodeStep (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

newtype Question = Question {question :: Text} deriving stock (Eq, Show, Generic)

instance ToJSON Question

instance ToSchema Question

instance FromModel Question

instance ToPrompt Question

instance Validatable Question

newtype City = City {city :: Text} deriving stock (Eq, Show, Generic)

instance ToJSON City

instance ToSchema City

instance FromModel City

instance ToPrompt City

instance Validatable City

newtype Country = Country {country :: Text} deriving stock (Eq, Show, Generic)

instance ToJSON Country

instance ToSchema Country

instance FromModel Country

instance ToPrompt Country

instance Validatable Country

citySig :: Signature Question City
citySig = mkSignature "Extract city"

countrySig :: Signature City Country
countrySig = mkSignature "Resolve country"

program :: Program Question Country
program = Compose (predictCaptured citySig) (predictCaptured countrySig)

train :: Dataset Question Country
train = dataset [example (Question "Where is Paris?") (Country "France")]

expected :: [[Demo]]
expected = [[Demo (toJSON (Question "Where is Paris?")) (toJSON (City "Paris"))], [Demo (toJSON (City "Paris")) (toJSON (Country "France"))]]

runCity :: IORef Int -> Eff '[LLM, Error ShikumiError, Concurrent, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runCity calls =
  runEff
    . runPrim
    . runTime
    . runConcurrent
    . runErrorNoCallStack @ShikumiError
    . interpret
      ( \_ -> \case
          Complete _ ctx _ -> do
            liftIO (modifyIORef' calls (+ 1))
            callNumber <- liftIO (readIORef calls)
            let prompt = fromMaybe "" (ctx ^. #systemPrompt)
                canAnswer = not ("Student" `T.isInfixOf` prompt) || V.length (ctx ^. #messages) > 1
                body
                  | "Retry country" `T.isInfixOf` prompt && callNumber == 2 = "{\"country\":\"Spain\"}"
                  | "Extract city" `T.isInfixOf` prompt = if canAnswer then "{\"city\":\"Paris\"}" else "{\"city\":\"Lyon\"}"
                  | otherwise = if canAnswer then "{\"country\":\"France\"}" else "{\"country\":\"Spain\"}"
            pure (emptyResponse & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ body)))
          Stream {} -> pure []
      )

recover :: (LLM :> es, Error ShikumiError :> es, Prim :> es) => NodeBootstrapConfig -> Program Question Country -> Program i o -> Eff es (Map.Map NodePath [Demo], BootstrapReport)
recover cfg teacher student = do
  meter <- newBudgetMeter defaultBudget
  bootstrapNodeDemos cfg meter teacher train exactMatch student

tests :: TestTree
tests =
  testGroup
    "node-local bootstrap"
    [ testCase "bootstrap excludes successful leaves from a rejected retry attempt" $ do
        calls <- newIORef 0
        let retryTeacher =
              Retry
                2
                ( Validate
                    (\out -> if out == Country "France" then Right out else Left "retry")
                    (mapParamsAt 1 (\ps -> ps {instructionOverride = Just "Retry country"}) program)
                )
            cfg =
              defaultNodeBootstrapConfig
                { nodeMapping =
                    Just
                      [ (NodePath [StepRetry, StepValidate, StepComposeL], NodePath [StepComposeL]),
                        (NodePath [StepRetry, StepValidate, StepComposeR], NodePath [StepComposeR])
                      ]
                }
        result <- runCity calls (recover cfg retryTeacher program)
        case result of Right (pools, _) -> Map.elems pools @?= expected; Left e -> assertFailure (show e)
        readIORef calls >>= (@?= 4),
      testCase "explicit mapping handles a differently wrapped teacher" $ do
        calls <- newIORef 0
        let wrapped = Validate Right program
            pairs = [(NodePath [StepValidate, StepComposeL], NodePath [StepComposeL]), (NodePath [StepValidate, StepComposeR], NodePath [StepComposeR])]
        automatic <- runCity calls (recover defaultNodeBootstrapConfig wrapped program)
        case automatic of Left (ValidationFailure _) -> pure (); _ -> assertFailure "expected explicit mapping requirement"
        readIORef calls >>= (@?= 0)
        mapped <- runCity calls (recover (defaultNodeBootstrapConfig {nodeMapping = Just pairs}) wrapped program)
        case mapped of Right (pools, _) -> Map.elems pools @?= expected; Left e -> assertFailure (show e),
      testCase "compatible predictors use independent seeded subsets" $ do
        calls <- newIORef 0
        let parallel = Parallel (predictCaptured citySig) (predictCaptured citySig)
            examples = dataset [example (Question (T.pack (show n))) (City "Paris", City "Paris") | n <- [1 .. 12 :: Int]]
            cfg = defaultNodeBootstrapConfig {nodeSeed = Just 17, nodeBootstrapConfig = BootstrapConfig 1 3}
            collect = do
              meter <- newBudgetMeter defaultBudget
              bootstrapNodeDemos cfg meter parallel examples exactMatch parallel
        first <- runCity calls collect
        again <- runCity calls collect
        first @?= again
        case first of
          Right (pools, _) -> case Map.elems pools of
            [a, b] -> do
              map length [a, b] @?= [3, 3]
              assertBool "independent subsets" (a /= b)
            _ -> assertFailure "expected two nodes"
          Left e -> assertFailure (show e),
      testCase "duplicate targets require explicit merge" $ do
        calls <- newIORef 0
        let parallel = Parallel (predictCaptured citySig) (predictCaptured citySig)
            examples = dataset [example (Question "Paris?") (City "Paris", City "Paris")]
            cfg = defaultNodeBootstrapConfig {nodeMapping = Just [(NodePath [StepParallelL], NodePath []), (NodePath [StepParallelR], NodePath [])]}
            collect c = do
              meter <- newBudgetMeter defaultBudget
              bootstrapNodeDemos c meter parallel examples exactMatch (predictCaptured citySig)
        rejected <- runCity calls (collect cfg)
        case rejected of Left (ValidationFailure _) -> pure (); _ -> assertFailure "expected duplicate rejection"
        readIORef calls >>= (@?= 0)
        merged <- runCity calls (collect (cfg {mergeTargetMappings = True}))
        case merged of Right (pools, _) -> map length (Map.elems pools) @?= [2]; Left e -> assertFailure (show e),
      testCase "heterogeneous demos run and round-trip onto the capture template" $ do
        calls <- newIORef 0
        result <- runCity calls $ do
          cp <- optimize (bootstrapFewShot program defaultBudget) train exactMatch program
          out <- runProgram (compiledProgram cp) (Question "Where is Paris?")
          pure (cp, out)
        case result of
          Left e -> assertFailure (show e)
          Right (cp, out) -> do
            out @?= Country "France"
            map demos (programParams (compiledProgram cp)) @?= expected
            case decodeCompiledOnto program (encodeCompiled cp) of
              Left e -> assertFailure e
              Right restored -> do
                map demos (programParams (compiledProgram restored)) @?= expected
                replay <- runCity calls (runProgram (compiledProgram restored) (Question "Where is Paris?"))
                replay @?= Right (Country "France"),
      testCase "incompatible mappings fail before calls" $ do
        calls <- newIORef 0
        let cfg = defaultNodeBootstrapConfig {nodeMapping = Just [(NodePath [StepComposeL], NodePath [StepComposeR])]}
        result <- runCity calls (recover cfg program program)
        case result of Left (ValidationFailure _) -> pure (); _ -> assertFailure "expected preflight rejection"
        readIORef calls >>= (@?= 0),
      testCase "uncaptured composite fails before calls" $ do
        calls <- newIORef 0
        result <- runCity calls (recover defaultNodeBootstrapConfig (Compose (predict citySig) (predict countrySig)) program)
        case result of Left (ValidationFailure msg) -> assertBool "actionable" ("predictCaptured" `T.isInfixOf` msg); _ -> assertFailure "expected missing codec"
        readIORef calls >>= (@?= 0),
      testCase "failed root contributes no demos" $ do
        calls <- newIORef 0
        let failed = Validate (const (Left "rejected")) program
            cfg = defaultNodeBootstrapConfig {nodeMapping = Just [(NodePath [StepValidate, StepComposeL], NodePath [StepComposeL]), (NodePath [StepValidate, StepComposeR], NodePath [StepComposeR])]}
        result <- runCity calls (recover cfg failed program)
        case result of Right (pools, _) -> Map.elems pools @?= [[], []]; Left e -> assertFailure (show e),
      testCase "a dishonest codec is rejected by target decoding" $ do
        calls <- newIORef 0
        let codec = CaptureCodec toJSON (const (object ["wrong" .= ("Paris" :: Text)])) (deriveSchema @Question) (deriveSchema @City)
            bad = Compose (PredictCaptured codec citySig emptyParams) (predictCaptured countrySig)
        result <- runCity calls (recover defaultNodeBootstrapConfig bad program)
        case result of
          Right (pools, BootstrapReport notes) -> do
            Map.lookup (NodePath [StepComposeL]) pools @?= Just []
            assertBool "diagnostic" (not (null notes))
          Left e -> assertFailure (show e),
      testCase "seeded pools reproduce and obey per-node caps" $ do
        calls <- newIORef 0
        let cfg = defaultNodeBootstrapConfig {nodeSeed = Just 17, nodeBootstrapConfig = BootstrapConfig 1 1}
        a <- runCity calls (recover cfg program program)
        b <- runCity calls (recover cfg program program)
        a @?= b
        case a of Right (pools, _) -> map length (Map.elems pools) @?= [1, 1]; Left e -> assertFailure (show e),
      testCase "random search accepts a heterogeneous capture program" $ do
        calls <- newIORef 0
        let student =
              mapParamsAt 0 (\ps -> ps {instructionOverride = Just "Student Extract city"}) $
                mapParamsAt 1 (\ps -> ps {instructionOverride = Just "Student Resolve country"}) program
        result <- runCity calls (optimize (bootstrapRandomSearch program 2 defaultBudget) train exactMatch student)
        case result of
          Right cp -> do
            map demos (programParams (compiledProgram cp)) @?= expected
            runCity calls (runProgram (compiledProgram cp) (Question "Paris?")) >>= (@?= Right (Country "France"))
          Left e -> assertFailure (show e),
      testCase "MIPRO builds separate valid node candidate pools" $ do
        calls <- newIORef 0
        result <- runCity calls (bootstrapDemoCandidates ((miprov2Auto Miprov2Light) {numDemoCandidates = 4}) program train exactMatch program)
        case result of
          Right sets -> map (filter (not . null)) sets @?= map (: []) expected
          Left e -> assertFailure (show e)
    ]
