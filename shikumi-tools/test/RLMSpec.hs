{-# LANGUAGE GADTs #-}

module RLMSpec (tests) where

import Baikai (Model, emptyModel)
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..), object, (.=))
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import GHC.Generics (Generic)
import RLMExample qualified
import Shikumi.Adapter (ToPrompt)
import Shikumi.CodeExec.Prompt (encodeText)
import Shikumi.CodeExec.RLM
import Shikumi.CodeExec.Session
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..))
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema (FromModel, ToSchema, Validatable (..))
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Testing (mkTextResponse)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

newtype Question = Question {question :: Text}
  deriving stock (Generic, Show)
  deriving anyclass (ToPrompt)

newtype Answer = Answer {answer :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

instance Validatable Answer where
  validate (Answer a) = if T.null a then Left "answer must be nonempty" else Right (Answer a)

sig :: Signature Question Answer
sig = mkSignature "Combine the two facts."

-- Capture exact textual request content and selected models; fail if the loop
-- dispatches even one unscripted call (including hidden extraction or repair).
runCaptured :: [Either ShikumiError Text] -> Program Question a -> IO (Either ShikumiError a, [(Model, Text)])
runCaptured script prog = do
  remaining <- newIORef script
  captured <- newIORef []
  out <-
    runEff
      . runErrorNoCallStack @ShikumiError
      . interpret
        ( \_ -> \case
            Complete model ctx _ -> do
              -- Context JSON contains every message and system string, not just a
              -- hand-selected excerpt. Decode-free capture also catches source leaks.
              let rendered = encodeText (object ["system" .= (ctx ^. #systemPrompt), "messages" .= (ctx ^. #messages)])
              liftIO (modifyIORef' captured ((model, rendered) :))
              xs <- liftIO (readIORef remaining)
              case xs of
                [] -> throwError (ProviderFailure "unscripted call")
                x : rest -> do
                  liftIO (modifyIORef' remaining (const rest))
                  either throwError (pure . mkTextResponse) x
            Stream {} -> throwError (ProviderFailure "unexpected stream")
        )
      $ runProgram prog (Question "Find both facts")
  calls <- reverse <$> readIORef captured
  pure (out, calls)

docs :: [(Text, Text)] -> IO ContextStore
docs xs = either (\e -> assertFailure (show e) >> fail "docs") pure (contextStore xs)

submit :: Text -> Text
submit a = encodeText (object ["op" .= ("submit" :: Text), "value" .= object ["answer" .= a]])

expectLimit :: SessionLimit -> Either ShikumiError (RLMOutcome Answer, RLMReport) -> Assertion
expectLimit limit (Right (out, report)) = do
  out @?= RLMExhausted limit
  termination report @?= Just limit
expectLimit _ x = assertFailure (show x)

tests :: TestTree
tests =
  testGroup
    "experimental RLM"
    [ testCase "documented RLM example" $ RLMExample.example >>= (@?= Right ("amber", 1)),
      testCase "two-megabyte source, bounded requests, persisted facts and concurrent isolation" $ do
        a <- newEmptyMVar
        b <- newEmptyMVar
        _ <- forkFinally (largeCase "amber" "owl") (putMVar a)
        _ <- forkFinally (largeCase "violet" "fox") (putMVar b)
        ra <- takeMVar a
        rb <- takeMVar b
        either (assertFailure . show) (@?= Right (Answer "amber owl")) ra
        either (assertFailure . show) (@?= Right (Answer "violet fox")) rb,
      testCase "three-question batch at two-call limit dispatches zero subqueries" $ do
        d <- docs []
        let c = defaultRLMConfig {session = defaultSessionConfig {maxSubqueries = 2}}
        (r, calls) <- runCaptured [Right "{\"op\":\"query_batch\",\"prompts\":[\"a\",\"b\",\"c\"]}"] (rlmWithReport c d sig)
        expectLimit Subqueries r
        length calls @?= 1
        case r of Right (_, rep) -> subqueriesAttempted rep @?= 0; _ -> pure (),
      testCase "accepted batch executes exactly two ordered calls using selected model" $ do
        d <- docs []
        let model = emptyModel & #modelId .~ "submodel"
            c = defaultRLMConfig {session = defaultSessionConfig {maxSubqueries = 2, subModel = model}}
        (r, calls) <- runCaptured (map Right ["{\"op\":\"query_batch\",\"prompts\":[\"first\",\"second\"]}", "one", "two", submit "one two"]) (rlmWithReport c d sig)
        length calls @?= 4
        map ((^. #modelId) . fst) calls @?= ["", "submodel", "submodel", ""]
        case r of
          Right (RLMSubmitted (Answer "one two"), rep) -> do
            subqueriesAttempted rep @?= 2
            operations rep @?= 2
            [observationValue o | row <- audit rep, Just o <- [auditObservation row]] @?= [String "one", String "two"]
          _ -> assertFailure (show r),
      testCase "failed subquery propagates infrastructure error and stops batch" $ do
        d <- docs []
        (r, calls) <- runCaptured [Right "{\"op\":\"query_batch\",\"prompts\":[\"a\",\"b\"]}", Left (Timeout "cancelled")] (rlmWithReport defaultRLMConfig d sig)
        r @?= Left (Timeout "cancelled")
        length calls @?= 2,
      testCase "malformed action and invalid submission recover without extraction" $ do
        d <- docs [("empty", "")]
        (r, calls) <- runCaptured (map Right ["{", "{\"op\":\"submit\",\"value\":{}}", submit "", submit "fixed"]) (rlmWithReport defaultRLMConfig d sig)
        length calls @?= 4
        case r of
          Right (RLMSubmitted (Answer "fixed"), rep) -> operations rep @?= 4
          _ -> assertFailure (show r),
      testCase "outer, operation and observation exhaustion make no extra call" $ do
        d <- docs []
        let bad = Right "{"
        mapM_
          ( \(c, limit) -> do
              (r, calls) <- runCaptured [bad] (rlmWithReport c d sig)
              expectLimit limit r
              length calls @?= 1
          )
          [ (defaultRLMConfig {maxOuterIterations = 1}, OuterIterations),
            (defaultRLMConfig {session = defaultSessionConfig {maxOperations = 1}}, Operations),
            (defaultRLMConfig {session = defaultSessionConfig {maxObservedChars = 1}}, ObservationCharacters)
          ],
      testCase "request bounds are enforced before outer or sub-model dispatch" $ do
        d <- docs []
        (r, calls) <- runCaptured [] (rlmWithReport (defaultRLMConfig {maxRequestChars = 1}) d sig)
        expectLimit RequestCharacters r
        length calls @?= 0
        let c = defaultRLMConfig {maxRequestChars = 4000, session = defaultSessionConfig {maxSubqueryChars = 10000}}
            query = encodeText (object ["op" .= ("query" :: Text), "prompt" .= T.replicate 5000 "q"])
        (r2, calls2) <- runCaptured [Right query] (rlmWithReport c d sig)
        expectLimit RequestCharacters r2
        length calls2 @?= 1,
      testCase "retained action history cannot exceed request ceiling" $ do
        d <- docs []
        let c = defaultRLMConfig {maxRequestChars = 4000}
            action = encodeText (object ["op" .= ("store" :: Text), "name" .= ("memo" :: Text), "value" .= T.replicate 3000 "a"])
        (r, calls) <- runCaptured [Right action] (rlmWithReport c d sig)
        expectLimit RequestCharacters r
        length calls @?= 1,
      testCase "oversized subquery response is explicitly truncated in report and next request" $ do
        d <- docs []
        let c = defaultRLMConfig {session = defaultSessionConfig {maxObservationChars = 200}}
        (r, calls) <- runCaptured (map Right ["{\"op\":\"query\",\"prompt\":\"a\"}", T.replicate 10000 "😀", submit "ok"]) (rlmWithReport c d sig)
        length calls @?= 3
        case r of
          Right (RLMSubmitted _, rep) -> do
            let obs = [o | row <- audit rep, Just o <- [auditObservation row]]
            assertBool "truncation recorded" (any ((/= Nothing) . truncation) obs)
            assertBool "all observations bounded" (all ((<= 200) . T.length . renderObservation) obs)
          _ -> assertFailure (show r),
      testCase "invalid configs fail before any call; convenience maps exhaustion" $ do
        d <- docs []
        mapM_
          ( \c -> do
              (r, calls) <- runCaptured [] (rlmWithReport c d sig)
              case r of Left (ValidationFailure _) -> pure (); _ -> assertFailure (show r)
              length calls @?= 0
          )
          [defaultRLMConfig {maxOuterIterations = 0}, defaultRLMConfig {maxRequestChars = (-1)}, defaultRLMConfig {session = defaultSessionConfig {maxSubqueries = 0}}]
        (r, _) <- runCaptured [] (rlm (defaultRLMConfig {maxRequestChars = 1}) d sig)
        r @?= Left (BudgetExceeded "RLM session exhausted: RequestCharacters")
    ]

largeCase :: Text -> Text -> IO (Either ShikumiError Answer)
largeCase first second = do
  let prefix = "FACT_A=" <> first
      source = prefix <> T.replicate (1500000 - T.length prefix) "." <> "FACT_B=" <> second <> T.replicate 600000 "."
      c = defaultRLMConfig {maxRequestChars = 16000, session = defaultSessionConfig {maxScanChars = 2000000, maxObservationChars = 1000}}
      action op fields = encodeText (object (("op" .= (op :: Text)) : fields))
      script =
        map
          Right
          [ action "load" ["name" .= ("memo" :: Text)],
            action "find" ["name" .= ("source" :: Text), "needle" .= ("FACT_A=" :: Text), "start" .= (0 :: Int), "limit" .= (1 :: Int)],
            action "slice" ["name" .= ("source" :: Text), "start" .= (0 :: Int), "count" .= T.length prefix],
            action "store" ["name" .= ("memo" :: Text), "value" .= first],
            action "find" ["name" .= ("source" :: Text), "needle" .= ("FACT_B=" :: Text), "start" .= (1000000 :: Int), "limit" .= (1 :: Int)],
            action "slice" ["name" .= ("source" :: Text), "start" .= (1500000 :: Int), "count" .= (7 + T.length second)],
            action "load" ["name" .= ("memo" :: Text)],
            action "query" ["prompt" .= ("Combine FACT_A=" <> first <> " and FACT_B=" <> second)],
            first <> " " <> second,
            submit (first <> " " <> second)
          ]
  d <- docs [("source", source)]
  (r, calls) <- runCaptured script (rlmWithReport c d sig)
  assertBool "fixture is at least two megabytes" (T.length source > 2000000)
  length calls @?= 10
  mapM_
    ( \(_, request) -> do
        assertBool "no source copied" (not (source `T.isInfixOf` request))
        assertBool "even serialized capture stays bounded" (T.length request <= maxRequestChars c)
    )
    calls
  case r of
    Right (RLMSubmitted out, rep) -> do
      operations rep @?= 9
      subqueriesAttempted rep @?= 1
      let obs = [o | row <- audit rep, Just o <- [auditObservation row]]
      assertBool "fresh invocation has no memo" (any ((/= Nothing) . observationError) (take 1 obs))
      assertBool "first fact found at source origin" (any ((== object ["matches" .= ([0] :: [Int]), "scannedEnd" .= (2000000 :: Int), "nextOffset" .= (1 :: Int), "complete" .= False]) . observationValue) obs)
      assertBool "second fact sliced at distant source offset" (any ((== object ["name" .= ("source" :: Text), "start" .= (1500000 :: Int), "end" .= (1500007 + T.length second), "text" .= ("FACT_B=" <> second)]) . observationValue) obs)
      assertBool "stored fact is observed" (any ((== String first) . observationValue) obs)
      pure (Right out)
    Right other -> assertFailure (show other) >> pure (Left (ProviderFailure "exhausted"))
    Left e -> pure (Left e)
