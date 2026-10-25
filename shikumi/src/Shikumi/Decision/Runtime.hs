-- | Extraction of provider-neutral probability evidence. Provider selections are
-- deliberately ignored; the typed decoder derives every answer locally.
module Shikumi.Decision.Runtime (evidenceOf, evidenceObject, decodeDecisionEvidence) where

import Baikai (AssistantContent (..), Response)
import Control.Lens ((^.))
import Data.Aeson (Result (..), Value (..), fromJSON)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Shikumi.Decision
import Shikumi.Decision.Setting (DecisionSetting, deriveField)
import Shikumi.Error (ShikumiError (..))

evidenceOf :: [Judgment] -> Response -> Maybe (Either ShikumiError (Map Text FieldEvidence))
evidenceOf js response = case [d | AssistantData d <- V.toList (response ^. #message . #content)] of
  [] -> Nothing
  [d] -> Just $ do
    ps <- maybe (Left (SchemaMismatch "decision response: missing probabilities")) Right (d ^. #probabilities)
    let cs = maybe Map.empty id (d ^. #confidence)
        get field key probs = maybe (Left (SchemaMismatch (field <> ": missing probability " <> key))) Right (Map.lookup key probs)
    Map.fromList
      <$> traverse
        ( \j -> do
            let name = judgmentField j
            probs <- maybe (Left (MissingField name)) Right (Map.lookup name ps)
            if all (\p -> not (isNaN p || isInfinite p) && p >= 0 && p <= 1) (Map.elems probs ++ maybe [] pure (Map.lookup name cs))
              then pure ()
              else Left (ValidationFailure (name <> ": probability/confidence must be finite and in [0,1]"))
            ev <- case judgmentKind j of
              JudgeBoolean {} -> FieldNoul . NoulEvidence <$> get name "true" probs
              JudgeChoice labels -> do
                if Map.keysSet probs == Map.keysSet (Map.fromList labels) then pure () else Left (SchemaMismatch (name <> ": probability keys differ from declared labels"))
                pure (FieldChoice (ChoiceEvidence probs (Map.lookup name cs)))
              JudgeOrdered levels -> do
                let keys = map (T.pack . show) [0 .. length levels - 1]
                if Map.keysSet probs == Map.keysSet (Map.fromList [(k, ()) | k <- keys]) then pure () else Left (SchemaMismatch (name <> ": probability keys differ from declared levels"))
                values <- traverse (\k -> get name k probs) keys
                pure (FieldScore (ScoreEvidence (V.fromList values) (Map.lookup name cs)))
            pure (name, ev)
        )
        js
  _ -> Just (Left (SchemaMismatch "decision response: expected one structured data block"))

-- | Rich fields decode evidence; native closed fields decode the derived scalar.
evidenceObject :: Value -> [Judgment] -> Map Text DecisionSetting -> Map Text FieldEvidence -> Either ShikumiError Value
evidenceObject schema js settings evidence = Object . KM.fromList <$> traverse field js
  where
    props = case schema of
      Object o | Just (Object p) <- KM.lookup "properties" o -> p
      _ -> KM.empty
    field j = do
      let name = judgmentField j
          rich = case KM.lookup (K.fromText name) props of Just (Object p) -> KM.member "x-shikumi-decision" p; _ -> False
      ev <- maybe (Left (MissingField name)) Right (Map.lookup name evidence)
      derived <- deriveField j (Map.lookup name settings) ev
      let native = case derived of
            Object o | Just result <- KM.lookup "x-shikumi-derived" o -> case judgmentKind j of
              JudgeBoolean {} -> case result of Array a -> maybe Null id (a V.!? 0); _ -> Null
              JudgeOrdered {} -> case result of Array a -> maybe Null id (a V.!? 1); _ -> Null
              JudgeChoice {} -> result
            _ -> derived
      pure (K.fromText name, if rich then derived else native)

-- | Strict generative evidence grammar. Shape errors and range violations keep
-- the field path. No provider-supplied derived-answer annotation is accepted.
decodeDecisionEvidence :: Judgment -> Value -> Either ShikumiError FieldEvidence
decodeDecisionEvidence j value = do
  fields <- case value of Object o -> Right o; _ -> shape "expected evidence object"
  let expected = case judgmentKind j of JudgeBoolean {} -> ["noul"]; _ -> ["confidence", "probabilities"]
  if sort (KM.keys fields) == sort expected then pure () else shape "missing or extra evidence keys"
  case judgmentKind j of
    JudgeBoolean {} -> FieldNoul . NoulEvidence <$> (get "noul" fields >>= number)
    kind -> do
      probs <- get "probabilities" fields >>= \case Object p -> Right p; _ -> shape "expected probabilities object"
      let keys = case kind of JudgeChoice ls -> map (K.fromText . fst) ls; JudgeOrdered ls -> map (K.fromText . T.pack . show) [0 .. length ls - 1]; _ -> []
      if sort (KM.keys probs) == sort keys then pure () else shape "missing or extra probability keys"
      ps <- traverse number probs
      confidence <- get "confidence" fields >>= number
      let mapping = Map.fromList [(K.toText key, p) | (key, p) <- KM.toList ps]
      case kind of
        JudgeChoice {} -> pure (FieldChoice (ChoiceEvidence mapping (Just confidence)))
        JudgeOrdered {} -> pure (FieldScore (ScoreEvidence (V.fromList [mapping Map.! K.toText key | key <- keys]) (Just confidence)))
        _ -> shape "unexpected judgment kind"
  where
    shape :: Text -> Either ShikumiError a
    shape msg = Left (SchemaMismatch (judgmentField j <> ": " <> msg))
    get key fields = maybe (shape ("missing " <> K.toText key)) Right (KM.lookup key fields)
    number (Number n) = case fromJSON (Number n) of
      Success p | not (isNaN p || isInfinite p) && p >= 0 && p <= (1 :: Double) -> Right p
      _ -> Left (ValidationFailure (judgmentField j <> ": probability/confidence must be finite and in [0,1]"))
    number _ = shape "expected numeric probability/confidence"
