{-# LANGUAGE DataKinds #-}

-- | EP-67: a typed program whose output is a list of records decodes through a
-- subscription-CLI provider that enforces the derived schema, and fails the way
-- Mina's @codex-cli@ judges did when the same provider sits under a fallback tag.
--
-- The scripted provider stands in for baikai's CLI providers: it returns
-- schema-conforming JSON only when the request carries a 'B.JsonSchema'
-- @responseFormat@ (what @claude -p --json-schema@ / @codex exec --output-schema@
-- enforce), and otherwise replies like an unconstrained model — marker sections
-- whose list-of-records field holds bare strings. Registering the identical
-- provider under a @Custom@ tag is the control: only the routing decision differs.
module CliSchemaSpec
  ( tests,
    Severity (..),
    Concern (..),
    Assessment (..),
    Proposal (..),
  )
where

import Baikai qualified as B
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value)
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError, renderShikumiError)
import Shikumi.LLM (runLLMWith)
import Shikumi.Program (Program (Predict), emptyParams, runProgram)
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Schema (FromModel, ToSchema, Validatable, deriveSchema)
import Shikumi.Schema.Types (Field (..), field)
import Shikumi.Signature (Signature, mkSignature)
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

data Severity = Blocker | Major | Minor
  deriving stock (Generic, Show, Eq)

instance ToSchema Severity

instance FromModel Severity

data Concern = Concern
  { statement :: !(Field "What is wrong" Text),
    severity :: !Severity
  }
  deriving stock (Generic, Show, Eq)

instance ToSchema Concern

instance FromModel Concern

data Assessment = Assessment
  { concerns :: !(Field "Readiness concerns" [Concern]),
    verdict :: !(Field "Overall verdict" Text)
  }
  deriving stock (Generic, Show, Eq)

instance ToSchema Assessment

instance FromModel Assessment

instance ToPrompt Assessment

instance Validatable Assessment

newtype Proposal = Proposal {plan :: Field "The release plan to assess" Text}
  deriving stock (Generic, Show, Eq)

instance ToSchema Proposal

instance FromModel Proposal

instance ToPrompt Proposal

instance Validatable Proposal

assessSig :: Signature Proposal Assessment
assessSig = mkSignature "Assess whether the release plan is ready."

proposal :: Proposal
proposal = Proposal {plan = field "Ship on Friday."}

expectedAssessment :: Assessment
expectedAssessment =
  Assessment
    { concerns = field [Concern {statement = field "No rollback path", severity = Blocker}],
      verdict = field "not ready"
    }

-- | The reply a schema-enforcing CLI returns.
conformingJson :: Text
conformingJson =
  "{\"concerns\":[{\"statement\":\"No rollback path\",\"severity\":\"Blocker\"}],\"verdict\":\"not ready\"}"

-- | The reply an unconstrained model wrote in Mina: strings where records belong.
unconstrainedMarkers :: Text
unconstrainedMarkers =
  T.intercalate
    "\n"
    [ "[[ ## concerns ## ]]",
      "[\"No rollback path\"]",
      "[[ ## verdict ## ]]",
      "not ready",
      "[[ ## completed ## ]]"
    ]

textResponse :: B.Model -> Text -> B.Response
textResponse m t =
  B.emptyResponse
    & #message
      . #content
      .~ V.singleton (B.AssistantText (B.emptyTextContent & #text .~ t))
    & #model
      .~ m

-- | A registry whose single provider serves @api@ and enforces the schema only
-- when one is requested, recording every 'B.Options' it receives.
cliRegistry :: B.Api -> IO (B.ProviderRegistry, IORef [B.Options])
cliRegistry api = do
  seen <- newIORef []
  reg <- B.newProviderRegistry
  let reply m o = case o ^. #responseFormat of
        Just (B.JsonSchema _) -> textResponse m conformingJson
        _ -> textResponse m unconstrainedMarkers
  B.registerApiProviderWith
    reg
    ( B.apiProviderWith
        api
        (\_ _ _ -> Stream.nil)
        (\m _ o -> modifyIORef' seen (<> [o]) >> pure (reply m o))
    )
      { B.describeThinking = \_ _ -> B.noThinkingRequested
      }
  pure (reg, seen)

runOn :: B.Model -> B.ProviderRegistry -> IO (Either ShikumiError Assessment)
runOn model reg =
  runEff
    . runErrorNoCallStack @ShikumiError
    . runRouting model
    . runLLMWith reg
    . routeLLM
    $ runProgram (Predict assessSig emptyParams) proposal

schemaOf :: B.Options -> Maybe Value
schemaOf o = case o ^. #responseFormat of
  Just (B.JsonSchema fmt) -> Just (fmt ^. #schema)
  _ -> Nothing

tests :: TestTree
tests =
  testGroup
    "CliSchema"
    [ testCase "claude CLI model: routed with the strict derived schema and decodes a list of records" $ do
        let model = B.mkModel B.AnthropicMessagesCli "fixture" "https://example.invalid"
        (reg, seen) <- cliRegistry B.AnthropicMessagesCli
        result <- runOn model reg
        result @?= Right expectedAssessment
        recorded <- readIORef seen
        map (^. #responseFormat) recorded
          @?= [Just (B.JsonSchema (B.jsonSchemaFormat "output" (deriveSchema @Assessment) & #strict .~ True))]
        map schemaOf recorded @?= [Just (deriveSchema @Assessment)]
        -- Private shikumi metadata never reaches the transport.
        map (Map.keys . (^. #metadata)) recorded @?= [[]],
      testCase "codex CLI model: routed with the derived schema" $ do
        let model = B.mkModel B.OpenAICompletionsCli "fixture" "https://example.invalid"
        (reg, seen) <- cliRegistry B.OpenAICompletionsCli
        result <- runOn model reg
        result @?= Right expectedAssessment
        readIORef seen >>= (@?= [Just (deriveSchema @Assessment)]) . map schemaOf,
      testCase "same provider under a fallback tag: no schema, strings where records belong" $ do
        let api = B.Custom "no-schema"
            model = B.mkModel api "fixture" "https://example.invalid"
        (reg, seen) <- cliRegistry api
        result <- runOn model reg
        readIORef seen >>= (@?= [Nothing]) . map schemaOf
        case result of
          Left e
            | "expected object, got string" `T.isInfixOf` renderShikumiError e -> pure ()
            | otherwise -> assertFailure ("unexpected error: " <> T.unpack (renderShikumiError e))
          Right a -> assertFailure ("expected a decode failure, got " <> show a)
    ]
