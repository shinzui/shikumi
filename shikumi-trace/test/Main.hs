-- | EP-7 acceptance test suite. Milestones are selected with tasty's @-p@:
-- @spike@ (M0), @tree@ (M1), @store@ (M2), @replay@ (M3), @e2e@ (M5).
module Main (main) where

import Baikai (Context, Model, Options, Response, user, _Context, _Model, _Options)
import Control.Exception (try)
import Control.Lens ((&), (.~))
import Data.Aeson (Value (Object), decode, encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, addUTCTime)
import Data.Vector qualified as V
import Effectful (Eff, runEff, type (:>))
import Effectful.Prim (runPrim)
import Shikumi.Cache.Key (CacheKey (..))
import Shikumi.Cache.Key qualified as Key
import Shikumi.Effect.Time (runTime)
import Shikumi.LLM (LLM, complete)
import Shikumi.Trace
  ( Span (..),
    SpanAttrs (..),
    SpanId (..),
    SpanKind (..),
    TraceTree (..),
    childrenOf,
    emptyAttrs,
    renderTree,
    runTrace,
    tracedLLM,
    withSpan,
  )
import Shikumi.Trace.Demo (demoArticle, demoPipeline, demoResponder)
import Shikumi.Trace.Internal.Spike qualified as Spike
import Shikumi.Trace.Replay (ReplayDivergence (..), runLLMReplay)
import Shikumi.Trace.Store
  ( TraceFile (..),
    currentFormatVersion,
    readTraceFile,
    replayIndex,
    writeTraceFile,
  )
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (Gen, choose, elements, forAll, testProperty, vectorOf, (===))
import TraceFixtures
  ( ctxFor,
    lastUserText,
    mkResponse,
    optsFor,
    responseText,
    runFixedLLM,
    runKeyedCountingLLM,
    stubModel,
  )

main :: IO ()
main =
  defaultMain $
    testGroup "shikumi-trace" [spikeTests, treeTests, storeTests, replayTests, e2eTests]

-- ---------------------------------------------------------------------------
-- M0
-- ---------------------------------------------------------------------------

-- | M0: the interpose-plus-span-stack mechanism tags each LM call with the
-- enclosing span that was on top of the stack when the call ran.
spikeTests :: TestTree
spikeTests =
  testGroup
    "spike"
    [ testCase "each captured LM call is tagged with its enclosing span id" $ do
        captured <- Spike.runSpike
        map fst captured @?= [Spike.SpanId "draft", Spike.SpanId "critique"]
        map snd captured @?= ["first draft", "a sharp critique"]
    ]

-- ---------------------------------------------------------------------------
-- M1
-- ---------------------------------------------------------------------------

-- | M1: a two-@withSpan@ nest containing two stubbed LM calls produces a tree
-- with one root, two module children, each holding exactly one LM-call leaf;
-- @renderTree@ shows the model lines indented under their modules.
treeTests :: TestTree
treeTests =
  testGroup
    "tree"
    [ testCase "nested withSpans build a program -> module -> llm-call tree" $ do
        tree <- buildTree
        let roots = [s | s <- Map.elems (spans tree), parent s == Nothing]
        length roots @?= 1
        kind (spanAt tree (root tree)) @?= ProgramSpan
        let kids = childrenOf tree (root tree)
        length kids @?= 2
        map (kind . spanAt tree) kids @?= [ModuleSpan, ModuleSpan]
        let grandkids = concatMap (childrenOf tree) kids
        length grandkids @?= 2
        map (kind . spanAt tree) grandkids @?= [LlmCallSpan, LlmCallSpan],
      testCase "renderTree shows the model lines indented under their modules" $ do
        tree <- buildTree
        let out = renderTree tree
        assertBool "two llm-call model lines present" (T.count "stub/stub-model" out == 2)
        assertBool "llm-call lines are indented under modules" (T.isInfixOf "    llm-call  stub/stub-model" out)
        assertBool "module lines present" (T.count "module" out == 2)
    ]

-- ---------------------------------------------------------------------------
-- M2
-- ---------------------------------------------------------------------------

-- | M2: the trace tree serializes to a stable, versioned JSON document and reads
-- back; the replay index projects LM-call cacheKeys to responses; and the cache
-- key reproduces EP-6's pinned digest (integration point #7).
storeTests :: TestTree
storeTests =
  testGroup
    "store"
    [ testProperty "trace tree survives a JSON round-trip" $
        forAll genTree $ \t ->
          decode (encode (TraceFile currentFormatVersion t)) === Just (TraceFile currentFormatVersion t),
      testCase "writeTraceFile/readTraceFile round-trips on disk" $
        withSystemTempDirectory "shikumi-trace" $ \dir -> do
          tree <- buildTree
          let p = dir <> "/trace.json"
          writeTraceFile p tree
          res <- readTraceFile p
          res @?= Right tree,
      testCase "reading a file with a foreign formatVersion is Left" $
        withSystemTempDirectory "shikumi-trace" $ \dir -> do
          tree <- buildTree
          let p = dir <> "/bad.json"
          BL.writeFile p (encode (TraceFile 999 tree))
          res <- readTraceFile p
          case res of
            Left msg -> assertBool "the error names the offending version" (T.isInfixOf "999" msg)
            Right _ -> assertFailure "expected Left on a foreign formatVersion",
      testCase "replayIndex maps each llm-call cacheKey to its response" $ do
        tree <- buildTree
        let idx = replayIndex tree
        -- two LM-call leaves with distinct requests => two distinct keys.
        Map.size idx @?= 2
        assertBool "every indexed value is a JSON object (a recorded response)" (all isObject (Map.elems idx)),
      testCase "cacheKey reproduces EP-6's pinned digest (integration point #7)" $ do
        let CacheKey hex = Key.cacheKey fixModel fixCtx fixOpts
        hex @?= pinnedKey
    ]

-- ---------------------------------------------------------------------------
-- M3
-- ---------------------------------------------------------------------------

-- | M3: a two-stage pipeline captured live, persisted, and replayed offline
-- produces byte-identical outputs while making zero provider calls; a mutated
-- request raises a 'ReplayDivergence' naming the missing key.
replayTests :: TestTree
replayTests =
  testGroup
    "replay"
    [ testCase "replay reproduces the live outputs with zero provider calls" $
        withSystemTempDirectory "shikumi-trace" $ \dir -> do
          calls <- newIORef (0 :: Int)
          -- (1) live: run the pipeline, count provider calls, capture the tree.
          (live, tree) <-
            runEff . runPrim . runTime . runTrace . runKeyedCountingLLM calls responder . tracedLLM $
              twoStage "the article"
          liveCalls <- readIORef calls
          liveCalls @?= 2
          -- (2)+(3) persist and reload, build the replay index.
          let p = dir <> "/trace.json"
          writeTraceFile p tree
          Right tree' <- readTraceFile p
          let idx = replayIndex tree'
          -- (4) replay the SAME pipeline; the counting provider must not be hit.
          writeIORef calls 0
          replayed <- runEff . runLLMReplay idx $ twoStage "the article"
          replayCalls <- readIORef calls
          -- (5)+(6)+(7) identical outputs, zero provider calls.
          replayed @?= live
          replayCalls @?= 0,
      testCase "a request absent from the trace raises ReplayDivergence" $
        withSystemTempDirectory "shikumi-trace" $ \dir -> do
          calls <- newIORef (0 :: Int)
          (_, tree) <-
            runEff . runPrim . runTime . runTrace . runKeyedCountingLLM calls responder . tracedLLM $
              twoStage "the article"
          let p = dir <> "/trace.json"
          writeTraceFile p tree
          Right tree' <- readTraceFile p
          let idx = replayIndex tree'
          -- A different article => a first-stage key that was never recorded.
          res <- try (runEff . runLLMReplay idx $ twoStage "a different article")
          case res of
            Left (ReplayDivergence {divergedKey = CacheKey k}) ->
              assertBool "the divergence names a non-empty key" (not (T.null k))
            Right _ -> assertFailure "expected a ReplayDivergence on an unrecorded request"
    ]

-- ---------------------------------------------------------------------------
-- M5 (e2e)
-- ---------------------------------------------------------------------------

-- | M5: the demo's two-stage pipeline, captured live then replayed offline, prints
-- a byte-identical final critique while making zero provider calls — the headline
-- end-to-end story, run in-process.
e2eTests :: TestTree
e2eTests =
  testGroup
    "e2e"
    [ testCase "live capture then offline replay: identical FINAL, zero provider calls" $
        withSystemTempDirectory "shikumi-trace" $ \dir -> do
          calls <- newIORef (0 :: Int)
          -- live run of the demo pipeline; capture the tree, count provider calls.
          (liveFinal, tree) <-
            runEff . runPrim . runTime . runTrace . runKeyedCountingLLM calls demoResponder . tracedLLM $
              demoPipeline demoArticle
          liveCalls <- readIORef calls
          liveCalls @?= 2
          -- persist, reload, replay offline.
          let p = dir <> "/trace.json"
          writeTraceFile p tree
          Right tree' <- readTraceFile p
          let idx = replayIndex tree'
          writeIORef calls 0
          (replayFinal, _) <- runEff . runPrim . runTime . runTrace . runLLMReplay idx $ demoPipeline demoArticle
          replayCalls <- readIORef calls
          replayFinal @?= liveFinal
          replayCalls @?= 0
    ]

-- | A dependent two-stage pipeline: draft a summary of the article, then critique
-- the draft. The second stage's request depends on the first stage's output, so
-- replay must reproduce stage one exactly to reach the same stage-two request.
twoStage :: (LLM :> es) => Text -> Eff es (Text, Text)
twoStage article = do
  draft <- responseText <$> complete stubModel (ctxFor ("draft: " <> article)) optsFor
  crit <- responseText <$> complete stubModel (ctxFor ("critique: " <> draft)) optsFor
  pure (draft, crit)

-- | The deterministic stub: a draft request yields a fixed summary; a critique
-- request echoes the draft it was given. Deterministic per request, so replay is
-- well-defined.
responder :: Context -> Response
responder c =
  let t = lastUserText c
   in if "draft:" `T.isPrefixOf` t
        then mkResponse "a tight one-line summary"
        else mkResponse ("looks good: " <> T.drop (T.length "critique: ") t)

-- | The EP-6 golden fixture and its pinned digest, copied here so the two plans
-- are proven byte-for-byte identical.
fixModel :: Model
fixModel = _Model & #modelId .~ "claude-sonnet-4-6" & #provider .~ "anthropic"

fixCtx :: Context
fixCtx =
  _Context
    & #systemPrompt .~ Just "You are helpful."
    & #messages .~ V.singleton (user "ping")

fixOpts :: Options
fixOpts = _Options & #temperature .~ Just 0.0 & #maxTokens .~ Just 1024

pinnedKey :: Text
pinnedKey = "30b2015562ec8b5cd4fdb64c7cc671c84f56f80d24891deec6676c521f008113"

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- | Run a two-stage traced computation: a program span containing two module
-- spans, each issuing one stubbed LM call (captured automatically by 'tracedLLM').
buildTree :: IO TraceTree
buildTree = do
  let resp = mkResponse "ok"
  ((), tree) <-
    runEff . runPrim . runTime . runTrace . runFixedLLM resp . tracedLLM $
      withSpan ProgramSpan "summarize-and-critique" $ do
        _ <- withSpan ModuleSpan "predict:Draft" (complete stubModel (ctxFor "draft this") optsFor)
        _ <- withSpan ModuleSpan "predict:Critique" (complete stubModel (ctxFor "critique that") optsFor)
        pure ()
  pure tree

spanAt :: TraceTree -> SpanId -> Span
spanAt tree sid = spans tree Map.! sid

isObject :: Value -> Bool
isObject v = case v of
  Object {} -> True
  _ -> False

-- ---------------------------------------------------------------------------
-- A small generator of random trees for the round-trip property
-- ---------------------------------------------------------------------------

baseTime :: UTCTime
baseTime = read "2026-06-08 00:00:00 UTC"

-- | A bare shape: a node kind and its children shapes.
data Shape = Shape SpanKind [Shape]

genShape :: Int -> Gen Shape
genShape d = do
  k <- elements [ProgramSpan, ModuleSpan, CombinatorSpan, LlmCallSpan]
  kids <-
    if d <= 0
      then pure []
      else do
        n <- choose (0, 3)
        vectorOf n (genShape (d - 1))
  pure (Shape k kids)

-- | Generate a random (single-rooted) tree of up to depth 3, with sequential span
-- ids, integer-second timestamps (exact JSON round-trip), and LM-call leaves
-- carrying a cacheKey + response so the serialized form exercises every field.
genTree :: Gen TraceTree
genTree = do
  shape <- genShape 3
  let (ss, _) = flattenShape Nothing 0 shape
      m = Map.fromList [(spanId s, s) | s <- ss]
      rootId = spanId (firstSpan ss)
  pure (TraceTree rootId m)
  where
    firstSpan (s : _) = s
    firstSpan [] = error "genTree: empty"

-- | Flatten a shape into spans, assigning ids/parents/times from a running
-- counter. Returns the produced spans (root first) and the next free counter.
flattenShape :: Maybe SpanId -> Int -> Shape -> ([Span], Int)
flattenShape par n (Shape k kids) =
  let sid = SpanId ("span-" <> T.pack (show n))
      s =
        Span
          { spanId = sid,
            parent = par,
            kind = k,
            label = "lbl-" <> T.pack (show n),
            startedAt = addUTCTime (fromIntegral (2 * n)) baseTime,
            endedAt = Just (addUTCTime (fromIntegral (2 * n + 1)) baseTime),
            attrs = attrsFor k n
          }
      (kidSpans, n') = foldl step ([], n + 1) kids
      step (acc, cnt) kidShape =
        let (ks, cnt') = flattenShape (Just sid) cnt kidShape
         in (acc ++ ks, cnt')
   in (s : kidSpans, n')

-- | LM-call leaves carry a key + response (exercising replayIndex and the Value
-- fields); structural nodes are empty.
attrsFor :: SpanKind -> Int -> SpanAttrs
attrsFor LlmCallSpan n =
  emptyAttrs
    { model = Just "m",
      cacheKey = Just ("key-" <> T.pack (show n)),
      response = Just (object ["text" .= ("resp-" <> T.pack (show n))]),
      inputTokens = Just (fromIntegral n),
      costUsd = Just (read "0.001")
    }
attrsFor _ _ = emptyAttrs
