-- | Versioned, completed-exchange checkpoints. Registries and closures stay caller-owned.
module Shikumi.Agent.History
  ( ReActSession,
    HistoryError (..),
    HistoryEntry (..),
    newSession,
    sessionProtocol,
    sessionFingerprint,
    sessionTools,
    sessionTurns,
    sessionIterations,
    sessionFinished,
    sessionCompactedThrough,
    auditHistory,
    promptEntries,
    promptMessages,
    entryMessages,
    appendUser,
    appendExchange,
    validateCalls,
    validateSession,
    compactSession,
    encodeSession,
    decodeSession,
  )
where

import Baikai qualified as B
import Baikai.Cost qualified as BC
import Control.Lens ((&), (.~), (^.))
import Control.Monad (foldM, unless, when)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import Data.Generics.Labels ()
import Data.Ratio (denominator, numerator, (%))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Vector qualified as V
import Shikumi.Tool.Output

newtype HistoryError = HistoryError Text deriving stock (Eq, Show)

-- | Rejected responses are audit-only; their correction replaces them in requests.
-- Accepted exchanges contain the original assistant payload and ordered results.
data HistoryEntry
  = UserTurn !B.UserPayload
  | Exchange !B.AssistantPayload ![(B.ToolCall, ToolOutput)] !(Maybe Text)
  deriving stock (Eq, Show)

data ReActSession = ReActSession
  { sessionProtocol :: !Text,
    sessionFingerprint :: !Value,
    sessionTools :: !Value,
    sessionTurns :: !Int,
    sessionIterations :: !Int,
    sessionFinished :: !Bool,
    auditHistory :: ![HistoryEntry],
    compactedThrough :: !Int,
    summary :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

newSession :: Text -> Value -> Value -> Text -> Either HistoryError ReActSession
newSession proto fingerprint tools input = do
  let s = ReActSession proto fingerprint tools 0 0 False [userEntry input] 0 Nothing
  validateSession s
  pure s

userEntry :: Text -> HistoryEntry
userEntry t = UserTurn (B.UserPayload (V.singleton (B.UserText (B.TextContent t))) Nothing)

sessionCompactedThrough :: ReActSession -> Int
sessionCompactedThrough = compactedThrough

appendUser :: Text -> ReActSession -> Either HistoryError ReActSession
appendUser t s = do
  validateSession s
  pure s {auditHistory = auditHistory s <> [userEntry t], sessionIterations = 0, sessionFinished = False}

callsOf :: B.AssistantPayload -> [B.ToolCall]
callsOf p = [c | B.AssistantToolCall c <- V.toList (p ^. #content)]

-- | Validate the whole native proposal before dispatch, including prior accepted IDs.
validateCalls :: [Text] -> [B.ToolCall] -> Either HistoryError ()
validateCalls previous calls = do
  _ <- foldM check (Set.fromList previous) calls
  pure ()
  where
    check seen c
      | T.null (T.strip (c ^. #id_)) = Left (HistoryError "empty tool call ID")
      | Set.member (c ^. #id_) seen = Left (HistoryError "duplicate tool call ID")
      | B.isCutOffToolCall c = Left (HistoryError "cut-off tool arguments")
      | otherwise = Right (Set.insert (c ^. #id_) seen)

appendExchange :: B.AssistantPayload -> [(B.ToolCall, ToolOutput)] -> Maybe Text -> Bool -> ReActSession -> Either HistoryError ReActSession
appendExchange p outputs correction finished s = do
  let next = s {auditHistory = auditHistory s <> [Exchange p outputs correction], sessionTurns = sessionTurns s + 1, sessionIterations = sessionIterations s + 1, sessionFinished = finished}
  validateSession next
  pure next

validateSession :: ReActSession -> Either HistoryError ()
validateSession s = do
  ensure (sessionProtocol s `elem` ["native", "prompt"]) "unknown protocol"
  ensure (not (null (auditHistory s))) "empty history"
  case auditHistory s of
    UserTurn _ : _ -> pure ()
    _ -> Left (HistoryError "history must start with a user turn")
  ensure (sessionTurns s == length [() | Exchange {} <- auditHistory s]) "turn count mismatch"
  ensure (sessionIterations s >= 0 && sessionIterations s <= sessionTurns s) "invalid iteration count"
  ensure (compactedThrough s >= 0 && compactedThrough s <= length (auditHistory s)) "invalid compaction boundary"
  ensure ((compactedThrough s == 0) == (summary s == Nothing)) "missing compaction summary"
  ensure (sessionIterations s == length (takeWhile isExchange (reverse (auditHistory s)))) "iteration count mismatch"
  when (sessionFinished s) $ case reverse (auditHistory s) of
    Exchange _ [(call, _)] Nothing : _ -> ensure (call ^. #name == "shikumi_submit_final") "finished without final submission"
    _ -> Left (HistoryError "finished without accepted exchange")
  _ <- foldM validateEntry [] (auditHistory s)
  pure ()
  where
    isExchange Exchange {} = True
    isExchange _ = False
    validateEntry ids (UserTurn _) = pure ids
    validateEntry ids (Exchange p outputs correction) = case correction of
      Just reason -> do
        ensure (not (T.null reason) && null outputs) "rejected exchange has results or no correction"
        pure ids
      Nothing -> do
        let calls = map fst outputs
        ensure (not (null calls)) "unresolved exchange"
        validateCalls ids calls
        ensure (not (any ((== "shikumi_submit_final") . (^. #name)) calls) || length calls == 1) "mixed final submission"
        when (sessionProtocol s == "native") $
          ensure (callsOf p == calls) "results do not match assistant calls in order"
        when (sessionProtocol s == "prompt") $ do
          ensure (null (callsOf p)) "prompt exchange contains native calls"
          ensure (all (T.isPrefixOf "prompt-" . (^. #id_)) calls) "invalid synthetic prompt ID"
          let text = T.concat [t | B.AssistantText (B.TextContent t) <- V.toList (p ^. #content)]
              stripped = if "```" `T.isPrefixOf` T.strip text then T.unlines (drop 1 (initSafe (T.lines (T.strip text)))) else text
          actions <- first (HistoryError . T.pack) $ do
            value <- eitherDecodeStrict (encodeUtf8 stripped)
            parseEither (withObject "proposal" (\o -> o .: "calls" >>= traverse (withObject "call" (\c -> (,) <$> c .: "tool" <*> c .: "args")))) value
          ensure (actions == map (\c -> (c ^. #name, c ^. #arguments)) calls) "prompt results do not match actions"
        pure (ids <> map (^. #id_) calls)

initSafe :: [a] -> [a]
initSafe [] = []
initSafe xs = take (length xs - 1) xs

ensure :: Bool -> Text -> Either HistoryError ()
ensure ok message = unless ok (Left (HistoryError message))

entryMessages :: Text -> HistoryEntry -> [B.Message]
entryMessages _ (UserTurn p) = [B.UserMessage p]
entryMessages _ (Exchange _ _ (Just correction)) = [B.user ("Protocol correction: " <> correction)]
entryMessages proto (Exchange p outputs Nothing)
  | proto == "native" = B.AssistantMessage p : map (uncurry toolOutputMessage) outputs
  | otherwise = B.AssistantMessage p : [B.user (T.intercalate "\n" [c ^. #name <> ": " <> renderToolOutput o | (c, o) <- outputs])]

promptEntries :: ReActSession -> [HistoryEntry]
promptEntries s = maybe [] (\t -> [userEntry ("Earlier conversation summary: " <> t)]) (summary s) <> drop (compactedThrough s) (auditHistory s)

promptMessages :: ReActSession -> [B.Message]
promptMessages s = concatMap (entryMessages (sessionProtocol s)) (promptEntries s)

-- | Replace only an old prefix of complete entries; the full audit is unchanged.
compactSession :: Int -> Text -> ReActSession -> Either HistoryError ReActSession
compactSession through text s = do
  ensure (through > compactedThrough s) "compaction must advance"
  let next = s {compactedThrough = through, summary = Just text}
  validateSession next
  pure next

-- The transfer format is local and explicit, independent of Baikai's Message JSON.
encodeSession :: ReActSession -> Value
encodeSession s =
  object
    [ "version" .= (1 :: Int),
      "protocol" .= sessionProtocol s,
      "fingerprint" .= sessionFingerprint s,
      "tools" .= sessionTools s,
      "turns" .= sessionTurns s,
      "iterations" .= sessionIterations s,
      "finished" .= sessionFinished s,
      "history" .= map encodeEntry (auditHistory s),
      "compactedThrough" .= compactedThrough s,
      "summary" .= summary s
    ]

decodeSession :: Value -> Either HistoryError ReActSession
decodeSession value = do
  s <- first (HistoryError . T.pack) (parseEither parseSession value)
  validateSession s
  pure s

parseSession :: Value -> Parser ReActSession
parseSession = withObject "ReActSession" $ \o -> do
  version <- o .: "version"
  unless (version == (1 :: Int)) (fail "unknown checkpoint version")
  ReActSession
    <$> o .: "protocol"
    <*> o .: "fingerprint"
    <*> o .: "tools"
    <*> o .: "turns"
    <*> o .: "iterations"
    <*> o .: "finished"
    <*> (o .: "history" >>= traverse parseEntry)
    <*> o .: "compactedThrough"
    <*> o .: "summary"

encodeEntry :: HistoryEntry -> Value
encodeEntry (UserTurn p) = object ["kind" .= String "user", "content" .= (p ^. #content), "timestamp" .= (p ^. #timestamp)]
encodeEntry (Exchange p outputs correction) =
  object
    [ "kind" .= String "exchange",
      "content" .= (p ^. #content),
      "timestamp" .= (p ^. #timestamp),
      "stop" .= (p ^. #stopReason),
      "error" .= (p ^. #errorMessage),
      "usage" .= encodeUsage (p ^. #usage),
      "results" .= [object ["call" .= c, "blocks" .= (result r ^. #content), "isError" .= (result r ^. #isError), "structured" .= structuredContent r, "extensions" .= extensionBlocks r] | (c, r) <- outputs],
      "correction" .= correction
    ]

parseEntry :: Value -> Parser HistoryEntry
parseEntry = withObject "HistoryEntry" $ \o -> do
  kind <- o .: "kind" :: Parser Text
  case kind of
    "user" -> UserTurn <$> (B.UserPayload <$> o .: "content" <*> o .: "timestamp")
    "exchange" ->
      Exchange
        <$> (B.AssistantPayload <$> o .: "content" <*> (o .: "usage" >>= parseUsage) <*> o .: "stop" <*> o .: "error" <*> o .: "timestamp")
        <*> ( o .: "results"
                >>= traverse
                  ( withObject "result" $ \r ->
                      (,) <$> r .: "call" <*> (ToolOutput <$> (B.ToolResult <$> r .: "blocks" <*> r .: "isError") <*> r .: "structured" <*> r .: "extensions")
                  )
            )
        <*> o .: "correction"
    _ -> fail "unknown history entry"

-- Costs use integer ratios, preserving even non-terminating rational values exactly.
encodeUsage :: B.Usage -> Value
encodeUsage u =
  object
    [ "tokens" .= toJSON u,
      "costRatios"
        .= map
          (\r -> (numerator r, denominator r))
          [c ^. #usd, b ^. #inputUsd, b ^. #outputUsd, b ^. #cachedInputUsd, b ^. #cachedWriteUsd]
    ]
  where
    c = u ^. #cost
    b = c ^. #breakdown

parseUsage :: Value -> Parser B.Usage
parseUsage = withObject "usage" $ \o -> do
  ratios <- o .: "costRatios" :: Parser [(Integer, Integer)]
  unless (all ((> 0) . snd) ratios) (fail "invalid cost denominator")
  cost <- case map (uncurry (%)) ratios of
    [total, i, out, cached, written] -> pure (BC.Cost total (BC.CostBreakdown i out cached written))
    _ -> fail "invalid cost breakdown"
  u <-
    o .: "tokens"
      >>= withObject
        "tokens"
        ( \t ->
            B.Usage <$> t .: "input_tokens" <*> t .: "output_tokens" <*> t .: "cache_read_tokens" <*> t .: "cache_write_tokens" <*> t .: "reasoning_tokens" <*> t .: "total_tokens" <*> pure cost
        )
  pure (u & #cost .~ cost)
