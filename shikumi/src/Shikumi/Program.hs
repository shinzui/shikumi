{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | The keystone of shikumi (EP-4): a typed /deep embedding/ of an LM program as
-- inspectable data. A 'Program' @i o@ is a tree of three constructors that can be
-- done three different things with at once:
--
--   * __run__ as a typed function — 'runProgram' interprets the tree as an 'Eff'
--     computation that issues @LLM@ calls and returns a typed @o@ (or throws a
--     typed 'ShikumiError');
--   * __rewritten as data__ — 'paramsTraversal' / 'foldParams' / 'mapParams' /
--     'mapParamsAt' read and replace each node's optimizable 'Params' (its
--     instruction override and few-shot demos) without running the program and
--     without runtime reflection, which is what the optimizer
--     (@docs/plans/10-optimizer-framework.md@) needs;
--   * __serialized__ — 'programShape' captures the closure-free structure and
--     'programParams' / 'setProgramParams' move the JSON-serializable parameter
--     vector, so an optimized program's state can be saved and replayed.
--
-- The constructor set is deliberately minimal (three): richer modules
-- (@chainOfThought@; the combinators in
-- @docs/plans/5-module-combinators-and-control-flow.md@) are /derived/ functions
-- that build these constructors, not new constructors.
--
-- This module consumes EP-1 (@Shikumi.LLM@, @Shikumi.Error@) and EP-3
-- (@Shikumi.Signature@, @Shikumi.Adapter@, @Shikumi.Schema@). See the plan's
-- Decision Log for the reconciliations with the delivered EP-3 surface (which
-- exposes @render@/@parse@/@adapterFor@ rather than a single @runSignature@).
module Shikumi.Program
  ( -- * The representation
    Program
      ( Predict,
        Compose,
        FMap,
        Map,
        Parallel,
        Retry,
        RetryWhen,
        Validate,
        MajorityVote,
        Ensemble,
        Embed
      ),
    Params (..),
    Demo (..),
    emptyParams,
    TempSchedule (..),

    -- * Construction & execution
    pipeline,
    embed,
    runProgram,
    runProgramConc,

    -- * Per-node field metadata (EP-16)
    NodeFields (..),
    nodeFieldsIndexed,
    nodeInstructionsIndexed,

    -- * Execution internals (reused by alternative executors, e.g. @runProgramTraced@)
    retryWith,
    acceptOrReject,
    modal,
    sampleTemps,
    withSampleTemp,

    -- * Parameter interface (the optimizer/compiler contract)
    paramsTraversal,
    foldParams,
    mapParams,
    mapParamsAt,

    -- * Serialization (parameter state only — never closures)
    ProgramShape (..),
    ProgramShapeError (..),
    programShape,
    programParams,
    setProgramParams,
  )
where

import Baikai (Model, _Model)
import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Functor.Const (Const (..))
import Data.Functor.Identity (Identity (..))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Concurrent.Async (concurrently, mapConcurrently, pooledMapConcurrentlyN)
import Effectful.Dispatch.Dynamic (interpose, passthrough)
import Effectful.Error.Static (Error, catchError, throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter
  ( Adapter (..),
    ToPrompt,
    adapterFor,
    attachSchema,
    fallbackAdapter,
    nativeAdapter,
    stampTemperature,
  )
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..), Response, complete)
import Shikumi.Schema (FromModel, ToSchema, Validatable, deriveSchema, fromModel)
import Shikumi.Schema.Types (fieldName)
import Shikumi.Signature (Signature, getInstruction, inputFields, outputFields, setDemos, setInstruction)
import Shikumi.Signature qualified as Sig

-- ---------------------------------------------------------------------------
-- Optimizable node state
-- ---------------------------------------------------------------------------

-- | The optimizable overlay of a single node: an optional instruction override
-- (@Nothing@ = use the signature's default) and an ordered list of few-shot
-- demonstrations. This is the /uniform, serializable/ handle the compiler
-- (@docs/plans/9-compiler-layer.md@) and optimizer
-- (@docs/plans/10-optimizer-framework.md@) manipulate regardless of a node's
-- @i@/@o@ — hence demos are stored as type-agnostic JSON (see 'Demo').
data Params = Params
  { instructionOverride :: !(Maybe Text),
    demos :: ![Demo]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Params

instance FromJSON Params

-- | A worked input/output example, stored as JSON so it is uniform across nodes
-- of differing types. At run time each demo is decoded back into the node's typed
-- @Sig.Demo i o@ and spliced into the prompt by EP-3's adapter; a demo whose JSON
-- does not decode surfaces as a 'ShikumiError'.
data Demo = Demo
  { input :: !Value,
    output :: !Value
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Demo

instance FromJSON Demo

-- | The default empty overlay: no instruction override, no demos.
emptyParams :: Params
emptyParams = Params Nothing []

-- | How 'MajorityVote' varies sampling temperature across its @K@ samples.
-- 'TempFixed' lists an explicit temperature per sample (cycled if shorter than
-- @K@, empty = leave temperature at the provider default); 'TempSpread base spread'
-- centres on @base@ and fans @K@ values out evenly across @[base-spread,
-- base+spread]@.
--
-- Since EP-14 the schedule is /live/: each sample's temperature is stamped onto the
-- private request-metadata channel ('Shikumi.Adapter.stampTemperature') and the
-- router ("Shikumi.Routing".@routeLLM@) sets @Options.temperature@ from it, so the
-- @K@ samples are sent with distinct temperatures on the wire. (Without a router
-- installed the stamp is inert, as no interpreter realizes it — the hermetic stub
-- path and the live path both install one.)
data TempSchedule
  = TempFixed ![Double]
  | TempSpread !Double !Double
  deriving stock (Eq, Show, Generic)

instance ToJSON TempSchedule

instance FromJSON TempSchedule

-- ---------------------------------------------------------------------------
-- The GADT
-- ---------------------------------------------------------------------------

-- | A typed LM program. 'Predict' is a single signature-backed LM call carrying
-- its 'Params'; 'Compose' sequences two programs (its intermediate type is
-- existential); 'FMap' applies a pure post-processing function (no LM call).
--
-- 'Predict' captures the adapter/decode dictionaries existentially so that
-- 'runProgram' can recover them by pattern-matching — this is what lets a program
-- be rewritten as data while staying type-checked.
data Program i o where
  Predict ::
    (FromModel i, FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o) =>
    Signature i o ->
    Params ->
    Program i o
  Compose :: Program a b -> Program b c -> Program a c
  FMap :: (o -> o') -> Program i o -> Program i o'
  -- | Apply a program to every element of a list. The 'Int' is the
  -- concurrency width honoured by 'runProgramConc' (1 = sequential);
  -- 'runProgram' always runs sequentially regardless of the width.
  Map :: Int -> Program a b -> Program [a] [b]
  -- | Run two programs on the /same/ input and pair their outputs.
  Parallel :: Program i a -> Program i b -> Program i (a, b)
  -- | Re-run a program up to @n@ total attempts on any 'ShikumiError'.
  Retry :: Int -> Program i o -> Program i o
  -- | Like 'Retry' but only retries errors satisfying the predicate; a
  -- non-matching error propagates after a single attempt.
  RetryWhen :: (ShikumiError -> Bool) -> Int -> Program i o -> Program i o
  -- | Run a program, then check its output: 'Right' accepts (optionally
  -- normalizing), 'Left' rejects with a reason surfaced as a
  -- 'ValidationFailure'.
  Validate :: (o -> Either Text o) -> Program i o -> Program i o
  -- | Sample a program @K@ times and return the modal (most-frequent under
  -- 'Eq', ties broken by first-seen) output. Each sample is run with its
  -- 'TempSchedule' temperature applied to the wire (see 'TempSchedule').
  MajorityVote :: (Eq o) => Int -> TempSchedule -> Program i o -> Program i o
  -- | Run several programs on the same input, collect their (homogeneous)
  -- results, and fold them with a total reducer.
  Ensemble :: [Program i r] -> ([r] -> o) -> Program i o
  -- | An opaque effectful step embedded as a program node. The body is
  -- constrained to /exactly/ 'runProgram'\'s effect row
  -- (@LLM@ + @Error ShikumiError@) so an 'Embed' node runs under the ordinary
  -- 'runProgram'/'runProgramConc' without widening integration point #4\'s
  -- constraint. This is the constructor multi-step agents (ReAct,
  -- @docs/plans/11-typed-tools-and-react-agents.md@) are built on: the agent
  -- loop is one 'Embed' node, so the agent is a real, composable 'Program' that
  -- is runnable, structurally inspectable ('ShapeEmbed'), and serializable
  -- (it carries no 'Params', like 'FMap'). The body is a closure, so it is
  -- opaque to the parameter traversal — exactly as 'FMap'\'s function is.
  Embed :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o

-- | Sequence two programs, read left-to-right ("first @p@, then @q@"). Typechecks
-- only when @p@'s output type equals @q@'s input type — an invalid pipeline is a
-- compile error, which is the whole point.
pipeline :: Program a b -> Program b c -> Program a c
pipeline = Compose

-- | Embed an opaque effectful step as a 'Program' node. The smart constructor for
-- 'Embed': lift an @(i -> Eff es o)@ — runnable in 'runProgram'\'s effect row — into
-- a @Program i o@. Used by ReAct (@docs/plans/11-typed-tools-and-react-agents.md@) to
-- make a multi-step agent loop a first-class, composable program.
embed :: (forall es. (LLM :> es, Error ShikumiError :> es) => i -> Eff es o) -> Program i o
embed = Embed

-- ---------------------------------------------------------------------------
-- Execution
-- ---------------------------------------------------------------------------

-- | The inert placeholder model 'runPredict' passes to 'complete'. Since EP-14
-- 'runProgram' is model-agnostic: it never chooses a real provider itself. The
-- ambient model is supplied below the stack by "Shikumi.Routing".@runRouting@ and
-- the router ("Shikumi.Routing".@routeLLM@) overwrites this placeholder with it on
-- every outgoing call. With no router installed (the bare-stub test path) the call
-- still carries '_Model', which 'adapterFor' maps to the prompt-fallback adapter —
-- preserving EP-4's original behaviour for un-routed runs.
placeholderModel :: Model
placeholderModel = _Model

-- | Interpret a program as a typed @Eff@ computation. A 'Predict' node overlays
-- its 'Params' onto the signature (effective instruction + decoded demos), renders
-- the request via EP-3's adapter, issues the 'LLM' call, and parses the response
-- back into a typed @o@ — throwing a 'ShikumiError' on a parse or demo-decode
-- failure. 'Compose' threads the intermediate value; 'FMap' maps the result purely.
runProgram ::
  (LLM :> es, Error ShikumiError :> es) =>
  Program i o ->
  i ->
  Eff es o
runProgram (Predict sig ps) i = runPredict sig ps i
runProgram (Compose f g) i = runProgram f i >>= runProgram g
runProgram (FMap k p) i = k <$> runProgram p i
runProgram (Map _ p) xs = traverse (runProgram p) xs
runProgram (Parallel pa pb) i = (,) <$> runProgram pa i <*> runProgram pb i
runProgram (Retry n p) i = retryWith runProgram (const True) n p i
runProgram (RetryWhen ok n p) i = retryWith runProgram ok n p i
runProgram (Validate v p) i = runProgram p i >>= acceptOrReject v
runProgram (MajorityVote k sched p) i =
  modal <$> traverse (\mt -> withSampleTemp mt (runProgram p i)) (sampleTemps (max 1 k) sched)
runProgram (Ensemble ps reduce) i = reduce <$> traverse (\p -> runProgram p i) ps
runProgram (Embed f) i = f i

-- | The concurrent executor: identical observable semantics to 'runProgram', but
-- 'Map' (bounded by its width), 'Parallel', 'MajorityVote', and 'Ensemble' run
-- their independent sub-programs concurrently via @effectful@'s 'Concurrent'
-- effect. Offered as an additive opt-in so 'runProgram' can keep the exact
-- @(LLM, Error ShikumiError)@ constraint that is the MasterPlan's integration
-- point #4 — adding 'Concurrent' there would force it onto every consumer.
runProgramConc ::
  (LLM :> es, Error ShikumiError :> es, Concurrent :> es) =>
  Program i o ->
  i ->
  Eff es o
runProgramConc (Predict sig ps) i = runPredict sig ps i
runProgramConc (Compose f g) i = runProgramConc f i >>= runProgramConc g
runProgramConc (FMap k p) i = k <$> runProgramConc p i
runProgramConc (Map w p) xs = pooledMapConcurrentlyN (max 1 w) (runProgramConc p) xs
runProgramConc (Parallel pa pb) i = concurrently (runProgramConc pa i) (runProgramConc pb i)
runProgramConc (Retry n p) i = retryWith runProgramConc (const True) n p i
runProgramConc (RetryWhen ok n p) i = retryWith runProgramConc ok n p i
runProgramConc (Validate v p) i = runProgramConc p i >>= acceptOrReject v
runProgramConc (MajorityVote k sched p) i =
  modal <$> mapConcurrently (\mt -> withSampleTemp mt (runProgramConc p i)) (sampleTemps (max 1 k) sched)
runProgramConc (Ensemble ps reduce) i = reduce <$> mapConcurrently (\p -> runProgramConc p i) ps
-- The body requires only @(LLM, Error ShikumiError)@, a subset of this row, so it
-- runs unchanged; an embedded agent that wants concurrency uses 'runProgramConc'
-- internally via its own 'Concurrent' handler.
runProgramConc (Embed f) i = f i

-- | Interpret a single 'Predict' node: overlay its 'Params', render via EP-3's
-- adapter, issue the 'LLM' call, parse back to a typed @o@. Shared by both
-- executors so the wire behaviour is defined once.
runPredict ::
  forall i o es.
  (FromModel i, FromModel o, ToSchema o, ToPrompt i, ToPrompt o) =>
  (LLM :> es, Error ShikumiError :> es) =>
  Signature i o ->
  Params ->
  i ->
  Eff es o
runPredict sig ps i = do
  sig' <- effectiveSignature sig ps
  let adapter = adapterFor placeholderModel
      (ctx, opts0) = render adapter sig' i
      -- Stamp the derived schema onto the metadata channel regardless of which
      -- adapter rendered the prompt; the router attaches a real @responseFormat@
      -- from it for native-capable models and strips it otherwise.
      opts = attachSchema (deriveSchema @o) opts0
  resp <- complete placeholderModel ctx opts
  either throwError pure (parseResponse sig' resp)

-- | Decode a response back into the typed output, tolerant of /either/ wire shape:
-- a native model (whose @responseFormat@ the router enforced) replies with a JSON
-- object, while a fallback model replies with @[[ ## field ## ]]@ sections. Because
-- a model-agnostic 'runPredict' cannot know at render time which the real model is,
-- we try the native JSON parse first and fall back to the section parser, reporting
-- the fallback parser's error when both fail (so un-routed runs keep their exact
-- prior error behaviour).
parseResponse ::
  forall i o.
  (FromModel o, ToSchema o, Validatable o, ToPrompt i, ToPrompt o) =>
  Signature i o ->
  Response ->
  Either ShikumiError o
parseResponse sig' resp =
  case parse (nativeAdapter @i @o) sig' resp of
    Right o -> Right o
    Left _ -> parse (fallbackAdapter @i @o) sig' resp

-- | The per-sample temperatures for a 'MajorityVote' of @k@ samples. 'Nothing'
-- leaves the provider default in place; 'Just t' is stamped onto the sample's
-- requests. The multiset is identical between 'runProgram' and 'runProgramConc'.
sampleTemps :: Int -> TempSchedule -> [Maybe Double]
sampleTemps k (TempFixed xs)
  | null xs = replicate k Nothing
  | otherwise = map Just (take k (cycle xs))
sampleTemps k (TempSpread base spread) = map Just (spreadTemps k base spread)

-- | @k@ temperatures fanned evenly across @[base-spread, base+spread]@; a single
-- sample sits exactly on @base@.
spreadTemps :: Int -> Double -> Double -> [Double]
spreadTemps k base spread
  | k <= 1 = [base]
  | otherwise = [base - spread + fromIntegral i * step | i <- [0 .. k - 1]]
  where
    step = (2 * spread) / fromIntegral (k - 1)

-- | Run an action with one sample's temperature stamped onto every outgoing
-- 'Complete' (via the private metadata channel the router realizes). 'Nothing' runs
-- the action unchanged. Scoped to this sample only via 'interpose', so sibling
-- samples are unaffected and nested votes compose.
withSampleTemp :: (LLM :> es) => Maybe Double -> Eff es a -> Eff es a
withSampleTemp Nothing act = act
withSampleTemp (Just t) act =
  interpose
    ( \env -> \case
        Complete m c o -> complete m c (stampTemperature t o)
        other -> passthrough env other
    )
    act

-- | Apply a validator to a program's output, surfacing a rejection as a
-- 'ValidationFailure'.
acceptOrReject ::
  (Error ShikumiError :> es) => (o -> Either Text o) -> o -> Eff es o
acceptOrReject v o = either (throwError . ValidationFailure) pure (v o)

-- | The retry loop, parameterized over the executor so 'runProgram' and
-- 'runProgramConc' share it. Runs @p@ on @i@; on a matching error with attempts
-- remaining, re-runs; otherwise surfaces the last error.
retryWith ::
  (Error ShikumiError :> es) =>
  (Program i o -> i -> Eff es o) ->
  (ShikumiError -> Bool) ->
  Int ->
  Program i o ->
  i ->
  Eff es o
retryWith run ok n p i = go (max 1 n)
  where
    go left =
      run p i `catchError` \_cs e ->
        if ok e && left > 1 then go (left - 1) else throwError e

-- | The modal value of a non-empty list: most frequent under 'Eq', ties broken
-- by first appearance. Tallies in first-seen order, then keeps the first entry
-- whose count is strictly greatest.
modal :: (Eq o) => [o] -> o
modal = pickBest . foldl' tally []
  where
    tally acc x = case break ((== x) . fst) acc of
      (pre, (y, c) : post) -> pre ++ (y, c + 1) : post
      (pre, []) -> pre ++ [(x, 1 :: Int)]
    pickBest [] = error "Shikumi.Program.modal: empty sample list"
    pickBest (z : zs) =
      fst (foldl' (\best cur -> if snd cur > snd best then cur else best) z zs)

-- | Overlay a node's 'Params' onto its signature: substitute the instruction
-- override (when present) and decode the JSON demos into the signature's typed
-- demo channel. A demo whose JSON does not decode is reported as the located
-- 'ShikumiError' from 'fromModel'.
effectiveSignature ::
  (FromModel i, FromModel o, Error ShikumiError :> es) =>
  Signature i o ->
  Params ->
  Eff es (Signature i o)
effectiveSignature sig ps = do
  typed <- either throwError pure (traverse decodeDemo (demos ps))
  pure (setDemos typed (setInstruction instr sig))
  where
    instr = fromMaybe (getInstruction sig) (instructionOverride ps)
    decodeDemo (Demo inJ outJ) = Sig.Demo <$> fromModel inJ <*> fromModel outJ

-- ---------------------------------------------------------------------------
-- Parameter interface
-- ---------------------------------------------------------------------------

-- | The source-of-truth traversal: focuses every 'Params' in a program in
-- /left-to-right depth-first/ order (for @Compose f g@ all of @f@'s come before
-- @g@'s). Composite nodes ('Compose', 'FMap') carry no 'Params' of their own — so
-- a program's parameter count equals its number of 'Predict' nodes. Obeys the
-- @lens@ @Traversal'@ laws; use it directly with @toListOf@/@over@/@set@.
paramsTraversal :: (Applicative f) => (Params -> f Params) -> Program i o -> f (Program i o)
paramsTraversal h (Predict sig ps) = Predict sig <$> h ps
paramsTraversal h (Compose f g) = Compose <$> paramsTraversal h f <*> paramsTraversal h g
paramsTraversal h (FMap k p) = FMap k <$> paramsTraversal h p
paramsTraversal h (Map w p) = Map w <$> paramsTraversal h p
paramsTraversal h (Parallel pa pb) = Parallel <$> paramsTraversal h pa <*> paramsTraversal h pb
paramsTraversal h (Retry n p) = Retry n <$> paramsTraversal h p
paramsTraversal h (RetryWhen ok n p) = RetryWhen ok n <$> paramsTraversal h p
paramsTraversal h (Validate v p) = Validate v <$> paramsTraversal h p
paramsTraversal h (MajorityVote k sched p) = MajorityVote k sched <$> paramsTraversal h p
paramsTraversal h (Ensemble ps reduce) = Ensemble <$> traverse (paramsTraversal h) ps <*> pure reduce
-- 'Embed' carries no 'Params' (its body is an opaque closure, like 'FMap'\'s
-- function), so it is a traversal leaf — preserved untouched.
paramsTraversal _ (Embed f) = pure (Embed f)

-- | Read every node's 'Params', in traversal order.
foldParams :: Program i o -> [Params]
foldParams = getConst . paramsTraversal (\ps -> Const [ps])

-- | The input- and output-field names of a single 'Predict' node, recovered
-- structurally. A 'Predict' hides its @i@\/@o@ types existentially, so a typed
-- @Signature@ cannot escape the GADT — but the field /names/ are plain 'Text' and
-- can. This is what the EP-16 node-correlated trace and the grounded instruction
-- proposer (@docs/plans/19-grounded-instruction-proposer.md@) consume.
data NodeFields = NodeFields
  { inputFieldNames :: ![Text],
    outputFieldNames :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

-- | For every 'Predict' node, in 'foldParams' order, its index-aligned field
-- metadata. So @nodeFieldsIndexed p !! n@ describes the same node @mapParamsAt n@
-- edits and @foldParams p !! n@ parameterizes — the integration-point-#3 ordering
-- law, shared with @Shikumi.Trace.Node.programNodePaths@.
nodeFieldsIndexed :: Program i o -> [NodeFields]
nodeFieldsIndexed = go
  where
    go :: forall x y. Program x y -> [NodeFields]
    go (Predict sig _) =
      [NodeFields (map fieldName (inputFields sig)) (map fieldName (outputFields sig))]
    go (Compose a b) = go a ++ go b
    go (FMap _ p) = go p
    go (Map _ p) = go p
    go (Parallel a b) = go a ++ go b
    go (Retry _ p) = go p
    go (RetryWhen _ _ p) = go p
    go (Validate _ p) = go p
    go (MajorityVote _ _ p) = go p
    go (Ensemble ps _) = concatMap go ps
    go (Embed _) = []

-- | For every 'Predict' node, in 'foldParams' order, its signature instruction.
-- Index-aligned with 'nodeFieldsIndexed' and 'foldParams': entry @n@ describes the
-- same node those functions address, so the two lists can be zipped. Composite
-- nodes carry no instruction and 'Embed' is opaque, so neither contributes an
-- entry. This reads the /signature's/ base instruction (not any per-node 'Params'
-- instruction override), which is the stable task description suitable for
-- documentation (consumed by @shikumi-okf@'s program-doc renderer).
nodeInstructionsIndexed :: Program i o -> [Text]
nodeInstructionsIndexed = go
  where
    go :: forall x y. Program x y -> [Text]
    go (Predict sig _) = [getInstruction sig]
    go (Compose a b) = go a ++ go b
    go (FMap _ p) = go p
    go (Map _ p) = go p
    go (Parallel a b) = go a ++ go b
    go (Retry _ p) = go p
    go (RetryWhen _ _ p) = go p
    go (Validate _ p) = go p
    go (MajorityVote _ _ p) = go p
    go (Ensemble ps _) = concatMap go ps
    go (Embed _) = []

-- | Apply a function to every node's 'Params', preserving structure and types.
mapParams :: (Params -> Params) -> Program i o -> Program i o
mapParams f = runIdentity . paramsTraversal (Identity . f)

-- | Apply a function to the 'Params' at a single 0-based index in traversal order;
-- an out-of-range index leaves the program unchanged. The optimizer's primary edit
-- primitive: "replace node @n@'s instruction/demos". The index it addresses is the
-- same index 'foldParams' produces (the ordering law).
mapParamsAt :: Int -> (Params -> Params) -> Program i o -> Program i o
mapParamsAt n f = fst . go 0
  where
    go :: forall x y. Int -> Program x y -> (Program x y, Int)
    go idx (Predict sig ps) = (Predict sig (if idx == n then f ps else ps), idx + 1)
    go idx (Compose a b) =
      let (a', idx') = go idx a
          (b', idx'') = go idx' b
       in (Compose a' b', idx'')
    go idx (FMap k p) =
      let (p', idx') = go idx p
       in (FMap k p', idx')
    go idx (Map w p) =
      let (p', idx') = go idx p
       in (Map w p', idx')
    go idx (Parallel a b) =
      let (a', idx') = go idx a
          (b', idx'') = go idx' b
       in (Parallel a' b', idx'')
    go idx (Retry m p) =
      let (p', idx') = go idx p
       in (Retry m p', idx')
    go idx (RetryWhen ok m p) =
      let (p', idx') = go idx p
       in (RetryWhen ok m p', idx')
    go idx (Validate v p) =
      let (p', idx') = go idx p
       in (Validate v p', idx')
    go idx (MajorityVote k sched p) =
      let (p', idx') = go idx p
       in (MajorityVote k sched p', idx')
    go idx (Ensemble ps reduce) =
      let (ps', idx') = goList idx ps
       in (Ensemble ps' reduce, idx')
    go idx (Embed body) = (Embed body, idx) -- leaf, no 'Params'
    -- Thread the running index left-to-right across a member list.
    goList :: forall x y. Int -> [Program x y] -> ([Program x y], Int)
    goList idx [] = ([], idx)
    goList idx (q : qs) =
      let (q', idx') = go idx q
          (qs', idx'') = goList idx' qs
       in (q' : qs', idx'')

-- ---------------------------------------------------------------------------
-- Serialization (parameter state only, never closures)
-- ---------------------------------------------------------------------------

-- | A closure-free description of a program's structure, paired with a saved
-- parameter vector to verify it loads onto the program it was saved from. It
-- records the constructor tree and a per-'Predict' label; an 'FMap' node's mapped
-- function is intentionally omitted (opaque, unserializable).
data ProgramShape
  = -- | a 'Predict' node, labeled by its joined output-field names
    ShapePredict !Text
  | ShapeCompose !ProgramShape !ProgramShape
  | -- | an 'FMap' node; the function is opaque and omitted
    ShapeFMap !ProgramShape
  | -- | a 'Map' node, carrying its concurrency width
    ShapeMap !Int !ProgramShape
  | ShapeParallel !ProgramShape !ProgramShape
  | ShapeRetry !Int !ProgramShape
  | -- | a 'RetryWhen' node; the predicate is opaque and omitted
    ShapeRetryWhen !Int !ProgramShape
  | -- | a 'Validate' node; the validator is opaque and omitted
    ShapeValidate !ProgramShape
  | ShapeMajorityVote !Int !TempSchedule !ProgramShape
  | -- | an 'Ensemble' node; the reducer is opaque and omitted
    ShapeEnsemble ![ProgramShape]
  | -- | an 'Embed' node; the embedded effectful body is opaque and omitted
    ShapeEmbed
  deriving stock (Eq, Show, Generic)

instance ToJSON ProgramShape

instance FromJSON ProgramShape

-- | Why a parameter vector could not be applied to a program.
newtype ProgramShapeError
  = -- | the vector's length did not match the program's node count (expected, got)
    ParamCountMismatch (Int, Int)
  deriving stock (Eq, Show, Generic)

instance ToJSON ProgramShapeError

instance FromJSON ProgramShapeError

-- | Extract a program's closure-free structural shape. Stable across parameter
-- changes (parameters do not affect shape).
programShape :: Program i o -> ProgramShape
programShape (Predict sig _) = ShapePredict (sigLabel sig)
programShape (Compose a b) = ShapeCompose (programShape a) (programShape b)
programShape (FMap _ p) = ShapeFMap (programShape p)
programShape (Map w p) = ShapeMap w (programShape p)
programShape (Parallel a b) = ShapeParallel (programShape a) (programShape b)
programShape (Retry n p) = ShapeRetry n (programShape p)
programShape (RetryWhen _ n p) = ShapeRetryWhen n (programShape p)
programShape (Validate _ p) = ShapeValidate (programShape p)
programShape (MajorityVote k sched p) = ShapeMajorityVote k sched (programShape p)
programShape (Ensemble ps _) = ShapeEnsemble (map programShape ps)
programShape (Embed _) = ShapeEmbed

-- | A stable, parameter-independent label for a 'Predict' node: its output-field
-- names joined. (EP-3 exposes no @signatureName@; the field names are the stable
-- structural identity available.)
sigLabel :: Signature i o -> Text
sigLabel sig = T.intercalate "," (map fieldName (outputFields sig))

-- | The ordered parameter vector, in 'foldParams' order — JSON-serializable
-- because 'Params'/'Demo' are. Saving an optimized program = write
-- @(programShape p, programParams p)@; loading = read the @[Params]@, reconstruct
-- @p@ in code, then 'setProgramParams'.
programParams :: Program i o -> [Params]
programParams = foldParams

-- | Apply a saved parameter vector onto a program of the matching shape, replacing
-- each node's 'Params' in 'foldParams' order. The vector must have exactly one
-- entry per 'Predict' node; a length mismatch is a 'ParamCountMismatch' 'Left'.
setProgramParams :: [Params] -> Program i o -> Either ProgramShapeError (Program i o)
setProgramParams ps prog
  | length ps /= n = Left (ParamCountMismatch (n, length ps))
  | otherwise = Right (fst (go ps prog))
  where
    n = length (foldParams prog)
    go :: forall x y. [Params] -> Program x y -> (Program x y, [Params])
    go (q : qs) (Predict sig _) = (Predict sig q, qs)
    go qs (Predict sig old) = (Predict sig old, qs) -- unreachable after the length guard
    go qs (Compose a b) =
      let (a', qs') = go qs a
          (b', qs'') = go qs' b
       in (Compose a' b', qs'')
    go qs (FMap k p) =
      let (p', qs') = go qs p
       in (FMap k p', qs')
    go qs (Map w p) =
      let (p', qs') = go qs p
       in (Map w p', qs')
    go qs (Parallel a b) =
      let (a', qs') = go qs a
          (b', qs'') = go qs' b
       in (Parallel a' b', qs'')
    go qs (Retry m p) =
      let (p', qs') = go qs p
       in (Retry m p', qs')
    go qs (RetryWhen ok m p) =
      let (p', qs') = go qs p
       in (RetryWhen ok m p', qs')
    go qs (Validate v p) =
      let (p', qs') = go qs p
       in (Validate v p', qs')
    go qs (MajorityVote k sched p) =
      let (p', qs') = go qs p
       in (MajorityVote k sched p', qs')
    go qs (Ensemble ms reduce) =
      let (ms', qs') = goList qs ms
       in (Ensemble ms' reduce, qs')
    go qs (Embed f) = (Embed f, qs) -- leaf, consumes no 'Params'
    goList :: forall x y. [Params] -> [Program x y] -> ([Program x y], [Params])
    goList qs [] = ([], qs)
    goList qs (m : ms) =
      let (m', qs') = go qs m
          (ms', qs'') = goList qs' ms
       in (m' : ms', qs'')
