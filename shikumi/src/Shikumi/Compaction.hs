-- | Helpers for shrinking an in-flight working context before it exceeds the
-- selected model's context window.
module Shikumi.Compaction
  ( CompactionConfig (..),
    defaultCompactionConfig,
    overflowThreshold,
    usageExceedsWindow,
    compactTail,
  )
where

import Baikai
  ( AssistantContent (..),
    Context,
    Model,
    Options,
    Response,
    TextContent (..),
    Usage,
    flattenAssistantBlocks,
    user,
    _Context,
    _Options,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, throwError)
import Numeric.Natural (Natural)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM, complete)

data CompactionConfig = CompactionConfig
  { reserveTokens :: !Natural,
    keepRecent :: !Int,
    enabled :: !Bool
  }
  deriving stock (Eq, Show)

defaultCompactionConfig :: CompactionConfig
defaultCompactionConfig =
  CompactionConfig
    { reserveTokens = 16384,
      keepRecent = 4,
      enabled = True
    }

-- | The token count at or above which a caller should compact. The subtraction
-- saturates so tiny fixture windows never underflow.
overflowThreshold :: CompactionConfig -> Model -> Natural
overflowThreshold cfg model =
  let window = model ^. #contextWindow
   in if window <= reserveTokens cfg then 0 else window - reserveTokens cfg

-- | Whether the provider-reported prompt usage has reached the compaction
-- threshold for this model.
usageExceedsWindow :: CompactionConfig -> Model -> Usage -> Bool
usageExceedsWindow cfg model usage =
  enabled cfg && (model ^. #contextWindow) > 0 && (usage ^. #inputTokens) >= overflowThreshold cfg model

-- | Fold the older portion of an oldest-first list into one synthesized summary
-- item, preserving the most recent 'keepRecent' items verbatim.
compactTail ::
  (LLM :> es, Error ShikumiError :> es) =>
  CompactionConfig ->
  Model ->
  (a -> Text) ->
  (Text -> a) ->
  [a] ->
  Eff es [a]
compactTail cfg model render inject xs
  | olderCount <= 0 = pure xs
  | otherwise = do
      requireErrorRow Nothing
      let (older, recent) = splitAt olderCount xs
          (ctx, opts) = summaryRequest (renderItems render older)
      resp <- complete model ctx opts
      pure (inject (responseText resp) : recent)
  where
    keep = max 0 (keepRecent cfg)
    olderCount = length xs - keep

-- The exported compaction primitive intentionally shares the ReAct loop's
-- @(LLM, Error ShikumiError)@ row even though the current summarize path only
-- throws through the @LLM@ interpreter. Keep the constraint visible and checked.
requireErrorRow :: (Error ShikumiError :> es) => Maybe ShikumiError -> Eff es ()
requireErrorRow Nothing = pure ()
requireErrorRow (Just e) = throwError e

summaryRequest :: Text -> (Context, Options)
summaryRequest rendered =
  ( _Context
      & #systemPrompt
        .~ Just
          ( T.unlines
              [ "Compact the earlier working context into a short, faithful summary.",
                "Preserve decisions, tool results, constraints, unresolved questions, and facts needed to continue.",
                "Do not invent new facts."
              ]
          )
      & #messages .~ V.singleton (user rendered),
    _Options
  )

renderItems :: (a -> Text) -> [a] -> Text
renderItems render xs =
  T.intercalate "\n\n" (zipWith one [1 :: Int ..] xs)
  where
    one n x = "Item " <> T.pack (show n) <> ":\n" <> render x

responseText :: Response -> Text
responseText resp =
  T.concat [t | AssistantText (TextContent t) <- V.toList (flattenAssistantBlocks resp)]
