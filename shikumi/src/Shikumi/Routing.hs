{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | Ambient model routing (EP-14) — the keystone that lets
-- 'Shikumi.Program.runProgram' dispatch a /named/ model without changing its
-- pinned signature (MasterPlan integration point #4:
-- @runProgram :: (LLM :> es, Error ShikumiError :> es) => Program i o -> i -> Eff es o@).
--
-- The mechanism is approach (a) from the parent MasterPlan: a re-interpreting
-- router installed /below/ 'Shikumi.Program.runProgram' on the existing @LLM@
-- effect — exactly the seam @cachedLLM@ ("Shikumi.Cache") and @tracedLLM@
-- ("Shikumi.Trace") already use. 'runProgram' renders each 'Predict' node
-- model-agnostically against the inert placeholder model and stamps its intentions
-- (the derived JSON schema, any per-sample temperature, and the native-format render
-- alternative — system prompt + JSON demos) onto the private request-metadata
-- channel ('Shikumi.Adapter.attachSchema' / 'Shikumi.Adapter.stampTemperature' /
-- 'Shikumi.Adapter.attachNativeRender'). 'routeLLM' then reads the /ambient/ model
-- supplied by 'runRouting', overwrites the placeholder with it, and calls
-- 'translateForWire', which for a native-capable model sets
-- @Options.responseFormat@ from the stamped schema and swaps the marker @Context@
-- (system prompt + demo assistant turns) for the stamped native-format alternative;
-- sets @Options.temperature@ when stamped; and in all cases strips the private keys
-- before forwarding the call to the real @LLM@ interpreter beneath it.
--
-- Install order (mirroring @runTrace . runKeyedLLM . tracedLLM@): 'runRouting' is
-- /outer/ of the real @LLM@ interpreter, which is /outer/ of 'routeLLM' (the
-- innermost, closest to 'runProgram'). For example:
--
-- @
-- runEff
--   . runErrorNoCallStack \@ShikumiError
--   . runRouting openai_gpt_4o_mini   -- supplies the ambient model
--   . runLLMResilient cfg             -- the real LLM interpreter (or a stub)
--   . routeLLM                        -- rewrites outgoing LLM calls
--   $ runProgram program input
-- @
module Shikumi.Routing
  ( -- * The effect
    Routing (..),
    currentModel,
    runRouting,

    -- * The router
    routeLLM,
  )
where

import Baikai (Context, Message (..), Model, Options, ResponseFormat (..), assistant)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (FromJSON, Result (..), Value, fromJSON)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (interpose, interpret, passthrough, send)
import Shikumi.Adapter
  ( ModelCapability (..),
    capabilityFor,
    metaNativeDemosKey,
    metaNativePromptKey,
    metaResponseSchemaKey,
    metaTemperatureKey,
  )
import Shikumi.LLM (LLM (..), complete)

-- | The ambient model-routing effect. Its single operation reads the model every
-- 'Predict' node should dispatch against. It is supplied by an interpreter at the
-- bottom of the stack ('runRouting'), exactly as @LLM@ and @Error@ already are, so
-- it never appears in 'Shikumi.Program.runProgram'\'s constraint row.
data Routing :: Effect where
  CurrentModel :: Routing m Model

type instance DispatchOf Routing = 'Dynamic

-- | Read the ambient model.
currentModel :: (Routing :> es) => Eff es Model
currentModel = send CurrentModel

-- | Supply a constant ambient model to everything above. A pure reader: every
-- 'currentModel' resolves to @m@.
runRouting :: Model -> Eff (Routing : es) a -> Eff es a
runRouting m = interpret (\_ CurrentModel -> pure m)

-- | The router. Re-interpret the @LLM@ effect so each outgoing 'Complete' is
-- dispatched against the ambient model (overwriting the placeholder model the
-- model-agnostic 'Shikumi.Program.runProgram' passes), with the private metadata
-- channel translated to real wire options and stripped. 'Stream' is forwarded
-- unchanged ('runProgram' never streams).
routeLLM :: (Routing :> es, LLM :> es) => Eff es a -> Eff es a
routeLLM = interpose $ \env -> \case
  Complete _placeholder ctx opts -> do
    m <- currentModel
    let (ctx', opts') = translateForWire m ctx opts
    complete m ctx' opts'
  other -> passthrough env other

-- | Realize the private request-metadata channel against the real model. For a
-- native-capable model: attach the native @responseFormat@ from the stamped
-- schema, and swap the marker-format 'Context' (system prompt + demo assistant
-- turns) for the stamped native-format alternative. In all cases: set
-- @temperature@ when one was stamped, and strip every private @shikumi.*@ key so
-- nothing private reaches the transport. Fallback-capability models keep the
-- marker 'Context' unchanged; non-'Predict' @Complete@ calls (no stamps) are never
-- rewritten.
translateForWire :: Model -> Context -> Options -> (Context, Options)
translateForWire m ctx opts =
  let md = opts ^. #metadata
      mSchema = Map.lookup metaResponseSchemaKey md
      mTemp = Map.lookup metaTemperatureKey md >>= valueToDouble
      mNativeSys = Map.lookup metaNativePromptKey md >>= fromJSONMaybe
      mNativeDemos = Map.lookup metaNativeDemosKey md >>= fromJSONMaybe
      stripped =
        foldr
          Map.delete
          md
          [metaResponseSchemaKey, metaTemperatureKey, metaNativePromptKey, metaNativeDemosKey]
      isNative = case capabilityFor m of NativeSchema -> True; PromptFallback -> False
      withSchema o
        | isNative,
          Just s <- mSchema =
            o & #responseFormat .~ Just (JsonSchema {name = "output", schema = s, strict = True})
        | otherwise = o
      withTemp o = case mTemp of
        Just t -> o & #temperature .~ Just t
        Nothing -> o
      opts' = withTemp (withSchema (opts & #metadata .~ stripped))
      ctx' = case (isNative, mNativeSys, mNativeDemos) of
        (True, Just sys, Just demos) -> rewriteNativeContext sys demos ctx
        _ -> ctx
   in (ctx', opts')

-- | Install the native-format system prompt and demo assistant turns into a
-- 'Context'. The assistant turns of a 'Predict'-rendered context are exactly the
-- demo outputs, in order; each is replaced (via baikai's deterministic 'assistant'
-- constructor) with the corresponding stamped native text. Defensive: if the count
-- of assistant turns differs from the stamped list length the messages are left
-- untouched (only the system prompt is swapped), so a hand-built or unexpected
-- context is never corrupted.
rewriteNativeContext :: Text -> [Text] -> Context -> Context
rewriteNativeContext sys demos ctx =
  let msgs = V.toList (ctx ^. #messages)
      assistantCount = length [() | AssistantMessage _ <- msgs]
      msgs'
        | assistantCount == length demos = replaceAssistants demos msgs
        | otherwise = msgs
   in ctx & #systemPrompt .~ Just sys & #messages .~ V.fromList msgs'

-- | Replace each assistant message's text with the next demo text, in order,
-- preserving all user/tool messages. Total: if the demo list runs out, remaining
-- assistant messages are kept as-is.
replaceAssistants :: [Text] -> [Message] -> [Message]
replaceAssistants _ [] = []
replaceAssistants ds (m : rest) = case m of
  AssistantMessage _ -> case ds of
    (d : ds') -> assistant d : replaceAssistants ds' rest
    [] -> m : replaceAssistants ds rest
  _ -> m : replaceAssistants ds rest

-- | Read a JSON number back into a 'Double' (the per-sample temperature).
valueToDouble :: Value -> Maybe Double
valueToDouble v = case fromJSON v of
  Success d -> Just d
  Error _ -> Nothing

-- | Read a stamped JSON value back into a decodable Haskell value (the native
-- prompt 'Text' and the demo @[Text]@), returning 'Nothing' on any mismatch.
fromJSONMaybe :: (FromJSON a) => Value -> Maybe a
fromJSONMaybe v = case fromJSON v of
  Success a -> Just a
  Error _ -> Nothing
