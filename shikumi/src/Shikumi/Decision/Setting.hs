-- | Pure per-field calibration settings and local derivation. These values never
-- enter provider requests or response-cache identity.
module Shikumi.Decision.Setting (DecisionSetting (..), defaultSetting, validateSetting, deriveField) where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, toJSON, withObject, (.:), (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.Bifunctor (first)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Decision (Judgment (..), JudgmentKind (..))
import Shikumi.Decision qualified as D
import Shikumi.Error (ShikumiError (..))

data DecisionSetting
  = NoulSetting {threshold :: !Double}
  | ScoreSetting {cuts :: ![Double]}
  | ChoiceSetting {weights :: !(Map Text Double)}
  deriving stock (Eq, Show, Generic)

instance ToJSON DecisionSetting where
  toJSON = \case
    NoulSetting t -> object ["kind" .= ("noul" :: Text), "threshold" .= t]
    ScoreSetting cs -> object ["kind" .= ("score" :: Text), "cuts" .= cs]
    ChoiceSetting ws -> object ["kind" .= ("choice" :: Text), "weights" .= ws]

instance FromJSON DecisionSetting where
  parseJSON = withObject "DecisionSetting" $ \o -> do
    kind <- o .: "kind" :: Parser Text
    case kind of
      "noul" -> NoulSetting <$> o .: "threshold"
      "score" -> ScoreSetting <$> o .: "cuts"
      "choice" -> ChoiceSetting <$> o .: "weights"
      _ -> fail "unknown decision setting kind"

defaultSetting :: Judgment -> DecisionSetting
defaultSetting j = case judgmentKind j of
  JudgeBoolean {} -> NoulSetting 0.5
  JudgeOrdered levels -> ScoreSetting [fromIntegral k + 0.5 | k <- [0 .. length levels - 2]]
  JudgeChoice {} -> ChoiceSetting Map.empty

-- | Validate against the declared domain. Omitted Choice weights stay absent
-- and mean 1; zero weights are valid and disable the corresponding label.
validateSetting :: Judgment -> DecisionSetting -> Either Text DecisionSetting
validateSetting j setting = case (judgmentKind j, setting) of
  (JudgeBoolean {}, NoulSetting t)
    | not (finite t) || t < 0 || t > 1 -> bad "threshold must be finite and in [0,1]"
    | otherwise -> Right setting
  (JudgeOrdered levels, ScoreSetting cs)
    | length cs /= length levels - 1 -> bad "cuts must have exactly N-1 entries"
    | any (\c -> not (finite c) || c <= 0 || c >= fromIntegral (length levels - 1)) cs -> bad "cuts must be finite and in (0,N-1)"
    | not (and (zipWith (<) cs (drop 1 cs))) -> bad "cuts must be strictly increasing"
    | otherwise -> Right setting
  (JudgeChoice options, ChoiceSetting ws)
    | any (`notElem` map fst options) (Map.keys ws) -> bad "weights must name declared labels"
    | any (\w -> not (finite w) || w < 0) (Map.elems ws) -> bad "weights must be finite and non-negative"
    | otherwise -> Right setting
  _ -> bad "setting kind does not match the decision field"
  where
    bad rule = Left (judgmentField j <> ": " <> rule)
    finite x = not (isNaN x || isInfinite x)

-- | Derive once, after validating settings and evidence. The private annotation
-- is consumed only by the rich FromModel leaves; it never enters request identity
-- or the public evidence codecs. Native fields receive an ordinary scalar.
deriveField :: Judgment -> Maybe DecisionSetting -> D.FieldEvidence -> Either ShikumiError Value
deriveField j stored ev = do
  setting <- first ValidationFailure (validateSetting j (fromMaybe (defaultSetting j) stored))
  case (judgmentKind j, setting, ev) of
    (JudgeBoolean {}, NoulSetting t, D.FieldNoul e@(D.NoulEvidence _)) ->
      let answer = D.deriveNoul t e in pure (annotate (toJSON answer) (toJSON e))
    (JudgeChoice labels, ChoiceSetting ws, D.FieldChoice e) -> do
      label <- first located (D.deriveChoice (map fst labels) ws e)
      pure (annotate (toJSON label) (toJSON e))
    (JudgeOrdered _, ScoreSetting cs, D.FieldScore e) -> do
      answer <- first located (D.deriveScore cs e)
      pure (annotate (toJSON answer) (toJSON e))
    _ -> Left (located "evidence kind does not match judgment")
  where
    located msg = SchemaMismatch (judgmentField j <> ": " <> msg)
    annotate result (Object o) = Object (KM.insert "x-shikumi-derived" result o)
    annotate _ v = v
