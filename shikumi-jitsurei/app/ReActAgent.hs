-- | (7) Typed tools and a ReAct agent loop.
--
-- A tool is an ordinary function over record types; its argument schema is
-- Generic-derived and lowered to baikai's wire tool. @reactWithTrajectory@ builds
-- a @Program@ whose embedded loop alternates thought -> action -> observation
-- until the model finishes or a bound is hit, then extracts the typed answer —
-- recording a structured 'Trajectory' throughout. The whole agent is itself a
-- first-class, composable @Program@.
--
-- Offline, a /script/ of model turns drives the loop: propose a tool call,
-- finish, then extract the typed answer.
module Main (main) where

import Data.Aeson (ToJSON)
import Data.Text (Text)
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Agent.ReAct
  ( Action (..),
    Step (..),
    Trajectory (..),
    defaultReActConfig,
    reactWithTrajectory,
  )
import Shikumi.Jitsurei.Stub (mkTextResponse, runAgent)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Tool (SomeTool (..), Tool, ToolRegistry, mkRegistry, mkTool)

-- ---------------------------------------------------------------------------
-- A tool's request/response are records; the agent's question/answer too.
-- ---------------------------------------------------------------------------

data WeatherReq = WeatherReq {city :: !Text, units :: !Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

instance Validatable WeatherReq

data WeatherResp = WeatherResp {tempC :: !Double, summary :: !Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt, ToJSON)

instance Validatable WeatherResp

newtype AskWeather = AskWeather {question :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToPrompt)

-- A pure typed tool: it returns a fixed forecast (the demo only needs
-- determinism, not a real lookup).
weatherTool :: Tool WeatherReq WeatherResp
weatherTool =
  mkTool "get_weather" "Look up the current weather for a city." $ \_req ->
    pure (WeatherResp {tempC = 12.0, summary = "mild"})

weatherRegistry :: ToolRegistry
weatherRegistry = mkRegistry [SomeTool weatherTool]

weatherSignature :: Signature AskWeather WeatherResp
weatherSignature = mkSignature "Answer the user's weather question, using tools when helpful."

-- The scripted model turns: propose a tool call, then finish, then extract.
script :: [Text]
script =
  [ "{\"thought\": \"I should look up Paris.\", \"action\": {\"tool\": \"get_weather\", \"args\": {\"city\": \"Paris\", \"units\": \"c\"}}}",
    "{\"thought\": \"I have the forecast.\", \"action\": {\"finish\": true}}",
    "{\"tempC\": 12.0, \"summary\": \"mild\"}"
  ]

main :: IO ()
main = do
  putStrLn "jitsurei-react: a typed tool + ReAct agent loop\n"
  result <-
    runAgent
      (map mkTextResponse script)
      (reactWithTrajectory weatherSignature weatherRegistry defaultReActConfig)
      (AskWeather "What's the weather in Paris?")
  case result of
    Left err -> putStrLn $ "agent failed: " <> show err
    Right (answer, traj) -> do
      putStrLn $ "answer      -> " <> show answer
      putStrLn $ "termination -> " <> show (termination traj)
      putStrLn $ "steps:"
      mapM_ printStep (V.toList (steps traj))
  where
    printStep s =
      putStrLn $
        "  - "
          <> describe (action s)
          <> maybe "" (\o -> "  (observed: " <> show o <> ")") (observation s)
    describe (CallTool nm _) = "call " <> show nm
    describe Finish = "finish"
    describe Summarized = "summary"
