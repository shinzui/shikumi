-- | The bundled @shikumi@ executable: the CLI wired around the example registry.
-- A user building the CLI for their own programs writes this same one-liner around
-- their own registry.
module Main (main) where

import Shikumi.Cli (cliMain)
import Shikumi.Cli.Example (exampleRegistry)

main :: IO ()
main = cliMain exampleRegistry
