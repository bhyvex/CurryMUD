{-# OPTIONS_GHC -funbox-strict-fields -Wall -Werror #-}
{-# LANGUAGE NamedFieldPuns, OverloadedStrings, PatternSynonyms, ViewPatterns #-}

module Mud.Interp.CentralDispatch (centralDispatch) where

import Mud.Cmds.Admin
import Mud.Cmds.Debug
import Mud.Cmds.Pla
import Mud.Data.Misc
import Mud.Data.State.ActionParams.ActionParams
import Mud.Data.State.State
import Mud.Data.State.Util.Get
import Mud.Data.State.Util.Output
import Mud.Data.State.Util.Pla
import Mud.TopLvlDefs.Misc
import Mud.Util.Misc

import Control.Monad (when)
import qualified Data.Text as T


centralDispatch :: Interp
centralDispatch cn p@(ActionParams { plaId, plaMsgQueue }) = do
    findAction plaId cn >>= maybe sorry (\act -> act p)
    flip when (prompt plaMsgQueue dfltPrompt) =<< getPlaIsDfltPrompt plaId
  where
    sorry = send plaMsgQueue . nlnl $ "What?"


findAction :: Id -> CmdName -> MudStack (Maybe Action)
findAction i (T.toLower -> cn) = do
    r  <- getPCRm       i
    ia <- getPlaIsAdmin i
    let cmds = mkCmdListWithNonStdRmLinks r              ++
               (if ia            then adminCmds else []) ++
               (if ia && isDebug then debugCmds else [])
    maybe (return Nothing)
          (\fn -> return . Just . findActionForFullName fn $ cmds)
          (findFullNameForAbbrev cn [ cmdName cmd | cmd <- cmds ])
  where
    findActionForFullName fn = action . head . filter ((== fn) . cmdName)
