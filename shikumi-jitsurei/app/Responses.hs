-- | Released Responses transport, typed output and completed-turn checkpoints.
-- Default: loopback fixture. Public calls require both --live and explicit opt-in.
module Main (main) where

import Baikai qualified as B
import Baikai.Models.Generated (allModels)
import Baikai.Provider.OpenAI.Responses (openaiResponsesProvider)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (unless)
import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import Data.List (find)
import Data.Text qualified as T
import Data.Text.IO qualified as Text
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Effectful.Prim (runPrim)
import Shikumi.Agent.History qualified as H
import Shikumi.Agent.ReAct qualified as R
import Shikumi.Compaction (CompactionConfig (..))
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Eval.Report qualified as Report
import Shikumi.Eval.Usage (withUsageTotals)
import Shikumi.LLM qualified as L
import Shikumi.LLM.Continuation (hasOpaqueContinuation)
import Shikumi.LLM.Defaults
import Shikumi.LLM.Observation qualified as O
import Shikumi.Program (runProgram)
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Testing.Fixtures (Answer (..), Question (..), instructedProg)
import Shikumi.Testing.Responses
import Shikumi.Tool qualified as Tool
import Shikumi.Tool.Output (textToolOutput)
import Shikumi.Trace qualified as Trace
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import System.Timeout (timeout)

signature :: Signature Question Answer
signature = mkSignature "Use lookup to find the stored city, then submit the city and a confidence between 0 and 1."

tools :: Tool.ToolRegistry
tools = Tool.mkRegistry [Tool.mkDynTool "lookup" "Return the stored city." (object ["type" .= String "object", "properties" .= object []]) (\_ -> pure (Right (textToolOutput "Paris")))]

main :: IO ()
main =
  getArgs >>= \case
    [] ->
      withResponsesFixture
        [ sseReply [completed [messageItem "{\"answer\":\"Paris\",\"confidence\":0.9}"]],
          sseReply [completed [reasoningItem, functionItem "lookup-item" "lookup-call" "lookup" (object [])]],
          sseReply [completed [functionItem "final-item" "final-call" R.finalToolName (object ["answer" .= String "Paris", "confidence" .= (0.9 :: Double)])]]
        ]
        (\f -> demonstrate False (model f) (registry f) fixtureOptions)
    ["--live", "--model", modelId] -> do
      enabled <- lookupEnv "SHIKUMI_RESPONSES_LIVE"
      unless (enabled == Just "1") (die "Live mode requires SHIKUMI_RESPONSES_LIVE=1.")
      key <- lookupEnv "OPENAI_API_KEY" >>= maybe (die "Live mode requires OPENAI_API_KEY.") pure
      unless (not (null key)) (die "OPENAI_API_KEY must not be empty.")
      catalog <-
        maybe
          (die "Unknown OpenAI model in the released Baikai catalog.")
          pure
          (find (\m -> m ^. #provider == "openai" && m ^. #modelId == T.pack modelId) allModels)
      reg <- B.newProviderRegistry
      B.registerApiProviderWith reg openaiResponsesProvider
      let target = catalog & #api .~ B.OpenAIResponses
          opts = B.emptyOptions & #apiKey .~ Just (B.ApiKeyLiteral (T.pack key)) & #timeoutMs .~ Just 15000
      result <- timeout 65000000 (demonstrate True target reg opts)
      maybe (die "Live example exceeded its run timeout.") pure result
    _ -> die "Usage: jitsurei-responses [--live --model MODEL_ID]"

demonstrate :: Bool -> B.Model -> B.ProviderRegistry -> B.Options -> IO ()
demonstrate live model registry transport = do
  (observer, snapshot) <- O.newBillingCollectorWithLimit 8
  let runtime = (L.defaultLLMConfig registry) {L.observer = Just observer, L.retryPolicy = L.RetryPolicy 1 0 0}
      defaults =
        emptyRequestDefaults
          { defaultMaxTokens = Just 256,
            defaultThinking = Just B.ThinkingLow,
            defaultEvidence = Just (B.evidenceRequest "responses-example")
          }
      agent = R.defaultReActConfig {R.protocol = R.ProtocolNative, R.maxIters = 3, R.compaction = CompactionConfig 0 4 False}
  (result, tree) <- runEff
    . runPrim
    . runTime
    . runConcurrent
    . Trace.runTrace
    . runErrorNoCallStack @ShikumiError
    . runRouting model
    . L.runLLMResilient runtime
    . withTransportOptions transport
    . Trace.tracedLLM
    . withRequestDefaults defaults
    . routeLLM
    $ Trace.withSpan Trace.ProgramSpan "Responses workflow" . withUsageTotals
    $ do
      _ <- runProgram instructedProg (Question "Name the capital of France.")
      initial <- R.startSessionWithModel model signature tools agent (Question "Which city is stored?")
      first <- R.advanceSession signature tools agent initial
      case first of
        R.SessionFinished answer finished -> pure (answer, finished, False)
        R.SessionPaused checkpoint -> do
          let bytes = encode (H.encodeSession checkpoint)
              restored = eitherDecode bytes >>= either (Left . show) Right . H.decodeSession
          saved <- either (throwError . ValidationFailure . T.pack) pure restored
          resumed <- R.continueSession signature tools agent (Question "Submit the stored city.") saved
          final <- R.runSession signature tools agent resumed
          case final of
            R.SessionFinished answer finished -> pure (answer, finished, hasOpaqueContinuation (H.promptMessages saved))
            R.SessionPaused _ -> throwError (ValidationFailure "Agent iteration limit reached without a validated answer.")
  billing <- snapshot
  case result of
    Left _ -> do
      -- Raw provider errors may contain request details. The billing view exposes
      -- classification only, and the CLI intentionally keeps this failure terse.
      Text.putStrLn (O.renderBillingSummary billing)
      die "Responses workflow failed; see the terminal classification above."
    Right ((answer, finished, opaqueSent), logical) -> do
      let executions = length [() | H.Exchange _ outputs _ <- H.auditHistory finished, (call, _) <- outputs, call ^. #name /= R.finalToolName]
          attached = Trace.attachBillingSummary billing tree
      unless (live || (executions == 1 && opaqueSent && answer == Answer "Paris" 0.9)) (die "Offline workflow did not meet its checkpoint assertions.")
      putStrLn ("validated answer: " <> show answer)
      putStrLn ("tool executions: " <> show executions)
      putStrLn ("logical usage: calls returned; tokens=" <> show (Report.totalTokens logical) <> ", USD=" <> show (Report.totalCostUsd logical))
      Text.putStrLn (O.renderBillingSummary billing)
      putStrLn ("opaque continuation sent on resume: " <> show opaqueSent)
      putStrLn "Live connectivity alone is not proof of exact reasoning replay; the offline tests inspect outgoing replay JSON."
      Text.putStrLn (Trace.renderTree attached)
