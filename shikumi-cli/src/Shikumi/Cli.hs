-- | The shikumi CLI entry point: parse the command line and dispatch to a handler,
-- driving everything from a caller-supplied 'Registry' of typed tasks.
--
-- A user wires the CLI around their own programs by calling @cliMain myRegistry@
-- from a tiny @main@; the bundled @shikumi@ executable is exactly
-- @cliMain exampleRegistry@ (see "Shikumi.Cli.Example").
module Shikumi.Cli
  ( cliMain,
    dispatch,
    module Shikumi.Cli.Options,
    module Shikumi.Cli.Registry,
  )
where

import Options.Applicative (customExecParser, prefs, showHelpOnEmpty)
import Shikumi.Cli.Options
import Shikumi.Cli.Registry
import Shikumi.Cli.Run
  ( runEval,
    runOptimizeCmd,
    runRecordCmd,
    runReplayCmd,
    runTraceCmd,
  )

-- | Parse @argv@ and run the selected subcommand against the given registry.
cliMain :: Registry -> IO ()
cliMain reg = do
  (gopts, cmd) <- customExecParser (prefs showHelpOnEmpty) parseCommand
  dispatch reg gopts cmd

-- | Dispatch a parsed command to its handler.
dispatch :: Registry -> GlobalOpts -> Command -> IO ()
dispatch reg gopts = \case
  CmdEval o -> runEval reg gopts o
  CmdTrace o -> runTraceCmd gopts o
  CmdOptimize o -> runOptimizeCmd reg gopts o
  CmdReplay o -> runReplayCmd reg gopts o
  CmdRecord o -> runRecordCmd reg gopts o
