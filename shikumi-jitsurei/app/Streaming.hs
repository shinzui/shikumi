-- | (10) Program-level streaming: field chunks and status messages.
--
-- @streamProgram@ runs a program and hands a callback a sequence of 'StreamEvent's
-- as execution proceeds — field chunks (a piece of an output field as the model
-- writes it) and status messages (LM call started/finished, node boundaries) — and
-- /still returns the fully-decoded typed output/, identical to what @runProgram@
-- would return. The blocking contract is untouched; streaming is additive surface.
--
-- Offline, a stub streaming interpreter scripts the wire events @["Hel", "lo"]@
-- followed by a terminal structured reply. Running a single-@Predict@ program shows
-- the callback receive, in order: an @LmStart@ status, two field chunks, an @LmEnd@
-- status; and @streamProgram@ returns the typed @Answer "Hello"@.
module Main (main) where

import Baikai
  ( AssistantContent (..),
    AssistantMessageEvent (..),
    BlockEndPayload (..),
    DeltaPayload (..),
    IndexPayload (..),
    Message (AssistantMessage),
    Response,
    StartPayload (..),
    StopReason (..),
    TerminalPayload (..),
    doneTerminal,
    _Response,
    _TextContent,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..))
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Stream (StreamEvent, streamProgram)

-- A single-text-field signature — the honest field-chunk case.
newtype Question = Question {question :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype Answer = Answer {answer :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

qToAnswer :: Signature Question Answer
qToAnswer = mkSignature "Answer the question."

prog :: Program Question Answer
prog = predict qToAnswer

-- ---------------------------------------------------------------------------
-- A stub streaming LM: the deltas stream as text chunks; the terminal event
-- carries the whole structured reply the fallback adapter parses.
-- ---------------------------------------------------------------------------

answerEvents :: [AssistantMessageEvent]
answerEvents = streamEventsFor ["Hel", "lo"] markerBody
  where
    markerBody = T.intercalate "\n" ["[[ ## answer ## ]]", "Hello", "[[ ## completed ## ]]"]

streamEventsFor :: [Text] -> Text -> [AssistantMessageEvent]
streamEventsFor deltas terminalText =
  [ EventStart (StartPayload (AssistantMessage (_Response ^. #message))),
    TextStart (IndexPayload 0)
  ]
    ++ [TextDelta (DeltaPayload 0 d) | d <- deltas]
    ++ [ TextEnd (BlockEndPayload 0 (T.concat deltas)),
         EventDone (doneTerminal Stop (AssistantMessage (payloadWith terminalText)))
       ]
  where
    payloadWith t = (_Response ^. #message) & #content .~ V.singleton (AssistantText (_TextContent & #text .~ t))

terminalResponse :: [AssistantMessageEvent] -> Response
terminalResponse evs =
  case [p | EventDone TerminalPayload {message = AssistantMessage p} <- evs] of
    (p : _) -> _Response & #message .~ p
    [] -> _Response

runStreamingStub :: [AssistantMessageEvent] -> Eff (LLM : es) a -> Eff es a
runStreamingStub evs = interpret $ \_ -> \case
  Complete _ _ _ -> pure (terminalResponse evs)
  Stream _ _ _ -> pure evs

main :: IO ()
main = do
  putStrLn "jitsurei-streaming: field chunks + status, with the typed answer at the end\n"
  let cb :: (IOE :> es) => StreamEvent -> Eff es ()
      cb ev = liftIO (putStrLn ("  event: " <> show ev))
  out <-
    runEff . runErrorNoCallStack @ShikumiError . runStreamingStub answerEvents $
      streamProgram prog (Question "say hello") cb
  putStrLn $ "\nreturned (same value as runProgram) -> " <> show out
