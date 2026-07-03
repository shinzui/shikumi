-- | (3) Control flow as combinators.
--
-- Every combinator is a constructor of the same @Program@ GADT, so the result
-- stays a runnable, inspectable @Program i o@ — retries, validation, batching,
-- voting, and ensembling are all ordinary values you build up and run the same
-- way. @runProgram@ executes everything sequentially; the concurrency widths
-- (e.g. @mapP@'s) are honoured by @runProgramConc@.
module Main (main) where

import Baikai (Context, Response)
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Combinator (ensemble, majorityVote, mapP, retry, validateRetry)
import Shikumi.Jitsurei.Stub (markerResponse, runStub)
import Shikumi.Module (predict)
import Shikumi.Program (Program, TempSchedule (..))
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)

newtype Review = Review {reviewText :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype Label = Label {label :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

instance Validatable Label

classifySig :: Signature Review Label
classifySig = mkSignature "Classify the review sentiment as positive or negative."

classify :: Program Review Label
classify = predict classifySig

-- The stub always answers "positive".
positive :: Context -> Response
positive = const (markerResponse [("label", "positive")])

sample :: Review
sample = Review "Loved it, would buy again"

-- ---------------------------------------------------------------------------
-- Five combinators, each still a @Program@.
-- ---------------------------------------------------------------------------

-- Re-run on transient failure, up to 3 attempts.
robust :: Program Review Label
robust = retry 3 classify

-- Reject output that fails a predicate, and re-run (here: insist on "positive").
checked :: Program Review Label
checked = validateRetry 2 (\l -> label l == "positive") "label must be positive" classify

-- Self-consistency: sample 3 times, take the modal answer.
voted :: Program Review Label
voted = majorityVote 3 (TempFixed [0.0]) classify

-- Map over a list with bounded concurrency.
batch :: Program [Review] [Label]
batch = mapP 4 classify

-- Fan one input to several programs and fold the results (here: first answer).
panel :: Program Review Label
panel = ensemble [classify, classify, classify] firstOrUnknown
  where
    firstOrUnknown (x : _) = x
    firstOrUnknown [] = Label "unknown"

main :: IO ()
main = do
  putStrLn "jitsurei-combinators: control flow as composable programs\n"

  r1 <- runStub positive robust sample
  putStrLn $ "retry 3            -> " <> show r1

  r2 <- runStub positive checked sample
  putStrLn $ "validateRetry      -> " <> show r2

  r3 <- runStub positive voted sample
  putStrLn $ "majorityVote 3     -> " <> show r3

  r4 <- runStub positive batch [sample, Review "Total waste of money", Review "It was fine"]
  putStrLn $ "mapP 4 (a list)    -> " <> show r4

  r5 <- runStub positive panel sample
  putStrLn $ "ensemble of 3      -> " <> show r5
