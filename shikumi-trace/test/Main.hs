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
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, addUTCTime)
import Data.Vector qualified as V
import Effectful (Eff, runEff, type (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Prim (runPrim)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Cache.Key (CacheKey (..))
import Shikumi.Cache.Key qualified as Key
import Shikumi.Combinator (majorityVote, majorityVoteBy, parallel2, (>>>))
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM, complete)
import Shikumi.Module (predict)
import Shikumi.Program
  ( NodeFields (..),
    Params (..),
    Program,
    TempSchedule (TempFixed),
    foldParams,
    mapParamsAt,
  )
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)
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
import Shikumi.Trace.Feedback
  ( FeedbackLog,
    attachFeedback,
    feedbackFor,
    runFeedback,
  )
import Shikumi.Trace.Internal.Spike qualified as Spike
import Shikumi.Trace.Node
  ( NodePath (..),
    NodeStep (..),
    nodeFields,
    programNodePaths,
  )
import Shikumi.Trace.Program
  ( runCurrentNode,
    runProgramTraced,
    tracedNodeLLM,
  )
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
    testGroup
      "shikumi-trace"
      [spikeTests, treeTests, storeTests, replayTests, e2eTests, nodeTests, correlateTests, feedbackTests]

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
pinnedKey = "b31fd70140abbd0198c6b7caec748a8389bf93be909164bdcc340731b7032564"

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

-- ---------------------------------------------------------------------------
-- EP-16: node identity, correlation, and the feedback channel
-- ---------------------------------------------------------------------------

-- | A self-looping record so @predict cellSig :: Program Cell Cell@ composes with
-- itself to make a multi-node program.
newtype Cell = Cell {cell :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Cell

instance FromModel Cell

instance ToPrompt Cell

instance Validatable Cell

cellSig :: Signature Cell Cell
cellSig = mkSignature "Echo the cell"

-- | A two-@Predict@ chain: @Compose (Predict) (Predict)@.
chain2 :: Program Cell Cell
chain2 = predict cellSig >>> predict cellSig

-- | A fixed response in fallback @[[ ## field ## ]]@ form, decoded by the lenient
-- parser into @Cell "echoed"@.
cellResp :: Response
cellResp = mkResponse "[[ ## cell ## ]]\nechoed\n[[ ## completed ## ]]\n"

chkLen :: Program a b -> IO ()
chkLen p = length (programNodePaths p) @?= length (foldParams p)

-- | A total ensemble reducer (the program is only shape-inspected, never run).
firstOr :: [Cell] -> Cell
firstOr (c : _) = c
firstOr [] = Cell ""

-- | The @LlmCallSpan@s of a tree, in start order.
llmSpansInOrder :: TraceTree -> [Span]
llmSpansInOrder t = sortOn startedAt [s | s <- Map.elems (spans t), kind s == LlmCallSpan]

-- | Run a program under 'runProgramTraced' with the node-aware stack, returning the
-- decoded result and the captured tree (or a typed error).
runTraced :: Program Cell Cell -> Cell -> IO (Either ShikumiError (Cell, TraceTree))
runTraced prog input =
  runEff
    . runErrorNoCallStack @ShikumiError
    . runPrim
    . runTime
    . runTrace
    . runCurrentNode
    . runFixedLLM cellResp
    . tracedNodeLLM
    $ runProgramTraced prog input

-- | M1: 'NodePath' identity, its agreement with @foldParams@, field metadata, and
-- JSON round-trips.
nodeTests :: TestTree
nodeTests =
  testGroup
    "node"
    [ testCase "programNodePaths length agrees with foldParams across shapes" $ do
        chkLen chain2
        chkLen (majorityVote 3 (TempFixed []) (predict cellSig))
        chkLen (majorityVoteBy 2 (TempFixed []) firstOr (predict cellSig))
        chkLen (parallel2 (predict cellSig) (predict cellSig)),
      testCase "programNodePaths yields the expected structural paths for a chain" $
        programNodePaths chain2 @?= [NodePath [StepComposeL], NodePath [StepComposeR]],
      testCase "nodeFields returns each node's input/output field names" $ do
        let nf = map snd (nodeFields chain2)
        map inputFieldNames nf @?= [["cell"], ["cell"]]
        map outputFieldNames nf @?= [["cell"], ["cell"]],
      testCase "mapParamsAt k edits the node at programNodePaths !! k (index law)" $ do
        let edited = mapParamsAt 1 (\ps -> ps & #instructionOverride .~ Just "x") chain2
        map instructionOverride (foldParams edited) @?= [Nothing, Just "x"],
      testCase "NodePath and a nodePath-bearing SpanAttrs round-trip as JSON" $ do
        let np = NodePath [StepComposeL, StepEnsemble 2]
        decode (encode np) @?= Just np
        let a = emptyAttrs & #nodePath .~ Just np
        decode (encode a) @?= Just a
    ]

-- | M2: each model-call span is tagged with its issuing node's 'NodePath', and the
-- nodePath-bearing tree round-trips through the store at formatVersion 2.
correlateTests :: TestTree
correlateTests =
  testGroup
    "correlate"
    [ testCase "each llm-call span carries its node's path, in programNodePaths order" $ do
        res <- runTraced chain2 (Cell "x")
        case res of
          Left e -> assertFailure ("traced run failed: " <> show e)
          Right (out, tree) -> do
            out @?= Cell "echoed"
            let llms = llmSpansInOrder tree
            length llms @?= 2
            let paths = programNodePaths chain2
            map (nodePath . attrs) llms @?= [Just (paths !! 0), Just (paths !! 1)],
      testCase "a nodePath-bearing tree round-trips through the store (formatVersion 2)" $
        withSystemTempDirectory "shikumi-trace-node" $ \dir -> do
          res <- runTraced chain2 (Cell "x")
          case res of
            Left e -> assertFailure ("traced run failed: " <> show e)
            Right (_, tree) -> do
              let p = dir <> "/trace.json"
              writeTraceFile p tree
              loaded <- readTraceFile p
              loaded @?= Right tree
    ]

-- | M3: the per-node feedback channel round-trips writes and reads.
feedbackTests :: TestTree
feedbackTests =
  testGroup
    "feedback"
    [ testCase "feedbackFor returns critiques in attach order; untargeted node is empty" $ do
        let p1 = NodePath [StepComposeL]
            p2 = NodePath [StepComposeR]
            p3 = NodePath [StepFMap]
        (_, fb) <-
          runEff . runPrim . runFeedback $ do
            attachFeedback p1 "first"
            attachFeedback p1 "second"
            attachFeedback p2 "only"
        feedbackFor p1 fb @?= ["first", "second"]
        feedbackFor p2 fb @?= ["only"]
        feedbackFor p3 fb @?= [],
      testCase "FeedbackLog round-trips as JSON" $ do
        (_, fb) <-
          runEff . runPrim . runFeedback $
            attachFeedback (NodePath [StepComposeL]) "c"
        decode (encode (fb :: FeedbackLog)) @?= Just fb
    ]
