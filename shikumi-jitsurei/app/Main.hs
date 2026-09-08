module Main (main) where

main :: IO ()
main = do
  putStrLn "shikumi-jitsurei (実例): runnable worked examples for shikumi.\n"
  putStrLn "Every example defaults to an offline stub or loopback fixture"
  putStrLn "(no API key or public provider call). Run one with: cabal run <name>\n"
  putStrLn "Available examples:"
  putStrLn "  jitsurei-predict        Records in, records out; typed errors and validation"
  putStrLn "  jitsurei-compose        Compose typed programs with (>>>)"
  putStrLn "  jitsurei-combinators    retry / validate / mapP / majorityVote / ensemble"
  putStrLn "  jitsurei-evaluate       A typed metric over a dataset -> a Report"
  putStrLn "  jitsurei-optimize       Optimize demos, then serialize and reload them"
  putStrLn "  jitsurei-structure-search Finite typed structure selection and restoration"
  putStrLn "  jitsurei-gepa-objectives Validation-selected GEPA with quality/cost reports"
  putStrLn "  jitsurei-react          A typed tool and a ReAct agent loop"
  putStrLn "  jitsurei-trace-replay   Caching, hierarchical tracing, deterministic replay"
  putStrLn "  jitsurei-multimodal     An image input field the model actually sees"
  putStrLn "  jitsurei-streaming      Program-level streaming: field chunks + status"
  putStrLn "  jitsurei-adapters       XML adapter, two-step extraction, field constraints"
  putStrLn "  jitsurei-codeexec       programOfThought / codeAct over a hermetic sandbox"
  putStrLn "  jitsurei-request-defaults Shared request settings, caching and evidence bypass"
  putStrLn "  jitsurei-responses      Real Responses adapter, reasoning resume and billing"
