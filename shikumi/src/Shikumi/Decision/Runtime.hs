-- | Extraction of provider-neutral probability evidence. Provider selections are
-- deliberately ignored; the typed decoder derives every answer locally.
module Shikumi.Decision.Runtime (evidenceOf, evidenceObject) where

import Baikai (AssistantContent (..), Response)
import Control.Lens ((^.))
import Data.Aeson (Value (..), toJSON)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Shikumi.Decision
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
evidenceObject :: Value -> [Judgment] -> Map Text FieldEvidence -> Either ShikumiError Value
evidenceObject schema js evidence = Object . KM.fromList <$> traverse field js
  where
    props = case schema of
      Object o | Just (Object p) <- KM.lookup "properties" o -> p
      _ -> KM.empty
    field j = do
      let name = judgmentField j
          rich = case KM.lookup (K.fromText name) props of Just (Object p) -> KM.member "x-shikumi-decision" p; _ -> False
      ev <- maybe (Left (MissingField name)) Right (Map.lookup name evidence)
      v <- if rich then pure (payload ev) else scalar j ev
      pure (K.fromText name, v)
    payload = \case FieldNoul e -> toJSON e; FieldChoice e -> toJSON e; FieldScore e -> toJSON e
    scalar j = \case
      FieldNoul e -> Right (Bool (fst (deriveNoul 0.5 e)))
      FieldChoice e -> either (Left . SchemaMismatch) (Right . String) (deriveChoice (case judgmentKind j of JudgeChoice ls -> map fst ls; _ -> []) Map.empty e)
      FieldScore e@(ScoreEvidence ps _) -> either (Left . SchemaMismatch) (Right . toJSON . snd) (deriveScore [fromIntegral k + 0.5 | k <- [0 .. V.length ps - 2]] e)
