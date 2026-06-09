-- | M4: 'Shikumi.Signature'. Field metadata is derived from the record types
-- (matching the schema), and the instruction/demos are first-class replaceable
-- parameters (read back what you write).
module SignatureSpec (tests) where

import Fixtures (Article, Summary, sampleArticle, sampleSummary)
import Shikumi.Schema.Types (FieldMeta (..))
import Shikumi.Signature
  ( Demo (..),
    Signature,
    getDemos,
    getInstruction,
    inputFields,
    mkSignature,
    outputFields,
    setDemos,
    setInstruction,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

sig0 :: Signature Article Summary
sig0 = mkSignature "Summarize the article"

tests :: TestTree
tests =
  testGroup
    "SignatureSpec"
    [ testCase "instruction is the one supplied" $
        getInstruction sig0 @?= "Summarize the article",
      testCase "demos start empty" $
        getDemos sig0 @?= [],
      testCase "input field metadata is derived from the input record" $
        inputFields sig0
          @?= [ FieldMeta "title" (Just "The article's headline"),
                FieldMeta "body" (Just "The full article text")
              ],
      testCase "output field metadata matches the output record (descriptions and all)" $
        outputFields sig0
          @?= [ FieldMeta "headline" (Just "A one-line summary"),
                FieldMeta "bullets" (Just "Three to five key points"),
                FieldMeta "author" Nothing,
                FieldMeta "sentiment" Nothing,
                FieldMeta "note" Nothing
              ],
      testCase "instruction is replaceable" $
        getInstruction (setInstruction "New instruction" sig0) @?= "New instruction",
      testCase "demos are replaceable" $
        getDemos (setDemos [Demo sampleArticle sampleSummary] sig0)
          @?= [Demo sampleArticle sampleSummary]
    ]
