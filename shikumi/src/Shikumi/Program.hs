{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

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
    Program (Predict, Compose, FMap),
    Params (..),
    Demo (..),
    emptyParams,

    -- * Construction & execution
    pipeline,
    runProgram,

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
import Effectful.Error.Static (Error, throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter (Adapter (..), ToPrompt, adapterFor)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM, complete)
import Shikumi.Schema (FromModel, ToSchema, Validatable, fromModel)
import Shikumi.Schema.Types (fieldName)
import Shikumi.Signature (Signature, getInstruction, outputFields, setDemos, setInstruction)
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
  { demoInput :: !Value,
    demoOutput :: !Value
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Demo

instance FromJSON Demo

-- | The default empty overlay: no instruction override, no demos.
emptyParams :: Params
emptyParams = Params Nothing []

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

-- | Sequence two programs, read left-to-right ("first @p@, then @q@"). Typechecks
-- only when @p@'s output type equals @q@'s input type — an invalid pipeline is a
-- compile error, which is the whole point.
pipeline :: Program a b -> Program b c -> Program a c
pipeline = Compose

-- ---------------------------------------------------------------------------
-- Execution
-- ---------------------------------------------------------------------------

-- | The provider-neutral model every node dispatches against. It is the bottom
-- 'Baikai' registry, not the program, that selects a real provider; EP-4 uses the
-- neutral '_Model', which 'adapterFor' maps to the prompt-fallback adapter (the
-- MasterPlan's "exercised path" until EP-2 lands native schemas). Wiring a real
-- ambient model is deferred to the plans that need real routing.
defaultModel :: Model
defaultModel = _Model

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
runProgram (Predict sig ps) i = do
  sig' <- effectiveSignature sig ps
  let adapter = adapterFor defaultModel
      (ctx, opts) = render adapter sig' i
  resp <- complete defaultModel ctx opts
  either throwError pure (parse adapter sig' resp)
runProgram (Compose f g) i = runProgram f i >>= runProgram g
runProgram (FMap k p) i = k <$> runProgram p i

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

-- | Read every node's 'Params', in traversal order.
foldParams :: Program i o -> [Params]
foldParams = getConst . paramsTraversal (\ps -> Const [ps])

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
