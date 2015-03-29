module Mud.Misc.Persist (persist) where

import Mud.Data.State.MudData
import Mud.TopLvlDefs.FilePaths

import Control.Concurrent (forkIO)
import Control.Lens (views)
import Control.Lens.Operators ((^.))
import Control.Monad.Trans.Resource (runResourceT)
import Data.Aeson (encode, toJSON)
import Data.Conduit (($$), (=$), yield)
import Data.Tuple (swap)
import qualified Data.ByteString.Lazy as BL (toStrict)
import qualified Data.Conduit.Binary as CB (sinkFile)
import qualified Data.Conduit.List as CL (map)
import qualified Data.IntMap.Lazy as IM (fromList, map)
import qualified Data.Map.Lazy as M (toList)


-- TODO: Handle exceptions? We shouldn't be able to interrupt a save.
persist :: MudState -> IO ()
persist ms = mapM_ (forkIO . runResourceT) [ helper (ms^.armTbl    ) armTblFile
                                           , helper (ms^.clothTbl  ) clothTblFile
                                           , helper (ms^.coinsTbl  ) coinsTblFile
                                           , helper (ms^.conTbl    ) conTblFile
                                           , helper (ms^.entTbl    ) entTblFile
                                           , helper (eqTblHelper ms) eqTblFile
                                           , helper (ms^.invTbl    ) invTblFile
                                           , helper (ms^.mobTbl    ) mobTblFile
                                           , helper (ms^.objTbl    ) objTblFile
                                           , helper (ms^.pcTbl     ) pcTblFile
                                           , helper (ms^.plaTbl    ) plaTblFile
                                           , helper (ms^.rmTbl     ) rmTblFile
                                           , helper (ms^.typeTbl   ) typeTblFile
                                           , helper (ms^.wpnTbl    ) wpnTblFile ]
  where
    helper tbl file = yield (toJSON tbl) $$ CL.map (BL.toStrict . encode) =$ CB.sinkFile file
    eqTblHelper     = views eqTbl convertEqMaps
    convertEqMaps   = IM.map (IM.fromList . map swap . M.toList)
