-- | Serialization of a 'CompiledProgram'.
--
-- __Parameter-state plus shape fingerprint, not whole-structure.__ A @Program@'s
-- executable structure cannot be serialized in general (its @FMap@ nodes hold
-- opaque functions and its GADT type indices are not reflected at runtime). What
-- /can/ be saved — and is exactly what the optimizer (EP-10) and CLI (EP-12)
-- need — is each node's tunable 'Shikumi.Program.Params', plus a closure-free
-- structural fingerprint used to reject the wrong /template/. This mirrors DSPy's
-- @dump_state@/@load_state@: dump the parameters, load them back onto a program you
-- still hold as code.
--
-- This reuses EP-4's already-provided parameter interface verbatim:
-- 'Shikumi.Program.programShape', 'Shikumi.Program.programParams' (the ordered
-- @[Params]@ vector, in @foldParams@ order), and
-- 'Shikumi.Program.setProgramParams' (re-apply a vector onto a matching program,
-- with a length-mismatch guard). So this module is a thin JSON wrapper — the shape
-- and node-order contracts are EP-4's, not re-invented here.
module Shikumi.Compile.Serialize
  ( encodeCompiled,
    decodeCompiledOnto,
  )
where

import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode)
import Data.ByteString.Lazy (ByteString)
import GHC.Generics (Generic)
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Program
  ( Params,
    Program,
    ProgramShape,
    ProgramShapeError (..),
    programParams,
    programShape,
    setProgramParams,
  )

-- | The persisted form of a compiled program: a closure-free structural
-- fingerprint plus the ordered parameter vector.
data CompiledState = CompiledState
  { shape :: !ProgramShape,
    params :: ![Params]
  }
  deriving stock (Generic)

instance ToJSON CompiledState

instance FromJSON CompiledState

-- | Emit a compiled program's shape fingerprint and ordered parameter vector as
-- JSON.
encodeCompiled :: CompiledProgram i o -> ByteString
encodeCompiled (CompiledProgram p) = encode (CompiledState (programShape p) (programParams p))

-- | Re-apply saved state onto a structural /template/ (the program, held as code),
-- in node order. Fails with a descriptive message if the JSON is malformed, if the
-- shape fingerprint does not match the template, or if the parameter count is
-- inconsistent with the template. The template must have the same compiled shape
-- that produced the saved state: for structural compilers such as
-- 'Shikumi.Compile.ChainOfThought.chainOfThoughtCompiler', re-apply the same
-- compiler to the base program before loading. The signature mirrors DSPy's
-- @load_state(program)@.
decodeCompiledOnto ::
  Program i o ->
  ByteString ->
  Either String (CompiledProgram i o)
decodeCompiledOnto template bs = do
  st <-
    either
      (Left . decodeError)
      Right
      (eitherDecode bs :: Either String CompiledState)
  let templateShape = programShape template
  if shape st /= templateShape
    then
      Left
        ( "shikumi-compile: shape mismatch — the saved state was produced by a structurally different program. saved shape: "
            <> show (shape st)
            <> "; template shape: "
            <> show templateShape
        )
    else applyParams (params st)
  where
    decodeError e =
      "shikumi-compile: expected a compiled-state envelope with shape and params; "
        <> "legacy bare parameter arrays are not supported and must be re-encoded. Aeson error: "
        <> e
    applyParams ps =
      case setProgramParams ps template of
        Left (ParamCountMismatch (expected, got)) ->
          Left
            ( "shikumi-compile: parameter count mismatch — the template has "
                <> show expected
                <> " node(s) but the saved state has "
                <> show got
            )
        Right prog -> Right (CompiledProgram prog)
