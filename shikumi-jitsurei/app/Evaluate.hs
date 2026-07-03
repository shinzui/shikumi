-- | (5) Evaluate against a dataset with a typed metric.
--
-- @Dataset i o@, @Metric o@, and @Report@ are all typed by @i@/@o@. A failing
-- example scores zero rather than aborting the run, so the aggregate measures
-- robustness. Here the stub always answers "positive", so on a mixed dataset two
-- examples pass and two fail — a deterministic, believable report.
module Main (main) where

import Data.Text (Text)
import Data.Text.IO qualified as TIO
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Eval (Dataset, dataset, evaluatePure, exactMatch, example, renderReportText)
import Shikumi.Jitsurei.Stub (markerResponse, runStubEval)
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)

newtype Review = Review {reviewText :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype Label = Label {label :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

instance Validatable Label

classify :: Program Review Label
classify = predict (mkSignature "Classify the review sentiment as positive or negative." :: Signature Review Label)

reviews :: Dataset Review Label
reviews =
  dataset
    [ example (Review "Loved it, would buy again") (Label "positive"),
      example (Review "Total waste of money") (Label "negative"),
      example (Review "Exceeded my expectations") (Label "positive"),
      example (Review "Broke on day one") (Label "negative")
    ]

main :: IO ()
main = do
  putStrLn "jitsurei-evaluate: a typed metric over a dataset\n"
  result <-
    runStubEval
      (const (markerResponse [("label", "positive")]))
      (evaluatePure reviews exactMatch classify)
  case result of
    Left err -> putStrLn $ "evaluation failed: " <> show err
    Right report -> TIO.putStr (renderReportText report)
