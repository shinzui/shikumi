-- | Serialization of a 'CompiledProgram'.
--
-- __Parameter-state, not whole-structure.__ A @Program@'s structure cannot be
-- serialized in general (its @FMap@ nodes hold opaque functions and its GADT type
-- indices are not reflected at runtime). What /can/ be saved — and is exactly what
-- the optimizer (EP-10) and CLI (EP-12) need — is each node's tunable
-- 'Shikumi.Program.Params', against a known program /template/. This mirrors DSPy's
-- @dump_state@/@load_state@: dump the parameters, load them back onto a program you
-- still hold as code.
--
-- This reuses EP-4's already-provided parameter interface verbatim:
-- 'Shikumi.Program.programParams' (the ordered @[Params]@ vector, in @foldParams@
-- order) and 'Shikumi.Program.setProgramParams' (re-apply a vector onto a matching
-- program, with a length-mismatch guard). So this module is a thin JSON wrapper —
-- the node-order contract and the count check are EP-4's, not re-invented here.
module Shikumi.Compile.Serialize
  ( encodeCompiled,
    decodeCompiledOnto,
  )
where

import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy (ByteString)
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Program
  ( Params,
    Program,
    ProgramShapeError (..),
    programParams,
    setProgramParams,
  )

-- | Emit a compiled program's ordered parameter vector as JSON (a JSON array of
-- @Params@, in 'Shikumi.Program.foldParams' order).
encodeCompiled :: CompiledProgram i o -> ByteString
encodeCompiled (CompiledProgram p) = encode (programParams p)

-- | Re-apply a saved parameter vector onto a structural /template/ (the base
-- program, held as code), in node order. Fails with a descriptive message if the
-- JSON is malformed or if its node count does not match the template — which would
-- mean the template is not the program the parameters were saved from. The signature
-- mirrors DSPy's @load_state(program)@.
decodeCompiledOnto ::
  Program i o ->
  ByteString ->
  Either String (CompiledProgram i o)
decodeCompiledOnto template bs = do
  ps <- eitherDecode bs :: Either String [Params]
  case setProgramParams ps template of
    Left (ParamCountMismatch (expected, got)) ->
      Left
        ( "shikumi-compile: parameter count mismatch — the template has "
            <> show expected
            <> " node(s) but the saved state has "
            <> show got
        )
    Right prog -> Right (CompiledProgram prog)
