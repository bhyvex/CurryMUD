{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE LambdaCase, OverloadedStrings #-}

module Mud.Threads.FeelingTimer ( startFeeling
                                , stopFeelings
                                , threadFeelingTimer ) where

import Mud.Data.Misc
import Mud.Data.State.MudData
import Mud.Data.State.Util.Get
import Mud.Data.State.Util.Misc
import Mud.Threads.Misc
import Mud.TopLvlDefs.Misc
import Mud.Util.Misc
import Mud.Util.Operators
import Mud.Util.Quoting
import qualified Mud.Misc.Logging as L (logExMsg, logPla)

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, poll)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TMQueue (newTMQueueIO, tryReadTMQueue, writeTMQueue)
import Control.Exception (AsyncException(..), SomeException, fromException)
import Control.Exception.Lifted (catch, finally)
import Control.Lens.Operators ((%~), (.~))
import Control.Monad ((>=>), mapM_)
import Control.Monad.IO.Class (liftIO)
import Data.Monoid ((<>))
import Data.Text (Text)
import qualified Data.Map.Strict as M (delete, empty, insert, lookup, toList)
import qualified Data.Text as T


default (Int)


-----


logExMsg :: Text -> Text -> SomeException -> MudStack ()
logExMsg = L.logExMsg "Mud.Threads.FeelingTimer"


logPla :: Text -> Id -> Text -> MudStack ()
logPla = L.logPla "Mud.Threads.FeelingTimer"


-- ==================================================


startFeeling :: Id -> EffectFeeling -> FeelingVal -> MudStack ()
startFeeling i (EffectFeeling tag newDur) newV = getState >>= \ms ->
    let fm = getFeelingMap i ms in case M.lookup tag fm of
      Nothing -> do feel <- uncurry (Feeling newV newDur) <$> spawn
                    feelingMapHelper feel
                    logHelper . T.concat $ [ "started new feeling with tag ", dblQuote tag, ": ", pp feel, "." ]
      Just (Feeling _ existDur existQ existA) -- TODO: We need to be able to determine how many seconds remain for a running feeling.
        | newDur > existDur -> do
            liftIO . cancel $ existA
            feel <- uncurry (Feeling newV newDur) <$> spawn
            feelingMapHelper feel
            let msg = T.concat [ "feeling ", dblQuote tag, " has been restarted with a longer duration: ", pp feel, "." ]
            logHelper msg
        | otherwise -> liftIO (poll existA) >>= \case
          Nothing -> do liftIO . atomically . writeTMQueue existQ $ ResetTimer -- The async has not completed yet.
                        let feel = Feeling newV existDur existQ existA
                        feelingMapHelper feel
                        logRestart       feel
          _       -> do feel <- uncurry (Feeling newV existDur) <$> spawn -- The async has completed.
                        feelingMapHelper feel
                        logRestart       feel
  where
    spawn = do newQ <- liftIO newTMQueueIO
               newA <- runAsync . threadFeelingTimer i tag newDur $ newQ
               return (newQ, newA)
    feelingMapHelper feel = tweak $ mobTbl.ind i.feelingMap %~ M.insert tag feel
    logHelper             = logPla "startFeeling" i
    logRestart feel       = logHelper . T.concat $ [ "feeling ", dblQuote tag, " has been restarted: ", pp feel, "." ]


threadFeelingTimer :: Id -> FeelingTag -> Seconds -> TimerQueue -> MudStack ()
threadFeelingTimer i tag dur tq = sequence_ [ setThreadType . FeelingTimer $ i
                                            , loop 0 `catch` exHandler ] `finally` stopTimer tq
  where
    loop secs = getState >>= \ms -> do
        liftIO . threadDelay $ 1 * 10 ^ 6
        tq |&| liftIO . atomically . tryReadTMQueue >=> \case
          Just Nothing | secs >= dur -> do logHelper $ mkName ms <> " is expiring."
                                           tweak $ mobTbl.ind i.feelingMap %~ (tag `M.delete`)
                       | otherwise   -> loop . succ $ secs
          Just (Just ResetTimer    ) -> logHelper (mkName ms <> " is resetting.") >> loop 0
          _                          -> unit
    exHandler :: SomeException -> MudStack ()
    exHandler e = getState >>= \ms -> case fromException e of
      Just ThreadKilled -> logHelper $ mkName ms <> " has been killed."
      _                 -> logExMsg fn ("exception caught on thread for " <> mkName ms) e
    mkName ms = T.concat [ "feeling timer ", descSingId i ms, " ", dblQuote tag ]
    logHelper = logPla fn i
    fn        = "threadFeelingTimer"


-----


-- To stop (cancel) a single feeling, cancel the async and remove the entry in the mob's feeling map. See "stopFeeling"
-- in module "Mud.Threads.Effect".
stopFeelings :: Id -> MudStack ()
stopFeelings i = sequence_ [ getFeelingMap i <$> getState >>= mapM_ (liftIO . cancel . feelingAsync . snd) . M.toList
                           , tweak $ mobTbl.ind i.feelingMap .~ M.empty ]
