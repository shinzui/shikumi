module RequestDefaultsSpec (tests) where

import Baikai (ToolChoice (..), emptyContext, emptyModel, emptyOptions, emptyResponse)
import Baikai.Evidence qualified as E
import Baikai.Speed (Speed (..))
import Baikai.ThinkingLevel (ThinkingLevel (..))
import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..))
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Effectful (liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack)
import Shikumi.Error (ShikumiError (..), isTransient)
import Shikumi.LLM (LLM (..), complete, stream)
import Shikumi.LLM.Defaults
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

defaults :: RequestDefaults
defaults = RequestDefaults (Just ThinkingHigh) (Just SpeedFast) (Just 4096) (Just (E.evidenceRequest "default"))

tests :: TestTree
tests =
  testGroup
    "Request defaults"
    [ testCase "empty is identity and unrelated policy and metadata survive" $ do
        let opts =
              emptyOptions
                & #temperature .~ Just 0.7
                & #toolChoice .~ Just ToolChoiceAuto
                & #metadata .~ Map.fromList [("shikumi.continuation.v1", String "protected"), ("schema", Bool True)]
        applyRequestDefaults emptyRequestDefaults opts @?= opts
        let merged = applyRequestDefaults defaults opts
        merged ^. #temperature @?= opts ^. #temperature
        merged ^. #toolChoice @?= opts ^. #toolChoice
        merged ^. #metadata @?= opts ^. #metadata
        merged @?= (opts & #thinking .~ Just ThinkingHigh & #speed .~ Just SpeedFast & #maxTokens .~ Just 4096 & #evidence .~ defaultEvidence defaults),
      testCase "explicit fields and whole evidence object override every default" $ do
        let evidence = (E.evidenceRequest "explicit") {E.strictness = E.EvidenceRequired E.EvidenceFullyObserved, E.attempt = 3, E.supersedes = Just "previous"}
            opts = emptyOptions & #thinking .~ Just ThinkingLow & #speed .~ Just SpeedStandard & #maxTokens .~ Just 12 & #evidence .~ Just evidence
        applyRequestDefaults defaults opts @?= opts
        applyRequestDefaults defaults (applyRequestDefaults defaults emptyOptions) @?= applyRequestDefaults defaults emptyOptions,
      testCase "blocking and streaming use nearest scope and preserve explicit values" $ do
        ref <- newIORef []
        result <- runEff
          . runErrorNoCallStack @ShikumiError
          . interpret
            ( \_ -> \case
                Complete _ _ o -> liftIO (modifyIORef' ref (++ [o])) >> pure emptyResponse
                Stream _ _ o -> liftIO (modifyIORef' ref (++ [o])) >> pure []
            )
          . withRequestDefaults defaults
          $ do
            _ <- complete emptyModel emptyContext emptyOptions
            withRequestDefaults (emptyRequestDefaults {defaultSpeed = Just SpeedStandard}) $ do
              _ <- stream emptyModel emptyContext emptyOptions
              _ <- complete emptyModel emptyContext (emptyOptions & #speed .~ Just SpeedFast)
              pure ()
        result @?= Right ()
        captured <- readIORef ref
        map (^. #speed) captured @?= [Just SpeedFast, Just SpeedStandard, Just SpeedFast]
        map (^. #thinking) captured @?= replicate 3 (Just ThinkingHigh)
        map (^. #evidence) captured @?= replicate 3 (defaultEvidence defaults),
      testCase "zero default ceiling rejects before either dispatch or action" $ do
        ref <- newIORef (0 :: Int)
        result <- runEff
          . runErrorNoCallStack @ShikumiError
          . interpret
            ( \_ -> \case
                Complete {} -> liftIO (modifyIORef' ref (+ 1)) >> pure emptyResponse
                Stream {} -> liftIO (modifyIORef' ref (+ 1)) >> pure []
            )
          . withRequestDefaults (defaults {defaultMaxTokens = Just 0})
          $ do
            liftIO (modifyIORef' ref (+ 1))
            _ <- complete emptyModel emptyContext (emptyOptions & #maxTokens .~ Just 12)
            pure ()
        result @?= Left (ValidationFailure "request defaults: defaultMaxTokens must be positive")
        readIORef ref >>= (@?= 0)
        isTransient (ValidationFailure "invalid configuration") @?= False,
      testCase "concurrent invocations retain independent settings" $ do
        let run :: Speed -> IO [Maybe Speed]
            run speed = do
              ref <- newIORef []
              r <- runEff
                . runErrorNoCallStack @ShikumiError
                . interpret
                  ( \_ -> \case
                      Complete _ _ o -> liftIO (modifyIORef' ref (++ [o ^. #speed])) >> pure emptyResponse
                      Stream _ _ o -> liftIO (modifyIORef' ref (++ [o ^. #speed])) >> pure []
                  )
                . withRequestDefaults (emptyRequestDefaults {defaultSpeed = Just speed})
                $ do
                  _ <- complete emptyModel emptyContext emptyOptions
                  _ <- stream emptyModel emptyContext emptyOptions
                  pure ()
              r @?= Right ()
              readIORef ref
        a <- newEmptyMVar
        b <- newEmptyMVar
        _ <- forkFinally (run SpeedFast) (putMVar a)
        _ <- forkFinally (run SpeedStandard) (putMVar b)
        takeMVar a >>= either (assertFailure . show) (@?= replicate 2 (Just SpeedFast))
        takeMVar b >>= either (assertFailure . show) (@?= replicate 2 (Just SpeedStandard))
    ]
