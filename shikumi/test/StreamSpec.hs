{-# LANGUAGE OverloadedStrings #-}

-- | EP-25: program-level streaming. Verified entirely hermetically against a
-- scripted streaming 'LLM' interpreter (no network, no routing). The decisive
-- proof of fidelity: in M2/M3 the streamed return value is asserted equal to what
-- the blocking 'runProgram' produces for the same scripted events — so streaming is
-- an additive parallel path over the same decode, and 'runProgram'\'s contract is
-- untouched.
module StreamSpec (tests) where

import Baikai
  ( AssistantContent (..),
    AssistantMessageEvent (..),
    BlockEndPayload (..),
    DeltaPayload (..),
    IndexPayload (..),
    Message (..),
    Response,
    StartPayload (..),
    StopReason (..),
    TerminalPayload (..),
    doneTerminal,
    _Context,
    _Model,
    _Options,
    _Response,
    _TextContent,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack)
import GHC.Generics (Generic)
import ProgramFixtures (Draft (..), Topic (..), markerBody, outlineToDraft, topicToOutline, topicToVerdict)
import Shikumi.Adapter (ToPrompt, responseText)
import Shikumi.Combinator ((>>>))
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..))
import Shikumi.Module (predict)
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Stream
  ( FieldChunk (..),
    Status (..),
    StatusPhase (..),
    StreamEvent (..),
    streamComplete,
    streamProgram,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- A single-text-field signature, the honest field-chunk case.
newtype Question = Question {question :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Question

instance FromModel Question

instance ToPrompt Question

instance Validatable Question

newtype Answer = Answer {answer :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Answer

instance FromModel Answer

instance ToPrompt Answer

instance Validatable Answer

qToAnswer :: Signature Question Answer
qToAnswer = mkSignature "Answer the question"

-- ---------------------------------------------------------------------------
-- Scripted streaming LLM: one event-list per call. Stream returns it; Complete
-- derives a Response from its terminal event, so the SAME script drives both the
-- streamed and the blocking run (and the equality assertion is meaningful).
-- ---------------------------------------------------------------------------

runStreamingLLM :: (IOE :> es) => IORef [[AssistantMessageEvent]] -> Eff (LLM : es) a -> Eff es a
runStreamingLLM ref = interpret $ \_ -> \case
  Complete _ _ _ -> liftIO (terminalResponse <$> popEvents ref)
  Stream _ _ _ -> liftIO (popEvents ref)

popEvents :: IORef [[AssistantMessageEvent]] -> IO [AssistantMessageEvent]
popEvents ref = atomicModifyIORef' ref step
  where
    step (x : xs) = (xs, x)
    step [] = ([], [])

-- | A response carrying @t@ as its single assistant text block.
mkResponse :: Text -> Response
mkResponse t =
  _Response & #message . #content .~ V.singleton (AssistantText (_TextContent & #text .~ t))

-- | The 'Response' assembled from a stream's terminal event.
terminalResponse :: [AssistantMessageEvent] -> Response
terminalResponse evs =
  case [p | EventDone TerminalPayload {message = AssistantMessage p} <- evs] of
    (p : _) -> _Response & #message .~ p
    [] -> mkResponse ""

-- | A valid event sequence: @deltas@ stream as text chunks, and the terminal event
-- carries @terminalText@ as the fully-assembled message (the structured body the
-- fallback adapter parses). The two are decoupled here as a fake: the deltas model
-- the value streaming incrementally, the terminal carries the whole structured reply.
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

-- | A recording callback: append each event to the IORef in order.
recorder :: (IOE :> es) => IORef [StreamEvent] -> StreamEvent -> Eff es ()
recorder rec ev = liftIO (modifyIORef' rec (++ [ev]))

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "StreamSpec"
    [ testCase "M1: streamComplete folds deltas into field chunks and assembles the response" $ do
        ref <- newIORef [streamEventsFor ["Hel", "lo"] "Hello"]
        rec <- newIORef []
        resp <-
          runEff . runStreamingLLM ref $
            streamComplete "answer" _Model _Context _Options (recorder rec)
        evs <- readIORef rec
        evs
          @?= [ StreamFieldChunk (FieldChunk "answer" "Hel" False),
                StreamFieldChunk (FieldChunk "answer" "lo" True)
              ]
        responseText resp @?= "Hello",
      testCase "M2: streamProgram streams a single Predict's field, bracketed by LM status" $ do
        ref <- newIORef [streamEventsFor ["Hel", "lo"] (markerBody [("answer", "Hello")])]
        rec <- newIORef []
        out <-
          runEff . runErrorNoCallStack @ShikumiError . runStreamingLLM ref $
            streamProgram (predict qToAnswer) (Question "q?") (recorder rec)
        evs <- readIORef rec
        evs
          @?= [ StreamStatus (Status LmStart "LM call started"),
                StreamFieldChunk (FieldChunk "answer" "Hel" False),
                StreamFieldChunk (FieldChunk "answer" "lo" True),
                StreamStatus (Status LmEnd "LM call finished")
              ]
        out @?= Right (Answer "Hello"),
      testCase "M2: streamProgram returns the same value as runProgram" $ do
        let script = [streamEventsFor ["Hel", "lo"] (markerBody [("answer", "Hello")])]
        ref1 <- newIORef script
        streamed <-
          runEff . runErrorNoCallStack @ShikumiError . runStreamingLLM ref1 $
            streamProgram (predict qToAnswer) (Question "q?") (\_ -> pure ())
        ref2 <- newIORef script
        blocking <-
          runEff . runErrorNoCallStack @ShikumiError . runStreamingLLM ref2 $
            runProgram (predict qToAnswer) (Question "q?")
        streamed @?= blocking,
      testCase "EP-32: a failing Validatable rule surfaces through streamProgram" $ do
        ref <- newIORef [streamEventsFor ["99"] (markerBody [("score", "99")])]
        out <-
          runEff . runErrorNoCallStack @ShikumiError . runStreamingLLM ref $
            streamProgram (predict topicToVerdict) (Topic "haskell") (\_ -> pure ())
        out @?= Left (ValidationFailure "score: must be at most 10"),
      testCase "M3: a chain of predicts brackets each LM with status and streams both fields" $ do
        let script =
              [ streamEventsFor ["pts"] (markerBody [("points", "[\"intro\", \"body\", \"end\"]")]),
                streamEventsFor ["txt"] (markerBody [("prose", "A fine essay about the outline.")])
              ]
            chain :: Program Topic Draft
            chain = predict topicToOutline >>> predict outlineToDraft
        ref <- newIORef script
        rec <- newIORef []
        out <-
          runEff . runErrorNoCallStack @ShikumiError . runStreamingLLM ref $
            streamProgram chain (Topic "haskell") (recorder rec)
        evs <- readIORef rec
        evs
          @?= [ StreamStatus (Status NodeStart "node started"),
                StreamStatus (Status LmStart "LM call started"),
                StreamFieldChunk (FieldChunk "points" "pts" True),
                StreamStatus (Status LmEnd "LM call finished"),
                StreamStatus (Status LmStart "LM call started"),
                StreamFieldChunk (FieldChunk "prose" "txt" True),
                StreamStatus (Status LmEnd "LM call finished"),
                StreamStatus (Status NodeEnd "node finished")
              ]
        out @?= Right (Draft {prose = "A fine essay about the outline."})

        -- and the streamed value equals the blocking run for the same script
        ref2 <- newIORef script
        blocking <-
          runEff . runErrorNoCallStack @ShikumiError . runStreamingLLM ref2 $
            runProgram chain (Topic "haskell")
        Right (Draft {prose = "A fine essay about the outline."}) @?= blocking,
      testCase "M3: ToolStart/ToolEnd status events flow through the callback in order" $ do
        rec <- newIORef []
        runEff $ do
          let cb = recorder rec
          cb (StreamStatus (Status ToolStart "tool started"))
          cb (StreamStatus (Status ToolEnd "tool finished"))
        evs <- readIORef rec
        evs
          @?= [ StreamStatus (Status ToolStart "tool started"),
                StreamStatus (Status ToolEnd "tool finished")
              ]
    ]
