-- | Full offline evaluation through actual transport, runtime, cache and export.
module BillingSpec (tests) where

import Baikai (Response, StopReason (ErrorReason), emptyContext, emptyOptions)
import Baikai.Cost qualified as C
import Baikai.Error qualified as BE
import Baikai.Evidence qualified as E
import Baikai.Usage qualified as U
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (eitherDecode, encode)
import Data.Generics.Labels ()
import Data.HashMap.Strict qualified as HM
import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Data.Ratio ((%))
import Data.Set qualified as Set
import Data.Text qualified as T
import Effectful (liftIO, runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Concurrent.Async (mapConcurrently)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Prim (runPrim)
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Trace.Core qualified as Otel
import Shikumi.Cache (cachedLLM)
import Shikumi.Cache.Backend.Memory (newMemoryCache, runCacheMemory)
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval.Evaluate (evaluateWith)
import Shikumi.Eval.Report qualified as R
import Shikumi.Eval.Types (Example (..), dataset, scoreOne)
import Shikumi.LLM qualified as L
import Shikumi.LLM.Defaults
import Shikumi.LLM.Observation qualified as B
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Testing.Fixtures
import Shikumi.Testing.Transport
import Shikumi.Trace qualified as Tr
import Shikumi.Trace.LiveExport (exportTreeWith)
import Shikumi.Trace.Store (replayIndex)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

-- An estimate followed by provider-reported zero must retain the estimate.
knownUsage :: Rational -> C.CostBasis -> U.Usage
knownUsage amount basis =
  U.zeroUsage
    & #inputTokens .~ 10
    & #totalTokens .~ 10
    & #availability .~ Just (U.UsageAvailability Set.empty False Set.empty)
    & #cost . #usd .~ amount
    & #cost . #basis .~ basis

responseWith :: U.Usage -> Response
responseWith u = validAnswerResponse & #message . #usage .~ u

fixtureEvidence :: E.ModelCallEvidence
fixtureEvidence =
  E.baseEvidence
    (E.evidenceRequest "fixture")
    "fixture-call"
    (E.EndpointIdentity "fixture" "custom" E.TransportHttpApi Nothing "0.7.0.0" Nothing)
    "requested-model"
    E.noThinkingRequested
    instant
    instant
    E.CallSucceeded
    "digest"
    "config"
    & #observedModel .~ E.Observed "observed-model"
  where
    instant = read "2026-09-08 00:00:00 UTC"

tests :: TestTree
tests =
  testGroup
    "EP-61 transport billing"
    [ testCase "evaluation retry, reported zero, missing usage and cache hit stay separate" $ do
        let estimated = C.standardCostBasis <> C.CostBasis Set.empty (Set.singleton C.PricingUnavailable)
            failure =
              responseWith (knownUsage (1 % 100) estimated)
                & #message . #stopReason .~ ErrorReason
                & #errorInfo .~ Just ((BE.providerError "private provider output") {BE.category = BE.TransientError})
            success =
              responseWith (knownUsage (2 % 100) C.providerReportedBasis)
                & #evidence .~ Just fixtureEvidence
            zero = responseWith (knownUsage 0 C.providerReportedBasis & #inputTokens .~ 0 & #totalTokens .~ 0)
            missing =
              responseWith
                ( U.zeroUsage
                    & #availability
                      .~ Just
                        ( U.UsageAvailability
                            (Set.fromList [U.InputUsage, U.OutputUsage, U.CacheReadUsage, U.CacheWriteUsage])
                            False
                            Set.empty
                        )
                    & #cost .~ C.estimateCost [C.UsageNotReported] C.zeroCost
                )
        (model, registry, requests) <- scriptedTransport [failure, success, zero, missing]
        (observer, snapshot) <- B.newBillingCollectorWithLimit 10
        cache <- newMemoryCache
        let cfg = (L.defaultLLMConfig registry) {L.observer = Just observer, L.retryPolicy = L.RetryPolicy 2 0 0}
            ds = dataset [Example (Question q) (Answer "It is forty-two." 0.9) | q <- ["retry", "zero", "missing", "retry"]]
        (result, tree) <-
          runEff
            . runPrim
            . runTime
            . runConcurrent
            . Tr.runTrace
            . runErrorNoCallStack @ShikumiError
            . runRouting model
            . runCacheMemory cache
            . L.runLLMResilient cfg
            . cachedLLM
            . Tr.tracedLLM
            . withRequestDefaults (emptyRequestDefaults {defaultMaxTokens = Just 123})
            . routeLLM
            $ Tr.withSpan Tr.ProgramSpan "billing evaluation"
            $ evaluateWith (R.defaultEvalConfig {R.concurrency = 1}) ds (\_ _ -> pure scoreOne) instructedProg
        report <- either (\e -> assertFailure (show e) >> fail "unreachable") pure result
        summary <- snapshot
        let attached = R.attachBillingSummary summary report
            attachedTree = Tr.attachBillingSummary summary tree
        R.totalCostUsd (R.usage attached) @?= 4 % 100
        C.usd (U.cost (B.getUsage (B.observedUsage summary))) @?= 3 % 100
        B.completedAttempts summary @?= 3
        B.failedAttempts summary @?= 1
        B.unknownUsageAttempts summary @?= 1
        map B.attempt (B.retainedAttempts summary) @?= [1, 2, 1, 1]
        assertBool "estimate survives aggregation" (Set.member C.PricingUnavailable (C.estimateReasons (C.basis (U.cost (B.getUsage (B.observedUsage summary))))))
        captured <- requests
        length captured @?= 4
        assertBool "observer sees effective defaults" (all (\(_, o) -> o ^. #maxTokens == Just 123) captured)
        assertBool "both report views rendered" (all (`T.isInfixOf` R.renderReportText attached) ["logical usage quality", "transport billing", "usage_not_reported", "provider_reported_total"])
        eitherDecode (encode attachedTree) @?= Right attachedTree
        replayIndex attachedTree @?= replayIndex tree
        case replayIndex attachedTree of
          Right index -> Map.size index @?= 3
          Left err -> assertFailure (T.unpack err)
        assertBool "failure text never retained" (not ("private provider output" `T.isInfixOf` B.renderBillingSummary summary))
        (processor, ref) <- inMemoryListExporter
        exportTreeWith processor "billing-test" attachedTree
        emitted <- readIORef ref
        attrs <- mapM (fmap (Attr.getAttributeMap . Otel.hotAttributes) . readIORef . Otel.spanHot) emitted
        let scope name = filter ((== Just (Attr.toAttribute (name :: T.Text))) . HM.lookup "shikumi.accounting.scope") attrs
        length (scope "logical-call") @?= 4
        length (filter (HM.member "gen_ai.response.model") (scope "logical-call")) @?= 1
        length (scope "transport-attempt") @?= 4
        length (scope "transport-summary") @?= 1
        assertBool "requested model is never claimed as observed" (all ((/= Just (Attr.toAttribute ("requested-model" :: T.Text))) . HM.lookup "gen_ai.response.model") attrs)
        assertBool "actual observed identity exported" (any ((== Just (Attr.toAttribute ("observed-model" :: T.Text))) . HM.lookup "gen_ai.response.model") attrs)
        assertBool "billing basis exported" (any (HM.member "shikumi.cost.basis") (scope "transport-attempt"))
        statuses <- mapM (fmap Otel.hotStatus . readIORef . Otel.spanHot) emitted
        assertBool "failed attempt is an error span" (Otel.Error "TransientError" `elem` statuses),
      testCase "FailScore and FailAbort retain terminal failure billing" $ do
        let failure =
              responseWith (knownUsage (1 % 100) C.providerReportedBasis)
                & #message . #stopReason .~ ErrorReason
                & #errorInfo .~ Just ((BE.providerError "refused") {BE.category = BE.ContentFiltered})
            ds = dataset [Example (Question "refuse") (Answer "unused" 1)]
            run policy = do
              (model, registry, _) <- scriptedTransport [failure]
              (observer, snapshot) <- B.newBillingCollector
              result <-
                runEff
                  . runPrim
                  . runTime
                  . runConcurrent
                  . runErrorNoCallStack @ShikumiError
                  . runRouting model
                  . L.runLLMResilient ((L.defaultLLMConfig registry) {L.observer = Just observer})
                  . routeLLM
                  $ evaluateWith (R.defaultEvalConfig {R.failurePolicy = policy}) ds (\_ _ -> pure scoreOne) instructedProg
              summary <- snapshot
              B.failedAttempts summary @?= 1
              C.usd (U.cost (B.getUsage (B.observedUsage summary))) @?= 1 % 100
              pure result
        scored <- run (R.failurePolicy R.defaultEvalConfig)
        case scored of
          Right r -> do R.failCount r @?= 1; R.totalCostUsd (R.usage r) @?= 0
          Left e -> assertFailure (show e)
        aborted <- run R.FailAbort
        assertBool "FailAbort propagates" (either (const True) (const False) aborted),
      testCase "bare completion and stream agree; separate concurrent collectors do not mix" $ do
        let action amount = do
              (model, registry, _) <- scriptedTransport [responseWith (knownUsage amount C.standardCostBasis)]
              (observer, snapshot) <- B.newBillingCollectorWithLimit 2
              _ <-
                runEff . runErrorNoCallStack @ShikumiError . L.runLLMWithObserver registry observer $
                  L.complete model emptyContext emptyOptions
              snapshot
        summaries <- runEff . runConcurrent $ mapConcurrently (liftIO . action) [1 % 3, 2 % 3]
        map (C.usd . U.cost . B.getUsage . B.observedUsage) summaries @?= [1 % 3, 2 % 3]
        a <- action (1 % 3)
        (model, registry, _) <- scriptedTransport [responseWith (knownUsage (1 % 3) C.standardCostBasis) & #evidence .~ Just fixtureEvidence]
        (observer, snapshot) <- B.newBillingCollectorWithLimit 2
        (_, streamTree) <-
          runEff
            . runPrim
            . runTime
            . Tr.runTrace
            . runErrorNoCallStack @ShikumiError
            . L.runLLMWithObserver registry observer
            . Tr.tracedLLM
            $ L.stream model emptyContext emptyOptions
        case Map.elems (Tr.spans streamTree) of
          [span] -> do
            Tr.billingQuality (Tr.attrs span) @?= Just (B.UsageRecord (knownUsage (1 % 3) C.standardCostBasis))
            Tr.observedModel (Tr.attrs span) @?= Just "observed-model"
            Tr.response (Tr.attrs span) @?= Nothing
          _ -> assertFailure "expected one streaming span"
        replayIndex streamTree @?= Right Map.empty
        b <- snapshot
        B.observedUsage a @?= B.observedUsage b
        B.completedAttempts a @?= 1
        B.completedAttempts b @?= 1
    ]
