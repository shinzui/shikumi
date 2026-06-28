module CompactionSpec (tests) where

import Baikai (_Model, _Usage)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Fixtures
  ( WeatherResp,
    expectedWeather,
    weatherQuestion,
    weatherRegistry,
    weatherSignature,
  )
import MockLLM
  ( mkTextResponse,
    mkUsageResponse,
    runAgent,
    runEffMock,
    runMockLLMThrowingOn,
  )
import Shikumi.Agent.ReAct
  ( Action (..),
    ReActConfig (..),
    Step (..),
    Termination (..),
    ToolProtocol (..),
    Trajectory (..),
    defaultReActConfig,
    reactWithTrajectory,
  )
import Shikumi.Compaction
  ( CompactionConfig (..),
    compactTail,
    defaultCompactionConfig,
    overflowThreshold,
    usageExceedsWindow,
  )
import Shikumi.Error (ShikumiError (..))
import Shikumi.Program (runProgram)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Compaction"
    [ testCase "usageExceedsWindow flips at the boundary" $ do
        let cfg = defaultCompactionConfig {reserveTokens = 100}
            model = _Model & #contextWindow .~ 1000
            usage n = _Usage & #inputTokens .~ n
        overflowThreshold cfg model @?= 900
        usageExceedsWindow cfg model (usage 899) @?= False
        usageExceedsWindow cfg model (usage 900) @?= True
        usageExceedsWindow (cfg {enabled = False}) model (usage 900) @?= False
        usageExceedsWindow cfg _Model (usage 0) @?= False
        overflowThreshold cfg (_Model & #contextWindow .~ 50) @?= 0,
      testCase "compactTail folds older items and keeps the recent tail" $ do
        let cfg = defaultCompactionConfig {keepRecent = 2}
        res <-
          runEffMock [mkTextResponse "S"] $
            compactTail cfg _Model id ("summary:" <>) (["e1", "e2", "e3", "e4", "e5", "e6"] :: [Text])
        res @?= Right ["summary:S", "e5", "e6"],
      testCase "agent on tiny window compacts and completes" $ do
        let cfg =
              defaultReActConfig
                { maxIters = 5,
                  protocol = ProtocolPrompt,
                  compaction = defaultCompactionConfig {reserveTokens = 10, keepRecent = 1}
                }
            model = _Model & #contextWindow .~ 100
            script =
              [ mkUsageResponse model 10 (callReply "first"),
                mkUsageResponse model 90 (callReply "second"),
                mkTextResponse "summary of the first step",
                mkUsageResponse model 10 finishReply,
                mkTextResponse extractReply
              ]
        res <- runAgent script (reactWithTrajectory weatherSignature weatherRegistry cfg) weatherQuestion
        case res of
          Right (o :: WeatherResp, traj) -> do
            o @?= expectedWeather
            termination traj @?= TerminatedFinish
            let ss = V.toList (steps traj)
            assertBool "trajectory contains a summary step" (any isSummary ss)
            case ss of
              [summary, recent, finish] -> do
                assertBool "first step is summary" (isSummary summary)
                case action recent of
                  CallTool "get_weather" _ -> assertBool "recent step records an observation" (observation recent /= Nothing)
                  other -> assertFailure ("recent step should be get_weather, got " <> show other)
                action finish @?= Finish
              other -> assertFailure ("expected summary, recent tool step, finish; got " <> show other)
          Left e -> assertFailure ("agent failed: " <> show e),
      testCase "overflow error is caught, compacted, and retried once" $ do
        let cfg =
              defaultReActConfig
                { maxIters = 5,
                  protocol = ProtocolPrompt,
                  compaction = defaultCompactionConfig {reserveTokens = 10, keepRecent = 0}
                }
            model = _Model & #contextWindow .~ 100
            script =
              [ mkUsageResponse model 10 (callReply "first"),
                mkTextResponse "reactive summary",
                mkTextResponse finishReply,
                mkTextResponse extractReply
              ]
            prog = reactWithTrajectory weatherSignature weatherRegistry cfg
        res <-
          runEff
            . runErrorNoCallStack @ShikumiError
            . runMockLLMThrowingOn [2] (ContextWindowExceeded "context length exceeded") script
            $ runProgram prog weatherQuestion
        case res of
          Right (_ :: WeatherResp, traj) ->
            assertBool "trajectory contains a summary step after recovery" (any isSummary (V.toList (steps traj)))
          Left e -> assertFailure ("agent failed: " <> show e),
      testCase "extract overflow is caught, compacted, and retried once" $ do
        let cfg =
              defaultReActConfig
                { maxIters = 5,
                  protocol = ProtocolPrompt,
                  compaction = defaultCompactionConfig {reserveTokens = 10, keepRecent = 1}
                }
            model = _Model & #contextWindow .~ 100
            script =
              [ mkUsageResponse model 10 (callReply "first"),
                mkTextResponse finishReply,
                mkTextResponse "extract recovery summary",
                mkTextResponse extractReply
              ]
            prog = reactWithTrajectory weatherSignature weatherRegistry cfg
        res <-
          runEff
            . runErrorNoCallStack @ShikumiError
            . runMockLLMThrowingOn [3] (ContextWindowExceeded "context length exceeded") script
            $ runProgram prog weatherQuestion
        case res of
          Right (_ :: WeatherResp, traj) ->
            assertBool "returned trajectory contains extract recovery summary" (any isSummary (V.toList (steps traj)))
          Left e -> assertFailure ("agent failed: " <> show e),
      testCase "overflow retry is bounded to one retry" $ do
        let cfg =
              defaultReActConfig
                { maxIters = 5,
                  protocol = ProtocolPrompt,
                  compaction = defaultCompactionConfig {reserveTokens = 10, keepRecent = 0}
                }
            model = _Model & #contextWindow .~ 100
            script =
              [ mkUsageResponse model 10 (callReply "first"),
                mkTextResponse "reactive summary"
              ]
            prog = reactWithTrajectory weatherSignature weatherRegistry cfg
        res <-
          runEff
            . runErrorNoCallStack @ShikumiError
            . runMockLLMThrowingOn [2, 4] (ContextWindowExceeded "context length exceeded") script
            $ runProgram prog weatherQuestion
        res @?= Left (ContextWindowExceeded "context length exceeded")
    ]

callReply :: Text -> Text
callReply th =
  "{\"thought\": \""
    <> th
    <> "\", \"action\": {\"tool\": \"get_weather\", \"args\": {\"city\": \"Paris\", \"units\": \"c\"}}}"

finishReply :: Text
finishReply = "{\"thought\": \"I have the forecast.\", \"action\": {\"finish\": true}}"

extractReply :: Text
extractReply = "{\"tempC\": 12.0, \"summary\": \"mild\"}"

isSummary :: Step -> Bool
isSummary s = thought s == "(compacted summary of earlier steps)"
