{-# LANGUAGE OverloadedStrings #-}

-- | A worked example of the OKF generator that doubles as the regenerate-and-diff
-- fixture. It builds a small two-program manifest — one typed @Predict@ program and
-- one opaque @Embed@ program (the shape an agent runtime such as shikigami produces)
-- — and writes the bundle to the directory given as the first argument (default
-- @./out@, i.e. @shikumi-okf/example/out@ when run from the package directory).
--
-- Run it with:
--
-- > cabal run shikumi-okf-example
--
-- then validate the result with the standalone @okf@ CLI (see the package docs and
-- EP-31). Because no timestamp is passed, regenerating an unchanged manifest yields
-- byte-identical output, so the committed @example/out@ tree can be regenerated and
-- diffed in CI.
module Main (main) where

import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Module (predict)
import Shikumi.Okf.Generate (writeProgramBundle)
import Shikumi.Okf.Types
  ( AppInfo (..),
    ProgramDoc (..),
    ProgramManifest (..),
    SomeProgram (..),
  )
import Shikumi.Program (Program, embed)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)
import System.Environment (getArgs)

-- A typed program's input/output records.
newtype Ticket = Ticket {ticket :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Ticket

instance FromModel Ticket

instance ToPrompt Ticket

instance Validatable Ticket

newtype Category = Category {category :: Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Category

instance FromModel Category

instance ToPrompt Category

instance Validatable Category

classifyProgram :: Program Ticket Category
classifyProgram = predict (mkSignature "Classify the support ticket." :: Signature Ticket Category)

-- An opaque embedded program: no inspectable internal structure.
heartbeatProgram :: Program () ()
heartbeatProgram = embed (\_ -> pure ())

manifest :: ProgramManifest
manifest =
  ProgramManifest
    [ ProgramDoc
        { name = "classify-ticket",
          title = Just "Classify Ticket",
          description = Just "Assigns a support ticket to a category.",
          tags = ["support", "classification"],
          declaredInputs = Nothing,
          declaredOutputs = Nothing,
          program = Just (SomeProgram classifyProgram)
        },
      ProgramDoc
        { name = "heartbeat",
          title = Just "Heartbeat",
          description = Just "Declared-agent heartbeat that emits a fixed digest.",
          tags = ["agent"],
          declaredInputs = Just "Trigger payload (ignored).",
          declaredOutputs = Just "A fixed heartbeat digest.",
          program = Just (SomeProgram heartbeatProgram)
        }
    ]

exampleApp :: AppInfo
exampleApp =
  AppInfo
    { appNamespace = "shinzui",
      appName = "example-app",
      appTitle = Just "Example Application",
      appDescription = Just "A worked example of shikumi-okf program documentation."
    }

main :: IO ()
main = do
  args <- getArgs
  let root = case args of
        (dir : _) -> dir
        [] -> "out"
  result <- writeProgramBundle root exampleApp Nothing manifest
  case result of
    Left err -> error ("bundle generation failed: " <> show err)
    Right () -> putStrLn ("Wrote OKF bundle to " <> root)
