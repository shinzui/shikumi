-- | The shikumi evaluation framework — one import for the whole public surface
-- (MasterPlan integration point #5). Re-exports the owned data model
-- ('Shikumi.Eval.Types'), the metrics ('Shikumi.Eval.Metric'), the report
-- ('Shikumi.Eval.Report'), the 'evaluate' runner ('Shikumi.Eval.Evaluate'), and
-- golden testing ('Shikumi.Eval.Golden').
--
-- Worked example: measure a @Question -> Answer@ program over a small typed
-- dataset with the exact-match metric, then read the aggregate score. (The
-- @runProgram@/@evaluate@ effect stack is discharged under a mock or replayed LM
-- in tests; against a live provider it is the substrate's @LLM@ interpreter.)
--
-- @
-- import Shikumi.Eval
--
-- qaData :: 'Dataset' Question Answer
-- qaData = 'dataset'
--   [ 'example' (Question \"What is 2+2?\")     (Answer \"4\")
--   , 'example' (Question \"Capital of France?\") (Answer \"Paris\")
--   ]
--
-- -- inside an Eff stack with (LLM, Concurrent, Error ShikumiError, IOE):
-- run :: ('LLM' :> es, 'Concurrent' :> es, 'Error' 'ShikumiError' :> es, 'IOE' :> es)
--     => 'Program' Question Answer -> Eff es Double
-- run prog = do
--   report <- 'evaluatePure' qaData 'exactMatch' prog
--   pure ('aggregateScore' report)
-- @
--
-- The same snippet is exercised end-to-end under a mock in the test suite's
-- @Doc@ group, so it cannot rot.
module Shikumi.Eval
  ( module Shikumi.Eval.Types,
    module Shikumi.Eval.Metric,
    module Shikumi.Eval.Report,
    module Shikumi.Eval.Evaluate,
    module Shikumi.Eval.Golden,
  )
where

import Shikumi.Eval.Evaluate
import Shikumi.Eval.Golden
import Shikumi.Eval.Metric
import Shikumi.Eval.Report
import Shikumi.Eval.Types
