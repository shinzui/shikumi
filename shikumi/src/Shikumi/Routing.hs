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
-- (the derived JSON schema, and any per-sample temperature) onto the private
-- request-metadata channel ('Shikumi.Adapter.attachSchema' /
-- 'Shikumi.Adapter.stampTemperature'). 'routeLLM' then reads the /ambient/ model
-- supplied by 'runRouting', overwrites the placeholder with it, translates the
-- stamped metadata into @Options.responseFormat@ (for native-capable models only)
-- and @Options.temperature@, strips the private keys, and forwards the call to the
-- real @LLM@ interpreter beneath it.
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

import Baikai (Model, Options, ResponseFormat (..))
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Result (..), Value, fromJSON)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (interpose, interpret, passthrough, send)
import Shikumi.Adapter
  ( ModelCapability (..),
    capabilityFor,
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
    complete m ctx (translateForWire m opts)
  other -> passthrough env other

-- | Realize the private request-metadata channel against the real model: attach a
-- native @responseFormat@ when the schema was stamped /and/ the model is
-- native-capable; set @temperature@ when one was stamped; then strip both private
-- keys so nothing private reaches the transport.
translateForWire :: Model -> Options -> Options
translateForWire m opts =
  let md = opts ^. #metadata
      mSchema = Map.lookup metaResponseSchemaKey md
      mTemp = Map.lookup metaTemperatureKey md >>= valueToDouble
      stripped = Map.delete metaResponseSchemaKey (Map.delete metaTemperatureKey md)
      withSchema o = case (mSchema, capabilityFor m) of
        (Just s, NativeSchema) ->
          o & #responseFormat .~ Just (JsonSchema {name = "output", schema = s, strict = True})
        _ -> o
      withTemp o = case mTemp of
        Just t -> o & #temperature .~ Just t
        Nothing -> o
   in withTemp (withSchema (opts & #metadata .~ stripped))

-- | Read a JSON number back into a 'Double' (the per-sample temperature).
valueToDouble :: Value -> Maybe Double
valueToDouble v = case fromJSON v of
  Success d -> Just d
  Error _ -> Nothing
