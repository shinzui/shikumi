{-# LANGUAGE ScopedTypeVariables #-}

-- | Experimental bounded recursive language-model sessions. Documents stay out
-- of the prompt until explicitly inspected; subqueries have depth one.
module Shikumi.CodeExec.RLM
  ( RLMConfig (..),
    defaultRLMConfig,
    RLMOutcome (..),
    RLMReport (..),
    RLMAudit (..),
    rlm,
    rlmWithReport,
  )
where

import Baikai (emptyModel)
import Data.Aeson (Value (..), object, (.=))
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)
import Shikumi.Adapter (ToPrompt (toPrompt), responseText)
import Shikumi.CodeExec.Prompt (encodeText, simpleContext)
import Shikumi.CodeExec.Session
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM, complete)
import Shikumi.Program (Program, embed)
import Shikumi.Schema (FromModel, ToSchema, Validatable, parseOutput, toSchema)
import Shikumi.Signature (Signature, getInstruction)

data RLMConfig = RLMConfig
  { session :: !SessionConfig,
    maxOuterIterations :: !Int,
    -- | Sum of system and user text characters, checked before every call.
    maxRequestChars :: !Int
  }

defaultRLMConfig :: RLMConfig
defaultRLMConfig = RLMConfig defaultSessionConfig 40 64000

data RLMOutcome o = RLMSubmitted o | RLMExhausted SessionLimit
  deriving stock (Eq, Show)

data RLMAudit = RLMAudit
  { actionText :: !Text,
    actionTruncated :: !Bool,
    auditObservation :: !(Maybe SessionObservation)
  }
  deriving stock (Eq, Show)

data RLMReport = RLMReport
  { outerIterations :: !Int,
    operations :: !Int,
    subqueriesAttempted :: !Int,
    totalObservedChars :: !Int,
    audit :: ![RLMAudit],
    -- | Nothing means typed submission; Just identifies exhaustion.
    termination :: !(Maybe SessionLimit)
  }
  deriving stock (Eq, Show)

rlm :: (ToPrompt i, ToSchema o, FromModel o, Validatable o) => RLMConfig -> ContextStore -> Signature i o -> Program i o
rlm cfg docs sig = embed $ \i -> do
  (out, _) <- runRLM cfg docs sig i
  case out of
    RLMSubmitted o -> pure o
    RLMExhausted limit -> throwError (BudgetExceeded ("RLM session exhausted: " <> T.pack (show limit)))

rlmWithReport :: (ToPrompt i, ToSchema o, FromModel o, Validatable o) => RLMConfig -> ContextStore -> Signature i o -> Program i (RLMOutcome o, RLMReport)
rlmWithReport cfg docs sig = embed (runRLM cfg docs sig)

runRLM :: forall i o es. (LLM :> es, Error ShikumiError :> es, ToPrompt i, ToSchema o, FromModel o, Validatable o) => RLMConfig -> ContextStore -> Signature i o -> i -> Eff es (RLMOutcome o, RLMReport)
runRLM cfg docs sig input = do
  if maxOuterIterations cfg <= 0 || maxRequestChars cfg <= 0
    then throwError (ValidationFailure "RLM limits must be positive")
    else pure ()
  s <- either (\(SessionError e) -> throwError (ValidationFailure e)) pure (newSession sc docs)
  loop 0 s [] ""
  where
    sc = session cfg
    sys = getInstruction sig <> "\n" <> guide <> "\nSubmit value must match: " <> encodeText (toSchema (Proxy @o))
    initial = "Question:\n" <> toPrompt input <> "\nContext metadata:\n" <> encodeText (contextMetadata docs) <> "\nLimits:\n" <> limits
    limits =
      encodeText $
        object
          [ "outerIterations" .= maxOuterIterations cfg,
            "requestChars" .= maxRequestChars cfg,
            "contextChars" .= maxContextChars sc,
            "storedChars" .= maxStoredChars sc,
            "actionBytes" .= maxActionBytes sc,
            "observationChars" .= maxObservationChars sc,
            "observedChars" .= maxObservedChars sc,
            "operations" .= maxOperations sc,
            "scanChars" .= maxScanChars sc,
            "matches" .= maxMatches sc,
            "subqueries" .= maxSubqueries sc,
            "subqueryChars" .= maxSubqueryChars sc
          ]
    report n s rows term = RLMReport n (operationCount s) (subqueryAttempts s) (observedChars s) (reverse rows) term
    exhausted limit n s rows = pure (RLMExhausted limit, report n s rows (Just limit))
    fits system prompt = toInteger (T.length system) + toInteger (T.length prompt) <= toInteger (maxRequestChars cfg)
    loop n s rows history
      | n >= maxOuterIterations cfg = exhausted OuterIterations n s rows
      | operationCount s >= maxOperations sc = exhausted Operations n s rows
      | not (fits sys (initial <> history)) = exhausted RequestCharacters n s rows
      | otherwise = do
          let (ctx, opts) = simpleContext sys (initial <> history)
          raw <- responseText <$> complete emptyModel ctx opts
          let parsed = parseSessionAction sc raw
              clipped = case parsed of
                Right _ -> raw
                Left _ -> T.take (maxActionBytes sc `div` 4) raw
              row = RLMAudit clipped (clipped /= raw) Nothing
              (s1, result) = stepSession s parsed
              rows1 = row : rows
              history1 = history <> "\nAction: " <> clipped
              n1 = n + 1
          case result of
            Left limit -> exhausted limit n1 s1 rows1
            Right (Observed obs) -> continue n1 s1 rows1 history1 obs
            Right (Submitted value) -> case parseOutput (encodeText value) of
              Right o -> pure (RLMSubmitted o, report n1 s1 rows1 Nothing)
              Left _ -> continue n1 s1 rows1 history1 (SessionObservation Null (Just (SessionError "submission failed output schema or validation; correct value")) Nothing)
            Right (RunQueries prompts)
              | any (not . fits subSystem) prompts -> exhausted RequestCharacters n1 s1 rows1
              | otherwise -> queryAll n1 s1 rows1 history1 prompts
    continue n s rows history obs =
      case retain s rows history obs of
        (s1, rows1, _, Left limit) -> exhausted limit n s1 rows1
        (s1, rows1, history1, Right ()) -> loop n s1 rows1 history1
    retain s rows history obs =
      let (s1, result) = recordObservation s obs
       in case result of
            Left limit -> (s1, rows, history, Left limit)
            Right bounded ->
              let row = RLMAudit "" False (Just bounded)
               in (s1, row : rows, history <> "\nObservation: " <> renderObservation bounded, Right ())
    queryAll n s rows history [] = loop n s rows history
    queryAll n s rows history (p : ps) = do
      let s1 = attemptedSubquery s
          (ctx, opts) = simpleContext subSystem p
      -- Infrastructure errors propagate unchanged. Reserved slots are never
      -- refunded and no further batch member is dispatched after a failure.
      answer <- responseText <$> complete (subModel sc) ctx opts
      let obs = SessionObservation (String answer) Nothing Nothing
      case retain s1 rows history obs of
        (s2, rows2, _, Left limit) -> exhausted limit n s2 rows2
        (s2, rows2, history2, Right ()) -> queryAll n s2 rows2 history2 ps

subSystem :: Text
subSystem = "Answer the supplied question using only its supplied excerpts. You cannot invoke session operations."

guide :: Text
guide =
  T.unlines
    [ "Experimental document session. Return exactly one JSON action per turn, no fences.",
      "Actions: {op:describe,name}; {op:slice,name,start,count}; {op:find,name,needle,start,limit};",
      "{op:store,name,value}; {op:load,name}; {op:query,prompt}; {op:query_batch,prompts:[string]}; {op:submit,value}.",
      "Use quoted JSON keys and strings. Offsets/counts are Unicode characters, zero-based, half-open.",
      "Find is literal, returns overlapping match offsets and nextOffset for bounded continuation.",
      "Documents are immutable; variables persist privately. Names use ASCII letters, digits, underscore or hyphen, at most 128 characters; operation names are reserved.",
      "Subqueries run sequentially at depth one; their observations follow prompt order. Include excerpts explicitly.",
      "Observations may show marked prefixes. For slices, use nextOffset to continue. Generic truncated values are JSON-text prefixes.",
      "Errors consume operations. Correct invalid actions/submissions within the remaining limits. Submit performs no extra model call."
    ]
