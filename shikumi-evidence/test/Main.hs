-- | The shikumi-evidence suite. Each group is one of the deterministic tests the
-- production-evidence request demands; every group runs offline against stub
-- providers or checked-in recordings.
module Main (main) where

import ArtifactSpec qualified
import BindingSpec qualified
import BudgetSpec qualified
import ComparisonSpec qualified
import ConclusionSpec qualified
import DatasetDigestSpec qualified
import DriverGateSpec qualified
import HoldoutIsolationSpec qualified
import LabelSpec qualified
import ReplaySpec qualified
import SplitSpec qualified
import Test.Tasty (defaultMain, testGroup)
import Uc7Spec qualified

main :: IO ()
main =
  defaultMain $
    testGroup
      "shikumi-evidence"
      [ DatasetDigestSpec.tests,
        SplitSpec.tests,
        LabelSpec.tests,
        ArtifactSpec.tests,
        ConclusionSpec.tests,
        BindingSpec.tests,
        HoldoutIsolationSpec.tests,
        ComparisonSpec.tests,
        BudgetSpec.tests,
        ReplaySpec.tests,
        DriverGateSpec.tests,
        Uc7Spec.tests
      ]
