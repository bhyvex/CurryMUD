{-# OPTIONS_GHC -funbox-strict-fields -Wall -Werror #-}
{-# LANGUAGE FlexibleContexts, LambdaCase, OverloadedStrings, RankNTypes #-}

module Mud.Logging ( closeLogs
                   , initLogging
                   , initPlaLog
                   , logAndDispIOEx
                   , logError
                   , logExMsg
                   , logIOEx
                   , logIOExRethrow
                   , logNotice ) where

import Mud.MiscDataTypes
import Mud.StateDataTypes
import Mud.StateHelpers
import Mud.TopLvlDefs
import Mud.Util

import Control.Concurrent.Async (async, waitBoth)
import Control.Concurrent.STM.TQueue (newTQueueIO, readTQueue, writeTQueue)
import Control.Exception (IOException, SomeException)
import Control.Exception.Lifted (throwIO)
import Control.Lens (at)
import Control.Lens.Operators ((&), (.=), (?~))
import Control.Monad (forM_, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.STM (atomically)
import Data.Functor ((<$>))
import Data.Maybe (fromJust)
import Data.Monoid ((<>))
import System.Log (Priority(..))
import System.Log.Formatter (simpleLogFormatter)
import System.Log.Handler (close, setFormatter)
import System.Log.Handler.Simple (fileHandler)
import System.Log.Logger (errorM, infoM, noticeM, setHandlers, setLevel, updateGlobalLogger)
import qualified Data.Text as T


closeLogs :: MudStack ()
closeLogs = do
    logNotice "Mud.Logging" "closeLogs" "closing the logs"
    [ (na, nq), (ea, eq) ] <- sequence [ fromJust <$> getLog noticeLog, fromJust <$> getLog errorLog ]
    forM_ [ nq, eq ] $ liftIO . atomically . flip writeTQueue Stop
    liftIO . void . waitBoth na $ ea


initLogging :: MudStack ()
initLogging = do
    nq <- liftIO newTQueueIO
    eq <- liftIO newTQueueIO
    na <- liftIO . spawnLogger "notice.log" NOTICE "currymud.notice" noticeM $ nq
    ea <- liftIO . spawnLogger "error.log"  ERROR  "currymud.error"  errorM  $ eq
    nonWorldState.logServices.noticeLog .= Just (na, nq)
    nonWorldState.logServices.errorLog  .= Just (ea, eq)


type LogName    = String
type LoggingFun = String -> String -> IO ()


spawnLogger :: FilePath -> Priority -> LogName -> LoggingFun -> LogQueue -> IO LogAsync
spawnLogger fn p ln f q = async . loop =<< initLog
  where
    initLog = do
        gh <- fileHandler (logDir ++ fn) p
        let h = setFormatter gh . simpleLogFormatter $ "[$time $loggername] $msg"
        updateGlobalLogger ln (setHandlers [h] . setLevel p)
        return gh
    loop gh = (atomically . readTQueue $ q) >>= \case
      Stop  -> close gh
      Msg m -> f ln m >> loop gh


registerMsg :: String -> LogQueue -> MudStack ()
registerMsg msg q = liftIO . atomically . writeTQueue q . Msg $ msg


logNotice :: String -> String -> String -> MudStack ()
logNotice modName funName msg = maybeVoid helper =<< getLog noticeLog
  where
    helper = registerMsg (concat [ modName, " ", funName, ": ", msg, "." ]) . snd


logError :: String -> MudStack ()
logError msg = maybeVoid (registerMsg msg . snd) =<< getLog errorLog


logExMsg :: String -> String -> String -> SomeException -> MudStack ()
logExMsg modName funName msg e = logError . concat $ [ modName, " ", funName, ": ", msg, ". ", dblQuoteStr . show $ e ]


logIOEx :: String -> String -> IOException -> MudStack ()
logIOEx modName funName e = logError . concat $ [ modName, " ", funName, ": ", dblQuoteStr . show $ e ]


logAndDispIOEx :: MsgQueue -> Cols -> String -> String -> IOException -> MudStack ()
logAndDispIOEx mq cols modName funName e = let msg = concat [ modName, " ", funName, ": ", dblQuoteStr . show $ e ]
                                           in logError msg >> (send mq . nl . T.unlines . wordWrap cols . T.pack $ msg)


logIOExRethrow :: String -> String -> IOException -> MudStack ()
logIOExRethrow modName funName e = do
    logError . concat $ [ modName, " ", funName, ": unexpected exception; rethrowing." ]
    liftIO . throwIO $ e


initPlaLog :: Id -> Sing -> MudStack ()
initPlaLog i n = do
    q <- liftIO newTQueueIO
    a <- liftIO . spawnLogger (T.unpack $ n <> ".log") INFO (T.unpack $ "currymud." <> n) infoM $ q
    modifyNWS plaLogsTblTMVar $ \plt -> plt & at i ?~ (a, q)
