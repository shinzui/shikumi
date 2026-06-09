module Main (main) where

main :: IO ()
main = do
  putStrLn "shikumi-jitsurei (実例): runnable worked examples for shikumi.\n"
  putStrLn "Every example runs fully offline against a deterministic stub LM"
  putStrLn "(no API key, no network). Run one with: cabal run <name>\n"
  putStrLn "Available examples:"
  putStrLn "  jitsurei-predict        Records in, records out; typed errors and validation"
  putStrLn "  jitsurei-compose        Compose typed programs with (>>>)"
  putStrLn "  jitsurei-combinators    retry / validate / mapP / majorityVote / ensemble"
  putStrLn "  jitsurei-evaluate       A typed metric over a dataset -> a Report"
  putStrLn "  jitsurei-optimize       Optimize demos, then serialize and reload them"
  putStrLn "  jitsurei-react          A typed tool and a ReAct agent loop"
  putStrLn "  jitsurei-trace-replay   Caching, hierarchical tracing, deterministic replay"
