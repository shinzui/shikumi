{-# LANGUAGE DataKinds #-}

-- | (11) Adapter completeness and declarative field constraints.
--
-- Three richer-I/O capabilities on the typed seam, all offline:
--
--   * __@xmlAdapter@__ — a third wire format. @render@ asks for @\<field\>…\</field\>@
--     tags; @parse@ reads them back into the typed output (it is opt-in — a caller
--     picks it, @adapterFor@ never auto-selects it).
--   * __@twoStep@__ — a two-call program: a free-form prose answer, then a structured
--     extraction call. Useful for strong reasoners weak at structured output.
--   * __@Constrained@__ — declarative field constraints that flow into /both/ the JSON
--     schema keywords and the post-decode validator from one type-level declaration.
module Main (main) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Shikumi.Adapter (Adapter (..), ToPrompt, xmlAdapter)
import Shikumi.Jitsurei.Stub (markerResponse, mkTextResponse, runAgent, systemContains)
import Shikumi.Module (twoStep)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, deriveSchema, fromModel)
import Shikumi.Schema.Types (Constrained, Constraint (..), Field)
import Shikumi.Signature (Signature, mkSignature)

-- ---------------------------------------------------------------------------
-- Shared records for the XML and two-step demos.
-- ---------------------------------------------------------------------------

newtype Ask = Ask {question :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToPrompt)

data Memo = Memo
  { headline :: !(Field "A one-line summary" Text),
    bullets :: !(Field "Key points" [Text])
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

memoSig :: Signature Ask Memo
memoSig = mkSignature "Summarise the question into a headline and key points."

-- ---------------------------------------------------------------------------
-- A constrained record for the constraints demo.
-- ---------------------------------------------------------------------------

data Bio = Bio
  { tagline :: !(Constrained '[ 'MinLen 10] Text),
    score :: !(Constrained '[ 'MinVal "0", 'MaxVal "100"] Int)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

-- ---------------------------------------------------------------------------
-- Helpers to drill into a derived schema Value.
-- ---------------------------------------------------------------------------

prop :: Text -> Text -> Value -> Maybe Value
prop name kw (Object o) = do
  Object props <- KM.lookup "properties" o
  Object field' <- KM.lookup (Key.fromText name) props
  KM.lookup (Key.fromText kw) field'
prop _ _ _ = Nothing

main :: IO ()
main = do
  putStrLn "jitsurei-adapters: XML adapter, two-step extraction, declarative constraints\n"

  -- (a) The XML adapter renders <tags> and parses them back.
  putStrLn "[xmlAdapter]"
  let (xmlCtx, _) = render xmlAdapter memoSig (Ask "What is shikumi?")
  putStrLn $ "  render asks for <headline> tags -> " <> show (systemContains "<headline>" xmlCtx)
  let xmlReply =
        T.intercalate
          "\n"
          [ "<headline>",
            "Shikumi types LM programs",
            "</headline>",
            "<bullets>",
            "[\"records in\", \"records out\"]",
            "</bullets>"
          ]
  putStrLn $ "  parse a tagged reply           -> " <> show (parse xmlAdapter memoSig (mkTextResponse xmlReply))

  -- (b) twoStep: a free-form answer, then a structured extraction call.
  putStrLn "\n[twoStep]"
  let twoStepScript =
        [ mkTextResponse "Shikumi types LM programs: records in, records out, errors are typed.",
          markerResponse [("headline", "Shikumi types LM programs"), ("bullets", "[\"records in\", \"records out\"]")]
        ]
  out <- runAgent twoStepScript (twoStep memoSig :: Program Ask Memo) (Ask "What is shikumi?")
  putStrLn $ "  free-form -> extract -> typed  -> " <> show out

  -- (c) Declarative constraints: one declaration drives schema + validation.
  putStrLn "\n[Constrained]"
  let schema = deriveSchema @Bio
  putStrLn $ "  schema tagline.minLength       -> " <> show (prop "tagline" "minLength" schema)
  putStrLn $ "  schema score.minimum/maximum   -> " <> show (prop "score" "minimum" schema, prop "score" "maximum" schema)
  putStrLn $ "  decode short tagline           -> " <> show (fromModel @Bio (bioJson "short" 50))
  putStrLn $ "  decode out-of-range score      -> " <> show (fromModel @Bio (bioJson "long enough tagline" 150))
  putStrLn $ "  decode conforming value        -> " <> show (fromModel @Bio (bioJson "long enough tagline" 50))
  where
    bioJson t s = object ["tagline" .= (t :: Text), "score" .= (s :: Int)]
