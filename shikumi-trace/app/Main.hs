-- | The @shikumi-trace-demo@ executable (EP-7, M5). Delegates to the testable
-- core 'Shikumi.Trace.Demo.demoMain':
--
-- @
-- cabal run shikumi-trace-demo                       -- live: prints the tree, writes trace.json
-- SHIKUMI_OFFLINE=1 cabal run shikumi-trace-demo -- --replay trace.json
-- @
module Main (main) where

import Shikumi.Trace.Demo (demoMain)
import System.Environment (getArgs)

main :: IO ()
main = getArgs >>= demoMain
