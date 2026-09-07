{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Structured evidence from one sequential execution, isolated from other runs.
module Shikumi.Trace.Observation (NodeObservation (..), runProgramObserved) where

import Data.Aeson (Value)
import Data.Either (isRight)
import Data.Text (Text)
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, catchError, throwError)
import Effectful.Prim (Prim)
import Effectful.Prim.IORef (modifyIORef', newIORef, readIORef)
import Shikumi.Adapter (ToPrompt (..))
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM)
import Shikumi.Program (CaptureCodec (..), Program (..), runProgram)
import Shikumi.Trace (SpanKind)
import Shikumi.Trace.Node (NodePath)
import Shikumi.Trace.Program (walkProgramWith)

-- | Invocation numbers start at zero per example, across all leaves. Rejection
-- lineage records the enclosing scope label and its first invocation number.
-- Opaque Embed observations never claim to identify internal predictors.
data NodeObservation = NodeObservation
  { observationPath :: !NodePath,
    observationInvocation :: !Int,
    observationInput :: !(Maybe Value),
    observationInputFields :: ![(Text, Text)],
    observationOutputFields :: ![(Text, Text)],
    observationOutput :: !(Maybe Value),
    observationStatus :: !(Either ShikumiError ()),
    observationEligible :: !Bool,
    observationRejectedBy :: ![(Text, Int)],
    observationOpaque :: !Bool
  }
  deriving stock (Eq, Show)

-- | Typed failures retain observations. Host exceptions and cancellation escape.
-- Uses private Prim cells, so concurrent callers never exchange evidence.
runProgramObserved ::
  forall i o es.
  (LLM :> es, Error ShikumiError :> es, Prim :> es) =>
  Program i o -> i -> Eff es (Either ShikumiError o, [NodeObservation])
runProgramObserved program input = do
  observations <- newIORef []
  next <- newIORef 0
  let scope :: forall a. SpanKind -> Text -> Eff es a -> Eff es a
      scope _ label action = do
        start <- readIORef next
        action `catchError` \_ (err :: ShikumiError) -> do
          modifyIORef'
            observations
            ( map
                ( \obs ->
                    if observationInvocation obs >= start
                      then obs {observationEligible = False, observationRejectedBy = (label, start) : observationRejectedBy obs}
                      else obs
                )
            )
          throwError err
      record ::
        forall x y.
        NodePath ->
        Bool ->
        (x -> Maybe Value) ->
        (y -> Maybe Value) ->
        (x -> [(Text, Text)]) ->
        (y -> [(Text, Text)]) ->
        Program x y ->
        x ->
        Eff es y
      record path opaque encodeIn encodeOut fieldsIn fieldsOut node x = do
        ordinal <- readIORef next
        modifyIORef' next (+ 1)
        result <- (Right <$> runProgram node x) `catchError` \_ err -> pure (Left err)
        let obs =
              NodeObservation
                path
                ordinal
                (encodeIn x)
                (fieldsIn x)
                (either (const []) fieldsOut result)
                (either (const Nothing) encodeOut result)
                (() <$ result)
                (isRight result && not opaque)
                []
                opaque
        modifyIORef' observations (obs :)
        either throwError pure result
      leaf :: forall x y. NodePath -> Program x y -> x -> Eff es y
      leaf path node@(PredictCaptured codec _ _) =
        record
          path
          False
          (Just . encodeCaptureInput codec)
          (Just . encodeCaptureOutput codec)
          toPromptFields
          toPromptFields
          node
      leaf path node@(Predict _ _) = record path False (const Nothing) (const Nothing) toPromptFields toPromptFields node
      leaf path node = record path True (const Nothing) (const Nothing) (const []) (const []) node
  result <- (Right <$> walkProgramWith scope leaf (pure ()) program input) `catchError` \_ err -> pure (Left err)
  obs <- reverse <$> readIORef observations
  pure (result, obs)
