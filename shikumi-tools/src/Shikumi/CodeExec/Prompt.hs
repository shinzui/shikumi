-- | Small prompt/parse helpers shared by the code-execution modules
-- ('Shikumi.CodeExec.ProgramOfThought', 'Shikumi.CodeExec.CodeAct'). These mirror
-- the equivalents in 'Shikumi.Agent.ReAct' (which keeps its own copies private);
-- they are factored here to avoid duplicating the few small helpers across the two
-- code-execution modules (EP-27).
module Shikumi.CodeExec.Prompt
  ( simpleContext,
    stripFences,
    schemaInstruction,
    encodeText,
  )
where

import Baikai (Context, Options, user, _Context, _Options)
import Control.Lens ((&), (.~))
import Data.Aeson (Value, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Vector qualified as V

-- | A request context with a system prompt and a single user message, default
-- options. The neutral one-turn shape both code-execution loops use per model call.
simpleContext :: Text -> Text -> (Context, Options)
simpleContext sys userMsg =
  ( _Context & #systemPrompt .~ Just sys & #messages .~ V.singleton (user userMsg),
    _Options
  )

-- | Strip a leading/trailing Markdown code fence (@```@ / @```json … ```@), if any,
-- so a fenced reply still decodes. Falls back to the trimmed input. (Same logic as
-- 'Shikumi.Agent.ReAct'\'s private @stripFences@.)
stripFences :: Text -> Text
stripFences t =
  let trimmed = T.strip t
   in case T.stripPrefix "```" trimmed of
        Nothing -> trimmed
        Just rest -> T.strip (dropClosingFence (dropFirstLine rest))
  where
    dropFirstLine s = T.drop 1 (T.dropWhile (/= '\n') s)
    dropClosingFence s = fst (T.breakOn "```" s)

-- | An extraction instruction: ask for one JSON object matching the given schema.
schemaInstruction :: Value -> Text
schemaInstruction schema =
  "Produce the final answer as exactly one JSON object matching this schema, and nothing else:\n"
    <> encodeText schema

-- | Compact-encode a JSON value to text.
encodeText :: Value -> Text
encodeText = decodeUtf8 . LBS.toStrict . encode
