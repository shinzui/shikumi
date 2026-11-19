{-# LANGUAGE RankNTypes #-}

-- | The UC-7 fixture shared by the evidence suites: a miniature reviewer agent
-- that classifies how a changed decision record relates to the guidance it cites,
-- its synthetic production evidence, a metric policy, and the stub providers that
-- generate the recordings.
module Fixture
  ( -- * The program
    Review (..),
    Finding (..),
    reviewer,
    baselineInstruction,
    ruleInstruction,
    verboseRuleInstruction,
    codec,
    exactDisposition,
    falseActionable,

    -- * Evidence
    fixedTime,
    sources,
    uc7Records,
    uc7Spec,
    noRedaction,
    uc7Dataset,
    baselineArtifact,
    uc7Policy,
    uc7Limits,

    -- * Providers
    Provider (..),
    respond,
    responseFor,
    unreachable,
    requestText,
    userText,

    -- * Jobs
    uc7Job,
    runJob,
    runJobWith,
    expectRight,
  )
where

import Baikai (AssistantContent (..), Context, Response, emptyResponse, emptyTextContent)
import Baikai.Content (TextContent (..), UserContent (..))
import Baikai.Message (Message (..))
import Control.Exception (ErrorCall (..), throw)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (object, (.=))
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Data.Vector qualified as V
import Effectful (Eff, IOE)
import Effectful.Concurrent (Concurrent)
import Effectful.Error.Static (Error)
import Effectful.Prim (Prim)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Compile.Types (CompiledProgram (..))
import Shikumi.Effect.Time (Time)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval (Metric, boolScore, predictionPrimary)
import Shikumi.Evidence
import Shikumi.LLM (LLM)
import Shikumi.Module (predict)
import Shikumi.Optimize.Execution (RunLimits (..))
import Shikumi.Optimize.Feedback (EvaluationEvidence (..))
import Shikumi.Optimize.GEPA (reflectiveProposer)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)
import Shikumi.Testing (runStubEval, systemContains)
import Test.Tasty.HUnit (assertFailure)

-- ---------------------------------------------------------------------------
-- The program
-- ---------------------------------------------------------------------------

-- | A changed decision record, summarized.
newtype Review = Review {summary :: Text}
  deriving stock (Eq, Show, Generic)

instance FromModel Review

instance ToSchema Review

instance ToPrompt Review

-- | How the record relates to its cited guidance: @consistent@, @adr-suspect@ or
-- @guidance-suspect@.
newtype Finding = Finding {disposition :: Text}
  deriving stock (Eq, Show, Generic)

instance FromModel Finding

instance ToSchema Finding

instance ToPrompt Finding

instance Validatable Finding

-- | The baseline instruction. It carries no rule, so the stub reviewer answers
-- @consistent@ to everything.
baselineInstruction :: Text
baselineInstruction = "Classify how a changed decision record relates to the guidance it cites."

-- | The instruction the good proposer returns.
ruleInstruction :: Text
ruleInstruction =
  "RULE: name the conflict. Answer adr-suspect when the record contradicts the guidance, \
  \guidance-suspect when the guidance is outdated, and consistent otherwise."

-- | The instruction the costly proposer returns: the same rule, verbosely.
verboseRuleInstruction :: Text
verboseRuleInstruction = "VERBOSE " <> ruleInstruction <> " Explain every step at length before answering."

-- | The reviewer: one predict node.
reviewer :: Program Review Finding
reviewer = predict (mkSignature baselineInstruction)

-- | The dataset codec, from the program's own instances.
codec :: EvidenceCodec Review Finding
codec = modelEvidenceCodec

-- | Exact match on the disposition.
exactDisposition :: Metric Finding
exactDisposition expected p = boolScore (expected.disposition == (predictionPrimary p).disposition)

-- | One when the program raises an actionable finding for a record labeled
-- consistent.
falseActionable :: Finding -> EvaluationEvidence Finding -> Map Text Double
falseActionable expected ev = Map.singleton "false_actionable" $ case executionResult ev of
  Right out | expected.disposition == "consistent" && out.disposition /= "consistent" -> 1
  _ -> 0

-- ---------------------------------------------------------------------------
-- Evidence
-- ---------------------------------------------------------------------------

-- | The fixed creation time of every fixture artifact.
fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 11 1) 0

-- | The fixture's source revisions.
sources :: [SourceRef]
sources =
  [ SourceRef "program-template" "repo_shikumi" "1111111111111111111111111111111111111111",
    SourceRef "shikumi" "repo_shikumi" "2222222222222222222222222222222222222222"
  ]

-- | Twenty-four synthetic records in six groups of four. Every group holds one
-- consistent record, one that contradicts the guidance, one whose guidance is
-- outdated, and one ambiguous contradiction the improved program still gets
-- wrong. Each group's records are adjacent, and every summary is distinct.
uc7Records :: [EvidenceRecord]
uc7Records = concatMap group [1 .. 6 :: Int]
  where
    group g =
      [ record g "a" ("Record " <> n <> " keeps the retry budget the guidance prescribes for service " <> n <> ".") "consistent",
        record g "b" ("Record " <> n <> " contradicts the guidance by removing the audit step for service " <> n <> ".") "adr-suspect",
        record g "c" ("Record " <> n <> " follows a practice the guidance is outdated about for service " <> n <> ".") "guidance-suspect",
        record g "d" ("Record " <> n <> " arguably drifts from the guidance on timeouts for service " <> n <> ".") "adr-suspect"
      ]
      where
        n = T.pack (show g)
    record g k text disp =
      EvidenceRecord
        { exampleId = "uc7-" <> T.pack (show g) <> k,
          groupKey = "incident-" <> T.pack (show g),
          input = object ["summary" .= (text :: Text)],
          expected = Just (object ["disposition" .= (disp :: Text)]),
          label = Just (Label HumanLabel "adjudicator-1" fixedTime Nothing (Just "approved") Nothing),
          source = EvidenceSource ("run/uc7/" <> T.pack (show g) <> k) (Just ("outcome/uc7/" <> T.pack (show g) <> k)) [],
          critiques = []
        }

-- | The fixture dataset's identity and split policy.
uc7Spec :: DatasetSpec
uc7Spec =
  DatasetSpec
    { datasetId = "uc7-reviewer-evidence",
      agent = "kikan/reviewer",
      behaviorVersions = ["reviewer-v1"],
      inputSchemaDigest = digestValue codec.inputSchema,
      outputSchemaDigest = digestValue codec.outputSchema,
      collection = Collection fixedTime fixedTime "adjudicated reviews, window 2026-10" "selection-v1",
      splitPolicy = SplitPolicy "uc7-split-v1" "incident" "uc7-salt" 160 333 8 3,
      retentionPolicyId = "retention-90d",
      createdAt = fixedTime,
      createdBy = "fixture-adapter"
    }

-- | A redaction policy that rewrites and prohibits nothing.
noRedaction :: RedactionPolicy
noRedaction = RedactionPolicy "redaction-none-v1" id (const False)

-- | The sealed fixture dataset. Training records labeled @adr-suspect@ carry a
-- human critique at the root node, attached after splitting so only training
-- examples hold critiques.
uc7Dataset :: EvidenceDataset
uc7Dataset = either (error . show) id (sealDataset uc7Spec noRedaction critiqued)
  where
    splits = assignSplits (splitPolicy' uc7Spec) uc7Records
    splitPolicy' s = s.splitPolicy
    critiqued =
      [ if s == Train && r.expected == Just (object ["disposition" .= ("adr-suspect" :: Text)])
          then r {critiques = [Critique (Just "root") "Name the conflict between the record and the guidance." HumanLabel "adjudicator-1" fixedTime]}
          else r
      | (r, s) <- zip uc7Records splits
      ]

-- | The baseline artifact for the reviewer.
baselineArtifact :: ProgramArtifact
baselineArtifact =
  either (error . show) id (sealBaseline (ArtifactSpec "uc7-reviewer-baseline" sources fixedTime "fixture") codec (CompiledProgram reviewer))

-- | The fixture metric policy.
uc7Policy :: MetricPolicy
uc7Policy =
  MetricPolicy
    { policyId = "uc7-promotion",
      policyVersion = "1",
      metrics =
        [ MetricSpec "quality" "quality" "score" Maximize MeanOverLabeled Required,
          MetricSpec "completion-rate" "completed" "share" Maximize MeanOverLabeled Required,
          MetricSpec "false-actionable" "false_actionable" "count" Minimize TotalOverLabeled Required,
          MetricSpec "cost-per-success" "cost_usd" "usd" Minimize TotalPerCompleted Required,
          MetricSpec "mean-latency" "latency_ms" "ms" Minimize MeanOverCompleted Required
        ],
      primaryMetric = "quality",
      constraints =
        [ Constraint "full-completion" "completion-rate" (AbsoluteLimit 1),
          Constraint "no-new-false-actionable" "false-actionable" (BaselineMargin 0),
          Constraint "cost-per-success" "cost-per-success" (BaselineRatio 1.15),
          Constraint "latency" "mean-latency" (BaselineRatio 1.1)
        ],
      customMeasures = ["false_actionable"],
      minImprovement = 0.1,
      regressionMargin = 0.02,
      minLabeledSamples = 8,
      maxMissingRate = 0.25,
      exampleTimeoutMs = Just 1000,
      maxComparisonOperations = 32
    }

-- | Sixty operations, two candidates, sequential, seed one.
uc7Limits :: RunLimits
uc7Limits = RunLimits 60 2 1 1

-- ---------------------------------------------------------------------------
-- Providers
-- ---------------------------------------------------------------------------

-- | Which proposer the stub provider plays.
data Provider = Good | Costly
  deriving stock (Eq, Show)

-- | The stub provider. The reviewer answers @consistent@ without a rule in its
-- instruction; with one it answers correctly except on ambiguous summaries.
-- Answers under a verbose instruction cost four times as much. The proposer
-- returns the rule when its feedback asks to name the conflict.
respond :: Provider -> Context -> Response
respond provider ctx
  | systemContains "proposedInstruction" ctx =
      if "Name the conflict" `T.isInfixOf` requestText ctx
        then responseFor 1 [("proposedInstruction", if provider == Good then ruleInstruction else verboseRuleInstruction)]
        else responseFor 1 [("proposedInstruction", baselineInstruction)]
  | otherwise = responseFor (if systemContains "VERBOSE" ctx then 4 else 1) [("disposition", answer)]
  where
    s = userText ctx
    answer
      | not (systemContains "RULE" ctx) = "consistent"
      | "arguably" `T.isInfixOf` s = "consistent"
      | "contradicts" `T.isInfixOf` s = "adr-suspect"
      | "outdated" `T.isInfixOf` s = "guidance-suspect"
      | otherwise = "consistent"

-- | A marker-format response costing @units@ thousandths of a dollar, with 23
-- tokens and 4 ms of latency. The cost is a terminating decimal, so it survives
-- the JSON round trip exactly.
responseFor :: Rational -> [(Text, Text)] -> Response
responseFor units fields =
  emptyResponse
    & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ body))
    & #message . #usage . #inputTokens .~ 18
    & #message . #usage . #outputTokens .~ 5
    & #message . #usage . #totalTokens .~ 23
    & #message . #usage . #cost . #usd .~ (units / 1000)
    & #latencyMs .~ 4
  where
    body = T.unlines (concatMap (\(k, v) -> ["[[ ## " <> k <> " ## ]]", v]) fields ++ ["[[ ## completed ## ]]"])

-- | A provider that fails the test if any call reaches it.
unreachable :: Context -> Response
unreachable _ = throw (ErrorCall "a replayed job reached the provider")

-- | The system prompt and every user message of a request.
requestText :: Context -> Text
requestText ctx = T.intercalate "\n" (maybe [] pure (ctx ^. #systemPrompt) ++ userTexts ctx)

-- | The last user message of a request.
userText :: Context -> Text
userText ctx = case userTexts ctx of
  [] -> ""
  xs -> last xs

userTexts :: Context -> [Text]
userTexts ctx = [T.concat [t | UserText (TextContent t) <- V.toList (u ^. #content)] | UserMessage u <- V.toList (ctx ^. #messages)]

-- ---------------------------------------------------------------------------
-- Jobs
-- ---------------------------------------------------------------------------

type Stack = '[LLM, Concurrent, Error ShikumiError, Time, Prim, IOE]

-- | The UC-7 job with the GEPA evidence optimizer and no request pipeline.
uc7Job :: Text -> ExecutionMode -> EvidenceJob Stack Review Finding
uc7Job jobName execMode =
  EvidenceJob
    { dataset = uc7Dataset,
      codec = codec,
      template = reviewer,
      baseline = baselineArtifact,
      optimizer = gepaEvidenceOptimizer defaultGepaEvidenceConfig reflectiveProposer,
      limits = uc7Limits,
      searchMetric = exactDisposition,
      customMeasures = falseActionable,
      policy = uc7Policy,
      context = ExecutionContext "fixture-runner" fixedTime jobName Nothing sources noPriorExposure,
      requestPipeline = id,
      mode = execMode
    }

-- | Run a job against a responder.
runJob :: (Context -> Response) -> EvidenceJob Stack Review Finding -> IO (Either ShikumiError EvidenceJobResult)
runJob responder job = runStubEval responder (runEvidenceJob job)

-- | Run any action against a responder.
runJobWith :: (Context -> Response) -> Eff Stack a -> IO (Either ShikumiError a)
runJobWith = runStubEval

-- | Fail the test on a typed error.
expectRight :: (Show e) => Either e a -> IO a
expectRight = either (\e -> assertFailure (show e) >> error "unreachable") pure
