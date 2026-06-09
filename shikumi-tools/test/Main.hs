-- | The @shikumi-tools@ test suite: typed tools, the ReAct loop, the protocol
-- seam, and the end-to-end acceptance — all network-free against a mock LM.
module Main (main) where

import AcceptanceSpec qualified
import ProtocolSpec qualified
import ReActSpec qualified
import SchemaSpec qualified
import Test.Tasty (defaultMain, testGroup)
import ToolSpec qualified

main :: IO ()
main =
  defaultMain $
    testGroup
      "shikumi-tools"
      [ SchemaSpec.tests,
        ToolSpec.tests,
        ReActSpec.tests,
        ProtocolSpec.tests,
        AcceptanceSpec.tests
      ]
