{-# LANGUAGE GADTs #-}

-- | The data the OKF generator consumes: a manifest of an application's named
-- programs plus the application's own identity.
--
-- A shikumi @Program i o@ is a typed value with no name of its own, so the
-- generator cannot discover programs by itself. Instead an application supplies a
-- 'ProgramManifest': a list of 'ProgramDoc' entries, each naming a program and
-- carrying the human-authored metadata that documents it. The program itself is
-- held behind the constraint-free existential 'SomeProgram' — every function the
-- generator runs on it ('Shikumi.Program.programShape',
-- 'Shikumi.Program.nodeFieldsIndexed') is fully polymorphic in @i@/@o@, so no
-- class dictionaries are needed. That is what lets the manifest hold both a typed
-- @Predict@ pipeline and an opaque @Embed@-based @Program Value Value@ (the shape
-- downstream agent runtimes such as @shikigami@ produce) side by side.
module Shikumi.Okf.Types
  ( SomeProgram (..),
    ProgramDoc (..),
    ProgramManifest (..),
    AppInfo (..),
  )
where

import Data.Text (Text)
import Shikumi.Program (Program)

-- | A shikumi program with its input/output types hidden. The constructor places
-- no constraints on @i@/@o@ because the generator only ever inspects the program
-- structurally (constructor tree and per-node field names), never runs or
-- serializes it.
data SomeProgram where
  SomeProgram :: Program i o -> SomeProgram

-- | One documented program. 'name' is the concept-id leaf used in the bundle
-- (e.g. @"sentiment"@ becomes concept @programs/sentiment@), so it must be a valid
-- OKF concept-id segment (starts with @[A-Za-z0-9_]@; may then contain @[-._]@).
--
-- 'declaredInputs' and 'declaredOutputs' are free-text summaries the author
-- supplies. They carry the documentary weight for opaque programs: an @Embed@
-- agent has no inspectable internal structure, so without them its document would
-- describe almost nothing.
--
-- 'program' is optional. 'Just' wraps a program whose structure the renderer can
-- reflect; 'Nothing' documents a program from metadata alone — used when a source
-- (such as a @handan@ task with no eval handle) names a program it cannot hand
-- over as a value. A metadata-only doc still produces a valid concept; its
-- structure section says the structure is unavailable.
data ProgramDoc = ProgramDoc
  { name :: !Text,
    title :: !(Maybe Text),
    description :: !(Maybe Text),
    tags :: ![Text],
    declaredInputs :: !(Maybe Text),
    declaredOutputs :: !(Maybe Text),
    program :: !(Maybe SomeProgram)
  }

-- | An application's catalogue of documented programs, in the order they should
-- appear in the bundle.
newtype ProgramManifest = ProgramManifest
  { entries :: [ProgramDoc]
  }

-- | The owning application's identity. Used to build the @Shikumi App@ concept and
-- the @shikumi://\<namespace\>/\<app\>@ resource URIs that tie every program
-- concept back to its application.
data AppInfo = AppInfo
  { appNamespace :: !Text,
    appName :: !Text,
    appTitle :: !(Maybe Text),
    appDescription :: !(Maybe Text)
  }
