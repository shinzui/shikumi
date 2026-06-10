{-# LANGUAGE RankNTypes #-}

-- | The sandbox as a swappable /value/ (EP-27).
--
-- A 'CodeInterpreter' takes a string of model-emitted code and returns either a
-- recoverable error message (fed back to the model) or the code's textual output.
-- It is captured in an 'Shikumi.Program.Embed' closure exactly as a
-- 'Shikumi.Tool.ToolRegistry' is — never added to the effect row — because the
-- @Embed@ body is fixed to the row @(LLM, Error ShikumiError)@. The hermetic
-- interpreters here are /pure/ (they ignore the effects and 'pure' their result), so
-- they fit inside any row.
--
-- == SECURITY POSTURE
--
-- Running model-emitted code is a genuine remote-code-execution risk. The hermetic
-- default 'restrictedInterpreter' is safe /by construction/: it parses a tiny DSL
-- and evaluates it purely — there is no syscall it can make, no filesystem, no
-- network, no unbounded loop primitive (a step/expression-size cap bounds runtime and
-- returns a typed error past it). The dangerous path is a real subprocess
-- interpreter (DSPy uses a @deno@/Pyodide sandbox); that is intentionally /not/
-- shipped here. A future, gated, non-CI @subprocessInterpreter@ (EP-27 M4) would have
-- to enforce, at minimum: no network; no host filesystem access beyond a single fresh
-- scratch dir; no environment inheritance; CPU/memory/wall-clock limits (killing the
-- child and surfacing a 'Shikumi.Error.Timeout'); and loud failure (any limit breach
-- becomes a 'Shikumi.Error.ShikumiError', never a silent empty result). Because such
-- a subprocess needs @IOE@, which the @Embed@ row lacks, it could only be offered
-- through a separate @IOE@-bearing entry point, never inside the composable
-- @programOfThought@/@codeAct@ programs.
--
-- == The restricted DSL
--
-- A single expression (optionally prefixed @result = @), built from: integer and
-- rational literals and @+ - * /@ with parentheses; string literals with @++@
-- concatenation and the functions @len@, @upper@, @lower@; and list literals @[a, b,
-- …]@ with @sum@, @length@, @concat@. The value of the expression is rendered to
-- text as the output. A parse error, an unknown identifier/function, a type error,
-- division by zero, or exceeding the step cap is returned as @Left \<message\>@.
module Shikumi.CodeExec.Interpreter
  ( -- * The interpreter value
    CodeInterpreter (..),

    -- * Hermetic implementations
    restrictedInterpreter,
    echoInterpreter,

    -- * The pure restricted evaluator (exposed for unit tests)
    runRestricted,
  )
where

import Control.Applicative ((<|>))
import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.Ratio (denominator, numerator)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM)
import Text.Read (readMaybe)

-- | A sandbox as a plain value: run a code string, get back either a recoverable
-- error message (@Left@, fed to the model) or the program's textual output
-- (@Right@). A genuine infrastructure failure (e.g. a real subprocess dying) would
-- be thrown as a 'ShikumiError' from inside 'runCode'; the hermetic interpreters
-- never do that.
newtype CodeInterpreter = CodeInterpreter
  { runCode :: forall es. (LLM :> es, Error ShikumiError :> es) => Text -> Eff es (Either Text Text)
  }

-- | The hermetic default: parse and evaluate the restricted DSL purely. No IO, no
-- network, no filesystem; a step cap bounds runtime.
restrictedInterpreter :: CodeInterpreter
restrictedInterpreter = CodeInterpreter (pure . runRestricted)

-- | Echo the code back as its output (a trivial stub for wiring tests).
echoInterpreter :: CodeInterpreter
echoInterpreter = CodeInterpreter (pure . Right)

-- ---------------------------------------------------------------------------
-- The restricted evaluator
-- ---------------------------------------------------------------------------

-- | Evaluate one restricted-DSL expression, returning the rendered result (@Right@)
-- or a recoverable error message (@Left@). Pure and total.
runRestricted :: Text -> Either Text Text
runRestricted src = do
  toks <- tokenize src
  expr <- parseProgram toks
  (v, _) <- eval stepCap expr
  pure (renderVal v)
  where
    stepCap = 10000

-- ---------------------------------------------------------------------------
-- Values
-- ---------------------------------------------------------------------------

data Val
  = VNum !Rational
  | VStr !Text
  | VList ![Val]
  deriving stock (Eq, Show)

renderVal :: Val -> Text
renderVal (VNum r)
  | denominator r == 1 = T.pack (show (numerator r))
  | otherwise = T.pack (show (fromRational r :: Double))
renderVal (VStr s) = s
renderVal (VList xs) = "[" <> T.intercalate ", " (map renderVal xs) <> "]"

-- ---------------------------------------------------------------------------
-- Tokenizer
-- ---------------------------------------------------------------------------

data Tok
  = TNum !Rational
  | TStr !Text
  | TIdent !Text
  | TKwResult
  | TPlus
  | TMinus
  | TStar
  | TSlash
  | TConcat
  | TLParen
  | TRParen
  | TLBrack
  | TRBrack
  | TComma
  | TEq
  deriving stock (Eq, Show)

tokenize :: Text -> Either Text [Tok]
tokenize = go . T.unpack
  where
    go [] = Right []
    go (c : cs)
      | isSpace c = go cs
      | isDigit c =
          let (numStr, rest) = span (\x -> isDigit x || x == '.') (c : cs)
           in case readNum numStr of
                Just r -> (TNum r :) <$> go rest
                Nothing -> Left ("bad number literal: " <> T.pack numStr)
      | c == '"' =
          let (str, rest) = break (== '"') cs
           in case rest of
                ('"' : rest') -> (TStr (T.pack str) :) <$> go rest'
                _ -> Left "unterminated string literal"
      | isAlpha c || c == '_' =
          let (ident, rest) = span (\x -> isAlphaNum x || x == '_') (c : cs)
           in (identTok ident :) <$> go rest
      | c == '+' = case cs of
          ('+' : rest) -> (TConcat :) <$> go rest
          _ -> (TPlus :) <$> go cs
      | c == '-' = (TMinus :) <$> go cs
      | c == '*' = (TStar :) <$> go cs
      | c == '/' = (TSlash :) <$> go cs
      | c == '(' = (TLParen :) <$> go cs
      | c == ')' = (TRParen :) <$> go cs
      | c == '[' = (TLBrack :) <$> go cs
      | c == ']' = (TRBrack :) <$> go cs
      | c == ',' = (TComma :) <$> go cs
      | c == '=' = (TEq :) <$> go cs
      | otherwise = Left ("unexpected character: " <> T.singleton c)
    identTok "result" = TKwResult
    identTok s = TIdent (T.pack s)
    readNum :: String -> Maybe Rational
    readNum s = (fromInteger <$> (readMaybe s :: Maybe Integer)) <|> (toRational <$> (readMaybe s :: Maybe Double))

-- ---------------------------------------------------------------------------
-- Parser (recursive descent)
-- ---------------------------------------------------------------------------

data Op = Add | Sub | Mul | Div | Concat
  deriving stock (Eq, Show)

data Expr
  = ENum !Rational
  | EStr !Text
  | EList ![Expr]
  | EBin !Op !Expr !Expr
  | ECall !Text ![Expr]
  deriving stock (Eq, Show)

type P a = [Tok] -> Either Text (a, [Tok])

parseProgram :: [Tok] -> Either Text Expr
parseProgram toks0 = do
  let toks = case toks0 of
        (TKwResult : TEq : rest) -> rest
        _ -> toks0
  (e, rest) <- parseExpr toks
  case rest of
    [] -> Right e
    _ -> Left "unexpected trailing tokens"

parseExpr :: P Expr
parseExpr = parseAdd

parseAdd :: P Expr
parseAdd toks = do
  (l, r1) <- parseMul toks
  goAdd l r1
  where
    goAdd l (TPlus : ts) = parseMul ts >>= \(r, ts') -> goAdd (EBin Add l r) ts'
    goAdd l (TMinus : ts) = parseMul ts >>= \(r, ts') -> goAdd (EBin Sub l r) ts'
    goAdd l (TConcat : ts) = parseMul ts >>= \(r, ts') -> goAdd (EBin Concat l r) ts'
    goAdd l ts = Right (l, ts)

parseMul :: P Expr
parseMul toks = do
  (l, r1) <- parseFactor toks
  goMul l r1
  where
    goMul l (TStar : ts) = parseFactor ts >>= \(r, ts') -> goMul (EBin Mul l r) ts'
    goMul l (TSlash : ts) = parseFactor ts >>= \(r, ts') -> goMul (EBin Div l r) ts'
    goMul l ts = Right (l, ts)

parseFactor :: P Expr
parseFactor (TNum n : ts) = Right (ENum n, ts)
parseFactor (TStr s : ts) = Right (EStr s, ts)
parseFactor (TLParen : ts) = do
  (e, ts') <- parseExpr ts
  case ts' of
    (TRParen : ts'') -> Right (e, ts'')
    _ -> Left "expected closing )"
parseFactor (TLBrack : ts) = parseSeq TRBrack ts >>= \(es, ts') -> Right (EList es, ts')
parseFactor (TIdent name : TLParen : ts) = parseSeq TRParen ts >>= \(args, ts') -> Right (ECall name args, ts')
parseFactor (TIdent name : ts) = Right (ECall name [], ts)
parseFactor _ = Left "expected an expression"

-- | Parse a comma-separated sequence of expressions terminated by the given token.
parseSeq :: Tok -> P [Expr]
parseSeq close (t : ts) | t == close = Right ([], ts)
parseSeq close ts = do
  (e, ts') <- parseExpr ts
  case ts' of
    (TComma : ts'') -> parseSeq close ts'' >>= \(es, ts3) -> Right (e : es, ts3)
    (t : ts'') | t == close -> Right ([e], ts'')
    _ -> Left "expected , or closing bracket"

-- ---------------------------------------------------------------------------
-- Evaluator (with a step budget)
-- ---------------------------------------------------------------------------

eval :: Int -> Expr -> Either Text (Val, Int)
eval fuel _ | fuel <= 0 = Left "step cap exceeded"
eval fuel (ENum n) = Right (VNum n, fuel - 1)
eval fuel (EStr s) = Right (VStr s, fuel - 1)
eval fuel (EList es) = do
  (vs, f') <- evalList (fuel - 1) es
  Right (VList vs, f')
eval fuel (EBin op a b) = do
  (va, f1) <- eval (fuel - 1) a
  (vb, f2) <- eval f1 b
  v <- applyOp op va vb
  Right (v, f2)
eval fuel (ECall name args) = do
  (vs, f1) <- evalList (fuel - 1) args
  v <- applyFn name vs
  Right (v, f1)

evalList :: Int -> [Expr] -> Either Text ([Val], Int)
evalList fuel [] = Right ([], fuel)
evalList fuel (e : es) = do
  (v, f1) <- eval fuel e
  (vs, f2) <- evalList f1 es
  Right (v : vs, f2)

applyOp :: Op -> Val -> Val -> Either Text Val
applyOp Add (VNum a) (VNum b) = Right (VNum (a + b))
applyOp Sub (VNum a) (VNum b) = Right (VNum (a - b))
applyOp Mul (VNum a) (VNum b) = Right (VNum (a * b))
applyOp Div (VNum _) (VNum 0) = Left "division by zero"
applyOp Div (VNum a) (VNum b) = Right (VNum (a / b))
applyOp Concat (VStr a) (VStr b) = Right (VStr (a <> b))
applyOp Concat (VList a) (VList b) = Right (VList (a ++ b))
applyOp op _ _ = Left ("type error: operator " <> opName op <> " applied to incompatible values")

opName :: Op -> Text
opName = \case
  Add -> "+"
  Sub -> "-"
  Mul -> "*"
  Div -> "/"
  Concat -> "++"

applyFn :: Text -> [Val] -> Either Text Val
applyFn "len" [VStr s] = Right (VNum (fromIntegral (T.length s)))
applyFn "len" [VList xs] = Right (VNum (fromIntegral (length xs)))
applyFn "length" [VList xs] = Right (VNum (fromIntegral (length xs)))
applyFn "length" [VStr s] = Right (VNum (fromIntegral (T.length s)))
applyFn "upper" [VStr s] = Right (VStr (T.toUpper s))
applyFn "lower" [VStr s] = Right (VStr (T.toLower s))
applyFn "sum" [VList xs] = VNum . sum <$> traverse asNum xs
applyFn "concat" [VList xs] = concatVals xs
applyFn name [] = Left ("unknown identifier: " <> name)
applyFn name _ = Left ("unknown function or bad arguments: " <> name)

asNum :: Val -> Either Text Rational
asNum (VNum n) = Right n
asNum _ = Left "type error: expected a number"

concatVals :: [Val] -> Either Text Val
concatVals xs
  | all isStr xs = Right (VStr (T.concat [s | VStr s <- xs]))
  | all isList xs = Right (VList (concat [ys | VList ys <- xs]))
  | otherwise = Left "type error: concat expects a list of all-strings or all-lists"
  where
    isStr (VStr _) = True
    isStr _ = False
    isList (VList _) = True
    isList _ = False
