{-# LANGUAGE DeriveAnyClass #-}

-- | Shared fixtures for the @shikumi-tools@ specs: the weather records from the
-- plan's Purpose, their schema/decode/prompt instances, the typed @weatherTool@ and
-- its registry, the mock-LM scripts for both protocols, and the expected schema and
-- answer the specs assert against.
module Fixtures
  ( -- * Records
    WeatherReq (..),
    WeatherResp (..),
    AnswerWeatherQuestion (..),

    -- * Tool, signature, registry
    weatherTool,
    weatherRegistry,
    weatherSignature,

    -- * Inputs / expected outputs
    weatherQuestion,
    expectedWeather,
    weatherArgs,
    expectedReqSchema,

    -- * Mock-LM scripts
    promptScript,
    nativeScript,
    badArgsPromptScript,
    maxItersScript,
  )
where

import Baikai (Response)
import Data.Aeson (ToJSON, Value, object, (.=))
import Data.Text (Text)
import GHC.Generics (Generic)
import MockLLM (mkTextResponse, mkToolCallResponse)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Schema (FromModel, ToSchema)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Tool (SomeTool (..), Tool, ToolRegistry, mkRegistry, mkTool)

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------

data WeatherReq = WeatherReq {city :: !Text, units :: !Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data WeatherResp = WeatherResp {tempC :: !Double, summary :: !Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToJSON, ToPrompt)

newtype AnswerWeatherQuestion = AnswerWeatherQuestion {question :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToPrompt)

-- ---------------------------------------------------------------------------
-- Tool, signature, registry
-- ---------------------------------------------------------------------------

-- | A pure typed tool: it ignores its request and returns a fixed forecast (the
-- specs only need determinism, not a real lookup).
weatherTool :: Tool WeatherReq WeatherResp
weatherTool =
  mkTool "get_weather" "Look up the current weather for a city." $ \_req ->
    pure fixedForecast

fixedForecast :: WeatherResp
fixedForecast = WeatherResp {tempC = 12.0, summary = "mild"}

weatherRegistry :: ToolRegistry
weatherRegistry = mkRegistry [SomeTool weatherTool]

weatherSignature :: Signature AnswerWeatherQuestion WeatherResp
weatherSignature = mkSignature "Answer the user's weather question, using tools when helpful."

-- ---------------------------------------------------------------------------
-- Inputs / expected outputs
-- ---------------------------------------------------------------------------

weatherQuestion :: AnswerWeatherQuestion
weatherQuestion = AnswerWeatherQuestion {question = "What's the weather in Paris?"}

expectedWeather :: WeatherResp
expectedWeather = fixedForecast

-- | The arguments the scripted model proposes for @get_weather@.
weatherArgs :: Value
weatherArgs = object ["city" .= ("Paris" :: Text), "units" .= ("c" :: Text)]

-- | The exact JSON Schema 'Shikumi.Tool.toolSchemaOf' must produce for 'WeatherReq'
-- (frozen from "Shikumi.Schema"'s generator: both fields required, no additional
-- properties).
expectedReqSchema :: Value
expectedReqSchema =
  object
    [ "type" .= ("object" :: Text),
      "properties"
        .= object
          [ "city" .= object ["type" .= ("string" :: Text)],
            "units" .= object ["type" .= ("string" :: Text)]
          ],
      "required" .= (["city", "units"] :: [Text]),
      "additionalProperties" .= False
    ]

-- ---------------------------------------------------------------------------
-- Mock-LM scripts
-- ---------------------------------------------------------------------------

-- | The extract turn's reply: a JSON object decoding to 'expectedWeather'.
extractReply :: Text
extractReply = "{\"tempC\": 12.0, \"summary\": \"mild\"}"

-- | A prompt-protocol propose reply: one action JSON object matching the grammar
-- 'Shikumi.Agent.ReAct' renders. @CallTool@ form.
proposeCallReply :: Text
proposeCallReply =
  "{\"thought\": \"I should look up Paris.\", \"action\": {\"tool\": \"get_weather\", \"args\": {\"city\": \"Paris\", \"units\": \"c\"}}}"

-- | A prompt-protocol propose reply with arguments missing the required @units@
-- field, to exercise the typed 'Shikumi.Tool.ToolArgsInvalid' recovery path.
proposeBadArgsReply :: Text
proposeBadArgsReply =
  "{\"thought\": \"Looking up Paris.\", \"action\": {\"tool\": \"get_weather\", \"args\": {\"city\": \"Paris\"}}}"

-- | A prompt-protocol finish reply.
finishReply :: Text
finishReply = "{\"thought\": \"I have the forecast.\", \"action\": {\"finish\": true}}"

-- | Prompt protocol: propose the tool call, finish, then extract.
promptScript :: [Response]
promptScript =
  [ mkTextResponse proposeCallReply,
    mkTextResponse finishReply,
    mkTextResponse extractReply
  ]

-- | Native protocol: a tool-call block, a plain-text turn (no tool call = finish),
-- then the extract reply.
nativeScript :: [Response]
nativeScript =
  [ mkToolCallResponse "call_1" "get_weather" weatherArgs,
    mkTextResponse "I have the forecast now.",
    mkTextResponse extractReply
  ]

-- | Prompt protocol with malformed tool arguments on the first turn: the tool
-- decode fails (recorded as an observation), the model then finishes, then
-- extracts. The agent still returns a typed answer.
badArgsPromptScript :: [Response]
badArgsPromptScript =
  [ mkTextResponse proposeBadArgsReply,
    mkTextResponse finishReply,
    mkTextResponse extractReply
  ]

-- | A prompt-protocol script that never finishes: one tool-call propose, then the
-- extract reply. Run with @maxIters = 1@ it stops at the cap (after the single
-- proposal) and still extracts a best-effort answer.
maxItersScript :: [Response]
maxItersScript =
  [ mkTextResponse proposeCallReply,
    mkTextResponse extractReply
  ]
