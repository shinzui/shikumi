{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Closed decisions and their probability evidence. Answers are derived
-- locally; schemas describe judgments, while JSON decoding consumes evidence.
-- No provider transport or provider-specific response type lives here.
module Shikumi.Decision
  ( NoulWith (..),
    Noul,
    Choice (..),
    Score (..),
    NoulEvidence (..),
    ChoiceEvidence (..),
    ScoreEvidence (..),
    FieldEvidence (..),
    ChoiceOptions (..),
    IsDecision (..),
    DecisionOutputs,
    judgmentsOf,
    Judgment (..),
    JudgmentKind (..),
    judgmentsInSchema,
    questionJSON,
    renderDecisionState,
    deriveNoul,
    deriveScore,
    deriveChoice,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Pair, Parser, parseEither)
import Data.Bifunctor (first)
import Data.Kind (Constraint, Type)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics
import GHC.TypeLits (ErrorMessage (..), KnownSymbol, Nat, Symbol, TypeError, symbolVal, type (+))
import Shikumi.Adapter (PromptValue (..), ToPrompt (..))
import Shikumi.Error (ShikumiError (..))
import Shikumi.Schema (FromModel (..), ToSchema (..), Validatable)
import Shikumi.Schema.Types (Field, FieldMeta (..), FieldPath, renderPath)
import Shikumi.Signature (Demo (..), Signature, getDemos, getInstruction, inputFields)

-- Evidence JSON is shared by provider-backed and generative decisions.
newtype NoulEvidence = NoulEvidence {pTrue :: Double}
  deriving stock (Eq, Show, Generic)

data ChoiceEvidence = ChoiceEvidence
  {probabilities :: !(Map Text Double), confidence :: !(Maybe Double)}
  deriving stock (Eq, Show, Generic)

data ScoreEvidence = ScoreEvidence
  {levelProbabilities :: !(Vector Double), confidence :: !(Maybe Double)}
  deriving stock (Eq, Show, Generic)

data FieldEvidence = FieldNoul !NoulEvidence | FieldChoice !ChoiceEvidence | FieldScore !ScoreEvidence
  deriving stock (Eq, Show, Generic)

instance ToJSON NoulEvidence where
  toJSON (NoulEvidence p) = object ["noul" .= p]

instance FromJSON NoulEvidence where
  parseJSON = withObject "NoulEvidence" $ \o -> NoulEvidence <$> (o .: "noul" >>= probabilityP)

instance ToJSON ChoiceEvidence where
  toJSON (ChoiceEvidence ps c) = object ["probabilities" .= ps, "confidence" .= c]

instance FromJSON ChoiceEvidence where
  parseJSON = withObject "ChoiceEvidence" $ \o -> do
    ps <- o .: "probabilities" >>= traverse probabilityP
    if Map.null ps then fail "empty probability distribution" else pure ()
    c <- o .:? "confidence" >>= traverse probabilityP
    pure (ChoiceEvidence ps c)

instance ToJSON ScoreEvidence where
  toJSON (ScoreEvidence ps c) = object ["probabilities" .= indexedProbabilities ps, "confidence" .= c]

instance FromJSON ScoreEvidence where
  parseJSON = withObject "ScoreEvidence" $ \o -> do
    ps <- o .: "probabilities" >>= traverse probabilityP
    let n = Map.size ps
        keys = map (T.pack . show) [0 .. n - 1]
    if n < 2 || n > 10 || sort keys /= Map.keys ps
      then fail "score probabilities must have contiguous indices 0..N-1, with 2 to 10 levels"
      else pure ()
    c <- o .:? "confidence" >>= traverse probabilityP
    pure (ScoreEvidence (V.fromList [ps Map.! k | k <- keys]) c)

-- A wrapper needs a tag because numeric Choice labels and Score indices overlap.
instance ToJSON FieldEvidence where
  toJSON e = case e of
    FieldNoul x -> tagged "noul" (toJSON x)
    FieldChoice x -> tagged "choice" (toJSON x)
    FieldScore x -> tagged "score" (toJSON x)
    where
      tagged :: Text -> Value -> Value
      tagged k v = object ["kind" .= k, "evidence" .= v]

instance FromJSON FieldEvidence where
  parseJSON = withObject "FieldEvidence" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "noul" -> FieldNoul <$> o .: "evidence"
      "choice" -> FieldChoice <$> o .: "evidence"
      "score" -> FieldScore <$> o .: "evidence"
      _ -> fail "unknown decision evidence kind"

probabilityP :: Double -> Parser Double
probabilityP p
  | finite p && p >= 0 && p <= 1 = pure p
  | otherwise = fail "probability or confidence must be finite and in [0,1]"

finite :: Double -> Bool
finite p = not (isNaN p || isInfinite p)

indexedProbabilities :: Vector Double -> Map Text Double
indexedProbabilities ps = Map.fromList [(T.pack (show i), p) | (i, p) <- zip [0 :: Int ..] (V.toList ps)]

data NoulWith (t :: Symbol) (f :: Symbol) = Noul
  {value :: !Bool, probability :: !Double, confidence :: !Double}
  deriving stock (Eq, Show, Generic)

type Noul = NoulWith "" ""

data Choice a = Choice
  {value :: !a, probabilities :: !(Map Text Double), confidence :: !(Maybe Double)}
  deriving stock (Eq, Show, Generic)

-- The constructor carries the level-count constraint as well as the schema
-- instance, so an invalid Score cannot be constructed outside schema derivation.
data Score (levels :: [Symbol]) where
  Score ::
    (CheckLevels (Length levels)) =>
    {value :: !Double, level :: !Int, levelProbabilities :: !(Vector Double), confidence :: !(Maybe Double)} ->
    Score levels

deriving stock instance Eq (Score levels)

deriving stock instance Show (Score levels)

-- | Labels in declaration order, with optional criteria. Override the generic
-- nullary-enum default to use domain labels and descriptions.
class (Eq a) => ChoiceOptions a where
  choiceOptions :: [(Text, a, Maybe Text)]
  default choiceOptions :: (Generic a, GChoiceOptions (Rep a)) => [(Text, a, Maybe Text)]
  choiceOptions = [(n, to v, Nothing) | (n, v) <- gChoiceOptions]

class GChoiceOptions (f :: Type -> Type) where
  gChoiceOptions :: [(Text, f p)]

instance (GChoiceOptions f) => GChoiceOptions (D1 d f) where
  gChoiceOptions = [(n, M1 v) | (n, v) <- gChoiceOptions @f]

instance (GChoiceOptions a, GChoiceOptions b) => GChoiceOptions (a :+: b) where
  gChoiceOptions = [(n, L1 v) | (n, v) <- gChoiceOptions @a] ++ [(n, R1 v) | (n, v) <- gChoiceOptions @b]

instance (Constructor c) => GChoiceOptions (C1 c U1) where
  gChoiceOptions = [(T.pack (conName (undefined :: C1 c U1 ())), M1 U1)]

class KnownLevels (ss :: [Symbol]) where
  levelNames :: Proxy ss -> [Text]

instance KnownLevels '[] where levelNames _ = []

instance (KnownSymbol s, KnownLevels ss) => KnownLevels (s ': ss) where
  levelNames _ = T.pack (symbolVal (Proxy @s)) : levelNames (Proxy @ss)

type family Length (ss :: [Symbol]) :: Nat where
  Length '[] = 0
  Length (s ': ss) = 1 + Length ss

type family CheckLevels (n :: Nat) :: Constraint where
  CheckLevels 0 = TypeError ('Text "Score requires 2 to 10 levels")
  CheckLevels 1 = TypeError ('Text "Score requires 2 to 10 levels")
  CheckLevels 2 = ()
  CheckLevels 3 = ()
  CheckLevels 4 = ()
  CheckLevels 5 = ()
  CheckLevels 6 = ()
  CheckLevels 7 = ()
  CheckLevels 8 = ()
  CheckLevels 9 = ()
  CheckLevels 10 = ()
  CheckLevels n = TypeError ('Text "Score requires 2 to 10 levels; got " ':<>: 'ShowType n)

-- | Schema-independent metadata, also consumed by the generative evidence path.
data JudgmentKind
  = JudgeBoolean !(Maybe Value) !(Maybe Value)
  | JudgeChoice ![(Text, Maybe Value)]
  | JudgeOrdered ![Value]
  deriving stock (Eq, Show, Generic)

data Judgment = Judgment
  {judgmentField :: !Text, judgmentInstruction :: !(Maybe Text), judgmentKind :: !JudgmentKind}
  deriving stock (Eq, Show, Generic)

class IsDecision a where
  decisionKind :: Proxy a -> JudgmentKind
  decisionDescription :: Proxy a -> Maybe Text
  decisionDescription _ = Nothing

instance (KnownSymbol t, KnownSymbol f) => IsDecision (NoulWith t f) where
  decisionKind _ = JudgeBoolean (criterion @t) (criterion @f)

instance IsDecision Bool where decisionKind _ = JudgeBoolean Nothing Nothing

instance (ChoiceOptions a) => IsDecision (Choice a) where
  decisionKind _ = JudgeChoice [(n, String <$> d) | (n, _, d) <- choiceOptions @a]

instance (KnownLevels ss, CheckLevels (Length ss)) => IsDecision (Score ss) where
  decisionKind _ = JudgeOrdered (map String (levelNames (Proxy @ss)))

instance (KnownSymbol d, IsDecision a) => IsDecision (Field d a) where
  decisionKind _ = decisionKind (Proxy @a)
  decisionDescription _ = Just (T.pack (symbolVal (Proxy @d)))

criterion :: forall s. (KnownSymbol s) => Maybe Value
criterion = case T.pack (symbolVal (Proxy @s)) of
  "" -> Nothing
  t -> Just (String t)

-- | Compile-time guarantee that every output is a supported decision leaf.
class DecisionOutputs o where
  decisionJudgments :: Proxy o -> [Judgment]
  default decisionJudgments :: (GDecisionOutputs (Rep o)) => Proxy o -> [Judgment]
  decisionJudgments _ = gDecisionJudgments (Proxy @(Rep o))

judgmentsOf :: forall o. (DecisionOutputs o) => [Judgment]
judgmentsOf = decisionJudgments (Proxy @o)

type family RequireDecision (name :: Symbol) a :: Constraint where
  RequireDecision name (Field d a) = RequireDecision name a
  RequireDecision name (NoulWith t f) = ()
  RequireDecision name (Choice a) = ()
  RequireDecision name (Score ss) = ()
  RequireDecision name Bool = ()
  RequireDecision name a = TypeError ('Text "Decision output field `" ':<>: 'Text name ':<>: 'Text "` has unsupported type " ':<>: 'ShowType a)

class GDecisionOutputs (f :: Type -> Type) where
  gDecisionJudgments :: Proxy f -> [Judgment]

instance (GDecisionOutputs f) => GDecisionOutputs (D1 d f) where
  gDecisionJudgments _ = gDecisionJudgments (Proxy @f)

instance (GDecisionOutputs f) => GDecisionOutputs (C1 c f) where
  gDecisionJudgments _ = gDecisionJudgments (Proxy @f)

instance (GDecisionOutputs a, GDecisionOutputs b) => GDecisionOutputs (a :*: b) where
  gDecisionJudgments _ = gDecisionJudgments (Proxy @a) ++ gDecisionJudgments (Proxy @b)

instance (KnownSymbol name, RequireDecision name a, IsDecision a) => GDecisionOutputs (S1 ('MetaSel ('Just name) su ss ds) (K1 R a)) where
  gDecisionJudgments _ = [Judgment (T.pack (symbolVal (Proxy @name))) (decisionDescription (Proxy @a)) (decisionKind (Proxy @a))]

instance (KnownSymbol t, KnownSymbol f) => ToSchema (NoulWith t f) where
  toSchema _ = case decisionKind (Proxy @(NoulWith t f)) of
    JudgeBoolean Nothing Nothing -> marked "noul" ["type" .= ("boolean" :: Text)]
    JudgeBoolean t f -> marked "noul" ["type" .= ("boolean" :: Text), "anyOf" .= [branch (Bool True) t, branch (Bool False) f]]
    _ -> marked "noul" []

instance (ChoiceOptions a) => ToSchema (Choice a) where
  toSchema _ = marked "choice" ["type" .= ("string" :: Text), "anyOf" .= [branch (String n) (String <$> d) | (n, _, d) <- choiceOptions @a]]

instance (KnownLevels ss, CheckLevels (Length ss)) => ToSchema (Score ss) where
  toSchema _ = marked "score" ["type" .= ("integer" :: Text), "anyOf" .= [branch (toJSON i) (Just (String d)) | (i, d) <- zip [0 :: Int ..] (levelNames (Proxy @ss))]]

marked :: Text -> [Pair] -> Value
marked kind fields = object (fields ++ ["x-shikumi-decision" .= object ["kind" .= kind]])

branch :: Value -> Maybe Value -> Value
branch c d = object ["const" .= c, "description" .= d]

-- | Read only the declared judgment grammar. Unsupported or malformed fields
-- are returned separately for a pre-dispatch refusal. Property order follows a
-- complete, unique required array, otherwise ascending property name.
judgmentsInSchema :: Value -> ([Judgment], [Text])
judgmentsInSchema (Object schema)
  | Just (Object props) <- KM.lookup "properties" schema =
      foldMap (readField props) (propertyOrder schema props)
  where
    readField props name = case KM.lookup (Key.fromText name) props >>= readJudgment name of
      Just j -> ([j], [])
      Nothing -> ([], [name])
judgmentsInSchema _ = ([], [])

propertyOrder :: KM.KeyMap Value -> KM.KeyMap Value -> [Text]
propertyOrder schema props =
  let names = map (Key.toText . fst) (KM.toAscList props)
   in case KM.lookup "required" schema of
        Just (Array xs)
          | Just required <- traverse textOf (V.toList xs), sort required == names -> required
        _ -> names

readJudgment :: Text -> Value -> Maybe Judgment
readJudgment name (Object prop) = do
  -- Ignoring an unfamiliar constraint would widen the caller's declared domain.
  if all (`elem` ["type", "description", "title", "x-shikumi-decision", "anyOf", "oneOf", "enum"]) (KM.keys prop)
    then pure ()
    else Nothing
  instruction <- case KM.lookup "description" prop of
    Nothing -> Just Nothing
    Just Null -> Just Nothing
    Just (String t) -> Just (Just t)
    _ -> Nothing
  kind <- booleanKind prop <|> choiceKind prop <|> scoreKind prop
  pure (Judgment name instruction kind)
readJudgment _ _ = Nothing

booleanKind :: KM.KeyMap Value -> Maybe JudgmentKind
booleanKind p
  | KM.member "enum" p = Nothing
  | KM.lookup "type" p == Just (String "boolean"), not (KM.member "anyOf" p || KM.member "oneOf" p) = Just (JudgeBoolean Nothing Nothing)
  | allowedType "boolean" p = do
      if KM.member "anyOf" p && KM.member "oneOf" p then Nothing else pure ()
      Array xs <- KM.lookup "anyOf" p <|> KM.lookup "oneOf" p
      pairs <- traverse readBranch (V.toList xs)
      if sort (map fst pairs) == [Bool False, Bool True]
        then Just (JudgeBoolean (lookup (Bool True) pairs >>= id) (lookup (Bool False) pairs >>= id))
        else Nothing
  | otherwise = Nothing

choiceKind :: KM.KeyMap Value -> Maybe JudgmentKind
choiceKind p = do
  if allowedType "string" p && not (KM.member "oneOf" p) then pure () else Nothing
  labels <- case (KM.lookup "enum" p, KM.lookup "anyOf" p) of
    (Just (Array xs), Nothing) -> traverse (\v -> (,Nothing) <$> textOf v) (V.toList xs)
    (Nothing, Just (Array xs)) -> traverse (\v -> do (c, d) <- readBranch v; n <- textOf c; pure (n, d)) (V.toList xs)
    _ -> Nothing
  let names = map fst labels
  if null names || length names > 255 || Map.size (Map.fromList labels) /= length names
    then Nothing
    else Just (JudgeChoice labels)

scoreKind :: KM.KeyMap Value -> Maybe JudgmentKind
scoreKind p = do
  if allowedType "integer" p && not (KM.member "enum" p || KM.member "oneOf" p) then pure () else Nothing
  Array xs <- KM.lookup "anyOf" p
  pairs <- traverse readBranch (V.toList xs)
  let n = length pairs
  if n >= 2 && n <= 10 && map fst pairs == map toJSON [0 :: Int .. n - 1]
    then Just (JudgeOrdered (map (fromMaybe Null . snd) pairs))
    else Nothing

allowedType :: Text -> KM.KeyMap Value -> Bool
allowedType t p = maybe True (== String t) (KM.lookup "type" p)

readBranch :: Value -> Maybe (Value, Maybe Value)
readBranch (Object o)
  | all (`elem` ["const", "description"]) (KM.keys o) = do
      c <- KM.lookup "const" o
      pure (c, case KM.lookup "description" o of Just Null -> Nothing; d -> d)
readBranch _ = Nothing

textOf :: Value -> Maybe Text
textOf (String t) = Just t
textOf _ = Nothing

-- | Render a provider-neutral judgment question; no private marker is needed.
questionJSON :: Judgment -> Value
questionJSON (Judgment name instruction kind) =
  object
    (["type" .= kindName, "instructions" .= fromMaybe name instruction] ++ criteria)
  where
    (kindName, criteria) = case kind of
      JudgeBoolean Nothing Nothing -> ("noul" :: Text, [])
      JudgeBoolean t f -> ("noul", ["criteria" .= object ["true" .= t, "false" .= f]])
      JudgeChoice xs -> ("choice", ["criteria" .= object [Key.fromText n .= d | (n, d) <- xs]])
      JudgeOrdered ds -> ("score", ["criteria" .= ds])

-- | A single JSON state, with flat input/output demos. Demo answers use their
-- derived values through 'PromptValue', rather than evidence or Haskell Show.
renderDecisionState :: (ToPrompt i, ToPrompt o) => Signature i o -> i -> Value
renderDecisionState sig i =
  object
    ( [ "instructions" .= getInstruction sig,
        "input_fields" .= T.intercalate "\n" (zipWith describe [1 :: Int ..] (inputFields sig)),
        "inputs" .= toPromptJSON i
      ]
        ++ ["demos" .= map demo (getDemos sig) | not (null (getDemos sig))]
    )
  where
    inputObject = case toPromptJSON i of Object o -> o; _ -> KM.empty
    describe n (FieldMeta name description) =
      T.pack (show n) <> ". `" <> name <> "` (" <> jsonType (KM.lookup (Key.fromText name) inputObject) <> "): " <> fromMaybe "" description
    demo (Demo di o) = case (toPromptJSON di, toPromptJSON o) of
      (Object ins, Object outs) -> Object (KM.union outs ins)
      _ -> object []
    jsonType = \case
      Just (String _) -> "str"
      Just (Bool _) -> "bool"
      Just (Number _) -> "number"
      Just (Array _) -> "list"
      Just (Object _) -> "dict"
      _ -> "null"

-- Pure derivation accepts explicit settings; defaults are selected by decoding.
deriveNoul :: Double -> NoulEvidence -> (Bool, Double)
deriveNoul threshold (NoulEvidence p) = (p >= threshold, if denominator == 0 then 0 else abs (p - threshold) / denominator)
  where
    denominator = max threshold (1 - threshold)

deriveScore :: [Double] -> ScoreEvidence -> Either Text (Double, Int)
deriveScore cuts (ScoreEvidence ps _) = do
  validateMass (V.toList ps)
  let v = sum [fromIntegral n * p | (n, p) <- zip [0 :: Int ..] (V.toList ps)] / V.sum ps
  pure (v, length (filter (<= v) cuts))

-- | Select from declared labels in order; ties prefer the raw winner, then
-- declaration order. A probability map alone cannot retain that order.
deriveChoice :: [Text] -> Map Text Double -> ChoiceEvidence -> Either Text Text
deriveChoice labels weights (ChoiceEvidence ps _) = do
  if sort labels == Map.keys ps then pure () else Left "probability keys must match declared choice labels exactly"
  validateMass (Map.elems ps)
  let scored = [(label, ps Map.! label * Map.findWithDefault 1 label weights) | label <- labels]
  if any (\(_, p) -> not (finite p) || p < 0) scored
    then Left "weighted probabilities must be finite and non-negative"
    else if all ((== 0) . snd) scored then Left "no remaining probability mass" else pure ()
  let winner pairs = case pairs of
        [] -> Left "empty choice"
        x : xs -> Right (fst (foldl (\best next -> if snd next > snd best then next else best) x xs))
  raw <- winner [(label, ps Map.! label) | label <- labels]
  weighted <- winner scored
  pure (if lookup raw scored == lookup weighted scored then raw else weighted)

validateMass :: [Double] -> Either Text ()
validateMass ps
  | any (\p -> not (finite p) || p < 0 || p > 1) ps = Left "probabilities must be finite and in [0,1]"
  | sum ps <= 0 = Left "no remaining probability mass"
  | otherwise = Right ()

decodeEvidence :: (FromJSON a) => FieldPath -> Value -> Either ShikumiError a
decodeEvidence path = first (SchemaMismatch . ((renderPath path <> ": ") <>) . T.pack) . parseEither parseJSON

-- Internal normalized decode values, supplied after local derivation. These
-- annotations are never accepted from a provider evidence object.
derivedAt :: (FromJSON a) => FieldPath -> Value -> a -> Either ShikumiError a
derivedAt path (Object o) fallback = maybe (Right fallback) (decodeEvidence path) (KM.lookup "x-shikumi-derived" o)
derivedAt _ _ fallback = Right fallback

instance FromModel (NoulWith t f) where
  fromModelP path v = do
    e@(NoulEvidence p) <- decodeEvidence path v
    let (answer, c) = deriveNoul 0.5 e
    (answer', c') <- derivedAt path v (answer, c)
    pure (Noul answer' p c')

instance (ChoiceOptions a) => FromModel (Choice a) where
  fromModelP path v = do
    e@(ChoiceEvidence ps c) <- decodeEvidence path v
    label <- first (SchemaMismatch . ((renderPath path <> ": ") <>)) (deriveChoice [n | (n, _, _) <- choiceOptions @a] Map.empty e)
    label' <- derivedAt path v label
    case [a | (n, a, _) <- choiceOptions @a, n == label'] of
      a : _ -> pure (Choice a ps c)
      [] -> Left (SchemaMismatch (renderPath path <> ": undeclared choice label"))

instance (KnownLevels ss, CheckLevels (Length ss)) => FromModel (Score ss) where
  fromModelP path v = do
    e@(ScoreEvidence ps c) <- decodeEvidence path v
    let n = length (levelNames (Proxy @ss))
    if V.length ps == n then pure () else Left (SchemaMismatch (renderPath path <> ": score level count does not match declaration"))
    (answer, l) <- first (SchemaMismatch . ((renderPath path <> ": ") <>)) (deriveScore [fromIntegral k + 0.5 | k <- [0 .. n - 2]] e)
    (answer', l') <- derivedAt path v (answer, l)
    pure (Score answer' l' ps c)

instance ToJSON (NoulWith t f) where toJSON (Noul _ p _) = toJSON (NoulEvidence p)

instance ToJSON (Choice a) where toJSON (Choice _ ps c) = toJSON (ChoiceEvidence ps c)

instance ToJSON (Score ss) where toJSON (Score _ _ ps c) = toJSON (ScoreEvidence ps c)

instance Validatable (NoulWith t f)

instance Validatable (Choice a)

instance Validatable (Score ss)

instance PromptValue (NoulWith t f) where
  promptValue (Noul v _ _) = if v then "true" else "false"
  promptValueJSON (Noul v _ _) = Bool v

instance (ChoiceOptions a) => PromptValue (Choice a) where
  promptValue (Choice a _ _) = fromMaybe "" (lookup a [(v, n) | (n, v, _) <- choiceOptions @a])
  promptValueJSON = String . promptValue

instance PromptValue (Score ss) where
  promptValue (Score _ l _ _) = T.pack (show l)
  promptValueJSON (Score _ l _ _) = toJSON l
