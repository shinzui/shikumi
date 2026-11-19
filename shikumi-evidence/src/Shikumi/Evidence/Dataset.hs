{-# LANGUAGE DataKinds #-}

-- | The sealed dataset envelope: production evidence with its provenance, its
-- split assignment and a content digest.
--
-- Records come from adapters as t'EvidenceRecord' values. 'sealDataset' redacts
-- them, assigns each to the training, validation or protected holdout split
-- deterministically while keeping related records together, validates the result
-- and seals it. 'decodeDataset' reads a sealed envelope back, verifying its digest
-- on the raw JSON. 'openDataset' turns a valid envelope into typed training and
-- validation datasets with a caller-supplied codec.
--
-- No function exported here returns holdout examples from a t'SealedDataset':
-- the holdout is reachable only inside this package, by the driver's comparison.
module Shikumi.Evidence.Dataset
  ( -- * The envelope
    EvidenceDataset (..),
    EvidenceExample (..),
    EvidenceRecord (..),
    EvidenceSource (..),
    Label (..),
    LabelKind (..),
    Critique (..),
    Split (..),
    Collection (..),
    SplitPolicy (..),
    datasetKind,

    -- * Building
    DatasetSpec (..),
    RedactionPolicy (..),
    sealDataset,
    resealDataset,
    assignSplits,

    -- * Reading
    DatasetError (..),
    decodeDataset,
    validateDataset,
    datasetSplitCounts,

    -- * Typed access
    EvidenceCodec (..),
    modelEvidenceCodec,
    SealedDataset,
    openDataset,
    sealedTraining,
    sealedValidation,
    sealedTrainingIds,
    sealedTrainingCritiques,
    labelProvenance,
    parseNodePath,
  )
where

import Control.Monad (forM, unless)
import Data.Aeson (FromJSON (..), Options (..), ToJSON (..), Value (..), defaultOptions, genericParseJSON, genericToJSON, object, withObject, withText, (.:), (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BL
import Data.Either (lefts)
import Data.List (nub, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import GHC.Records (HasField (..))
import Shikumi.Cache.Key (canonicalJSON)
import Shikumi.Error (renderShikumiError)
import Shikumi.Eval (Dataset, Example (..), dataset)
import Shikumi.Evidence.Dataset.Internal
import Shikumi.Evidence.Digest
import Shikumi.Optimize.Feedback (Provenance (..), StoredCritique (..))
import Shikumi.Schema (FromModel, ToSchema, deriveSchema, fromModel)
import Shikumi.Trace.Node (NodePath (..), NodeStep (..))
import Text.Read (readMaybe)

-- ---------------------------------------------------------------------------
-- Envelope types
-- ---------------------------------------------------------------------------

-- | Generic JSON with absent optional fields omitted, so each value has exactly
-- one representation.
evidenceOptions :: Options
evidenceOptions = defaultOptions {omitNothingFields = True}

-- | Who or what produced a label or critique.
data LabelKind = HumanLabel | ModelLabel | InferredLabel
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON LabelKind where
  toJSON = String . \case HumanLabel -> "human"; ModelLabel -> "model"; InferredLabel -> "inferred"

instance FromJSON LabelKind where
  parseJSON = withText "LabelKind" $ \case
    "human" -> pure HumanLabel
    "model" -> pure ModelLabel
    "inferred" -> pure InferredLabel
    other -> fail ("unknown label kind: " <> T.unpack other)

-- | The critique provenance a label kind maps to in the optimizer.
labelProvenance :: LabelKind -> Provenance
labelProvenance = \case
  HumanLabel -> Human
  ModelLabel -> Model
  InferredLabel -> Inferred

-- | The adjudication that made an expected output trustworthy.
data Label = Label
  { kind :: !LabelKind,
    author :: !Text,
    labeledAt :: !UTCTime,
    confidence :: !(Maybe Double),
    -- | such as @approved@, @rejected@, @corrected@ or @useful@
    disposition :: !(Maybe Text),
    resolutionReason :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Label where toJSON = genericToJSON evidenceOptions

instance FromJSON Label where parseJSON = genericParseJSON evidenceOptions

-- | Where an example came from: the production run, its outcome and any
-- feedback records.
data EvidenceSource = EvidenceSource
  { runRef :: !Text,
    outcomeRef :: !(Maybe Text),
    feedbackRefs :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceSource where toJSON = genericToJSON evidenceOptions

instance FromJSON EvidenceSource where parseJSON = genericParseJSON evidenceOptions

-- | A stored critique. Without a @node@ it is program-scoped; a node is the
-- rendered node path ('Shikumi.Trace.Node.renderNodePath'), such as @root@.
data Critique = Critique
  { node :: !(Maybe Text),
    text :: !Text,
    kind :: !LabelKind,
    author :: !Text,
    at :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Critique where toJSON = genericToJSON evidenceOptions

instance FromJSON Critique where parseJSON = genericParseJSON evidenceOptions

-- | The three disjoint parts of a dataset.
data Split = Train | Validation | Holdout
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON Split where
  toJSON = String . \case Train -> "train"; Validation -> "validation"; Holdout -> "holdout"

instance FromJSON Split where
  parseJSON = withText "Split" $ \case
    "train" -> pure Train
    "validation" -> pure Validation
    "holdout" -> pure Holdout
    other -> fail ("unknown split: " <> T.unpack other)

-- | What an adapter produces: an example without a split.
data EvidenceRecord = EvidenceRecord
  { exampleId :: !Text,
    groupKey :: !Text,
    input :: !Value,
    expected :: !(Maybe Value),
    label :: !(Maybe Label),
    source :: !EvidenceSource,
    critiques :: ![Critique]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceRecord where toJSON = genericToJSON evidenceOptions

instance FromJSON EvidenceRecord where parseJSON = genericParseJSON evidenceOptions

-- | One sealed example: a record and the split it was assigned. In JSON the
-- record's fields and @split@ sit in one object. The record's fields are also
-- readable directly, as @example.exampleId@.
data EvidenceExample = EvidenceExample
  { split :: !Split,
    record :: !EvidenceRecord
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceExample where
  toJSON e = mergeObjects [toJSON e.record, object ["split" .= e.split]]

instance FromJSON EvidenceExample where
  parseJSON = withObject "EvidenceExample" $ \o -> EvidenceExample <$> o .: "split" <*> parseJSON (withoutKeys ["split"] o)

instance HasField "exampleId" EvidenceExample Text where getField e = e.record.exampleId

instance HasField "groupKey" EvidenceExample Text where getField e = e.record.groupKey

instance HasField "input" EvidenceExample Value where getField e = e.record.input

instance HasField "expected" EvidenceExample (Maybe Value) where getField e = e.record.expected

instance HasField "label" EvidenceExample (Maybe Label) where getField e = e.record.label

instance HasField "source" EvidenceExample EvidenceSource where getField e = e.record.source

instance HasField "critiques" EvidenceExample [Critique] where getField e = e.record.critiques

-- | The production window and query that selected the records.
data Collection = Collection
  { windowStart :: !UTCTime,
    windowEnd :: !UTCTime,
    selectionQuery :: !Text,
    selectionVersion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | How records were split. Shares are per mille of all examples, rounded up.
data SplitPolicy = SplitPolicy
  { splitPolicyId :: !Text,
    -- | the grouping dimension, such as @conversation@ or @incident@
    groupingKey :: !Text,
    salt :: !Text,
    validationPerMille :: !Int,
    holdoutPerMille :: !Int,
    -- | a holdout smaller than this makes every comparison @Invalid@
    minHoldoutExamples :: !Int,
    holdoutExposureLimit :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Every envelope field except the redaction policy, the examples and the
-- digest.
data DatasetSpec = DatasetSpec
  { datasetId :: !Text,
    agent :: !Text,
    -- | the eligible behavior versions, non-empty
    behaviorVersions :: ![Text],
    inputSchemaDigest :: !Digest,
    outputSchemaDigest :: !Digest,
    collection :: !Collection,
    splitPolicy :: !SplitPolicy,
    retentionPolicyId :: !Text,
    createdAt :: !UTCTime,
    createdBy :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The sealed dataset envelope. In JSON the spec's fields sit at the top level
-- beside @artifactKind@, @schemaVersion@, @redactionPolicyId@, @examples@ and
-- @contentDigest@, and they are also readable directly, as @dataset.splitPolicy@.
data EvidenceDataset = EvidenceDataset
  { artifactKind :: !Text,
    schemaVersion :: !Int,
    spec :: !DatasetSpec,
    redactionPolicyId :: !Text,
    examples :: ![EvidenceExample],
    contentDigest :: !Digest
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceDataset where
  toJSON d =
    mergeObjects
      [ toJSON d.spec,
        object
          [ "artifactKind" .= d.artifactKind,
            "schemaVersion" .= d.schemaVersion,
            "redactionPolicyId" .= d.redactionPolicyId,
            "examples" .= d.examples,
            "contentDigest" .= d.contentDigest
          ]
      ]

instance FromJSON EvidenceDataset where
  parseJSON = withObject "EvidenceDataset" $ \o ->
    EvidenceDataset
      <$> o .: "artifactKind"
      <*> o .: "schemaVersion"
      <*> parseJSON (withoutKeys ["artifactKind", "schemaVersion", "redactionPolicyId", "examples", "contentDigest"] o)
      <*> o .: "redactionPolicyId"
      <*> o .: "examples"
      <*> o .: "contentDigest"

instance HasField "datasetId" EvidenceDataset Text where getField d = d.spec.datasetId

instance HasField "agent" EvidenceDataset Text where getField d = d.spec.agent

instance HasField "behaviorVersions" EvidenceDataset [Text] where getField d = d.spec.behaviorVersions

instance HasField "inputSchemaDigest" EvidenceDataset Digest where getField d = d.spec.inputSchemaDigest

instance HasField "outputSchemaDigest" EvidenceDataset Digest where getField d = d.spec.outputSchemaDigest

instance HasField "splitPolicy" EvidenceDataset SplitPolicy where getField d = d.spec.splitPolicy

instance HasField "createdAt" EvidenceDataset UTCTime where getField d = d.spec.createdAt

-- | The @artifactKind@ of a dataset envelope.
datasetKind :: Text
datasetKind = "shikumi.evidence.dataset"

-- | A redaction policy: its id, a rewriting function applied to every text leaf
-- of inputs, expected outputs, critiques and label fields, and a predicate naming
-- content that must not remain after rewriting.
data RedactionPolicy = RedactionPolicy
  { redactionId :: !Text,
    rewriteText :: Text -> Text,
    prohibited :: Text -> Bool
  }

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

-- | Every problem a dataset can have. Validation reports all of them.
data DatasetError
  = MalformedDataset !Text
  | WrongDatasetKind !Text
  | UnsupportedDatasetVersion !Int
  | DatasetDigestMismatch !Digest !Digest
  | EmptyIdentifier !Text
  | DuplicateExampleId !Text
  | GroupCrossesSplits !Text
  | InputCrossesSplits ![Text]
  | LabelWithoutExpected !Text
  | ExpectedWithoutLabel !Text
  | InvalidLabelConfidence !Text
  | CritiqueOutsideTraining !Text
  | MultipleProgramCritiques !Text
  | InvalidCritiqueNode !Text !Text
  | NoBehaviorVersions
  | InvalidSplitPolicy !Text
  | HoldoutTooSmall !Int !Int
  | ProhibitedContent !Text
  | SchemaDigestMismatch !Text
  | ExampleDecodeFailure !Text !Text
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------

-- | Redact, split, validate and seal adapter records. Record order is kept.
sealDataset :: DatasetSpec -> RedactionPolicy -> [EvidenceRecord] -> Either [DatasetError] EvidenceDataset
sealDataset spec policy records = do
  let redacted = map (redactRecord (policy.rewriteText)) records
      leaks = [ProhibitedContent (rid r) | r <- redacted, any policy.prohibited (recordTexts r)]
  unless (null leaks) (Left leaks)
  let splits = assignSplits spec.splitPolicy redacted
      unsealed =
        EvidenceDataset
          { artifactKind = datasetKind,
            schemaVersion = 1,
            spec = spec,
            redactionPolicyId = policy.redactionId,
            examples = zipWith EvidenceExample splits redacted,
            contentDigest = Digest ""
          }
      sealed = resealDataset unsealed
  sealed <$ validateDataset sealed
  where
    rid (EvidenceRecord {exampleId = i}) = i

-- | Recompute and store a dataset's digest, for tooling that edits an
-- envelope deliberately. 'validateDataset' still applies to the result.
resealDataset :: EvidenceDataset -> EvidenceDataset
resealDataset = sealEnvelope (\d e -> e {contentDigest = d})

redactRecord :: (Text -> Text) -> EvidenceRecord -> EvidenceRecord
redactRecord f (EvidenceRecord i g inp ex l src cs) =
  EvidenceRecord i g (redactValue f inp) (redactValue f <$> ex) (redactLabel <$> l) src (map redactCritique cs)
  where
    redactLabel (Label k a t c d rr) = Label k (f a) t c (f <$> d) (f <$> rr)
    redactCritique (Critique n t k a w) = Critique n (f t) k (f a) w

redactValue :: (Text -> Text) -> Value -> Value
redactValue f = \case
  String t -> String (f t)
  Array xs -> Array (fmap (redactValue f) xs)
  Object o -> Object (fmap (redactValue f) o)
  v -> v

recordTexts :: EvidenceRecord -> [Text]
recordTexts r =
  valueTexts r.input
    ++ maybe [] valueTexts r.expected
    ++ maybe [] (\(Label _ a _ _ d rr) -> a : mapMaybe id [d, rr]) r.label
    ++ concat [[t, a] | Critique _ t _ a _ <- r.critiques]

valueTexts :: Value -> [Text]
valueTexts = \case
  String t -> [t]
  Array xs -> concatMap valueTexts xs
  Object o -> concatMap valueTexts (KM.elems o)
  _ -> []

-- | Deterministic, group-preserving split assignment, one split per record in
-- record order. Records that share a group key, or whose canonical inputs are
-- identical, form one component. Components are ordered by the BLAKE3 digest of
-- the salt and the component's smallest group key, then assigned to the holdout
-- until it holds at least its per-mille share of all records (rounded up), then
-- to validation likewise, and the rest to training.
assignSplits :: SplitPolicy -> [EvidenceRecord] -> [Split]
assignSplits sp records = [Map.findWithDefault Train ix bySplit | ix <- [0 .. n - 1]]
  where
    n = length records
    indexed = zip [0 :: Int ..] records
    groupEdges = Map.elems (Map.fromListWith (++) [(r.groupKey, [ix]) | (ix, r) <- indexed])
    inputEdges = Map.elems (Map.fromListWith (++) [(canonicalJSON r.input, [ix]) | (ix, r) <- indexed])
    adjacency = Map.fromListWith (++) [(a, filter (/= a) members) | members <- groupEdges ++ inputEdges, a <- members]
    components = go Set.empty [0 .. n - 1]
      where
        go _ [] = []
        go seen (x : xs)
          | Set.member x seen = go seen xs
          | otherwise =
              let comp = flood (Set.singleton x) [x]
               in Set.toList comp : go (Set.union seen comp) xs
        flood acc [] = acc
        flood acc (y : ys) =
          let next = [z | z <- Map.findWithDefault [] y adjacency, Set.notMember z acc]
           in flood (foldr Set.insert acc next) (next ++ ys)
    keyOf comp = minimum [(records !! ix).groupKey | ix <- comp]
    ordered = sortOn (\comp -> (digestBytes (encodeUtf8 (sp.salt <> "\n" <> keyOf comp)), keyOf comp)) components
    share perMille = (perMille * n + 999) `div` 1000
    holdoutTarget = share (max 0 sp.holdoutPerMille)
    validationTarget = share (max 0 sp.validationPerMille)
    assign _ _ [] = []
    assign h v (comp : rest)
      | h < holdoutTarget = (comp, Holdout) : assign (h + length comp) v rest
      | v < validationTarget = (comp, Validation) : assign h (v + length comp) rest
      | otherwise = (comp, Train) : assign h v rest
    assigned = assign 0 0 ordered
    bySplit = Map.fromList [(ix, s) | (comp, s) <- assigned, ix <- comp]

-- ---------------------------------------------------------------------------
-- Reading and validation
-- ---------------------------------------------------------------------------

-- | Decode a dataset envelope: the digest is checked on the raw JSON value, the
-- envelope must round-trip exactly, and it must validate.
decodeDataset :: BL.ByteString -> Either [DatasetError] EvidenceDataset
decodeDataset bytes = do
  (_, ds) <- either (Left . (: []) . MalformedDataset) Right (decodeEnvelope True bytes)
  ds <$ validateDataset ds

-- | Validate any envelope, whether or not 'sealDataset' produced it. Returns
-- every problem found.
validateDataset :: EvidenceDataset -> Either [DatasetError] ()
validateDataset ds = if null problems then Right () else Left problems
  where
    exs = ds.examples
    sp = ds.splitPolicy
    computed = envelopeDigest (toJSON ds)
    problems =
      [WrongDatasetKind ds.artifactKind | ds.artifactKind /= datasetKind]
        ++ [UnsupportedDatasetVersion ds.schemaVersion | ds.schemaVersion /= 1]
        ++ [DatasetDigestMismatch ds.contentDigest computed | ds.contentDigest /= computed]
        ++ [NoBehaviorVersions | null ds.behaviorVersions]
        ++ [EmptyIdentifier "datasetId" | T.null ds.datasetId]
        ++ policyProblems
        ++ concatMap exampleProblems exs
        ++ [DuplicateExampleId i | (i, c) <- Map.toList (Map.fromListWith (+) [(e.exampleId, 1 :: Int) | e <- exs]), c > 1]
        ++ [GroupCrossesSplits g | (g, ss) <- Map.toList (splitsBy (.groupKey)), Set.size ss > 1]
        ++ [ InputCrossesSplits [e.exampleId | e <- exs, canonicalJSON e.input == k]
           | (k, ss) <- Map.toList (splitsBy (canonicalJSON . (.input))),
             Set.size ss > 1
           ]
        ++ [HoldoutTooSmall holdoutCount sp.minHoldoutExamples | holdoutCount < sp.minHoldoutExamples]
    splitsBy :: (Ord k) => (EvidenceExample -> k) -> Map.Map k (Set.Set Split)
    splitsBy f = Map.fromListWith Set.union [(f e, Set.singleton e.split) | e <- exs]
    holdoutCount = length [() | e <- exs, e.split == Holdout]
    policyProblems =
      [ InvalidSplitPolicy msg
      | (bad, msg) <-
          [ (T.null sp.splitPolicyId, "splitPolicyId is empty"),
            (sp.validationPerMille < 0 || sp.holdoutPerMille < 0, "per-mille shares must be nonnegative"),
            (sp.validationPerMille + sp.holdoutPerMille > 1000, "validation and holdout shares exceed 1000 per mille"),
            (sp.minHoldoutExamples < 0, "minHoldoutExamples must be nonnegative"),
            (sp.holdoutExposureLimit < 0, "holdoutExposureLimit must be nonnegative")
          ],
        bad
      ]
    exampleProblems e =
      [EmptyIdentifier "exampleId" | T.null e.exampleId]
        ++ [EmptyIdentifier ("groupKey of " <> e.exampleId) | T.null e.groupKey]
        ++ [LabelWithoutExpected e.exampleId | isJust e.label, isNothing e.expected]
        ++ [ExpectedWithoutLabel e.exampleId | isJust e.expected, isNothing e.label]
        ++ [ InvalidLabelConfidence e.exampleId
           | Just (Label {confidence = Just c}) <- [e.label],
             not (finite c && c >= 0 && c <= 1)
           ]
        ++ [CritiqueOutsideTraining e.exampleId | not (null e.critiques), e.split /= Train]
        ++ [MultipleProgramCritiques e.exampleId | length [() | c <- e.critiques, isNothing c.node] > 1]
        ++ [InvalidCritiqueNode e.exampleId p | Critique {node = Just p} <- e.critiques, isNothing (parseNodePath p)]

-- | The number of training, validation and holdout examples.
datasetSplitCounts :: EvidenceDataset -> (Int, Int, Int)
datasetSplitCounts ds = (count Train, count Validation, count Holdout)
  where
    count s = length [() | e <- ds.examples, e.split == s]

-- | Invert 'Shikumi.Trace.Node.renderNodePath'.
parseNodePath :: Text -> Maybe NodePath
parseNodePath "root" = Just (NodePath [])
parseNodePath t = NodePath <$> mapM step (T.splitOn "/" t)
  where
    step = \case
      "compose.l" -> Just StepComposeL
      "compose.r" -> Just StepComposeR
      "fmap" -> Just StepFMap
      "map" -> Just StepMap
      "parallel.l" -> Just StepParallelL
      "parallel.r" -> Just StepParallelR
      "retry" -> Just StepRetry
      "retryWhen" -> Just StepRetryWhen
      "validate" -> Just StepValidate
      "majorityVote" -> Just StepMajorityVote
      s -> T.stripPrefix "ensemble." s >>= fmap StepEnsemble . readMaybe . T.unpack

-- ---------------------------------------------------------------------------
-- Typed access
-- ---------------------------------------------------------------------------

-- | How a program's input and output types read dataset JSON, and the schemas
-- whose digests the envelope must carry.
data EvidenceCodec i o = EvidenceCodec
  { decodeInput :: Value -> Either Text i,
    decodeExpected :: Value -> Either Text o,
    inputSchema :: Value,
    outputSchema :: Value
  }

-- | A codec from the program's own 'FromModel' and 'ToSchema' instances, so the
-- dataset decodes values exactly as the program does.
modelEvidenceCodec :: forall i o. (FromModel i, ToSchema i, FromModel o, ToSchema o) => EvidenceCodec i o
modelEvidenceCodec =
  EvidenceCodec
    { decodeInput = either (Left . renderShikumiError) Right . fromModel,
      decodeExpected = either (Left . renderShikumiError) Right . fromModel,
      inputSchema = deriveSchema @i,
      outputSchema = deriveSchema @o
    }

-- | Validate an envelope, check its schema digests against the codec's, and
-- decode every example. Only labeled examples enter the training and validation
-- datasets.
openDataset :: EvidenceCodec i o -> EvidenceDataset -> Either [DatasetError] (SealedDataset i o)
openDataset codec ds = do
  validateDataset ds
  let schemaProblems =
        [SchemaDigestMismatch "input" | digestValue (codec.inputSchema) /= ds.inputSchemaDigest]
          ++ [SchemaDigestMismatch "output" | digestValue (codec.outputSchema) /= ds.outputSchemaDigest]
  unless (null schemaProblems) (Left schemaProblems)
  decoded <- collect $ forM' ds.examples $ \e -> do
    i <- either (Left . ExampleDecodeFailure e.exampleId . ("input: " <>)) Right (codec.decodeInput e.input)
    o <- forM e.expected (either (Left . ExampleDecodeFailure e.exampleId . ("expected: " <>)) Right . codec.decodeExpected)
    pure (e, i, o)
  let labeled s = [(e.exampleId, Example i o) | (e, i, Just o) <- decoded, e.split == s]
      missing s = length [() | (e, _, Nothing) <- decoded, e.split == s]
  crits <- forM [(e, c) | e <- ds.examples, e.split == Train, c <- e.critiques] $ \(e, c) -> do
    path <- forM c.node $ \p -> maybe (Left [InvalidCritiqueNode e.exampleId p]) Right (parseNodePath p)
    pure (StoredCritique e.exampleId path c.text (labelProvenance c.kind) c.author)
  pure
    SealedDataset
      { trainingExamples = labeled Train,
        validationExamples = labeled Validation,
        holdoutExamples = [HoldoutExample e.exampleId i o | (e, i, o) <- decoded, e.split == Holdout],
        storedCritiques = crits,
        missingTrainingLabels = missing Train,
        missingValidationLabels = missing Validation
      }
  where
    forM' xs f = map f xs
    collect results = case lefts results of
      [] -> Right [r | Right r <- results]
      errs -> Left (nub errs)

-- | The labeled training examples the optimizer may inspect.
sealedTraining :: SealedDataset i o -> Dataset i o
sealedTraining s = dataset (map snd s.trainingExamples)

-- | The labeled validation examples, which may only rank candidates.
sealedValidation :: SealedDataset i o -> Dataset i o
sealedValidation s = dataset (map snd s.validationExamples)

-- | Training example ids, aligned position for position with 'sealedTraining'.
sealedTrainingIds :: SealedDataset i o -> [Text]
sealedTrainingIds s = map fst s.trainingExamples

-- | The critiques stored with training examples, keyed by example id.
sealedTrainingCritiques :: SealedDataset i o -> [StoredCritique]
sealedTrainingCritiques s = s.storedCritiques
