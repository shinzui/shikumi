-- | (2) Compose typed programs — mismatches are compile errors.
--
-- Each stage is a @Program i o@; @(>>>)@ chains them, and it typechecks only
-- because each stage's output type equals the next stage's input type. Reorder
-- them and it does not compile.
--
-- Offline, one stub responder serves the whole pipeline by branching on the
-- per-stage instruction (rendered into the request's system prompt).
module Main (main) where

import Baikai (Context, Response)
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Combinator ((>>>))
import Shikumi.Jitsurei.Stub (markerResponse, runStub, systemContains)
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema)
import Shikumi.Schema.Types (Field, field)
import Shikumi.Signature (mkSignature)

-- ---------------------------------------------------------------------------
-- Four record types, one per pipeline boundary.
-- ---------------------------------------------------------------------------

data RawEmail = RawEmail
  { subject :: !(Field "The email subject line" Text),
    bodyText :: !(Field "The email body" Text)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data Invoice = Invoice
  { vendor :: !Text,
    amount :: !Double
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data EnrichedInvoice = EnrichedInvoice
  { vendorTier :: !Text,
    amountUsd :: !Double
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data Decision = Decision
  { approved :: !Bool,
    reason :: !Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

-- ---------------------------------------------------------------------------
-- Three typed stages, chained into one program.
-- ---------------------------------------------------------------------------

extract :: Program RawEmail Invoice
extract = predict (mkSignature "Extract the vendor and amount from the raw email.")

enrich :: Program Invoice EnrichedInvoice
enrich = predict (mkSignature "Enrich the invoice with the vendor's tier.")

approve :: Program EnrichedInvoice Decision
approve = predict (mkSignature "Approve or reject the enriched invoice.")

-- The whole pipeline. Its type, @Program RawEmail Decision@, is enforced by the
-- chain: swap any two stages and this line is a type error.
pipeline :: Program RawEmail Decision
pipeline = extract >>> enrich >>> approve

sampleEmail :: RawEmail
sampleEmail =
  RawEmail
    { subject = field "Invoice #4021",
      bodyText = field "Acme Corp — amount due: $42.50"
    }

-- One responder for three stages: branch on the stage's instruction (it is
-- rendered into the request's system prompt). Each stage decodes only its own
-- fields, so a response carrying just that stage's markers is enough.
responder :: Context -> Response
responder ctx
  | systemContains "Extract" ctx =
      markerResponse [("vendor", "Acme Corp"), ("amount", "42.50")]
  | systemContains "Enrich" ctx =
      markerResponse [("vendorTier", "gold"), ("amountUsd", "42.50")]
  | otherwise =
      markerResponse [("approved", "true"), ("reason", "known vendor, positive amount")]

main :: IO ()
main = do
  putStrLn "jitsurei-compose: typed pipeline, mismatches are compile errors\n"
  result <- runStub responder pipeline sampleEmail
  case result of
    Left err -> putStrLn $ "pipeline failed: " <> show err
    Right decision -> do
      putStrLn "RawEmail >>> Invoice >>> EnrichedInvoice >>> Decision"
      putStrLn $ "decision -> " <> show decision
