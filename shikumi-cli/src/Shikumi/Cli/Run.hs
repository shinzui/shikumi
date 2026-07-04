-- | The subcommand handlers. Each looks a task up by name, runs the corresponding
-- framework capability offline, and prints a deterministic, golden-testable result
-- (reusing EP-8's 'renderReportText' and EP-7's 'renderTree' rather than inventing
-- renderers).
module Shikumi.Cli.Run
  ( runEval,
    runTraceCmd,
    runOptimizeCmd,
    runReplayCmd,
    runRecordCmd,
    validTraceId,
    replayFailureMessage,
  )
where

import Control.Monad (when)
import Data.Aeson (ToJSON, encode)
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Text.IO qualified as TIO
import Shikumi.Cli.Options
  ( EvalOpts (..),
    GlobalOpts (..),
    OptimizeOpts (..),
    RecordOpts (..),
    ReplayOpts (..),
    TraceOpts (..),
  )
import Shikumi.Cli.Registry (Registry, Task (..), lookupTask, registryNames)
import Shikumi.Cli.Runtime (recordTrace, runReplayProgram, runStubEval, runStubProgram)
import Shikumi.Compile (encodeCompiled)
import Shikumi.Eval (evaluatePure, renderReportText)
import Shikumi.Optimize (optimize)
import Shikumi.Trace (TraceTree (..), renderTree)
import Shikumi.Trace.LiveExport (exportTreeLive)
import Shikumi.Trace.Store (readTraceFile, writeTraceFile)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((<.>), (</>))
import System.IO (hPutStrLn, stderr)

-- | @eval@: evaluate the named task's program over its dataset with its metric and
-- print the Report.
runEval :: Registry -> GlobalOpts -> EvalOpts -> IO ()
runEval reg _g (EvalOpts name) =
  withTask reg name $ \(Task prog ds metric _input responder _opts) -> do
    r <- runStubEval responder (evaluatePure ds metric prog)
    case r of
      Left e -> die ("evaluation failed: " <> tshow e)
      Right rep ->
        TIO.putStr ("Report for program \"" <> name <> "\":\n\n" <> renderReportText rep)

-- | @trace@: load a recorded trace by id (the program name) and render its tree.
runTraceCmd :: GlobalOpts -> TraceOpts -> IO ()
runTraceCmd g (TraceOpts tid) =
  withValidTraceId tid $ \ok -> do
    let path = traceFilePath g ok
    exists <- doesFileExist path
    if not exists
      then die ("No trace found with id: " <> ok <> " (looked for " <> T.pack path <> "; run `shikumi record --program " <> ok <> "` first)")
      else do
        e <- readTraceFile path
        case e of
          Left err -> die err
          Right tree -> do
            TIO.putStr ("Trace " <> ok <> "\n\n" <> renderTree tree)
            when (otel g) $ do
              exportTreeLive "shikumi" tree
              ep <- otlpEndpointForMessage
              TIO.putStrLn ("\nExported " <> tshow (Map.size (spans tree)) <> " spans via OTLP to " <> ep)

-- | @optimize@: run the named optimizer over the task and save the compiled program.
runOptimizeCmd :: Registry -> GlobalOpts -> OptimizeOpts -> IO ()
runOptimizeCmd reg _g (OptimizeOpts name optName out) =
  withTask reg name $ \(Task prog ds metric _input responder opts) ->
    case Map.lookup optName opts of
      Nothing ->
        die
          ( "Unknown optimizer: "
              <> optName
              <> "\nAvailable optimizers for \""
              <> name
              <> "\": "
              <> T.intercalate ", " (Map.keys opts)
          )
      Just opt -> do
        r <- runStubEval responder (optimize opt ds metric prog)
        case r of
          Left e -> die ("optimization failed: " <> tshow e)
          Right cp -> do
            BL.writeFile out (encodeCompiled cp)
            TIO.putStrLn
              ( "Saved compiled program to "
                  <> T.pack out
                  <> " (optimizer="
                  <> optName
                  <> ")"
              )

-- | @replay@: re-run the task's program purely from its recorded trace and confirm
-- the output is identical to a fresh stub run (the recorded run), with zero
-- provider calls.
runReplayCmd :: Registry -> GlobalOpts -> ReplayOpts -> IO ()
runReplayCmd reg g (ReplayOpts tid) =
  withValidTraceId tid $ \ok ->
    withTask reg ok $ \(Task prog _ds _metric input responder _opts) -> do
      let path = traceFilePath g ok
      exists <- doesFileExist path
      if not exists
        then die ("No trace found with id: " <> ok <> " (run `shikumi record --program " <> ok <> "` first)")
        else do
          loaded <- readTraceFile path
          case loaded of
            Left err -> die err
            Right tree -> do
              replayed <- runReplayProgram tree prog input
              reference <- runStubProgram responder prog input
              case (replayed, reference) of
                (Right ro, Right refo) -> do
                  TIO.putStrLn ("Replaying " <> ok <> " (program \"" <> ok <> "\")\n")
                  TIO.putStrLn ("Output:\n" <> encodeText ro)
                  if encode ro == encode refo
                    then TIO.putStrLn "\nreplay: output identical to recorded run, provider calls: 0"
                    else die "replay: output DIFFERS from recorded run"
                _ -> maybe (die "replay failed") die (replayFailureMessage replayed reference)

-- | @record@: capture a trace fixture offline (run the program under the stub LM)
-- and persist it under the store directory.
runRecordCmd :: Registry -> GlobalOpts -> RecordOpts -> IO ()
runRecordCmd reg g (RecordOpts name) =
  withValidTraceId name $ \ok ->
    withTask reg ok $ \(Task prog _ds _metric input responder _opts) -> do
      (res, tree) <- recordTrace responder ok prog input
      createDirectoryIfMissing True (storeDir g)
      let path = traceFilePath g ok
      writeTraceFile path tree
      case res of
        Left e -> die ("recorded trace, but the run errored: " <> tshow e)
        Right () -> TIO.putStrLn ("Recorded trace to " <> T.pack path)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Look a task up by name, or fail with a message listing the registered names.
withTask :: Registry -> Text -> (Task -> IO ()) -> IO ()
withTask reg name k = case lookupTask name reg of
  Just t -> k t
  Nothing ->
    die
      ( "Unknown program: "
          <> name
          <> "\nRegistered programs: "
          <> T.intercalate ", " (registryNames reg)
      )

-- | The on-disk path for a trace id under the store directory.
traceFilePath :: GlobalOpts -> Text -> FilePath
traceFilePath g tid = storeDir g </> T.unpack tid <.> "json"

-- | Reject trace ids that could escape the store directory when spliced into a
-- path. Trace ids double as program names, so this is a reject-list, not an
-- allow-list.
validTraceId :: Text -> Either Text Text
validTraceId tid
  | T.null tid = Left "trace id must not be empty"
  | tid == "." = Left "trace id must not be \".\""
  | "/" `T.isInfixOf` tid = Left "trace id must not contain path separators"
  | "\\" `T.isInfixOf` tid = Left "trace id must not contain path separators"
  | ".." `T.isInfixOf` tid = Left "trace id must not contain \"..\""
  | otherwise = Right tid

withValidTraceId :: Text -> (Text -> IO ()) -> IO ()
withValidTraceId tid k = case validTraceId tid of
  Left reason -> die ("Invalid trace id: " <> tid <> " (" <> reason <> ")")
  Right ok -> k ok

replayFailureMessage :: (Show a) => Either a o -> Either a o -> Maybe Text
replayFailureMessage (Left err) _ = Just ("replay failed: the replayed run errored: " <> tshow err)
replayFailureMessage _ (Left err) = Just ("replay failed: the reference (stub) run errored: " <> tshow err)
replayFailureMessage _ _ = Nothing

encodeText :: (ToJSON a) => a -> Text
encodeText = decodeUtf8 . BL.toStrict . encode

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | The OTLP endpoint to name in the export-summary line. Echoes the same standard
-- variable the OTLP exporter itself reads ('OTEL_EXPORTER_OTLP_ENDPOINT'); the
-- actual endpoint resolution lives in the exporter, this is purely cosmetic.
otlpEndpointForMessage :: IO Text
otlpEndpointForMessage =
  maybe "http://localhost:4318 (default)" T.pack <$> lookupEnv "OTEL_EXPORTER_OTLP_ENDPOINT"

-- | Print a message to stderr and exit non-zero.
die :: Text -> IO ()
die msg = hPutStrLn stderr (T.unpack msg) >> exitFailure
