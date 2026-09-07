{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Offline example compiled and executed by the shikumi-tools test suite.
module ReActSessionExample (main, example) where

import Baikai qualified as B
import Control.Lens ((&), (.~))
import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.Generics.Labels ()
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (liftIO, runEff)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Agent.History (decodeSession, encodeSession, sessionTurns)
import Shikumi.Agent.ReAct
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..))
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Tool (mkDynTool, mkRegistry)
import Shikumi.Tool.Output (textToolOutput)

newtype Question = Question {question :: Text}
  deriving stock (Generic)
  deriving anyclass (ToPrompt)

newtype Answer = Answer {answer :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

instance Validatable Answer

signature :: Signature Question Answer
signature = mkSignature "Use the lookup tool and answer the question."

-- | Returns the typed answer and cumulative assistant exchange count.
example :: IO (Either ShikumiError (Text, Int))
example = do
  let registry = mkRegistry [mkDynTool "lookup" "Return the stored city." (object []) (\_ -> pure (Right (textToolOutput "Paris")))]
      cfg = defaultReActConfig {protocol = ProtocolNative}
      response callId name args = B.emptyResponse & #message . #content .~ V.singleton (B.AssistantToolCall (B.ToolCall callId name args))
      script = [response "call-A" "lookup" (object []), response "final-A" finalToolName (object ["answer" .= ("Paris, France" :: Text)])]
  replies <- newIORef script
  runEff
    . runErrorNoCallStack
    . interpret
      ( \_ -> \case
          Complete {} -> do
            next <-
              liftIO
                ( atomicModifyIORef'
                    replies
                    ( \xs -> case xs of
                        [] -> ([], Nothing)
                        x : rest -> (rest, Just x)
                    )
                )
            maybe (throwError (ProviderFailure "Unexpected extra model call")) pure next
          Stream {} -> pure []
      )
    $ do
      initial <- startSession signature registry cfg (Question "Which city is stored?")
      first <- advanceSession signature registry cfg initial
      checkpoint <- case first of
        SessionPaused s -> pure s
        _ -> throwError (ValidationFailure "Expected a checkpoint")
      -- Write these bytes to caller-owned storage if persistence is needed.
      let bytes = encode (encodeSession checkpoint)
          decoded = eitherDecode bytes >>= either (Left . show) Right . decodeSession
      saved <- either (throwError . ValidationFailure . T.pack) pure decoded
      resumed <- continueSession signature registry cfg (Question "Include the country too.") saved
      finished <- runSession signature registry cfg resumed
      case finished of
        SessionFinished (Answer text) s -> pure (text, sessionTurns s)
        SessionPaused _ -> throwError (ValidationFailure "Iteration budget exhausted")

main :: IO ()
main = example >>= print
