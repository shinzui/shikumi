-- | (6) Optimize against data, then serialize and reload the result.
--
-- An optimizer searches for better few-shot demos (and instructions), driven by
-- evaluation against a metric, and returns a @CompiledProgram@ — the structural
-- template plus a tuned parameter vector. Because the program is a GADT the
-- optimizer rewrites as data, that parameter vector serializes on its own:
-- 'encodeCompiled' saves it and 'decodeCompiledOnto' loads it back onto the
-- template. Everything below runs offline against the deterministic stub.
module Main (main) where

import Data.Aeson (ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Compile (decodeCompiledOnto, encodeCompiled)
import Shikumi.Eval (Dataset, dataset, exactMatch, example)
import Shikumi.Jitsurei.Stub (markerResponse, runStubEval)
import Shikumi.Module (predict)
import Shikumi.Optimize (labeledFewShot, optimize)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema)
import Shikumi.Signature (Signature, mkSignature)

newtype Review = Review {reviewText :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt, ToJSON)

newtype Label = Label {label :: Text}
  deriving stock (Generic, Show, Eq, Ord)
  deriving anyclass (ToSchema, FromModel, ToPrompt, ToJSON)

classify :: Program Review Label
classify = predict (mkSignature "Classify the review sentiment as positive or negative." :: Signature Review Label)

trainset :: Dataset Review Label
trainset =
  dataset
    [ example (Review "Loved it, would buy again") (Label "positive"),
      example (Review "Total waste of money") (Label "negative"),
      example (Review "Exceeded my expectations") (Label "positive"),
      example (Review "Broke on day one") (Label "negative")
    ]

main :: IO ()
main = do
  putStrLn "jitsurei-optimize: search for demos, then save and reload them\n"
  result <-
    runStubEval
      (const (markerResponse [("label", "positive")]))
      (optimize (labeledFewShot 2) trainset exactMatch classify)
  case result of
    Left err -> putStrLn $ "optimization failed: " <> show err
    Right compiled -> do
      putStrLn "optimized a CompiledProgram (template + tuned demos)."
      -- The tuned parameter vector round-trips through JSON on its own...
      let bytes = encodeCompiled compiled
      case decodeCompiledOnto classify bytes of
        Left err -> putStrLn $ "reload failed: " <> err
        Right _ -> putStrLn "...serialized and reloaded onto the structural template. OK"
