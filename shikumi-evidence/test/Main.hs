-- | The shikumi-evidence suite. Each group is one of the deterministic tests the
-- production-evidence request demands; every group runs offline against stub
-- providers or checked-in recordings.
module Main (main) where

import ArtifactSpec qualified
import BindingSpec qualified
import ConclusionSpec qualified
import DatasetDigestSpec qualified
import LabelSpec qualified
import SplitSpec qualified
import Test.Tasty (defaultMain, testGroup)

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
        BindingSpec.tests
      ]
