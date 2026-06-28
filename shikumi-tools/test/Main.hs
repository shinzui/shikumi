-- | The @shikumi-tools@ test suite: typed tools, the ReAct loop, the protocol
-- seam, and the end-to-end acceptance — all network-free against a mock LM.
module Main (main) where

import AcceptanceSpec qualified
import BuiltinAcceptanceSpec qualified
import CodeActSpec qualified
import EnvSpec qualified
import FsSpec qualified
import ProgramOfThoughtSpec qualified
import ProtocolSpec qualified
import ReActSpec qualified
import RestrictedSpec qualified
import SchemaSpec qualified
import ShellSpec qualified
import Test.Tasty (defaultMain, testGroup)
import ToolSpec qualified
import WebSpec qualified

main :: IO ()
main =
  defaultMain $
    testGroup
      "shikumi-tools"
      [ SchemaSpec.tests,
        ToolSpec.tests,
        EnvSpec.tests,
        WebSpec.tests,
        FsSpec.tests,
        ShellSpec.tests,
        ReActSpec.tests,
        ProtocolSpec.tests,
        AcceptanceSpec.tests,
        BuiltinAcceptanceSpec.tests,
        RestrictedSpec.tests,
        ProgramOfThoughtSpec.tests,
        CodeActSpec.tests
      ]
