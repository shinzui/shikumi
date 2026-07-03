{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

-- | Node-correlated program execution for the trace (EP-16, M2).
--
-- 'runProgramTraced' is an /additive/ entry point: it runs a
-- 'Shikumi.Program.Program' exactly like 'Shikumi.Program.runProgram' — reusing
-- its render\/parse\/retry\/vote semantics by delegating each @Predict@ leaf to
-- @runProgram@ — but it also opens a trace span per node and threads the active
-- node's 'NodePath' so that each model-call span is tagged with the structural
-- position of the node that issued it. 'Shikumi.Program.runProgram' /
-- 'Shikumi.Program.runProgramConc' are untouched (MasterPlan integration point #4).
--
-- The correlation is threaded by a tiny reader-style 'CurrentNode' effect held in
-- an @IORef@ cell: 'runProgramTraced' wraps each @Predict@ in 'localNode' as it
-- descends (with the same step prefix 'Shikumi.Trace.Node.programNodePaths' uses),
-- and the node-aware capture 'tracedNodeLLM' reads it ('askNode') to stamp the
-- span. The capture and the tag happen inside one 'withSpan', so there is no
-- cross-interpreter ordering subtlety (see the Decision Log of EP-16): use
-- 'tracedNodeLLM' /instead of/ 'Shikumi.Trace.tracedLLM' for a traced-program run.
--
-- Stack shape (note 'runCurrentNode' is outer of 'tracedNodeLLM' so both share the
-- same node cell):
--
-- @
-- runEff . runPrim . runTime . runTrace . runCurrentNode
--   . runKeyedLLM responder    -- base LLM interpreter (stub or real)
--   . tracedNodeLLM            -- opens the LlmCallSpan, fills attrs, tags nodePath
--   $ runProgramTraced program input
-- @
module Shikumi.Trace.Program
  ( -- * The current-node effect
    CurrentNode (..),
    askNode,
    localNode,
    runCurrentNode,

    -- * Node-aware capture and execution
    tracedNodeLLM,
    runProgramTraced,
  )
where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (interpose, interpret, localSeqUnlift, send)
import Effectful.Error.Static (Error, catchError, throwError)
import Effectful.Exception (bracket_)
import Effectful.Prim (Prim)
import Effectful.Prim.IORef (newIORef, readIORef, writeIORef)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..), complete, stream)
import Shikumi.Program
  ( Program
      ( Compose,
        Embed,
        Ensemble,
        FMap,
        MajorityVote,
        Map,
        Parallel,
        Predict,
        Retry,
        RetryWhen,
        Validate
      ),
    acceptOrReject,
    runProgram,
    sampleTemps,
    withSampleTemp,
  )
import Shikumi.Trace
  ( SpanKind (CombinatorSpan, LlmCallSpan, ModuleSpan),
    Trace,
    annotateSpan,
    bumpRetry,
    llmAttrs,
    llmLabel,
    withSpan,
  )
import Shikumi.Trace.Node (NodePath (..), NodeStep (..))

-- ---------------------------------------------------------------------------
-- The current-node effect
-- ---------------------------------------------------------------------------

-- | Carries the 'NodePath' of the node currently executing. 'localNode' sets it
-- for the duration of an inner action; 'askNode' reads it. A dedicated effect
-- (rather than @Effectful.Reader@) keeps the value dynamically scoped as execution
-- descends the program tree without the caller threading it, and keeps
-- 'Shikumi.Program.runProgram'\'s row untouched.
data CurrentNode :: Effect where
  AskNode :: CurrentNode m (Maybe NodePath)
  LocalNode :: NodePath -> m a -> CurrentNode m a

type instance DispatchOf CurrentNode = 'Dynamic

-- | The node currently executing, if any.
askNode :: (CurrentNode :> es) => Eff es (Maybe NodePath)
askNode = send AskNode

-- | Run an action with the given node marked as current.
localNode :: (CurrentNode :> es) => NodePath -> Eff es a -> Eff es a
localNode p act = send (LocalNode p act)

-- | Discharge 'CurrentNode' with a mutable cell (via 'Prim'). Because the cell is
-- shared, an 'askNode' issued from a lower interpose ('tracedNodeLLM') sees the
-- value a higher 'localNode' set, which is exactly how a model call is correlated
-- to its issuing node.
--
-- The cell is dynamically scoped for sequential execution. Do not compose
-- 'runCurrentNode'\/'tracedNodeLLM' with 'Shikumi.Program.runProgramConc': sibling
-- branches would share one mutable current-node slot and could mis-scope paths.
runCurrentNode :: (Prim :> es) => Eff (CurrentNode : es) a -> Eff es a
runCurrentNode act = do
  ref <- newIORef Nothing
  interpret
    ( \env -> \case
        AskNode -> readIORef ref
        LocalNode p inner -> do
          old <- readIORef ref
          bracket_
            (writeIORef ref (Just p))
            (writeIORef ref old)
            (localSeqUnlift env (\unlift -> unlift inner))
    )
    act

-- ---------------------------------------------------------------------------
-- Node-aware capture
-- ---------------------------------------------------------------------------

-- | Like 'Shikumi.Trace.tracedLLM' but also stamps the active 'NodePath' onto each
-- model-call span. The capture (model\/prompt\/response\/cost) and the node tag are
-- written inside the /same/ 'withSpan', so the tag always lands on the LM-call span
-- — no dependence on interpose ordering relative to a separate capture layer.
tracedNodeLLM :: (Trace :> es, CurrentNode :> es, LLM :> es) => Eff es a -> Eff es a
tracedNodeLLM = interpose $ \_ -> \case
  Complete m c o -> withSpan LlmCallSpan (llmLabel m) $ do
    resp <- complete m c o
    mp <- askNode
    annotateSpan (\_ -> llmAttrs m c o resp & #nodePath .~ mp)
    pure resp
  Stream m c o -> withSpan LlmCallSpan (llmLabel m) (stream m c o)

-- ---------------------------------------------------------------------------
-- Node-correlated execution
-- ---------------------------------------------------------------------------

-- | Run a program like 'Shikumi.Program.runProgram', opening a span per node and
-- tagging each model-call span with the issuing node's 'NodePath'. The step prefix
-- accumulated as it descends is the same one 'Shikumi.Trace.Node.programNodePaths'
-- builds, so a @Predict@ leaf's path here equals the path that enumeration assigns
-- it. Each @Predict@ leaf delegates to @runProgram@ (reusing its exact semantics);
-- the combinators are mirrored with spans and the same control flow.
runProgramTraced ::
  forall i o es.
  (LLM :> es, Trace :> es, CurrentNode :> es, Error ShikumiError :> es) =>
  Program i o ->
  i ->
  Eff es o
runProgramTraced = go []
  where
    go :: forall x y. [NodeStep] -> Program x y -> x -> Eff es y
    go prefix node@(Predict _ _) i =
      withSpan ModuleSpan "Predict" (localNode (NodePath (reverse prefix)) (runProgram node i))
    go prefix (Compose f g) i =
      withSpan CombinatorSpan "Compose" (go (StepComposeL : prefix) f i >>= go (StepComposeR : prefix) g)
    go prefix (FMap k p) i =
      withSpan CombinatorSpan "FMap" (k <$> go (StepFMap : prefix) p i)
    go prefix (Map _ p) xs =
      withSpan CombinatorSpan "Map" (traverse (go (StepMap : prefix) p) xs)
    go prefix (Parallel a b) i =
      withSpan CombinatorSpan "Parallel" ((,) <$> go (StepParallelL : prefix) a i <*> go (StepParallelR : prefix) b i)
    go prefix (Retry n p) i =
      withSpan CombinatorSpan "Retry" (tracedRetry (go (StepRetry : prefix)) (const True) n p i)
    go prefix (RetryWhen ok n p) i =
      withSpan CombinatorSpan "RetryWhen" (tracedRetry (go (StepRetryWhen : prefix)) ok n p i)
    go prefix (Validate v p) i =
      withSpan CombinatorSpan "Validate" (go (StepValidate : prefix) p i >>= acceptOrReject v)
    go prefix (MajorityVote k sched reduce p) i =
      withSpan CombinatorSpan "MajorityVote" $
        reduce <$> traverse (\mt -> withSampleTemp mt (go (StepMajorityVote : prefix) p i)) (sampleTemps k sched)
    go prefix (Ensemble ps reduce) i =
      withSpan CombinatorSpan "Ensemble" $
        reduce <$> sequence [go (StepEnsemble idx : prefix) p i | (idx, p) <- zip [0 ..] ps]
    go _ (Embed f) i =
      withSpan CombinatorSpan "Embed" (f i)

tracedRetry ::
  (Trace :> es, Error ShikumiError :> es) =>
  (Program x y -> x -> Eff es y) ->
  (ShikumiError -> Bool) ->
  Int ->
  Program x y ->
  x ->
  Eff es y
tracedRetry run ok n p i = attempt (max 1 n)
  where
    attempt left =
      run p i `catchError` \_cs e ->
        if ok e && left > 1
          then bumpRetry >> attempt (left - 1)
          else throwError e
