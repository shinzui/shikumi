-- | Built-in web tools.
module Shikumi.Tool.Builtin.Web
  ( FetchReq (..),
    SearchReq (..),
    webFetchTool,
    webSearchTool,
  )
where

import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Tool (Tool, mkTool)
import Shikumi.Tool.Web (FetchResult, SearchResult, WebClient (..))

data FetchReq = FetchReq
  { url :: !Text,
    maxBytes :: !(Maybe Int)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

data SearchReq = SearchReq
  { query :: !Text,
    maxResults :: !(Maybe Int)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

webFetchTool :: WebClient -> Tool FetchReq FetchResult
webFetchTool client =
  mkTool "web_fetch" "Fetch the contents of a URL over HTTP." $ \req ->
    webFetch client (req ^. #url) (req ^. #maxBytes)

webSearchTool :: WebClient -> Tool SearchReq SearchResult
webSearchTool client =
  mkTool "web_search" "Search the web with the configured search provider." $ \req ->
    webSearch client (req ^. #query) (req ^. #maxResults)
