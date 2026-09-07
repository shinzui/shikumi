-- | Lossless local tool results and explicit provider/text projections.
module Shikumi.Tool.Output
  ( ToolOutput (..),
    textToolOutput,
    renderToolOutput,
    toolOutputMessage,
  )
where

import Baikai qualified as B
import Control.Lens ((%~), (&), (^.))
import Data.Aeson (Value, encode, toJSON)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Vector qualified as V

-- | Native content, optional structured data, and uninterpreted extension blocks.
-- Image preservation does not imply that a provider accepts image tool results.
data ToolOutput = ToolOutput
  { result :: !B.ToolResult,
    structuredContent :: !(Maybe Value),
    extensionBlocks :: ![Value]
  }
  deriving stock (Eq, Show)

textToolOutput :: Text -> ToolOutput
textToolOutput t = ToolOutput (B.toolResultText t) Nothing []

jsonText :: Value -> Text
jsonText = decodeUtf8 . LBS.toStrict . encode

extraText :: ToolOutput -> [Text]
extraText o =
  maybe [] (\v -> ["Structured JSON: " <> jsonText v]) (structuredContent o)
    <> map (("Extension JSON: " <>) . jsonText) (extensionBlocks o)

-- | Text projection preserves image bytes as labeled JSON rather than dropping them.
renderToolOutput :: ToolOutput -> Text
renderToolOutput o = T.intercalate "\n" (map render (V.toList (result o ^. #content)) <> extraText o)
  where
    render (B.ToolResultText (B.TextContent t)) = t
    render (B.ToolResultImage img) = "Image JSON: " <> jsonText (toJSON img)

-- | Preserve native blocks and append explicitly labeled JSON text blocks.
toolOutputMessage :: B.ToolCall -> ToolOutput -> B.Message
toolOutputMessage call o =
  B.toolResultFromCall
    call
    (result o & #content %~ (<> V.fromList (map (B.ToolResultText . B.TextContent) (extraText o))))
