-- | The parsed-command algebra for the @shikumi@ CLI and its
-- @optparse-applicative@ parser.
--
-- Note (deviation from the EP-12 sketch, recorded in the plan's Decision Log): a
-- registered entry bundles its program + dataset + metric + optimizers as one
-- typed unit (see "Shikumi.Cli.Registry"), so the subcommands take a single
-- @--program NAME@ rather than separate @--dataset@/@--metric@ flags. This keeps
-- name-based dispatch fully type-safe (no @Typeable@ reunification across
-- heterogeneous existentials).
module Shikumi.Cli.Options
  ( Command (..),
    GlobalOpts (..),
    EvalOpts (..),
    TraceOpts (..),
    OptimizeOpts (..),
    ReplayOpts (..),
    RecordOpts (..),
    parseCommand,
  )
where

import Data.Text (Text)
import Options.Applicative

-- | The top-level command, after parsing.
data Command
  = CmdEval EvalOpts
  | CmdTrace TraceOpts
  | CmdOptimize OptimizeOpts
  | CmdReplay ReplayOpts
  | -- | Generate a trace fixture offline (DX helper, not one of the four headline
    -- subcommands): runs the program under the stub LM and writes its trace.
    CmdRecord RecordOpts
  deriving stock (Eq, Show)

-- | Options shared by every subcommand.
data GlobalOpts = GlobalOpts
  { storeDir :: !FilePath,
    otel :: !Bool
  }
  deriving stock (Eq, Show)

newtype EvalOpts = EvalOpts {evalProgram :: Text}
  deriving stock (Eq, Show)

newtype TraceOpts = TraceOpts {traceTarget :: Text}
  deriving stock (Eq, Show)

data OptimizeOpts = OptimizeOpts
  { optProgram :: !Text,
    optOptimizer :: !Text,
    optOut :: !FilePath
  }
  deriving stock (Eq, Show)

newtype ReplayOpts = ReplayOpts {replayTarget :: Text}
  deriving stock (Eq, Show)

newtype RecordOpts = RecordOpts {recordProgram :: Text}
  deriving stock (Eq, Show)

-- | The complete parser: global options plus a subcommand.
parseCommand :: ParserInfo (GlobalOpts, Command)
parseCommand =
  info
    (((,) <$> globalP <*> commandP) <**> helper)
    ( fullDesc
        <> progDesc "Run, trace, optimize, and replay typed shikumi LM programs"
        <> header "shikumi — typed LM program CLI"
    )

globalP :: Parser GlobalOpts
globalP =
  GlobalOpts
    <$> strOption
      ( long "store-dir"
          <> metavar "DIR"
          <> value ".shikumi"
          <> showDefault
          <> help "Directory holding the trace store"
      )
    <*> switch
      ( long "otel"
          <> help "Export OpenTelemetry spans for this run"
      )

commandP :: Parser Command
commandP =
  hsubparser
    ( command "eval" (info (CmdEval <$> evalP) (progDesc "Evaluate a program over its dataset with its metric"))
        <> command "trace" (info (CmdTrace <$> traceP) (progDesc "Render the hierarchical trace tree for a recorded run"))
        <> command "optimize" (info (CmdOptimize <$> optimizeP) (progDesc "Optimize a program and save the compiled result"))
        <> command "replay" (info (CmdReplay <$> replayP) (progDesc "Deterministically replay a stored trace"))
        <> command "record" (info (CmdRecord <$> recordP) (progDesc "Record a trace fixture offline (DX helper)"))
    )

programOpt :: Parser Text
programOpt =
  strOption (long "program" <> metavar "NAME" <> help "Registered program name")

evalP :: Parser EvalOpts
evalP = EvalOpts <$> programOpt

optimizeP :: Parser OptimizeOpts
optimizeP =
  OptimizeOpts
    <$> programOpt
    <*> strOption (long "optimizer" <> metavar "NAME" <> help "Registered optimizer name")
    <*> strOption (long "out" <> metavar "FILE" <> help "Where to save the compiled program (.json)")

traceP :: Parser TraceOpts
traceP = TraceOpts <$> argument str (metavar "TRACE-ID" <> help "Trace id (the program name) to render")

replayP :: Parser ReplayOpts
replayP = ReplayOpts <$> argument str (metavar "TRACE-ID" <> help "Trace id (the program name) to replay")

recordP :: Parser RecordOpts
recordP = RecordOpts <$> programOpt
