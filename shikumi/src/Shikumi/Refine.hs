{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Reward-driven self-refinement modules (EP-18): three ways to wrap an existing
-- 'Program' so its re-runs are /steered by how good the answer is/.
--
--   * 'bestOfN' — run the inner program @N@ times at spread temperatures, score
--     each output with a 'Reward', and keep the best (short-circuiting on a pass).
--   * 'refine' — run the inner program; on a sub-threshold output, ask an LM to
--     write a textual critique ("advice") and feed it into the next attempt.
--   * 'multiChainComparison' — run @M@ reasoning attempts, then make one final LM
--     call shown all @M@ candidates and asked to synthesize a consensus answer.
--
-- Each module is itself an ordinary 'Program' built from the existing 'embed'
-- ('Shikumi.Program.Embed') leaf — /no new GADT constructor/ — so it runs under the
-- unchanged 'runProgram'/'runProgramConc', composes with every combinator, holds no
-- optimizable 'Shikumi.Program.Params' of its own (it serializes as
-- 'Shikumi.Program.ShapeEmbed', exactly like @FMap@), and needs no edit to
-- @paramsTraversal@/@programShape@/@setProgramParams@. This is the same pattern V1's
-- ReAct agent uses. The cost, accepted: the inner program's per-node params are not
-- visible to an optimizer /through/ the wrapper (the @Embed@ body is opaque) — fine
-- for inference-time selection\/retry modules.
--
-- Per-sample temperature is requested through the same @TempSchedule@ /
-- 'Shikumi.Program.withSampleTemp' channel EP-14 makes live: each attempt stamps its
-- temperature onto the private request-metadata channel and the router
-- ("Shikumi.Routing".@routeLLM@) sets @Options.temperature@ from it. With no router
-- installed the stamp is inert (every attempt sampled identically — correct, just
-- less diverse); the hermetic stub honours the stamped temperature directly.
module Shikumi.Refine
  ( -- * The reward vocabulary (re-exported from "Shikumi.Reward")
    Reward (..),
    mkReward,
    boolReward,

    -- * Self-refinement modules
    bestOfN,
    bestOfNWith,
    refine,
    refineWith,
    multiChainComparison,
    MultiChainInput (..),
    multiChainSig,

    -- * Defaults
    defaultSpread,
  )
where

import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Object, Value (Object))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpose, passthrough)
import Effectful.Error.Static (Error, catchError, throwError)
import GHC.Generics (Generic, Rep)
import Shikumi.Adapter (ToPrompt (..), toPrompt)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (Context, LLM (..), complete)
import Shikumi.Module (WithReasoning (..), predict)
import Shikumi.Program
  ( Program,
    TempSchedule (..),
    embed,
    runProgram,
    sampleTemps,
    withSampleTemp,
  )
import Shikumi.Reward (Reward (..), boolReward, mkReward)
import Shikumi.Schema
  ( FromModel (..),
    GFieldMetas,
    ToSchema,
    Validatable,
    fieldMetasOf,
  )
import Shikumi.Schema.Types (FieldPath, pushField, renderPath)
import Shikumi.Signature (Signature (..), mkSignature)

-- ---------------------------------------------------------------------------
-- Shared building blocks
-- ---------------------------------------------------------------------------

-- | The default per-attempt temperature spread: centred at 0.7, fanning out by
-- 0.6 — the same convention @majorityVote@ uses.
defaultSpread :: TempSchedule
defaultSpread = TempSpread 0.7 0.6

-- | Run an effect that may throw a 'ShikumiError', recovering the error as a
-- 'Left' instead of propagating it (so a single failed attempt does not abort the
-- whole loop).
tryShikumi :: (Error ShikumiError :> es) => Eff es a -> Eff es (Either ShikumiError a)
tryShikumi act = (Right <$> act) `catchError` \_cs e -> pure (Left e)

-- | Keep the higher-reward of the running best and a fresh @(output, reward)@.
-- Ties keep the incumbent (first-seen wins).
keepBest :: Maybe (o, Double) -> o -> Double -> Maybe (o, Double)
keepBest Nothing o r = Just (o, r)
keepBest (Just (bo, br)) o r = if r > br then Just (o, r) else Just (bo, br)

-- | Render a value as 'Text' via 'Show'.
tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- ---------------------------------------------------------------------------
-- bestOfN
-- ---------------------------------------------------------------------------

-- | Run @inner@ up to @N@ times at spread temperatures, score each output, and
-- return the highest-scoring one — short-circuiting as soon as an output's reward
-- reaches @threshold@. Defaults: 'defaultSpread' temperatures and a @failCount@
-- (tolerated inner-program errors) of @N@.
bestOfN ::
  -- | @N@ attempts (clamped to @>= 1@)
  Int ->
  -- | pass threshold (reward @>=@ this short-circuits)
  Double ->
  Reward o ->
  Program i o ->
  Program i o
bestOfN n = bestOfNWith n (max 1 n) defaultSpread

-- | 'bestOfN' with an explicit @failCount@ budget and 'TempSchedule'.
bestOfNWith ::
  -- | @N@ attempts (clamped to @>= 1@)
  Int ->
  -- | @failCount@: tolerated inner-program errors before the error propagates
  Int ->
  TempSchedule ->
  -- | pass threshold
  Double ->
  Reward o ->
  Program i o ->
  Program i o
bestOfNWith n failCount sched threshold reward inner = embed $ \i ->
  let temps = NE.toList (sampleTemps n sched)
      go [] best lastErr _ = finish best lastErr
      go (t : ts) best lastErr budget = do
        res <- tryShikumi (withSampleTemp t (runProgram inner i))
        case res of
          Left e ->
            let budget' = budget - 1
             in if budget' < 0 then throwError e else go ts best (Just e) budget'
          Right o ->
            let r = runReward reward o
                best' = keepBest best o r
             in if r >= threshold then pure o else go ts best' lastErr budget
      finish (Just (o, _)) _ = pure o
      finish Nothing (Just e) = throwError e
      finish Nothing Nothing = throwError (ProviderFailure "Shikumi.Refine.bestOfN: no attempt produced an output")
   in go temps Nothing Nothing failCount

-- ---------------------------------------------------------------------------
-- refine
-- ---------------------------------------------------------------------------

-- | The input to the advice generator: the achieved reward and the target
-- threshold (rendered as text, since the inner program's input is opaque to the
-- wrapper). Mirrors DSPy's @OfferFeedback@ predictor, scoped to the whole inner
-- program.
data AdviceIn = AdviceIn
  { achievedReward :: !Text,
    targetThreshold :: !Text
  }
  deriving stock (Generic, Show, Eq)

instance ToSchema AdviceIn

instance FromModel AdviceIn

instance ToPrompt AdviceIn

instance Validatable AdviceIn

-- | The advice generator's output: one concrete piece of advice for the next
-- attempt.
newtype AdviceOut = AdviceOut {advice :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema AdviceOut

instance FromModel AdviceOut

instance ToPrompt AdviceOut

instance Validatable AdviceOut

adviceSig :: Signature AdviceIn AdviceOut
adviceSig =
  mkSignature
    "You are reviewing a previous attempt that scored below its target. \
    \Look at the achieved reward and the target threshold, then write one concrete \
    \piece of advice that would help the next attempt score higher."

-- | Like 'bestOfN', but on a sub-threshold output it derives textual advice from
-- the reward (via an LM call) and threads it into the next attempt. Returns the
-- best output seen across all attempts. Defaults: @failCount = N@.
refine ::
  -- | @N@ attempts (clamped to @>= 1@)
  Int ->
  -- | pass threshold
  Double ->
  Reward o ->
  Program i o ->
  Program i o
refine n = refineWith n (max 1 n)

-- | 'refine' with an explicit @failCount@ budget.
--
-- The advice-generation call between attempts is auxiliary: if it fails, the loop
-- keeps the previous advice (if any) and continues the remaining attempts without
-- consuming the @failCount@ budget, so a failed advice call never discards a valid
-- best-so-far output. @failCount@ guards /inner-program/ failures only.
refineWith ::
  -- | @N@ attempts (clamped to @>= 1@)
  Int ->
  -- | @failCount@: tolerated inner-program errors before the error propagates
  Int ->
  -- | pass threshold
  Double ->
  Reward o ->
  Program i o ->
  Program i o
refineWith n failCount threshold reward inner = embed $ \i ->
  let cnt = max 1 n
      go k best lastErr mAdvice budget
        | k >= cnt = finish best lastErr
        | otherwise = do
            res <- tryShikumi (withAdvice mAdvice (runProgram inner i))
            case res of
              Left e ->
                let budget' = budget - 1
                 in if budget' < 0
                      then throwError e
                      else go (k + 1) best (Just e) mAdvice budget'
              Right o ->
                let r = runReward reward o
                    best' = keepBest best o r
                 in if r >= threshold
                      then pure o
                      else
                        if k == cnt - 1
                          then finish best' lastErr
                          else do
                            -- The advice call is auxiliary: if it fails, keep the
                            -- previous advice (if any) and continue — never discard
                            -- a valid best-so-far, and do not consume the failCount
                            -- error budget (it guards inner-program failures only).
                            advE <- tryShikumi (generateAdvice r threshold)
                            let mAdvice' = either (const mAdvice) Just advE
                            go (k + 1) best' lastErr mAdvice' budget
      finish (Just (o, _)) _ = pure o
      finish Nothing (Just e) = throwError e
      finish Nothing Nothing = throwError (ProviderFailure "Shikumi.Refine.refine: no attempt produced an output")
   in go 0 Nothing Nothing Nothing failCount

-- | Ask the advice generator for one piece of advice, given the achieved reward
-- and the target threshold.
generateAdvice ::
  (LLM :> es, Error ShikumiError :> es) =>
  Double ->
  Double ->
  Eff es Text
generateAdvice r threshold = do
  out <- runProgram (predict adviceSig) (AdviceIn (tshow r) (tshow threshold))
  pure (advice out)

-- | Run an action with a previous attempt's advice injected into every outgoing
-- request: the advice is appended to the rendered system prompt as a "Hint from a
-- previous attempt" line, so the model (and the hermetic stub) sees it. 'Nothing'
-- runs the action unchanged. Scoped via 'interpose' so it only affects this
-- attempt's calls.
withAdvice :: (LLM :> es) => Maybe Text -> Eff es a -> Eff es a
withAdvice Nothing act = act
withAdvice (Just adv) act =
  interpose
    ( \env -> \case
        Complete m ctx o -> complete m (appendHint adv ctx) o
        other -> passthrough env other
    )
    act

-- | Append an advice hint to a request's system prompt.
appendHint :: Text -> Context -> Context
appendHint adv ctx =
  ctx & #systemPrompt .~ Just (cur <> "\n\nHint from a previous attempt: " <> adv)
  where
    cur = fromMaybe "" (ctx ^. #systemPrompt)

-- ---------------------------------------------------------------------------
-- multiChainComparison
-- ---------------------------------------------------------------------------

-- | The synthesis input: the original input plus the @M@ candidate
-- @(reasoning, answer)@ attempts. Its instances are hand-written (not
-- @Generic@-derived) because @attempts@ is polymorphic in @o@ — the same reason
-- 'WithReasoning'\'s instances are hand-written.
data MultiChainInput i o = MultiChainInput
  { original :: !i,
    -- | length @M@; each rendered as "Student Attempt #k"
    attempts :: ![WithReasoning o]
  }

-- | Render the original input, then each attempt as a "Student Attempt #k" line:
-- @"I tried to <reasoning>; my answer is <answer>"@ (mirroring DSPy's rendering).
instance (ToPrompt i, ToPrompt o) => ToPrompt (MultiChainInput i o) where
  toPromptFields mci =
    toPromptFields (original mci)
      ++ [ ("Student Attempt #" <> tshow k, renderAttempt a)
         | (k, a) <- zip [1 :: Int ..] (attempts mci)
         ]
    where
      renderAttempt a = "I tried to " <> reasoning a <> "; my answer is " <> toPrompt (value a)

  -- Fields are polymorphic in @i@/@o@, so the generic image walk cannot resolve; a
  -- synthesis input is text-only and carries no image fields.
  imageFields _ = []
  imageFieldNames _ = []

-- | A 'MultiChainInput' is only ever an /input/ to the synthesis 'predict' node,
-- so this decoder exists to satisfy the 'Shikumi.Program.Predict' constraint (used
-- when decoding demos, of which the synthesis node has none).
instance (FromModel i, FromModel o) => FromModel (MultiChainInput i o) where
  fromModelP path = \case
    Object obj ->
      MultiChainInput
        <$> getField path "original" obj
        <*> getField path "attempts" obj
    _ -> Left (SchemaMismatch (renderPath path <> ": expected object"))

instance Validatable (MultiChainInput i o)

-- | Look up a required field in a JSON object, locating a miss precisely.
getField :: (FromModel a) => FieldPath -> Text -> Object -> Either ShikumiError a
getField path nm o = case KM.lookup (Key.fromText nm) o of
  Nothing -> Left (MissingField (renderPath (pushField nm path)))
  Just v -> fromModelP (pushField nm path) v

-- | Build a synthesis signature for 'multiChainComparison'. The input is rendered
-- via 'MultiChainInput'\'s 'ToPrompt' (so the input-field metadata is empty); the
-- output-field metadata is derived from @o2@ so the output guide and demo
-- rendering name the right fields.
multiChainSig ::
  forall i o o2.
  (GFieldMetas (Rep o2)) =>
  -- | the synthesis instruction
  Text ->
  Signature (MultiChainInput i o) o2
multiChainSig instr =
  Signature
    { instruction = instr,
      demos = [],
      inputFields = [],
      outputFields = fieldMetasOf @o2
    }

-- | Run @M@ independent reasoning attempts (each a @(reasoning, answer)@ via a
-- @chainOfThoughtRaw@-shaped program) at spread temperatures, then make one final
-- synthesis 'predict' call shown all the candidates and asked to produce a single
-- corrected answer. Attempts that error are dropped; synthesis proceeds with the
-- survivors (at least one — if every attempt errors, the last error propagates).
multiChainComparison ::
  ( FromModel i,
    ToPrompt i,
    FromModel o,
    ToPrompt o,
    FromModel o2,
    ToSchema o2,
    Validatable o2,
    ToPrompt o2
  ) =>
  -- | @M@ reasoning attempts (clamped to @>= 1@)
  Int ->
  -- | the reasoning program (e.g. @chainOfThoughtRaw sig@)
  Program i (WithReasoning o) ->
  -- | the synthesis signature
  Signature (MultiChainInput i o) o2 ->
  Program i o2
multiChainComparison m reasoner synthSig = embed $ \i -> do
  let temps = NE.toList (sampleTemps m defaultSpread)
  results <- traverse (\t -> tryShikumi (withSampleTemp t (runProgram reasoner i))) temps
  let oks = [o | Right o <- results]
      errs = [e | Left e <- results]
  case oks of
    [] -> case errs of
      (e : _) -> throwError e
      [] -> throwError (ProviderFailure "Shikumi.Refine.multiChainComparison: no reasoning attempts")
    _ -> runProgram (predict synthSig) (MultiChainInput {original = i, attempts = oks})
