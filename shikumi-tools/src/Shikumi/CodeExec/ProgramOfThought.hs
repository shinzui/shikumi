{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | @programOfThought@ (EP-27): a program where the model writes code that
-- /computes/ the answer, the code runs in a sandbox, and the result flows back into
-- a typed answer.
--
-- The loop mirrors DSPy's @ProgramOfThought.forward@: ask the model for a code
-- snippet that computes the answer; run it through the captured 'CodeInterpreter';
-- if it errors, feed the error back and ask for a correction (up to @maxIters@
-- attempts); once it runs, ask the model to extract the typed output @o@ from the
-- code and its output. The whole loop is a single 'Shikumi.Program.Embed' node, so
-- @programOfThought@ is an ordinary @'Program' i o@ that carries no tunable
-- parameters (the parameter-count invariant holds: @foldParams (programOfThought
-- sig) == []@) and composes/serializes exactly like @react@.
module Shikumi.CodeExec.ProgramOfThought
  ( PoTConfig (..),
    defaultPoTConfig,
    programOfThought,
    programOfThoughtWith,
  )
where

import Baikai (_Model)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)
import Shikumi.Adapter (ToPrompt (toPrompt), responseText)
import Shikumi.CodeExec.Interpreter (CodeInterpreter (..), restrictedInterpreter)
import Shikumi.CodeExec.Prompt (schemaInstruction, simpleContext, stripFences)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM, complete)
import Shikumi.Program (Program, embed)
import Shikumi.Schema (FromModel, ToSchema, Validatable, parseOutput, toSchema)
import Shikumi.Signature (Signature, getInstruction)

-- | How @programOfThought@ runs: the max number of code (re)generation attempts and
-- the sandbox to run snippets in.
data PoTConfig = PoTConfig
  { maxIters :: !Int,
    interpreter :: !CodeInterpreter
  }

-- | Three attempts, the hermetic 'restrictedInterpreter'.
defaultPoTConfig :: PoTConfig
defaultPoTConfig = PoTConfig {maxIters = 3, interpreter = restrictedInterpreter}

-- | The ergonomic default: emit code, run it, fix on error up to @maxIters@, extract
-- the typed @o@. Uses 'defaultPoTConfig'.
programOfThought ::
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  Signature i o ->
  Program i o
programOfThought = programOfThoughtWith defaultPoTConfig

-- | @programOfThought@ with an explicit config (e.g. a different @maxIters@ or a
-- different 'CodeInterpreter').
programOfThoughtWith ::
  (ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  PoTConfig ->
  Signature i o ->
  Program i o
programOfThoughtWith cfg sig = embed (potLoop cfg sig)

-- | The loop body, in exactly the @Embed@ row.
potLoop ::
  forall i o es.
  (LLM :> es, Error ShikumiError :> es, ToPrompt i, ToSchema o, FromModel o, Validatable o) =>
  PoTConfig ->
  Signature i o ->
  i ->
  Eff es o
potLoop cfg sig i = go 0 Nothing
  where
    go :: Int -> Maybe (Text, Text) -> Eff es o
    go iter mPrev = do
      code <- propose mPrev
      r <- runCode (interpreter cfg) code
      case r of
        Right out -> extract code out
        Left err
          | iter + 1 >= maxIters cfg ->
              throwError
                ( ProviderFailure
                    ("programOfThought: code failed after " <> tshow (iter + 1) <> " attempts: " <> err)
                )
          | otherwise -> go (iter + 1) (Just (code, err))

    -- Generate (first attempt) or regenerate (with the previous code + error).
    propose :: Maybe (Text, Text) -> Eff es Text
    propose mPrev = do
      let (ctx, opts) = simpleContext (proposeSys mPrev) (toPrompt i)
      resp <- complete _Model ctx opts
      pure (stripFences (responseText resp))

    -- Extract: hand the model the final code and its output, ask for the typed o.
    extract :: Text -> Text -> Eff es o
    extract code out = do
      let prompt = toPrompt i <> "\n\nThe code:\n" <> code <> "\n\nIts output:\n" <> out
          (ctx, opts) = simpleContext extractSys prompt
      resp <- complete _Model ctx opts
      either throwError pure (parseOutput (stripFences (responseText resp)))

    proposeSys Nothing =
      getInstruction sig <> "\n\n" <> dslGuide <> "\nReply with only the code, no prose."
    proposeSys (Just (prevCode, err)) =
      getInstruction sig
        <> "\n\n"
        <> dslGuide
        <> "\nYour previous code:\n"
        <> prevCode
        <> "\nfailed with error:\n"
        <> err
        <> "\nReply with only the corrected code."

    extractSys = getInstruction sig <> "\n\n" <> schemaInstruction (toSchema (Proxy @o))

-- | A description of the restricted language for the code-generation prompt.
dslGuide :: Text
dslGuide =
  "Write a snippet in a restricted language that computes the answer. It supports "
    <> "integer/rational arithmetic (+ - * /) with parentheses, string literals with ++ and "
    <> "len/upper/lower, and lists with sum/length/concat. The value of the final expression "
    <> "(optionally written `result = <expr>`) is the answer."

tshow :: (Show a) => a -> Text
tshow = T.pack . show
