{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

module RLMExample (main, example) where

import Baikai qualified as B
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.CodeExec.RLM
import Shikumi.CodeExec.Session
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..))
import Shikumi.Program (runProgram)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)

newtype Question = Question {question :: Text}
  deriving stock (Generic)
  deriving anyclass (ToPrompt)

newtype Answer = Answer {answer :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

instance Validatable Answer

signature :: Signature Question Answer
signature = mkSignature "Inspect the source and answer the question."

example :: IO (Either ShikumiError (Text, Int))
example = do
  replies <-
    newIORef
      [ "{\"op\":\"slice\",\"name\":\"source\",\"start\":0,\"count\":12}",
        "{\"op\":\"query\",\"prompt\":\"What color is named in: Color: amber?\"}",
        "amber",
        "{\"op\":\"submit\",\"value\":{\"answer\":\"amber\"}}"
      ]
  runEff
    . runErrorNoCallStack
    . interpret
      ( \_ -> \case
          Complete {} -> do
            next <-
              liftIO
                ( atomicModifyIORef'
                    replies
                    ( \case
                        [] -> ([], Nothing)
                        x : xs -> (xs, Just x)
                    )
                )
            case next of
              Nothing -> throwError (ProviderFailure "Unexpected extra model call")
              Just text -> pure (B.emptyResponse & #message . #content .~ V.singleton (B.AssistantText (B.emptyTextContent & #text .~ text)))
          Stream {} -> throwError (ProviderFailure "Unexpected streaming call")
      )
    $ do
      -- Only the question is ToPrompt input. The source remains outside it.
      source <-
        either
          (\(SessionError e) -> throwError (ValidationFailure e))
          pure
          (contextStore [("source", "Color: amber")])
      (outcome, report) <-
        runProgram
          (rlmWithReport defaultRLMConfig source signature)
          (Question "Which color is named?")
      case outcome of
        RLMSubmitted (Answer text) -> pure (text, subqueriesAttempted report)
        RLMExhausted limit ->
          throwError
            ( BudgetExceeded
                ( "Session exhausted: " <> case limit of
                    Subqueries -> "subqueries"
                    _ -> "another configured allowance"
                )
            )

main :: IO ()
main = example >>= print
