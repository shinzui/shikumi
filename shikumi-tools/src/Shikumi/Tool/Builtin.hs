-- | Built-in work-tool catalog.
module Shikumi.Tool.Builtin
  ( builtinFsTools,
    builtinWebTools,
    builtinTools,
    builtinRegistry,
    module Shikumi.Tool.Builtin.Fs,
    module Shikumi.Tool.Builtin.Shell,
    module Shikumi.Tool.Builtin.Web,
  )
where

import Shikumi.Tool (SomeTool (..), ToolRegistry, mkRegistry)
import Shikumi.Tool.Builtin.Fs
import Shikumi.Tool.Builtin.Shell
import Shikumi.Tool.Builtin.Web
import Shikumi.Tool.Env (ToolEnv)
import Shikumi.Tool.Web (WebClient)

builtinFsTools :: ToolEnv -> [SomeTool]
builtinFsTools env =
  [ SomeTool (readTool env),
    SomeTool (writeTool env),
    SomeTool (editTool env),
    SomeTool (grepTool env),
    SomeTool (bashTool env),
    SomeTool (globTool env)
  ]

builtinWebTools :: WebClient -> [SomeTool]
builtinWebTools client =
  [ SomeTool (webFetchTool client),
    SomeTool (webSearchTool client)
  ]

builtinTools :: ToolEnv -> WebClient -> [SomeTool]
builtinTools env client = builtinFsTools env <> builtinWebTools client

builtinRegistry :: ToolEnv -> WebClient -> ToolRegistry
builtinRegistry env client = mkRegistry (builtinTools env client)
