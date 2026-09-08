-- | Invocation-scoped, fill-only defaults for every LLM operation.
-- Compose the base interpreter with cache/trace, then 'withRequestDefaults',
-- then routing. The rightmost wrapper sees the originating call first.
module Shikumi.LLM.Defaults
  ( RequestDefaults (..),
    emptyRequestDefaults,
    applyRequestDefaults,
    withRequestDefaults,
  )
where

import Baikai (Options)
import Baikai.Evidence (EvidenceRequest)
import Baikai.Speed (Speed)
import Baikai.ThinkingLevel (ThinkingLevel)
import Control.Applicative ((<|>))
import Control.Lens ((&), (.~), (^.))
import Control.Monad (when)
import Data.Generics.Labels ()
import Effectful (Eff, (:>))
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Error.Static (Error, throwError)
import Numeric.Natural (Natural)
import Shikumi.Error (ShikumiError (ValidationFailure))
import Shikumi.LLM (LLM (..), complete, stream)

-- | Only request preferences belong here. Models, schemas, tools, credentials,
-- temperatures and private continuation metadata remain owned by their callers.
-- Evidence is replaced as a whole; requested settings are not provider evidence.
data RequestDefaults = RequestDefaults
  { defaultThinking :: !(Maybe ThinkingLevel),
    defaultSpeed :: !(Maybe Speed),
    defaultMaxTokens :: !(Maybe Natural),
    defaultEvidence :: !(Maybe EvidenceRequest)
  }
  deriving stock (Eq, Show)

-- | No implicit reasoning, fast mode, token ceiling or evidence collection.
emptyRequestDefaults :: RequestDefaults
emptyRequestDefaults = RequestDefaults Nothing Nothing Nothing Nothing

-- | Fill absent options only. This pure merge does not validate token ceilings;
-- use 'withRequestDefaults' to reject a zero configured default before execution.
applyRequestDefaults :: RequestDefaults -> Options -> Options
applyRequestDefaults defaults opts =
  opts
    & #thinking .~ (opts ^. #thinking <|> defaultThinking defaults)
    & #speed .~ (opts ^. #speed <|> defaultSpeed defaults)
    & #maxTokens .~ (opts ^. #maxTokens <|> defaultMaxTokens defaults)
    & #evidence .~ (opts ^. #evidence <|> defaultEvidence defaults)

-- | Apply the same merge to blocking and streaming calls. Per-call values win;
-- the innermost default scope fills first and therefore wins over outer scopes.
-- A zero default ceiling is invalid even when a call supplies its own ceiling.
-- No mutable state is shared between invocations.
withRequestDefaults :: (LLM :> es, Error ShikumiError :> es) => RequestDefaults -> Eff es a -> Eff es a
withRequestDefaults defaults action = do
  when (defaultMaxTokens defaults == Just 0) $
    throwError (ValidationFailure "request defaults: defaultMaxTokens must be positive")
  interpose
    ( \_ -> \case
        Complete model ctx opts -> complete model ctx (applyRequestDefaults defaults opts)
        Stream model ctx opts -> stream model ctx (applyRequestDefaults defaults opts)
    )
    action
