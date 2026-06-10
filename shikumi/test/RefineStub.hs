{-# LANGUAGE LambdaCase #-}

-- | Hermetic, network-free fixtures and deterministic stub @LLM@ interpreters for
-- the EP-18 self-refinement spec ('Shikumi.Refine').
--
-- The whole point of a self-refinement test is that __a later attempt scores
-- better than the first__. So the stub is not a constant: it inspects the rendered
-- request and the per-sample temperature ('Options.temperature', made live by the
-- router installed above it) and answers by a rule:
--
--   * a /classify/ call answers a label chosen by the request's temperature
--     (@< 0.5@ → @low@, @< 1.0@ → @mid@, else @high@), so 'Shikumi.Refine.bestOfN'
--     — which fans its attempts out across temperatures — finds a better-scoring
--     answer than a single low-temperature shot;
--   * a /classify/ call whose system prompt carries an injected advice hint answers
--     @good@ (otherwise @bad@), so 'Shikumi.Refine.refine' climbs once advice lands;
--   * an /advice/ call (its output guide names an @advice@ field) returns a fixed
--     advice string;
--   * a /reasoning/ call (chain-of-thought; its guide names a @reasoning@ field)
--     answers a temperature-chosen candidate, and the /synthesis/ call returns the
--     modal candidate it is shown.
module RefineStub
  ( -- * Task records
    Sentence (..),
    Answer (..),

    -- * Signatures and programs
    classifySig,
    classifyProg,
    reasonProg,
    synthInstruction,
    mccSynthSig,

    -- * Rewards
    rewardByLabel,
    goodReward,

    -- * Decision rules
    decideTemp,
    decideRefine,
    decideMCC,

    -- * Stub interpreters
    runStub,
    runRecordingStub,
    runThrowingLLM,

    -- * Request readers (re-used by assertions)
    lastUserText,
  )
where

import Baikai (Context, Options, TextContent (..))
import Baikai.Content (UserContent (..))
import Baikai.Message (Message (..), UserPayload (..))
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', modifyIORef')
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, throwError)
import GHC.Generics (Generic)
import ProgramFixtures (markerBody, mkResponse)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..))
import Shikumi.Module (WithReasoning, chainOfThoughtRaw, predict)
import Shikumi.Program (Program, modal)
import Shikumi.Refine (MultiChainInput, multiChainSig)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)

-- ---------------------------------------------------------------------------
-- Task records
-- ---------------------------------------------------------------------------

-- | A sentence to classify.
newtype Sentence = Sentence {text :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Sentence

instance FromModel Sentence

instance ToPrompt Sentence

instance Validatable Sentence

-- | A one-field answer label.
newtype Answer = Answer {answer :: Text}
  deriving stock (Generic, Show, Eq, Ord)

instance ToSchema Answer

instance FromModel Answer

instance ToPrompt Answer

instance Validatable Answer

-- ---------------------------------------------------------------------------
-- Signatures and programs
-- ---------------------------------------------------------------------------

-- | A deliberately bland classify signature (no @advice@/@reasoning@ words, so the
-- stub's call-type detection stays unambiguous).
classifySig :: Signature Sentence Answer
classifySig = mkSignature "Classify the input into a label."

-- | The single-node classify program.
classifyProg :: Program Sentence Answer
classifyProg = predict classifySig

-- | The chain-of-thought reasoning program (produces @(reasoning, answer)@).
reasonProg :: Program Sentence (WithReasoning Answer)
reasonProg = chainOfThoughtRaw classifySig

-- | The synthesis instruction — deliberately free of the words @reasoning@ and
-- @advice@ so the stub recognises a synthesis call by elimination.
synthInstruction :: Text
synthInstruction = "Compare the student attempts and give the single consensus label."

-- | The synthesis signature for 'Shikumi.Refine.multiChainComparison'.
mccSynthSig :: Signature (MultiChainInput Sentence Answer) Answer
mccSynthSig = multiChainSig synthInstruction

-- ---------------------------------------------------------------------------
-- Rewards
-- ---------------------------------------------------------------------------

-- | Score an answer by its label, defaulting unknown labels to @0@.
rewardByLabel :: [(Text, Double)] -> Answer -> Double
rewardByLabel table (Answer a) = fromMaybe 0 (lookup a table)

-- | The reward used by the advice-driven test: @good@ is the only passing label.
goodReward :: Answer -> Double
goodReward (Answer a) = if a == "good" then 1.0 else 0.0

-- ---------------------------------------------------------------------------
-- Decision rules (a pure @Context -> Options -> Text@ response body)
-- ---------------------------------------------------------------------------

-- | The per-sample temperature carried on the request (0 when unset).
reqTemp :: Options -> Double
reqTemp opts = fromMaybe 0 (opts ^. #temperature)

-- | The label a classify call answers, chosen by request temperature.
labelForTemp :: Double -> Text
labelForTemp t
  | t < 0.5 = "low"
  | t < 1.0 = "mid"
  | otherwise = "high"

sysPrompt :: Context -> Text
sysPrompt ctx = fromMaybe "" (ctx ^. #systemPrompt)

hasField :: Text -> Context -> Bool
hasField name ctx = T.isInfixOf name (sysPrompt ctx)

-- | M1/M4 classify rule: answer a temperature-chosen label.
decideTemp :: Context -> Options -> Text
decideTemp _ opts = markerBody [("answer", labelForTemp (reqTemp opts))]

-- | M2 refine rule: an advice call returns fixed advice; a classify call answers
-- @good@ when an advice hint is present, @bad@ otherwise.
decideRefine :: Context -> Options -> Text
decideRefine ctx _
  | hasField "advice" ctx = markerBody [("advice", "State the keyword clearly.")]
  | hasField "Hint from a previous attempt" ctx = markerBody [("answer", "good")]
  | otherwise = markerBody [("answer", "bad")]

-- | M3 multi-chain rule: a reasoning call answers a temperature-chosen candidate; a
-- synthesis call returns the modal candidate it was shown.
decideMCC :: Context -> Options -> Text
decideMCC ctx opts
  | hasField "reasoning" ctx =
      markerBody [("reasoning", "considering the input"), ("value", answerJSON (candidateForTemp (reqTemp opts)))]
  | otherwise = markerBody [("answer", modalCandidate (lastUserText ctx))]

-- | The reasoning candidate for a temperature: low → @Paris@, otherwise
-- @Brussels@ (so 3 spread samples give @[Paris, Brussels, Brussels]@, modal
-- @Brussels@).
candidateForTemp :: Double -> Text
candidateForTemp t = if t < 0.5 then "Paris" else "Brussels"

-- | Render an 'Answer' as the nested JSON the fallback adapter expects under a
-- @value@ section.
answerJSON :: Text -> Text
answerJSON a = "{\"answer\": \"" <> a <> "\"}"

-- | The modal answer among the @"my answer is ..."@ fragments in a synthesis
-- prompt.
modalCandidate :: Text -> Text
modalCandidate t = case extractAnswers t of
  [] -> ""
  xs -> modal xs

-- | Pull each attempt's answer out of the rendered 'MultiChainInput' prompt.
extractAnswers :: Text -> [Text]
extractAnswers t = map clean (drop 1 (T.splitOn "my answer is " t))
  where
    clean p =
      let line = T.takeWhile (/= '\n') p
       in T.strip (fromMaybe line (T.stripPrefix "answer:" (T.strip line)))

-- ---------------------------------------------------------------------------
-- Stub interpreters
-- ---------------------------------------------------------------------------

-- | Interpret @LLM@ with a pure decision rule, counting completions (for the
-- short-circuit / budget assertions). Concurrency-safe via 'atomicModifyIORef''.
runStub ::
  (IOE :> es) =>
  IORef Int ->
  (Context -> Options -> Text) ->
  Eff (LLM : es) a ->
  Eff es a
runStub ref decide = interpret $ \_ -> \case
  Complete _ ctx opts -> do
    liftIO (atomicModifyIORef' ref (\n -> (n + 1, ())))
    pure (mkResponse (decide ctx opts))
  Stream {} -> pure []

-- | Like 'runStub' but records each request's last user text (for asserting what a
-- synthesis call was shown).
runRecordingStub ::
  (IOE :> es) =>
  IORef [Text] ->
  (Context -> Options -> Text) ->
  Eff (LLM : es) a ->
  Eff es a
runRecordingStub cap decide = interpret $ \_ -> \case
  Complete _ ctx opts -> do
    liftIO (modifyIORef' cap (++ [lastUserText ctx]))
    pure (mkResponse (decide ctx opts))
  Stream {} -> pure []

-- | An @LLM@ interpreter that throws on every completion (the always-fails case),
-- counting attempts.
runThrowingLLM ::
  (IOE :> es, Error ShikumiError :> es) =>
  IORef Int ->
  Eff (LLM : es) a ->
  Eff es a
runThrowingLLM ref = interpret $ \_ -> \case
  Complete _ _ _ -> do
    liftIO (atomicModifyIORef' ref (\n -> (n + 1, ())))
    throwError (ProviderFailure "RefineStub: scripted failure")
  Stream {} -> pure []

-- ---------------------------------------------------------------------------
-- Request readers
-- ---------------------------------------------------------------------------

-- | The text of the last user message — the actual input being processed.
lastUserText :: Context -> Text
lastUserText ctx =
  case [userPayloadText u | UserMessage u <- V.toList (ctx ^. #messages)] of
    [] -> ""
    xs -> last xs

-- | Concatenate the text blocks of a user message.
userPayloadText :: UserPayload -> Text
userPayloadText u = T.concat [t | UserText (TextContent t) <- V.toList (u ^. #content)]
