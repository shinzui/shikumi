-- | Repository references: opaque, validated pointers to the exact source a
-- program or measure came from.
--
-- A RepoRef is the pair of a repository id and a full 40-character commit id,
-- never a branch or tag name. Shikumi stores it as data and resolves nothing.
module Shikumi.Evidence.Source
  ( SourceRef (..),
    validateSourceRef,
    requiredSourceRoles,
    missingSourceRoles,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Char (isDigit, isHexDigit, isLower)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

-- | One RepoRef with the role it plays, such as @shikumi@ or
-- @program-template@.
data SourceRef = SourceRef
  { role :: !Text,
    repoId :: !Text,
    revision :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A RepoRef needs a role, a repository id and a full lowercase commit id.
validateSourceRef :: SourceRef -> Either Text ()
validateSourceRef ref
  | T.null (ref.role) = Left "source reference has an empty role"
  | T.null (ref.repoId) = Left ("source reference " <> ref.role <> " has an empty repository id")
  | T.length (ref.revision) /= 40 || not (T.all (\c -> isHexDigit c && (isDigit c || isLower c)) (ref.revision)) =
      Left ("source reference " <> ref.role <> " revision is not a full 40-character commit id: " <> ref.revision)
  | otherwise = Right ()

-- | The roles every evidence job must name: the Shikumi revision that ran it and
-- the revision of the program template (which also identifies custom measures).
requiredSourceRoles :: [Text]
requiredSourceRoles = ["shikumi", "program-template"]

-- | Required roles absent from a list of references.
missingSourceRoles :: [SourceRef] -> [Text]
missingSourceRoles refs = [r | r <- requiredSourceRoles, r `notElem` map (.role) refs]
