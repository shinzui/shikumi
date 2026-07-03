{-# LANGUAGE LambdaCase #-}

-- | Shared, network-free fixtures and a deterministic stub @LLM@ interpreter for
-- the EP-10 optimizer suite.
--
-- The whole point of an optimizer test is that __changing a program's parameters
-- changes its score__ — otherwise an optimizer cannot demonstrably improve
-- anything. So the stub is not a constant: it inspects the rendered request
-- (system prompt + messages) and answers accordingly, by a rule that is monotone
-- in parameter quality. The task is binary sentiment classification of a
-- 'Sentence' into a 'Label' (@"positive"@ / @"negative"@). The ground-truth rule
-- ('goldLabel') is lexical: a sentence containing the word @good@ is positive,
-- one containing @bad@ is negative.
--
-- The stub answers a sentiment request as follows:
--
--   * __with demonstrations present__ — nearest-demo classification: echo the
--     label of the demo sentence sharing the most words with the input (ties and
--     zero-overlap fall back to the demos' majority label). So better demo sets
--     (covering both classes' keywords) yield higher scores — which is exactly
--     what labeled-few-shot and bootstrap exploit.
--   * __no demos but an instruction mentioning @RULE@__ — apply 'goldLabel'
--     directly. So an instruction that describes the task unlocks correct answers
--     — which is what instruction search exploits.
--   * __no demos and no @RULE@ instruction__ — answer the constant @"neutral"@,
--     which never matches a real label, so a deliberately-underspecified program
--     scores zero. This is the "before" state the acceptance test improves on.
--
-- A second request shape, the instruction /proposer/ (recognised by its
-- @proposedInstruction@ output field), returns a candidate instruction chosen by
-- the @variant:N@ marker the optimizer embeds in the request: variant @0@ is the
-- "magic" @RULE@-bearing instruction, others are bland. This lets instruction
-- search demonstrably select the best proposal deterministically.
module StubLM
  ( -- * Task records
    Sentence (..),
    Label (..),

    -- * Signature and program
    sentimentSig,
    sentimentProg,
    ruled,

    -- * Ground truth and helpers
    goldLabel,
    ruleInstruction,
    blandInstruction,

    -- * The stub interpreters
    runStubLM,
    runStubLMCounting,
    runStubLMCapturing,

    -- * The joint instruction×demo task (EP-20)
    runJointStubLM,
    runJointStubLMCounting,

    -- * The reflective task (EP-22, GEPA)
    runGepaStubLM,
    runGepaStubLMCapturing,
  )
where

import Baikai
  ( AssistantContent (..),
    Context,
    Response,
    TextContent (..),
    _Response,
    _TextContent,
  )
import Baikai.Content (UserContent (..))
import Baikai.Message (AssistantPayload (..), Message (..), UserPayload (..))
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (ToJSON)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef')
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.LLM (LLM (..))
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)

-- ---------------------------------------------------------------------------
-- Task records
-- ---------------------------------------------------------------------------

-- | A sentence to classify.
newtype Sentence = Sentence {text :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToJSON)

instance ToSchema Sentence

instance FromModel Sentence

instance ToPrompt Sentence

instance Validatable Sentence

-- | A sentiment label (@"positive"@ / @"negative"@).
newtype Label = Label {sentiment :: Text}
  deriving stock (Generic, Show, Eq, Ord)
  deriving anyclass (ToJSON)

instance ToSchema Label

instance FromModel Label

instance ToPrompt Label

instance Validatable Label

-- ---------------------------------------------------------------------------
-- Signature and program
-- ---------------------------------------------------------------------------

-- | The deliberately-underspecified signature: an /empty/ instruction and no
-- demos. A program built from it scores zero under the stub until an optimizer
-- gives it useful parameters.
sentimentSig :: Signature Sentence Label
sentimentSig = mkSignature ""

-- | The single-node sentiment program.
sentimentProg :: Program Sentence Label
sentimentProg = predict sentimentSig

-- | A single-node sentiment program whose signature instruction already solves the
-- task under the stub. Optimizers must preserve it when "keep current" wins.
ruled :: Program Sentence Label
ruled = predict (mkSignature ruleInstruction)

-- ---------------------------------------------------------------------------
-- Ground truth and helpers
-- ---------------------------------------------------------------------------

-- | The ground-truth labelling rule: @good@ → positive, @bad@ → negative,
-- otherwise negative (the conservative default).
goldLabel :: Text -> Text
goldLabel s
  | "good" `elem` ws = "positive"
  | "bad" `elem` ws = "negative"
  | otherwise = "negative"
  where
    ws = T.words (T.toLower s)

-- | An instruction that unlocks correct answers under the stub (it mentions
-- @RULE@). The "magic" instruction the proposer offers as variant 0.
ruleInstruction :: Text
ruleInstruction = "RULE: classify the sentiment as positive or negative."

-- | An instruction that does /not/ unlock correct answers (no @RULE@).
blandInstruction :: Text
blandInstruction = "Please answer."

-- ---------------------------------------------------------------------------
-- The stub interpreters
-- ---------------------------------------------------------------------------

-- | Interpret the @LLM@ effect deterministically and offline (see module header).
runStubLM :: Eff (LLM : es) a -> Eff es a
runStubLM = interpret $ \_ -> \case
  Complete _ ctx _ -> pure (mkResponse (respondTo ctx))
  Stream {} -> pure []

-- | Like 'runStubLM' but increments a counter on every completion, for the
-- budget-enforcement test.
runStubLMCounting :: (IOE :> es) => IORef Int -> Eff (LLM : es) a -> Eff es a
runStubLMCounting ref = interpret $ \_ -> \case
  Complete _ ctx _ -> do
    liftIO (modifyIORef' ref (+ 1))
    pure (mkResponse (respondTo ctx))
  Stream {} -> pure []

-- | Like 'runStubLM' but records each request's full rendered text (system prompt +
-- user messages) into a test-readable 'IORef', so a test can assert which signals
-- (dataset summary, field names, tip) reached the model.
runStubLMCapturing :: (IOE :> es) => IORef [Text] -> Eff (LLM : es) a -> Eff es a
runStubLMCapturing ref = interpret $ \_ -> \case
  Complete _ ctx _ -> do
    liftIO (modifyIORef' ref (++ [fullRequestText ctx]))
    pure (mkResponse (respondTo ctx))
  Stream {} -> pure []

-- | The joint instruction×demo task (EP-20). The held-out score is a strictly
-- increasing function of getting /both/ axes right: "region A" sentences (those with
-- @good@/@bad@) are answered correctly only when a @RULE@ instruction is present, and
-- "region B" sentences (e.g. @great@/@terrible@) only when a covering demo is present.
-- A @RULE@-only program (what instruction search reaches) scores 0.5; a joint program
-- (instruction + demos, what MIPROv2 reaches) scores 1.0.
runJointStubLM :: Eff (LLM : es) a -> Eff es a
runJointStubLM = interpret $ \_ -> \case
  Complete _ ctx _ -> pure (mkResponse (respondWith answerJoint ctx))
  Stream {} -> pure []

-- | Like 'runJointStubLM' but counts completions, for the budget test.
runJointStubLMCounting :: (IOE :> es) => IORef Int -> Eff (LLM : es) a -> Eff es a
runJointStubLMCounting ref = interpret $ \_ -> \case
  Complete _ ctx _ -> do
    liftIO (modifyIORef' ref (+ 1))
    pure (mkResponse (respondWith answerJoint ctx))
  Stream {} -> pure []

-- | The joint task's classification rule (see 'runJointStubLM').
answerJoint :: Context -> Text
answerJoint ctx
  | "good" `elem` ws || "bad" `elem` ws =
      -- region A: correct only with a RULE instruction
      if instructionHasRule ctx then goldLabel s else "neutral"
  | otherwise =
      -- region B: correct only with a covering demo
      let demos = demoPairs (V.toList (ctx ^. #messages))
       in if any (\(ds, _) -> overlap s ds > 0) demos then nnLabel s demos else "neutral"
  where
    s = parseSentence (lastUserText ctx)
    ws = T.words (T.toLower s)

-- | The full rendered request: system prompt followed by every user message's text.
fullRequestText :: Context -> Text
fullRequestText ctx =
  T.intercalate "\n" (maybe [] pure (ctx ^. #systemPrompt) ++ allUserText ctx)

-- | All user message texts in a request.
allUserText :: Context -> [Text]
allUserText ctx = [userPayloadText u | UserMessage u <- V.toList (ctx ^. #messages)]

-- | Decide the response body for a request, with a pluggable sentiment-answer rule.
-- The grounded proposer (EP-19) issues several distinct sub-program requests; each is
-- recognised by the output-field marker its guide carries in the system prompt
-- (@[[ ## name ## ]]@). The @answerFn@ supplies the task-specific classification.
respondWith :: (Context -> Text) -> Context -> Text
respondWith answerFn ctx
  | sysHasMarker "programDescription" ctx =
      markerBody [("programDescription", "This program classifies the sentiment of a sentence.")]
  | sysHasMarker "observations" ctx =
      markerBody [("observations", "The rows pair short film reviews with positive or negative labels.")]
  | sysHasMarker "summary" ctx =
      markerBody [("summary", "A sentiment dataset of short film reviews labelled positive or negative.")]
  | sysHasMarker "moduleDescription" ctx =
      markerBody [("moduleDescription", "This module assigns a sentiment label to the input sentence.")]
  | sysHasMarker "proposedInstruction" ctx =
      markerBody [("proposedInstruction", groundedInstruction ctx)]
  | otherwise = markerBody [("sentiment", answerFn ctx)]

-- | Whether the request's system prompt carries a @[[ ## name ## ]]@ output marker.
sysHasMarker :: Text -> Context -> Bool
sysHasMarker name ctx = maybe False (T.isInfixOf ("## " <> name <> " ##")) (ctx ^. #systemPrompt)

-- | The default sentiment task's response decision.
respondTo :: Context -> Text
respondTo = respondWith answerSentiment

-- | GEPA's reflective task. Like the sentiment task, but the reflective proposer
-- (recognised by its @proposedInstruction@ output) returns the magic @RULE@
-- instruction whenever the request's feedback asks the node to be more /specific/,
-- and a bland instruction otherwise. So a node whose captured critique is "be more
-- specific" gets mutated to the instruction that unlocks correct answers.
runGepaStubLM :: Eff (LLM : es) a -> Eff es a
runGepaStubLM = interpret $ \_ -> \case
  Complete _ ctx _ -> pure (mkResponse (respondGepa ctx))
  Stream {} -> pure []

-- | Like 'runGepaStubLM' but records each request's rendered text for prompt-signal
-- assertions.
runGepaStubLMCapturing :: (IOE :> es) => IORef [Text] -> Eff (LLM : es) a -> Eff es a
runGepaStubLMCapturing ref = interpret $ \_ -> \case
  Complete _ ctx _ -> do
    liftIO (modifyIORef' ref (++ [fullRequestText ctx]))
    pure (mkResponse (respondGepa ctx))
  Stream {} -> pure []

respondGepa :: Context -> Text
respondGepa ctx
  | sysHasMarker "proposedInstruction" ctx =
      markerBody
        [ ( "proposedInstruction",
            if T.isInfixOf "specific" (lastUserText ctx) then ruleInstruction else blandInstruction
          )
        ]
  | otherwise = markerBody [("sentiment", answerSentiment ctx)]

-- | The grounded proposer's instruction choice: the "magic" @RULE@-bearing
-- instruction when the request carries the /creative/ tip (so exactly one candidate
-- per node proposes it), otherwise a bland one.
groundedInstruction :: Context -> Text
groundedInstruction ctx
  | T.isInfixOf "creative" (lastUserText ctx) = ruleInstruction
  | otherwise = blandInstruction

-- | Classify the actual input given the demos and instruction in the context.
answerSentiment :: Context -> Text
answerSentiment ctx =
  case demos of
    [] -> if instructionHasRule ctx then goldLabel s else "neutral"
    _ -> nnLabel s demos
  where
    msgs = V.toList (ctx ^. #messages)
    demos = demoPairs msgs
    s = parseSentence (lastUserText ctx)

-- | Whether the system prompt carries a @RULE@-bearing instruction.
instructionHasRule :: Context -> Bool
instructionHasRule ctx = maybe False (T.isInfixOf "RULE") (ctx ^. #systemPrompt)

-- | Nearest-demo classification: the label of the demo sentence with the largest
-- word overlap with @s@; ties and zero-overlap fall back to the majority label.
nnLabel :: Text -> [(Text, Text)] -> Text
nnLabel s demos
  | bestOverlap == 0 = majorityLabel (map snd demos)
  | otherwise = bestLabel
  where
    scored = [(overlap s ds, lbl) | (ds, lbl) <- demos]
    (bestOverlap, bestLabel) = foldl1Keep scored
    -- keep the earliest maximum (strictly-greater replaces)
    foldl1Keep (x : xs) = foldl' (\b c -> if fst c > fst b then c else b) x xs
    foldl1Keep [] = (0, "negative")

-- | Word-overlap (intersection size) of two strings, case-insensitive.
overlap :: Text -> Text -> Int
overlap a b = Set.size (Set.intersection (wordSet a) (wordSet b))
  where
    wordSet = Set.fromList . T.words . T.toLower

-- | The most frequent label, ties broken by first appearance.
majorityLabel :: [Text] -> Text
majorityLabel ls = case [(l, length (filter (== l) ls)) | l <- nubOrd ls] of
  [] -> "negative"
  (t : ts) -> fst (foldl' pick t ts)
  where
    pick best cur = if snd cur > snd best then cur else best

-- | Order-preserving de-duplication.
nubOrd :: [Text] -> [Text]
nubOrd = go Set.empty
  where
    go _ [] = []
    go seen (x : xs)
      | x `Set.member` seen = go seen xs
      | otherwise = x : go (Set.insert x seen) xs

-- ---------------------------------------------------------------------------
-- Request parsing (reading the rendered context)
-- ---------------------------------------------------------------------------

-- | The demonstration @(sentence, label)@ pairs in a request: the fallback
-- adapter renders each demo as a @user@ (input) then @assistant@ (output)
-- message, before the final @user@ message carrying the actual input.
demoPairs :: [Message] -> [(Text, Text)]
demoPairs (UserMessage u : AssistantMessage a : rest) =
  (parseSentence (userPayloadText u), parseLabel (assistantPayloadText a))
    : demoPairs rest
demoPairs _ = []

-- | The text of the last user message — the actual input being classified.
lastUserText :: Context -> Text
lastUserText ctx =
  case [userPayloadText u | UserMessage u <- V.toList (ctx ^. #messages)] of
    [] -> ""
    xs -> last xs

-- | Concatenate the text blocks of a user message.
userPayloadText :: UserPayload -> Text
userPayloadText u = T.concat [t | UserText (TextContent t) <- V.toList (u ^. #content)]

-- | Concatenate the text blocks of an assistant message.
assistantPayloadText :: AssistantPayload -> Text
assistantPayloadText a = T.concat [t | AssistantText (TextContent t) <- V.toList (a ^. #content)]

-- | Strip the @"text:"@ field label that @toPrompt@ renders for a 'Sentence'.
parseSentence :: Text -> Text
parseSentence t = T.strip (fromMaybe stripped (T.stripPrefix "text:" stripped))
  where
    stripped = T.strip t

-- | Read the @sentiment@ marker section out of a rendered demo output.
parseLabel :: Text -> Text
parseLabel = markerValue "sentiment"

-- | The value line following a @[[ ## name ## ]]@ marker, trimmed.
markerValue :: Text -> Text -> Text
markerValue name body =
  case dropWhile (not . isMarker) (T.lines body) of
    (_ : v : _) -> T.strip v
    _ -> ""
  where
    isMarker l = T.strip l == "[[ ## " <> name <> " ## ]]"

-- ---------------------------------------------------------------------------
-- Response construction
-- ---------------------------------------------------------------------------

-- | Build a fallback-style @[[ ## field ## ]]@ response body.
markerBody :: [(Text, Text)] -> Text
markerBody fields = T.unlines (concatMap sect fields ++ ["[[ ## completed ## ]]"])
  where
    sect (k, v) = ["[[ ## " <> k <> " ## ]]", v]

-- | An assistant 'Response' carrying @body@ as its single text block.
mkResponse :: Text -> Response
mkResponse body =
  _Response & #message . #content .~ V.singleton (AssistantText (_TextContent & #text .~ body))
