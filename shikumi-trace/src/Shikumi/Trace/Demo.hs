-- | The end-to-end demo (EP-7, M5): a two-stage pipeline that drafts a one-line
-- summary of a fixed article and then critiques the draft, tying together the
-- whole story — live trace → pretty-print → persist → deterministic offline
-- replay with identical output and zero provider calls.
--
-- The pipeline ('demoPipeline') is the shared core used by both the
-- @shikumi-trace-demo@ executable ('demoMain') and the @-p e2e@ acceptance test.
-- It is provider-agnostic: it issues 'Shikumi.LLM.complete' calls through the
-- @LLM@ effect and nests its stages in 'withSpan's, so the live run captures a
-- tree and the replay run is byte-identical.
--
-- For reproducibility the demo uses a deterministic in-process stub
-- ('demoResponder') rather than a real provider — no API keys, no network — so a
-- novice can run it anywhere and replay is well-defined. (The plan sketched an
-- optional live-provider path; the canned stub is the hermetic, always-runnable
-- choice. Replaying never contacts a provider regardless: 'runLLMReplay' has no
-- registry.)
module Shikumi.Trace.Demo
  ( demoArticle,
    demoModel,
    demoPipeline,
    demoResponder,
    runStubLLM,
    demoMain,
  )
where

import Baikai
  ( Api (Custom),
    AssistantContent (..),
    Context,
    Message (UserMessage),
    Model,
    Options,
    Response,
    TextContent (..),
    UserContent (UserText),
    user,
    _Context,
    _Model,
    _Options,
    _Response,
    _TextContent,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import Effectful (Eff, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Prim (runPrim)
import Shikumi.Effect.Time (runTime)
import Shikumi.LLM (LLM (..), complete)
import Shikumi.Trace
  ( SpanKind (ModuleSpan, ProgramSpan),
    Trace,
    renderTree,
    runTrace,
    tracedLLM,
    withSpan,
  )
import Shikumi.Trace.Replay (runLLMReplay)
import Shikumi.Trace.Store (readTraceFile, replayIndex, writeTraceFile)
import System.Environment (lookupEnv)

-- | The fixed input article the demo summarizes.
demoArticle :: Text
demoArticle = "Shikumi turns LM calls into typed, traceable, replayable programs."

-- | The demo model's routing identity (LM-call spans read @stub/stub-model@).
demoModel :: Model
demoModel =
  _Model
    & #provider .~ "stub"
    & #modelId .~ "stub-model"
    & #api .~ Custom "stub"

-- | The two-stage pipeline: draft a one-line summary, then critique the draft.
-- Stage two's request depends on stage one's output, so replay must reproduce
-- stage one exactly to reach stage two. Returns the critique.
demoPipeline :: (Trace :> es, LLM :> es) => Text -> Eff es Text
demoPipeline article =
  withSpan ProgramSpan "summarize-and-critique" $ do
    draft <-
      withSpan ModuleSpan "predict:Draft" $
        textOf <$> complete demoModel (ctxFor ("draft: " <> article)) opts
    withSpan ModuleSpan "predict:Critique" $
      textOf <$> complete demoModel (ctxFor ("critique: " <> draft)) opts

-- | The deterministic stub: a draft request yields a fixed summary; a critique
-- request returns a fixed verdict. Deterministic per request, so replay is
-- well-defined.
demoResponder :: Context -> Response
demoResponder c =
  if "draft:" `T.isPrefixOf` lastUserText c
    then mkResponse "Shikumi makes LM programs typed and replayable."
    else mkResponse "Accurate and concise; ship it."

-- | A base @LLM@ interpreter driving the demo from 'demoResponder'.
runStubLLM :: Eff (LLM : es) a -> Eff es a
runStubLLM = interpret $ \_ -> \case
  Complete _ c _ -> pure (demoResponder c)
  Stream {} -> pure []

-- ---------------------------------------------------------------------------
-- Executable entry point
-- ---------------------------------------------------------------------------

-- | The demo's command-line core. With no arguments it runs the pipeline live,
-- prints the trace tree and the final critique, and writes @trace.json@. With
-- @--replay PATH@ it loads the trace, replays the pipeline offline, and prints
-- the same critique plus @provider calls: 0@.
demoMain :: [String] -> IO ()
demoMain args = case args of
  [] -> liveMode
  ["--replay", path] -> replayMode path
  _ -> TIO.putStrLn "usage: shikumi-trace-demo [--replay PATH]"

liveMode :: IO ()
liveMode = do
  (critique, tree) <-
    runEff . runPrim . runTime . runTrace . runStubLLM . tracedLLM $ demoPipeline demoArticle
  TIO.putStr (renderTree tree)
  writeTraceFile "trace.json" tree
  TIO.putStrLn ("FINAL: " <> critique)

replayMode :: FilePath -> IO ()
replayMode path = do
  _ <- lookupEnv "SHIKUMI_OFFLINE" -- offline is structural: replay contacts no provider
  loaded <- readTraceFile path
  case loaded of
    Left err -> TIO.putStrLn ("trace load error: " <> err)
    Right tree -> do
      case replayIndex tree of
        Left err -> TIO.putStrLn ("replay index error: " <> err)
        Right idx -> do
          (critique, _) <- runEff . runPrim . runTime . runTrace . runLLMReplay idx $ demoPipeline demoArticle
          TIO.putStrLn ("FINAL: " <> critique)
          TIO.putStrLn "provider calls: 0"

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

opts :: Options
opts = _Options

ctxFor :: Text -> Context
ctxFor t = _Context & #messages .~ V.singleton (user t)

mkResponse :: Text -> Response
mkResponse t =
  _Response
    & #message . #content .~ V.singleton (AssistantText (_TextContent & #text .~ t))
    & #message . #usage . #inputTokens .~ 24
    & #message . #usage . #outputTokens .~ 9
    & #latencyMs .~ 7

textOf :: Response -> Text
textOf resp =
  mconcat [t | AssistantText (TextContent t) <- V.toList (resp ^. #message . #content)]

lastUserText :: Context -> Text
lastUserText c =
  mconcat
    [ t
    | UserMessage up <- V.toList (c ^. #messages),
      UserText (TextContent t) <- V.toList (up ^. #content)
    ]
