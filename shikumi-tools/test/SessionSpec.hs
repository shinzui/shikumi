module SessionSpec (tests) where

import Data.Aeson (Value (..), object, (.=))
import Data.Text qualified as T
import Shikumi.CodeExec.Session
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

setup :: SessionConfig -> [(T.Text, T.Text)] -> IO SessionState
setup c ds = either (\e -> assertFailure (show e) >> fail "setup") pure (contextStore ds >>= newSession c)

observation :: Either SessionLimit SessionResult -> IO SessionObservation
observation (Right (Observed o)) = pure o
observation x = assertFailure (show x) >> fail "observation"

tests :: TestTree
tests =
  testGroup
    "bounded session"
    [ testCase "variables persist, sources cannot be shadowed, sessions isolate" $ do
        s <- setup defaultSessionConfig [("doc", "hello")]
        let (s1, _) = stepSession s (Right (Store "memo" (String "remember")))
            (s2, rejected) = stepSession s1 (Right (Store "doc" Null))
        o <- observation rejected
        assertBool "shadow rejected" (observationError o /= Nothing)
        snd (stepSession s2 (Right (Load "memo"))) @?= Right (Observed (SessionObservation (String "remember") Nothing Nothing))
        isolated <- observation (snd (stepSession s (Right (Load "memo"))))
        assertBool "private variable" (observationError isolated /= Nothing)
        operationCount s2 @?= 2,
      testCase "Unicode slices use character offsets and empty documents work" $ do
        s <- setup defaultSessionConfig [("doc", "a😀界z"), ("empty", "")]
        o <- observation (snd (stepSession s (Right (Slice "doc" 1 2))))
        observationValue o @?= object ["name" .= ("doc" :: T.Text), "start" .= (1 :: Int), "end" .= (3 :: Int), "text" .= ("😀界" :: T.Text)]
        e <- observation (snd (stepSession s (Right (Slice "empty" 0 0))))
        observationError e @?= Nothing,
      testCase "invalid offsets, unknown names and builtins consume operations" $ do
        s <- setup defaultSessionConfig [("doc", "abc")]
        mapM_
          ( \a -> do
              let (s1, r) = stepSession s (Right a)
              o <- observation r
              assertBool (show a) (observationError o /= Nothing)
              operationCount s1 @?= 1
          )
          [Slice "doc" (-1) 1, Slice "doc" 4 0, Slice "doc" 1 3, Find "doc" "" 0 1, Find "doc" "a" 0 0, Load "absent", Describe "absent", Store "slice" Null],
      testCase "find scans bounded text and supports overlap and continuation" $ do
        s <- setup (defaultSessionConfig {maxScanChars = 4}) [("doc", "aaaaXYZ")]
        o <- observation (snd (stepSession s (Right (Find "doc" "aa" 0 2))))
        observationValue o @?= object ["matches" .= ([0, 1] :: [Int]), "scannedEnd" .= (4 :: Int), "nextOffset" .= (2 :: Int), "complete" .= False],
      testCase "stored character budget includes all values and names; rejection is atomic" $ do
        s <- setup (defaultSessionConfig {maxStoredChars = 10}) []
        let (s1, _) = stepSession s (Right (Store "x" (String "ok")))
            (s2, r) = stepSession s1 (Right (Store "x" (String (T.replicate 20 "x"))))
        o <- observation r
        assertBool "oversized rejected" (observationError o /= Nothing)
        snd (stepSession s2 (Right (Load "x"))) @?= snd (stepSession s1 (Right (Load "x"))),
      testCase "all limits must be positive and oversized contexts are refused" $ do
        let updates = [\c -> c {maxContextChars = 0}, \c -> c {maxStoredChars = (-1)}, \c -> c {maxActionBytes = 0}, \c -> c {maxObservationChars = 0}, \c -> c {maxObservedChars = 0}, \c -> c {maxOperations = 0}, \c -> c {maxScanChars = 0}, \c -> c {maxMatches = 0}, \c -> c {maxSubqueries = 0}, \c -> c {maxSubqueryChars = 0}]
        mapM_ (\f -> assertBool "invalid config" (validateSessionConfig (f defaultSessionConfig) /= Right ())) updates
        case contextStore [("d", "oversized")] >>= newSession (defaultSessionConfig {maxContextChars = 2}) of
          Left _ -> pure ()
          Right _ -> assertFailure "context admitted",
      testCase "UTF8 byte limit and malformed JSON are recoverable" $ do
        let c = defaultSessionConfig {maxActionBytes = 10}
        s <- setup c []
        mapM_
          ( \raw -> do
              let (s1, r) = stepSession s (parseSessionAction c raw)
              o <- observation r
              assertBool "parse error" (observationError o /= Nothing)
              operationCount s1 @?= 1
          )
          ["😀😀😀", "{", "{\"op\":1}"],
      testCase "observation bounds include escaping and truncation metadata" $ do
        s <- setup (defaultSessionConfig {maxObservationChars = 200, maxObservedChars = 250}) []
        let (s1, r) = recordObservation s (SessionObservation (String (T.replicate 1000 "\n")) Nothing Nothing)
        case r of
          Left e -> assertFailure (show e)
          Right o -> do
            assertBool "marked" (truncation o /= Nothing)
            assertBool "serialized bound" (T.length (renderObservation o) <= 200)
            observedChars s1 @?= T.length (renderObservation o)
            snd (recordObservation s1 o) @?= Left ObservationCharacters,
      testCase "truncated Unicode slices retain source offsets and can resume" $ do
        s <- setup (defaultSessionConfig {maxObservationChars = 250}) [("doc", T.replicate 1000 "😀\n")]
        o <- observation (snd (stepSession s (Right (Slice "doc" 0 1000))))
        case snd (recordObservation s o) of
          Right bounded -> case truncation bounded of
            Just tr -> do
              assertBool "prefix is nonempty" (displayedChars tr > 0)
              nextOffset tr @?= Just (displayedChars tr)
              assertBool "serialized slice is bounded" (T.length (renderObservation bounded) <= 250)
              next <- observation (snd (stepSession s (Right (Slice "doc" (displayedChars tr) 2))))
              observationError next @?= Nothing
            Nothing -> assertFailure "missing slice truncation"
          Left e -> assertFailure (show e),
      testCase "subquery slots persist across actions and oversized prompts reserve none" $ do
        s <- setup (defaultSessionConfig {maxSubqueries = 2, maxSubqueryChars = 3}) []
        let (s1, r) = stepSession s (Right (Query "long"))
        o <- observation r
        assertBool "prompt rejected" (observationError o /= Nothing)
        let (s2, r2) = stepSession s1 (Right (Query "a"))
        r2 @?= Right (RunQueries ["a"])
        snd (stepSession s2 (Right (QueryBatch ["b", "c"]))) @?= Left Subqueries,
      testCase "operation exhaustion and whole batch reservation are exact" $ do
        s <- setup (defaultSessionConfig {maxOperations = 1, maxSubqueries = 2}) []
        snd (stepSession s (Right (QueryBatch ["a", "b", "c"]))) @?= Left Subqueries
        let (s1, r) = stepSession s (Right (QueryBatch ["a", "b"]))
        r @?= Right (RunQueries ["a", "b"])
        subqueryAttempts s1 @?= 0
        subqueryAttempts (attemptedSubquery (attemptedSubquery s1)) @?= 2
        snd (stepSession s1 (Right (Submit Null))) @?= Left Operations
    ]
