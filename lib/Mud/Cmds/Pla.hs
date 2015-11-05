{-# LANGUAGE LambdaCase, MonadComprehensions, MultiWayIf, NamedFieldPuns, OverloadedStrings, ParallelListComp, PatternSynonyms, RecordWildCards, TransformListComp, TupleSections, TypeFamilies, ViewPatterns #-}

module Mud.Cmds.Pla ( getRecordUptime
                    , getUptime
                    , go
                    , handleEgress
                    , look
                    , plaCmds
                    , showMotd ) where

import Mud.Cmds.ExpCmds
import Mud.Cmds.Msgs.Advice
import Mud.Cmds.Msgs.Dude
import Mud.Cmds.Msgs.Hint
import Mud.Cmds.Msgs.Misc
import Mud.Cmds.Msgs.Sorry
import Mud.Cmds.Util.Abbrev
import Mud.Cmds.Util.EmoteExp.EmoteExp
import Mud.Cmds.Util.EmoteExp.TwoWayEmoteExp
import Mud.Cmds.Util.Misc
import Mud.Cmds.Util.Pla
import Mud.Data.Misc
import Mud.Data.State.ActionParams.ActionParams
import Mud.Data.State.ActionParams.Misc
import Mud.Data.State.MsgQueue
import Mud.Data.State.MudData
import Mud.Data.State.Util.Calc
import Mud.Data.State.Util.Coins
import Mud.Data.State.Util.Get
import Mud.Data.State.Util.Misc
import Mud.Data.State.Util.Output
import Mud.Data.State.Util.Random
import Mud.Misc.ANSI
import Mud.Misc.Database
import Mud.Misc.LocPref
import Mud.Misc.Logging hiding (logNotice, logPla, logPlaExec, logPlaExecArgs, logPlaOut)
import Mud.Misc.NameResolution
import Mud.TheWorld.AdminZoneIds (iLoggedOut, iWelcome)
import Mud.Threads.Regen
import Mud.TopLvlDefs.Chars
import Mud.TopLvlDefs.FilePaths
import Mud.TopLvlDefs.Misc
import Mud.TopLvlDefs.Padding
import Mud.Util.List hiding (headTail)
import Mud.Util.Misc hiding (blowUp, patternMatchFail)
import Mud.Util.Operators
import Mud.Util.Padding
import Mud.Util.Quoting
import Mud.Util.Text
import Mud.Util.Token
import Mud.Util.Wrapping
import qualified Mud.Misc.Logging as L (logNotice, logPla, logPlaExec, logPlaExecArgs, logPlaOut)
import qualified Mud.Util.Misc as U (blowUp, patternMatchFail)

import Control.Arrow ((***), first)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TQueue (writeTQueue)
import Control.Exception.Lifted (catch, try)
import Control.Lens (_1, _2, _3, _4, _5, _6, at, both, each, set, to, view, views)
import Control.Lens.Operators ((%~), (&), (+~), (-~), (.~), (<>~), (?~), (^.))
import Control.Monad ((>=>), foldM, forM, forM_, guard, mplus, unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Char (isDigit, isLetter)
import Data.Either (lefts, partitionEithers)
import Data.Function (on)
import Data.Int (Int64)
import Data.IntMap.Lazy ((!))
import Data.Ix (inRange)
import Data.List ((\\), delete, foldl', intercalate, intersperse, nub, nubBy, partition, sort, sortBy, unfoldr)
import Data.List.Split (chunksOf)
import Data.Maybe (fromJust, fromMaybe)
import Data.Monoid ((<>), All(..), Sum(..))
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Tuple (swap)
import GHC.Exts (sortWith)
import Prelude hiding (log, pi)
import System.Clock (Clock(..), TimeSpec(..), getTime)
import System.Console.ANSI (ColorIntensity(..), clearScreenCode)
import System.Directory (doesFileExist, getDirectoryContents)
import System.FilePath ((</>))
import System.Time.Utils (renderSecs)
import qualified Data.IntMap.Lazy as IM (IntMap, (!), keys)
import qualified Data.Map.Lazy as M ((!), elems, filter, fromList, keys, lookup, map, singleton, size, toList)
import qualified Data.Set as S (filter, toList)
import qualified Data.Text as T
import qualified Data.Text.IO as T (readFile)


{-# ANN module ("HLint: ignore Use &&"        :: String) #-}
{-# ANN module ("HLint: ignore Use camelCase" :: String) #-}
{-# ANN module ("HLint: ignore Use ||"        :: String) #-}


-----


blowUp :: T.Text -> T.Text -> [T.Text] -> a
blowUp = U.blowUp "Mud.Cmds.Pla"


patternMatchFail :: T.Text -> [T.Text] -> a
patternMatchFail = U.patternMatchFail "Mud.Cmds.Pla"


-----


logNotice :: T.Text -> T.Text -> MudStack ()
logNotice = L.logNotice "Mud.Cmds.Pla"


logPla :: T.Text -> Id -> T.Text -> MudStack ()
logPla = L.logPla "Mud.Cmds.Pla"


logPlaExec :: CmdName -> Id -> MudStack ()
logPlaExec = L.logPlaExec "Mud.Cmds.Pla"


logPlaExecArgs :: CmdName -> Args -> Id -> MudStack ()
logPlaExecArgs = L.logPlaExecArgs "Mud.Cmds.Pla"


logPlaOut :: T.Text -> Id -> [T.Text] -> MudStack ()
logPlaOut = L.logPlaOut "Mud.Cmds.Pla"


-- ==================================================


plaCmds :: [Cmd]
plaCmds = sort $ regularCmds ++ priorityAbbrevCmds ++ expCmds


-- TODO: "give" command.
regularCmds :: [Cmd]
regularCmds = map (uncurry3 mkRegularCmd)
    [ ("?",          plaDispCmdList,  "Display or search this command list.")
    , ("about",      about,           "About CurryMUD.")
    , ("admin",      admin,           "Display a list of administrators, or send a message to an administrator.")
    , ("channel",    chan,            "Send a message on a telepathic channel " <> plusRelatedMsg)
    , ("d",          go "d",          "Go down.")
    , ("e",          go "e",          "Go east.")
    , ("equipment",  equip,           "Display your readied equipment, or examine one or more items in your readied \
                                      \equipment.")
    , ("expressive", expCmdList,      "Display or search a list of available expressive commands and their results.")
    , ("n",          go "n",          "Go north.")
    , ("ne",         go "ne",         "Go northeast.")
    , ("newchannel", newChan,         "Create one or more new telepathic channels.")
    , ("nw",         go "nw",         "Go northwest.")
    , ("question",   question,        "Ask/answer newbie questions " <> plusRelatedMsg)
    , ("qui",        quitCan'tAbbrev, "")
    , ("quit",       quit,            "Quit playing CurryMUD.")
    , ("remove",     remove,          "Remove one or more items from a container.")
    , ("s",          go "s",          "Go south.")
    , ("se",         go "se",         "Go southeast.")
    , ("set",        setAction,       "View or change settings.")
    , ("sw",         go "sw",         "Go southwest.")
    , ("take",       getAction,       "Pick up one or more items.")
    , ("tune",       tune,            "Display a list of your telepathic connections, or tune in/out one or more \
                                      \telepathic connections.")
    , ("typo",       typo,            "Report a typo.")
    , ("u",          go "u",          "Go up.")
    , ("unlink",     unlink,          "Sever one or more telepathic links.")
    , ("uptime",     uptime,          "Display how long CurryMUD has been running.")
    , ("w",          go "w",          "Go west.")
    , ("whoami",     whoAmI,          "Confirm your name, sex, and race.") ]


mkRegularCmd :: CmdFullName -> Action -> CmdDesc -> Cmd
mkRegularCmd cfn act cd = Cmd { cmdName           = cfn
                              , cmdPriorityAbbrev = Nothing
                              , cmdFullName       = cfn
                              , action            = act
                              , cmdDesc           = cd }


priorityAbbrevCmds :: [Cmd]
priorityAbbrevCmds = concatMap (uncurry4 mkPriorityAbbrevCmd)
    [ ("bug",        "b",   bug,        "Report a bug.")
    , ("clear",      "cl",  clear,      "Clear the screen.")
    , ("color",      "col", color,      "Perform a color test.")
    , ("connect",    "co",  connect,    "Connect one or more people to a telepathic channel.")
    , ("disconnect", "di",  disconnect, "Disconnect one or more people from a telepathic channel.")
    , ("drop",       "dr",  dropAction, "Drop one or more items.")
    , ("emote",      "em",  emote,      "Freely describe an action.")
    , ("exits",      "ex",  exits,      "Display obvious exits.")
    , ("get",        "g",   getAction,  "Pick up one or more items.")
    , ("help",       "h",   help,       "Get help on one or more commands or topics.")
    , ("intro",      "in",  intro,      "Display a list of the people who have introduced themselves to you, or \
                                        \introduce yourself to one or more people.")
    , ("inventory",  "i",   inv,        "Display your inventory, or examine one or more items in your inventory.")
    , ("leave",      "le",  leave,      "Sever your connections to one or more telepathic channels.")
    , ("link",       "li",  link,       "Display a list of the people with whom you have established a telepathic \
                                        \link, or establish a telepathic link with one or more people.")
    , ("look",       "l",   look,       "Display a description of your current room, or examine one or more things in \
                                        \your current room.")
    , ("motd",       "m",   motd,       "Display the message of the day.")
    , ("put",        "p",   putAction,  "Put one or more items into a container.")
    , ("ready",      "r",   ready,      "Ready one or more items.")
    , ("say",        "sa",  say,        "Say something out loud.")
    , ("show",       "sh",  showAction, "Show one or more items in your inventory and/or readied equipment to another \
                                        \person.")
    , ("telepathy",  "t",   tele,       "Send a private message to a person with whom you have established a two-way \
                                        \telepathic link.")
    , ("unready",    "un",  unready,    "Unready one or more items.")
    , ("who",        "wh",  who,        "Display or search a list of who is currently awake.") ]


mkPriorityAbbrevCmd :: CmdFullName -> CmdPriorityAbbrevTxt -> Action -> CmdDesc -> [Cmd]
mkPriorityAbbrevCmd cfn cpat act cd = unfoldr helper (T.init cfn) ++ [ Cmd { cmdName           = cfn
                                                                           , cmdPriorityAbbrev = Just cpat
                                                                           , cmdFullName       = cfn
                                                                           , action            = act
                                                                           , cmdDesc           = cd } ]
  where
    helper ""                      = Nothing
    helper abbrev | abbrev == cpat = Just (mkExplicitAbbrevCmd, "")
                  | otherwise      = Just (mkExplicitAbbrevCmd, T.init abbrev)
      where
        mkExplicitAbbrevCmd = Cmd { cmdName           = abbrev
                                  , cmdPriorityAbbrev = Nothing
                                  , cmdFullName       = cfn
                                  , action            = act
                                  , cmdDesc           = "" }


-----


about :: Action
about (NoArgs i mq cols) = do
    helper |&| try >=> eitherRet ((sendGenericErrorMsg mq cols >>) . fileIOExHandler "about")
    logPlaExec "about" i
  where
    helper = multiWrapSend mq cols =<< [ T.lines cont | cont <- liftIO . T.readFile $ aboutFile ]
about p = withoutArgs about p


-----


admin :: Action
admin p@(NoArgs''     _) = adminList p
admin p@(AdviseOneArg a) = advise p ["admin"] . adviceAdminNoMsg $ a
admin (MsgWithTarget i mq cols target msg) = getState >>= helper >>= \logMsgs ->
    logMsgs |#| let f = uncurry (logPla "admin") in mapM_ f
  where
    helper ms =
        let SingleTarget { .. } = mkSingleTarget mq cols target "The name of the administrator you wish to message"
            s                   = getSing i ms
            notFound            = emptied . sendFun . sorryAdminName $ strippedTarget
            found      (adminId, _        ) | adminId == i = emptied . sendFun $ sorryAdminChanSelf
            found pair@(adminId, adminSing) = case emotifyTwoWay "admin" i ms adminId msg of
              Left  errorMsgs  -> emptied . multiSendFun $ errorMsgs
              Right (Right bs) -> ioHelper pair bs
              Right (Left  ()) -> case expCmdifyTwoWay i ms adminId adminSing msg of
                Left  errorMsg -> emptied . sendFun $ errorMsg
                Right bs       -> ioHelper pair bs
            ioHelper (adminId, adminSing) [ fst -> toSelf, fst -> toAdmin ] = do
                if getAll . mconcat $ [ All . isLoggedIn $ adminPla
                                      , (not . isAdminId i $ ms) |?| (All . not . isIncognito $ adminPla) ]
                  then sendFun formatted
                  else multiSendFun [ formatted, parensQuote "Message retained." ]
                retainedMsg adminId ms . mkRetainedMsgFromPerson s $ toAdmin
                ts <- liftIO mkTimestamp
                withDbExHandler_ "admin_msg" . insertDbTblAdminMsg . AdminMsgRec ts s adminSing $ toSelf
                return [ sentLogMsg, receivedLogMsg ]
              where
                adminPla  = getPla adminId ms
                formatted = T.concat [ parensQuote $ "to " <> adminSing
                                     , " "
                                     , quoteWith "__" s
                                     , " "
                                     , toSelf ]
                sentLogMsg     = (i,       T.concat [ "sent message to ", adminSing, ": ", toSelf  ])
                receivedLogMsg = (adminId, T.concat [ "received message from ", s,   ": ", toAdmin ])
            ioHelper _ xs = patternMatchFail "admin helper ioHelper" [ showText xs ]
            filterRoot idSings
              | isAdminId i ms = idSings
              | otherwise      =
                  let ([((`getPla` ms) -> rootPla, _)], others) = partition ((== "Root") . snd) idSings
                  in if isLoggedIn rootPla && (not . isIncognito $ rootPla)
                    then idSings
                    else others
        in (findFullNameForAbbrev strippedTarget . filterRoot . mkAdminIdSingList $ ms) |&| maybe notFound found
admin p = patternMatchFail "admin" [ showText p ]


adminList :: Action
adminList (NoArgs i mq cols) = (multiWrapSend mq cols =<< helper =<< getState) >> logPlaExecArgs "admin" [] i
  where
    helper ms =
        let p            = getPla i ms
            singSuffixes = [ (s, suffix) | (ai, s) <- mkAdminIdSingList ms
                                         , let suffix = " logged " <> mkSuffix ai
                                         , then sortWith by s ]
            mkSuffix ai = let { ap = getPla ai ms; isIncog = isIncognito ap } in if isAdmin p && isIncog
              then (inOut . isLoggedIn $ ap) <> " " <> parensQuote "incognito"
              else inOut (isLoggedIn ap && not isIncog)
            singSuffixes' = singSuffixes |&| (isAdmin p ? id :? filter f)
              where
                f (a, b) | a == "Root" = b == " logged in"
                         | otherwise   = otherwise
            combineds = [ padName abbrev <> suffix
                        | (_, suffix) <- singSuffixes'
                        | abbrev      <- styleAbbrevs Don'tQuote . map fst $ singSuffixes' ]
        in ()!# combineds ? return combineds :? unadulterated sorryNoAdmins
adminList p = patternMatchFail "adminList" [ showText p ]


-----


bug :: Action
bug p@AdviseNoArgs = advise p ["bug"] adviceBugNoArgs
bug p              = bugTypoLogger p BugLog


-----


chan :: Action
chan (NoArgs i mq cols) = getState >>= \ms ->
    let (chanNames, chanTunings) = mkChanNamesTunings i ms
        helper names tunings     = let txts = mkChanTxts
                                   in (()!# txts ? txts :? pure "None.") |&| ("Telepathic channels:" :)
          where
            mkChanTxts = [ padChanName n <> tunedInOut t | n <- names | t <- tunings ]
    in do
        multiWrapSend mq cols . helper (styleAbbrevs Don'tQuote chanNames) $ chanTunings
        logPlaExecArgs "chan" [] i
chan (OneArg i mq cols a@(T.toLower -> a')) = getState >>= \ms ->
    let notFound    = wrapSend mq cols . sorryChanName $ a
        found match =
            let (cn, c)                  = getMatchingChanWithName match cns cs
                ([(_, isTuned)], others) = partition ((== s) . fst) $ c^.chanConnTbl.to M.toList
                (linkeds, nonLinkeds)    = partition (views _1 (isLinked ms . (i, ))) . filter f . map mkTriple $ others
                f                        = views _1 (`isAwake` ms)
            in mapM (updateRndmName i . view _1) nonLinkeds >>= \rndmNames ->
                let combo       = linkeds ++ zipWith (\rndmName -> _2 .~ rndmName) rndmNames nonLinkeds
                    (ins, outs) = partition (view _3) . sortBy (compare `on` view _2) $ combo
                    styleds     = styleAbbrevs Don'tQuote . map (view _2) $ ins
                    ins'        = zipWith (\styled -> _2 .~ styled) styleds ins
                    g (_, n, isTuned') = let n' = isRndmName n ? underline n :? n in padName n' <> tunedInOut isTuned'
                    combo'             = ins' ++ outs
                in if isTuned
                  then do
                      let onlyYou           = pure "You are the only person connected."
                          msgs              = ()!# combo' ? map g combo' :? onlyYou
                          affixChanName txt = parensQuote cn <> " " <> txt
                      multiWrapSend mq cols $ "Channel " <> dblQuote cn <> ":" : msgs
                      logPla "chan" i . affixChanName . commas $ [ getSing i' ms <> " is " <> tunedInOut isTuned'
                                                                 | (i', _, isTuned') <- combo' ]
                  else wrapSend mq cols . sorryTunedOutICChan $ cn
        (cs, cns, s)           = mkChanBindings i ms
        mkTriple (s', isTuned) = (getIdForPCSing s' ms, s', isTuned)
    in findFullNameForAbbrev a' (map T.toLower cns) |&| maybe notFound found
chan (MsgWithTarget i mq cols target msg) = getState >>= \ms ->
    let notFound    = wrapSend mq cols . sorryChanName $ target
        found match = let (cn, c) = getMatchingChanWithName match cns cs in if
          | views chanConnTbl (not . (M.! s)) c    -> wrapSend mq cols . sorryTunedOutICChan $ cn
          | isIncognitoId i ms -> wrapSend mq cols . sorryChanIncog $ "a telepathic"
          | otherwise          -> getChanStyleds i c ms >>= \triples -> if ()# triples
            then wrapSend mq cols . sorryChanNoOneListening . dblQuote $ cn
            else let getStyled targetId = view _3 . head . filter (views _1 (== i)) <$> getChanStyleds targetId c ms
                     format (txt, is)   = if i `elem` is
                                            then ((formatChanMsg cn s txt, pure i) :) <$> mkBsWithStyled (i `delete` is)
                                            else mkBsWithStyled is
                       where
                         mkBsWithStyled is' = mapM getStyled is' >>= \styleds ->
                             return [ (formatChanMsg cn styled txt, pure i') | i' <- is' | styled <- styleds ]
                     ioHelper (expandEmbeddedIdsToSings ms -> logMsg) bs = do
                         bcastNl =<< expandEmbeddedIds ms cc bs
                         sendToWiretappers logMsg
                         logPlaOut "chan" i . pure $ parensQuote cn <> " " <> logMsg
                         ts <- liftIO mkTimestamp
                         withDbExHandler_ "chan" . insertDbTblChan . ChanRec ts (c^.chanId) cn s $ logMsg
                     sendToWiretappers tappedMsg =
                         let cn' = quoteWith' (wiretapColor <> " ", " " <> dfltColor) . parensQuote $ cn
                             is  = c^.wiretappers.to (map (`getIdForPCSing` ms))
                             is' = filter (isLoggedIn . (`getPla` ms)) is
                         in bcastNl . pure $ (T.concat [ cn', " ", s, ": ", tappedMsg ], is')
                     cc   = ChanContext "chan" (Just cn) False
                     f bs = let logMsg = dropANSI . fst . head $ bs in ioHelper logMsg =<< g bs
                     g    = concatMapM format
                     ws   = wrapSend      mq cols
                     mws  = multiWrapSend mq cols
                 in case targetify i cc triples msg of
                   Left  errorMsg   -> ws errorMsg
                   Right (Right bs) -> f bs
                   Right (Left  ()) -> case emotify i ms cc triples msg of
                     Left  errorMsgs  -> mws errorMsgs
                     Right (Right bs) -> f bs
                     Right (Left  ()) -> case expCmdify i ms cc triples msg of
                       Left  errorMsg     -> ws errorMsg
                       Right (bs, logMsg) -> ioHelper logMsg =<< g bs
        (cs, cns, s) = mkChanBindings i ms
    in findFullNameForAbbrev (T.toLower target) (map T.toLower cns) |&| maybe notFound found
chan p = patternMatchFail "chan" [ showText p ]


-----


clear :: Action
clear (NoArgs' i mq) = (send mq . T.pack $ clearScreenCode) >> logPlaExec "clear" i
clear p              = withoutArgs clear p


-----


color :: Action
color (NoArgs' i mq) = (send mq . nl . T.concat $ msg) >> logPlaExec "color" i
  where
    msg = [ nl . T.concat $ [ mkColorDesc fg bg, ansi, " CurryMUD ", dfltColor ]
          | fgc <- colors, bgc <- colors, fgc /= bgc
          , let fg = (Dull, fgc), let bg = (Dull, bgc), let ansi = mkColorANSI fg bg ] ++ other
    mkColorDesc (mkColorName -> fg) (mkColorName -> bg) = fg <> "on " <> bg
    mkColorName                                         = padColorName . showText . snd
    other = [ nl . T.concat $ [ pad 19 "Blinking",   blink     " CurryMUD " ]
            , nl . T.concat $ [ pad 19 "Underlined", underline " CurryMUD " ] ]
color p = withoutArgs color p


-----


connect :: Action
connect p@AdviseNoArgs       = advise p ["connect"] adviceConnectNoArgs
connect p@(AdviseOneArg a)   = advise p ["connect"] . adviceConnectNoChan $ a
connect (Lower i mq cols as) = getState >>= \ms -> let getIds = map (`getIdForPCSing` ms) in
    if isIncognitoId i ms
      then wrapSend mq cols . sorryIncog $ "connect"
      else connectHelper i (mkLastArgWithNubbedOthers as) |&| modifyState >=> \case
        ([Left msg], Nothing) -> bcastNl . mkBroadcast i $ msg
        (res,        Just ci)
          | (sorryMsgs, targetSings) <- partitionEithers res
          , sorryBs   <- [ (msg, pure i) | msg <- sorryMsgs ]
          , targetIds <- getIds targetSings
          , c         <- getChan ci ms
          , cn        <- c^.chanName
          , otherIds  <- let f = (\\ (i : targetIds)) . filter (`isAwake` ms) . getIds . M.keys . M.filter id
                         in views chanConnTbl f c
          , toTargets <- (T.concat [ getSing i ms, " has connected you to the ", dblQuote cn, " channel." ], targetIds)
          , toSelf    <- (focusingInnateMsg <>) $ case targetSings of
            [one] -> T.concat [ "you connect ", one, " to the ", dblQuote cn, " channel." ]
            _     -> T.concat [ "you connect the following people to the "
                              , dblQuote cn
                              , " channel: "
                              , commas targetSings
                              , "." ] -> do
              toOthers <- mkToOthers ms otherIds targetIds cn
              bcastNl $ toTargets : toOthers ++ (()!# targetSings |?| mkBroadcast i toSelf) ++ sorryBs
              connectBlink targetIds ms
              logPla "connect" i $ "connected to " <> dblQuote cn <> ": " <> commas targetSings
        xs -> patternMatchFail "connect" [ showText xs ]
  where
    mkToOthers ms otherIds targetIds cn = do
        namesForMe      <- mapM (getRelativePCName ms . (, i)) otherIds
        namesForTargets <- mapM (\otherId -> mapM (getRelativePCName ms . (otherId, )) targetIds) otherIds
        let f i' me = map g
              where
                g n = (T.concat [ me, " has connected ", n, " to the ", dblQuote cn, " channel." ], pure i')
        return . concat . zipWith3 f otherIds namesForMe $ namesForTargets
    connectBlink targetIds ms = forM_ targetIds $ \targetId ->
        rndmDo (calcProbConnectBlink targetId ms) . mkExpAction "blink" . mkActionParams targetId ms $ []
connect p = patternMatchFail "connect" [ showText p ]


connectHelper :: Id -> (T.Text, Args) -> MudState -> (MudState, ([Either T.Text Sing], Maybe Id))
connectHelper i (target, as) ms =
    let (f, guessWhat) | any hasLocPref as = (stripLocPref, sorryConnectIgnore)
                       | otherwise         = (id,           ""                )
        g           = ()# guessWhat ? id :? (Left guessWhat :)
        as'         = map (capitalize . T.toLower . f) as
        notFound    = sorry . sorryChanName $ target
        found match = let (cn, c) = getMatchingChanWithName match cns cs in if views chanConnTbl (M.! s) c
          then let procTarget pair@(ms', _) a =
                       let notFoundSing         = sorryProcTarget . notFoundSuggestAsleeps a asleepSings $ ms'
                           foundSing targetSing = case c^.chanConnTbl.at targetSing of
                             Just _  -> sorryProcTarget . sorryConnectAlready targetSing $ cn
                             Nothing ->
                                 let checkChanName targetId = if hasChanOfSameName targetId
                                       then blocked . sorryConnectChanName targetSing $ cn
                                       else checkPp
                                     checkPp | not . hasPp i ms' $ 1 = let msg = sorryPp $ "connect " <> targetSing
                                                                       in sorryProcTarget msg
                                             | otherwise = pair & _1.chanTbl.ind ci.chanConnTbl.at targetSing ?~ True
                                                                & _1.mobTbl.ind i.curPp -~ 1
                                                                & _2 <>~ (pure . Right $ targetSing)
                                 in either sorryProcTarget checkChanName . checkMutuallyTuned i ms' $ targetSing
                           sorryProcTarget msg = pair & _2 <>~ (pure . Left $ msg)
                           blocked             = sorryProcTarget . (effortsBlockedMsg <>)
                       in findFullNameForAbbrev a targetSings |&| maybe notFoundSing foundSing
                   ci                         = c^.chanId
                   dblLinkeds                 = views pcTbl (filter (isDblLinked ms . (i, )) . IM.keys) ms
                   dblLinkedsPair             = partition (`isAwake` ms) dblLinkeds
                   (targetSings, asleepSings) = dblLinkedsPair & both %~ map (`getSing` ms)
                   hasChanOfSameName targetId | targetCs  <- getPCChans targetId ms
                                              , targetCns <- map (views chanName T.toLower) targetCs
                                              = T.toLower cn `elem` targetCns
                   (ms'', res)                = foldl' procTarget (ms, []) as'
               in (ms'', (g res, Just ci))
          else sorry . sorryTunedOutICChan $ cn
        (cs, cns, s) = mkChanBindings i ms
        sorry msg    = (ms, (pure . Left $ msg, Nothing))
    in findFullNameForAbbrev target (map T.toLower cns) |&| maybe notFound found


-----


disconnect :: Action
disconnect p@AdviseNoArgs       = advise p ["disconnect"] adviceDisconnectNoArgs
disconnect p@(AdviseOneArg a)   = advise p ["disconnect"] . adviceDisconnectNoChan $ a
disconnect (Lower i mq cols as) = getState >>= \ms -> let getIds = map (`getIdForPCSing` ms) in
    if isIncognitoId i ms
      then wrapSend mq cols . sorryIncog $ "disconnect"
      else getAllChanIdNames i ms >>= \idNamesTbl ->
          disconnectHelper i (mkLastArgWithNubbedOthers as) idNamesTbl |&| modifyState >=> \case
            ([Left msg], Nothing) -> bcastNl . mkBroadcast i $ msg
            (res,        Just ci)
              | (sorryMsgs, idSingNames)              <- partitionEithers res
              , (targetIds, targetSings, targetNames) <- unzip3 idSingNames
              , sorryBs   <- [ (msg, pure i) | msg <- sorryMsgs ]
              , c         <- getChan ci ms
              , cn        <- c^.chanName
              , otherIds  <- let f = (\\ (i : targetIds)) . filter (`isAwake` ms) . getIds . M.keys . M.filter id
                             in views chanConnTbl f c
              , toTargets <- ( "Someone has severed your telepathic connection to the " <> dblQuote cn <> " channel."
                             , targetIds )
              , toSelf    <- (focusingInnateMsg <>) $ case targetNames of
                [n] -> T.concat [ "you disconnect ", format n, " from the ", dblQuote cn, " channel." ]
                _   -> T.concat [ "you disconnect the following people from the "
                                , dblQuote cn
                                , " channel: "
                                , commas . map format $ targetNames
                                , "." ] -> do
                  toOthers <- mkToOthers ms otherIds targetIds cn
                  bcastNl $ toTargets : toOthers ++ (()!# targetNames |?| mkBroadcast i toSelf) ++ sorryBs
                  targetSings |#| (const . logPla "disconnect" i . T.concat $ [ "disconnected from "
                                                                              , dblQuote cn
                                                                              , ": "
                                                                              , commas targetSings ])
            xs -> patternMatchFail "disconnect" [ showText xs ]
  where
    format n = isRndmName n ? underline n :? n
    mkToOthers ms otherIds targetIds cn = do
        namesForMe      <- mapM (getRelativePCName ms . (, i)) otherIds
        namesForTargets <- mapM (\otherId -> mapM (getRelativePCName ms . (otherId, )) targetIds) otherIds
        let f i' me = map g
              where
                g n = (T.concat [ me, " has disconnected ", n, " from the ", dblQuote cn, " channel." ], pure i')
        return . concat . zipWith3 f otherIds namesForMe $ namesForTargets
disconnect p = patternMatchFail "disconnect" [ showText p ]


disconnectHelper :: Id
                 -> (T.Text, Args)
                 -> IM.IntMap [(Id, T.Text)]
                 -> MudState
                 -> (MudState, ([Either T.Text (Id, Sing, T.Text)], Maybe Id))
disconnectHelper i (target, as) idNamesTbl ms =
    let (f, guessWhat) | any hasLocPref as = (stripLocPref, sorryDisconnectIgnore)
                       | otherwise         = (id,           ""                   )
        g           = ()# guessWhat ? id :? (Left guessWhat :)
        as'         = map (T.toLower . f) as
        notFound    = sorry . sorryChanName $ target
        found match = let (cn, c) = getMatchingChanWithName match cns cs in if views chanConnTbl (M.! s) c
          then let procTarget (pair@(ms', _), b) a = case filter ((== a) . T.toLower . snd) $ idNamesTbl IM.! ci of
                     [] -> (pair & _2 <>~ (pure . Left . hint . sorryChanTargetName (dblQuote cn) $ a), True)
                     [(targetId, targetName)]
                       | not . hasPp i ms' $ 2 ->
                           let targetName' = isRndmName targetName ? underline targetName :? targetName
                               msg         = sorryPp $ "disconnect " <> targetName'
                           in (pair & _2 <>~ (pure . Left $ msg), b)
                       | otherwise -> let targetSing = getSing targetId ms'
                                      in ( pair & _1.chanTbl.ind ci.chanConnTbl.at targetSing .~ Nothing
                                                & _1.mobTbl.ind i.curPp -~ 2
                                                & _2 <>~ (pure . Right $ (targetId, targetSing, targetName))
                                         , b )
                     xs -> patternMatchFail "disconnectHelper found" [ showText xs ]
                     where
                       hint | b         = id
                            | otherwise = (<> hintDisconnect) . (<> " ")
                   ci               = c^.chanId
                   ((ms'', res), _) = foldl' procTarget ((ms, []), False) as'
               in (ms'', (g res, Just ci))
          else sorry . sorryTunedOutICChan $ cn
        (cs, cns, s) = mkChanBindings i ms
        sorry msg    = (ms, (pure . Left $ msg, Nothing))
    in findFullNameForAbbrev target (map T.toLower cns) |&| maybe notFound found


-----


dropAction :: Action
dropAction p@AdviseNoArgs   = advise p ["drop"] adviceDropNoArgs
dropAction (LowerNub' i as) = helper |&| modifyState >=> \(bs, logMsgs) ->
    bcastIfNotIncogNl i bs >> logMsgs |#| logPlaOut "drop" i
  where
    helper ms =
        let (inInvs, inEqs, inRms) = sortArgsInvEqRm InInv as
            sorryInEq              = inEqs |!| mkBroadcast i sorryDropInEq
            sorryInRm              = inRms |!| mkBroadcast i sorryDropInRm
            invCoins               = getInvCoins i ms
            d                      = mkStdDesig  i ms DoCap
            ri                     = getRmId     i ms
            (eiss, ecs)            = uncurry (resolvePCInvCoins i ms inInvs) invCoins
            (ms',  bs,  logMsgs )  = foldl' (helperDropEitherInv      i d      i ri) (ms,  [], []     ) eiss
            (ms'', bs', logMsgs')  =         helperGetDropEitherCoins i d Drop i ri  (ms', bs, logMsgs) ecs
        in if ()!# invCoins
          then (ms'', (sorryInEq ++ sorryInRm ++ bs',       logMsgs'))
          else (ms,   (mkBroadcast i dudeYourHandsAreEmpty, []      ))
dropAction p = patternMatchFail "dropAction" [ showText p ]


-----


emote :: Action
emote p@AdviseNoArgs                                                       = advise p ["emote"] adviceEmoteNoArgs
emote p@(ActionParams { args }) | any (`elem` yous) . map T.toLower $ args = advise p ["emote"] adviceYouEmote
emote (WithArgs i mq cols as) = getState >>= \ms ->
    let d@(stdPCEntSing -> Just s) = mkStdDesig i ms DoCap
        ser                        = serialize d
        d'                         = d { shouldCap = Don'tCap }
        ser'                       = serialize d'
        xformed                    = xformArgs True as
        xformArgs _      []        = []
        xformArgs isHead [x]
          | (h, t) <- headTail x
          , h == emoteNameChar
          , all isPunc . T.unpack $ t
          = pure . mkRightForNonTargets $ expandEnc isHead & each <>~ t
        xformArgs isHead (x:xs)    = (: xformArgs False xs) $ if
          | x == enc               -> mkRightForNonTargets . expandEnc $ isHead
          | x == enc's             -> mkRightForNonTargets $ expandEnc isHead & each <>~ "'s"
          | enc `T.isInfixOf` x    -> Left . adviceEnc $ "emote "
          | x == etc               -> Left . adviceEtc $ "emote "
          | T.take 1 x == etc      -> isHead ? Left adviceEtcHead :? (procTarget ms . T.tail $ x)
          | etc `T.isInfixOf` x    -> Left . adviceEtc $ "emote "
          | isHead, hasEnc as      -> mkRightForNonTargets $ dup3 x  & each %~ capitalizeMsg
          | isHead, x' <- " " <> x -> mkRightForNonTargets $ dup3 x' & _1 %~ (s   <>)
                                                                     & _2 %~ (ser <>)
                                                                     & _3 %~ (ser <>)
          | otherwise              -> mkRightForNonTargets . dup3 $ x
        expandEnc isHead = (isHead ? (ser, ser) :? (ser', ser')) |&| uncurry (s, , )
    in case lefts xformed of
      [] -> let (toSelf, toOthers, targetIds, toTargetBs) = happy ms xformed
            in bcastNl $ (toSelf, pure i) : (toOthers, pcIds d \\ (i : targetIds)) : toTargetBs
      advices -> multiWrapSend mq cols . nub $ advices
  where
    procTarget ms word =
        case swap . (both %~ T.reverse) . T.span isPunc . T.reverse $ word of
          ("",   _) -> Left . adviceEtc $ "emote "
          ("'s", _) -> Left adviceEtcEmptyPoss
          (w,    p) ->
            let (isPoss, target) = ("'s" `T.isSuffixOf` w ? (True, T.dropEnd 2) :? (False, id)) & _2 %~ (w |&|)
                invCoins         = first (i `delete`) . getPCRmNonIncogInvCoins i $ ms
            in if ()!# invCoins
              then case singleArgInvEqRm InRm target of
                (InInv, _      ) -> sorry sorryEmoteTargetInInv
                (InEq,  _      ) -> sorry sorryEmoteTargetInEq
                (InRm,  target') -> case uncurry (resolveRmInvCoins i ms [target']) invCoins of
                  (_,                    [ Left [msg] ]) -> Left msg
                  (_,                    Right  _:_    ) -> sorry sorryEmoteTargetCoins
                  ([ Left  msg        ], _             ) -> Left msg
                  ([ Right (_:_:_)    ], _             ) -> Left sorryEmoteExcessTargets
                  ([ Right [targetId] ], _             ) ->
                      let targetSing = getSing targetId ms
                      in case getType targetId ms of
                        PCType  -> let targetDesig = addSuffix isPoss p . serialize . mkStdDesig targetId ms $ Don'tCap
                                   in Right ( targetDesig
                                            , [ mkEmoteWord isPoss p targetId, ForNonTargets targetDesig ]
                                            , targetDesig )
                        MobType -> mkRightForNonTargets . dup3 . addSuffix isPoss p . theOnLower $ targetSing
                        _       -> Left . sorryEmoteTargetType $ targetSing
                  x -> patternMatchFail "emote procTarget" [ showText x ]
              else Left sorryNoOneHere
    addSuffix   isPoss p = (<> p) . (isPoss ? (<> "'s") :? id)
    mkEmoteWord isPoss   = isPoss ? ForTargetPoss :? ForTarget
    sorry t              = Left . quoteWith' (t, sorryEmoteTargetRmOnly) $ " "
emote p = patternMatchFail "emote" [ showText p ]


-----


equip :: Action
equip (NoArgs   i mq cols   ) = getState >>= \ms -> send mq . nl . mkEqDesc i cols ms i (getSing i ms) $ PCType
equip (LowerNub i mq cols as) = getState >>= \ms ->
    let em@(M.elems -> is) = getEqMap i ms in send mq $ if ()!# em
      then let (inInvs, inEqs, inRms)                = sortArgsInvEqRm InEq as
               (gecrs, miss, rcs)                    = resolveEntCoinNames i ms inEqs is mempty
               eiss                                  = zipWith (curry procGecrMisPCEq) gecrs miss
               invDesc                               = foldl' helperEitherInv "" eiss
               helperEitherInv acc (Left  msg)       = (acc <>) . wrapUnlinesNl cols $ msg
               helperEitherInv acc (Right targetIds) = nl $ acc <> mkEntDescs i cols ms targetIds
               coinsDesc                             = rcs |!| wrapUnlinesNl cols sorryEquipCoins
           in T.concat [ inInvs |!| sorryInInv, inRms |!| sorryInRm, invDesc, coinsDesc ]
      else wrapUnlinesNl cols dudeYou'reNaked
  where
    sorryInInv = wrapUnlinesNl cols . sorryEquipInvLook EquipCmd $ InvCmd
    sorryInRm  = wrapUnlinesNl cols . sorryEquipInvLook EquipCmd $ LookCmd
equip p = patternMatchFail "equip" [ showText p ]


-----


exits :: Action
exits (NoArgs i mq cols) = getState >>= \ms ->
    (send mq . nl . mkExitsSummary cols . getPCRm i $ ms) >> logPlaExec "exits" i
exits p = withoutArgs exits p


-----


expCmdList :: Action
expCmdList (NoArgs i mq cols) =
    (pager i mq . concatMap (wrapIndent cmdNamePadding cols) $ mkExpCmdListTxt) >> logPlaExecArgs "expressive" [] i
expCmdList p@(ActionParams { plaId, args }) =
    dispMatches p cmdNamePadding mkExpCmdListTxt >> logPlaExecArgs "expressive" args plaId


mkExpCmdListTxt :: [T.Text]
mkExpCmdListTxt =
    let cmdNames       = [ cmdName cmd | cmd <- plaCmds ]
        styledCmdNames = styleAbbrevs Don'tQuote cmdNames
    in concatMap mkExpCmdTxt [ (styled, head matches) | (cn, styled) <- zip cmdNames styledCmdNames
                                                      , let matches = findMatches cn
                                                      , length matches == 1 ]
  where
    findMatches cn = S.toList . S.filter (\(ExpCmd ecn _) -> ecn == cn) $ expCmdSet
    mkExpCmdTxt (styled, ExpCmd ecn ect) = case ect of
      (NoTarget  toSelf _  ) -> [ paddedName <> mkInitialTxt  ecn <> toSelf ]
      (HasTarget toSelf _ _) -> [ paddedName <> mkInitialTxt (ecn <> " hanako") <> T.replace "@" "Hanako" toSelf ]
      (Versatile toSelf _ toSelfWithTarget _ _) -> [ paddedName <> mkInitialTxt ecn <> toSelf
                                                   , T.replicate cmdNamePadding (T.singleton indentFiller) <>
                                                     mkInitialTxt (ecn <> " hanako")                       <>
                                                     T.replace "@" "Hanako" toSelfWithTarget ]
      where
        paddedName         = padCmdName styled
        mkInitialTxt input = T.concat [ quoteWith' (quoteColor, dfltColor) input
                                      , " "
                                      , arrowColor
                                      , "->"
                                      , dfltColor
                                      , " " ]


-----


getAction :: Action
getAction p@AdviseNoArgs = advise p ["get"] adviceGetNoArgs
getAction (Lower _ mq cols as) | length as >= 3, (head . tail . reverse $ as) == "from" = wrapSend mq cols hintGet
getAction (LowerNub' i as) = helper |&| modifyState >=> \(bs, logMsgs) ->
    bcastIfNotIncogNl i bs >> logMsgs |#| logPlaOut "get" i
  where
    helper ms =
        let (inInvs, inEqs, inRms) = sortArgsInvEqRm InRm as

            sorryInInv = inInvs |!| mkBroadcast i sorryGetInInv
            sorryInEq  = inEqs  |!| mkBroadcast i sorryGetInEq
            ri                    = getRmId i ms
            invCoins              = first (i `delete`) . getNonIncogInvCoins ri $ ms
            d                     = mkStdDesig i ms DoCap
            (eiss, ecs)           = uncurry (resolveRmInvCoins i ms inRms) invCoins
            (ms',  bs,  logMsgs ) = foldl' (helperGetEitherInv       i d     ri i) (ms,  [], []     ) eiss
            (ms'', bs', logMsgs') =         helperGetDropEitherCoins i d Get ri i  (ms', bs, logMsgs) ecs
        in if ()!# invCoins
          then (ms'', (sorryInInv ++ sorryInEq ++ bs',    logMsgs'))
          else (ms,   (mkBroadcast i sorryGetNothingHere, []      ))
getAction p = patternMatchFail "getAction" [ showText p ]


-----


go :: T.Text -> Action
go dir p@(ActionParams { args = [] }) = goDispatcher p { args = pure dir   }
go dir p@(ActionParams { args      }) = goDispatcher p { args = dir : args }


goDispatcher :: Action
goDispatcher   (ActionParams { args = [] }) = unit
goDispatcher p@(Lower i mq cols as)         = mapM_ (tryMove i mq cols p { args = [] }) as
goDispatcher p                              = patternMatchFail "goDispatcher" [ showText p ]


tryMove :: Id -> MsgQueue -> Cols -> ActionParams -> T.Text -> MudStack ()
tryMove i mq cols p dir = helper |&| modifyState >=> \case
  Left  msg          -> wrapSend mq cols msg
  Right (bs, logMsg) -> look p >> bcastIfNotIncog i bs >> logPla "tryMove" i logMsg
  where
    helper ms =
        let originId = getRmId i ms
            originRm = getRm originId ms
        in case findExit originRm dir of
          Nothing -> (ms, Left sorry)
          Just (linkTxt, destId, maybeOriginMsg, maybeDestMsg) ->
            let originDesig = mkStdDesig i ms DoCap
                s           = fromJust . stdPCEntSing $ originDesig
                originPCIds = i `delete` pcIds originDesig
                destPCIds   = findPCIds ms $ ms^.invTbl.ind destId
                ms'         = ms & pcTbl .ind i.rmId   .~ destId
                                 & invTbl.ind originId %~ (i `delete`)
                                 & invTbl.ind destId   %~ (sortInv ms . (++ pure i))
                msgAtOrigin = nlnl $ case maybeOriginMsg of
                                Nothing  -> T.concat [ serialize originDesig, " ", verb, " ", expandLinkName dir, "." ]
                                Just msg -> T.replace "%" (serialize originDesig) msg
                msgAtDest   = let destDesig = mkSerializedNonStdDesig i ms s A DoCap in nlnl $ case maybeDestMsg of
                                Nothing  -> T.concat [ destDesig, " arrives from ", expandOppLinkName dir, "." ]
                                Just msg -> T.replace "%" destDesig msg
                logMsg      = T.concat [ "moved "
                                       , linkTxt
                                       , " from room "
                                       , showRm originId originRm
                                       , " to room "
                                       , showRm destId . getRm destId $ ms
                                       , "." ]
            in (ms', Right ([ (msgAtOrigin, originPCIds), (msgAtDest, destPCIds) ], logMsg))
    sorry = dir `elem` stdLinkNames ? sorryGoExit :? sorryGoParseDir dir
    verb
      | dir == "u"              = "goes"
      | dir == "d"              = "heads"
      | dir `elem` stdLinkNames = "leaves"
      | otherwise               = "enters"
    showRm (showText -> ri) (views rmName parensQuote -> rn) = ri <> " " <> rn


findExit :: Rm -> LinkName -> Maybe (T.Text, Id, Maybe T.Text, Maybe T.Text)
findExit (view rmLinks -> rls) ln =
    case [ (showLink rl, getDestId rl, getOriginMsg rl, getDestMsg rl) | rl <- rls, isValid rl ] of
      [] -> Nothing
      xs -> Just . head $ xs
  where
    isValid      StdLink    { .. } = ln == linkDirToCmdName _linkDir
    isValid      NonStdLink { .. } = ln `T.isPrefixOf` _linkName
    showLink     StdLink    { .. } = showText _linkDir
    showLink     NonStdLink { .. } = _linkName
    getDestId    StdLink    { .. } = _stdDestId
    getDestId    NonStdLink { .. } = _nonStdDestId
    getOriginMsg NonStdLink { .. } = Just _originMsg
    getOriginMsg _                 = Nothing
    getDestMsg   NonStdLink { .. } = Just _destMsg
    getDestMsg   _                 = Nothing


expandLinkName :: T.Text -> T.Text
expandLinkName "n"  = "north"
expandLinkName "ne" = "northeast"
expandLinkName "e"  = "east"
expandLinkName "se" = "southeast"
expandLinkName "s"  = "south"
expandLinkName "sw" = "southwest"
expandLinkName "w"  = "west"
expandLinkName "nw" = "northwest"
expandLinkName "u"  = "up"
expandLinkName "d"  = "down"
expandLinkName x    = patternMatchFail "expandLinkName" [x]


expandOppLinkName :: T.Text -> T.Text
expandOppLinkName "n"  = "the south"
expandOppLinkName "ne" = "the southwest"
expandOppLinkName "e"  = "the west"
expandOppLinkName "se" = "the northwest"
expandOppLinkName "s"  = "the north"
expandOppLinkName "sw" = "the northeast"
expandOppLinkName "w"  = "the east"
expandOppLinkName "nw" = "the southeast"
expandOppLinkName "u"  = "below"
expandOppLinkName "d"  = "above"
expandOppLinkName x    = patternMatchFail "expandOppLinkName" [x]


-----


help :: Action
help (NoArgs i mq cols) = (liftIO . T.readFile $ helpDir </> "root") |&| try >=> either handler helper
  where
    handler e = fileIOExHandler "help" e >> wrapSend mq cols helpRootErrorMsg
    helper rootHelpTxt = (isAdminId i <$> getState) >>= \ia -> do
        (sortBy (compare `on` helpName) -> hs) <- liftIO . mkHelpData $ ia
        let zipped                 = zip (styleAbbrevs Don'tQuote [ helpName h | h <- hs ]) hs
            (cmdNames, topicNames) = partition (isCmdHelp . snd) zipped & both %~ (formatHelpNames . mkHelpNames)
            helpTxt                = T.concat [ nl rootHelpTxt
                                              , nl "Help is available on the following commands:"
                                              , nl cmdNames
                                              , nl "Help is available on the following topics:"
                                              , topicNames
                                              , ia |?| footnote ]
        (pager i mq . parseHelpTxt cols $ helpTxt) >> logPla "help" i "read root help file."
    mkHelpNames zipped    = [ padHelpTopic . (styled <>) $ isAdminHelp h |?| asterisk | (styled, h) <- zipped ]
    formatHelpNames names = let wordsPerLine = cols `div` helpTopicPadding
                            in T.unlines . map T.concat . chunksOf wordsPerLine $ names
    footnote              = nlPrefix $ asterisk <> " indicates help that is available only to administrators."
help (LowerNub i mq cols as) = (isAdminId i <$> getState) >>= liftIO . mkHelpData >>= \hs -> do
    (map (parseHelpTxt cols) -> helpTxts, dropBlanks -> hns) <- unzip <$> forM as (getHelpByName cols hs)
    pager i mq . intercalateDivider cols $ helpTxts
    hns |#| logPla "help" i . ("read help on: " <>) . commas
help p = patternMatchFail "help" [ showText p ]


mkHelpData :: Bool -> IO [Help]
mkHelpData ia = helpDirs |&| mapM getHelpDirectoryContents >=> \[ plaHelpCmdNames
                                                                , plaHelpTopicNames
                                                                , adminHelpCmdNames
                                                                , adminHelpTopicNames ] -> do
    let phcs = [ Help { helpName     = T.pack phcn
                      , helpFilePath = plaHelpCmdsDir     </> phcn
                      , isCmdHelp    = True
                      , isAdminHelp  = False } | phcn <- plaHelpCmdNames     ]
        phts = [ Help { helpName     = T.pack phtn
                      , helpFilePath = plaHelpTopicsDir   </> phtn
                      , isCmdHelp    = False
                      , isAdminHelp  = False } | phtn <- plaHelpTopicNames   ]
        ahcs = [ Help { helpName     = T.pack $ adminCmdChar : whcn
                      , helpFilePath = adminHelpCmdsDir   </> whcn
                      , isCmdHelp    = True
                      , isAdminHelp  = True }  | whcn <- adminHelpCmdNames   ]
        ahts = [ Help { helpName     = T.pack whtn
                      , helpFilePath = adminHelpTopicsDir </> whtn
                      , isCmdHelp    = False
                      , isAdminHelp  = True }  | whtn <- adminHelpTopicNames ]
    return $ phcs ++ phts ++ (guard ia >> ahcs ++ ahts)
  where
    helpDirs                     = [ plaHelpCmdsDir, plaHelpTopicsDir, adminHelpCmdsDir, adminHelpTopicsDir ]
    getHelpDirectoryContents dir = dropIrrelevantFilenames . sort <$> getDirectoryContents dir


parseHelpTxt :: Cols -> T.Text -> [T.Text]
parseHelpTxt cols = concat . wrapLines cols . map expandDividers . T.lines . parseTokens
  where
    expandDividers l | l == T.singleton dividerToken = T.replicate cols "-"
                     | otherwise                     = l


getHelpByName :: Cols -> [Help] -> HelpName -> MudStack (T.Text, T.Text)
getHelpByName cols hs name = findFullNameForAbbrev name [ (h, helpName h) | h <- hs ] |&| maybe sorry found
  where
    sorry                                      = return (sorryHelpName name, "")
    found (helpFilePath -> hf, dblQuote -> hn) = (,) <$> readHelpFile hf hn <*> return hn
    readHelpFile hf hn                         = (liftIO . T.readFile $ hf) |&| try >=> eitherRet handler
      where
        handler e = do
            fileIOExHandler "getHelpByName readHelpFile" e
            return . wrapUnlines cols . helpFileErrorMsg $ hn


-----


intro :: Action
intro (NoArgs i mq cols) = getState >>= \ms -> let intros = getIntroduced i ms in if ()# intros
  then let introsTxt = "No one has introduced themselves to you yet." in
      wrapSend mq cols introsTxt >> (logPlaOut "intro" i . pure $ introsTxt)
  else let introsTxt = commas intros in do
      multiWrapSend mq cols [ "You know the following names:", introsTxt ]
      logPla "intro" i $ "known names: " <> introsTxt
intro (LowerNub i mq cols as) = getState >>= \ms -> if isIncognitoId i ms
  then wrapSend mq cols . sorryIncog $ "intro"
  else helper |&| modifyState >=> \(map fromClassifiedBroadcast . sort -> bs, logMsgs) ->
    bcastIfNotIncog i bs >> logMsgs |#| logPla "intro" i . slashes
  where
    helper ms =
        let (inInvs, inEqs, inRms) = sortArgsInvEqRm InRm as
            sorryInInv = inInvs |!| mkNTB sorryIntroInInv
            sorryInEq  = inEqs  |!| mkNTB sorryIntroInEq
            invCoins@(first (i `delete`) -> invCoins') = getPCRmNonIncogInvCoins i ms
            (eiss, ecs)          = uncurry (resolveRmInvCoins i ms inRms) invCoins'
            (pt, cbs,  logMsgs ) = foldl' (helperIntroEitherInv ms (fst invCoins)) (ms^.pcTbl, [],  []     ) eiss
            (    cbs', logMsgs') = foldl' helperIntroEitherCoins                   (           cbs, logMsgs) ecs
        in if ()!# invCoins'
          then (ms & pcTbl .~ pt, (sorryInInv ++ sorryInEq ++ cbs', logMsgs'))
          else (ms, (mkNTB sorryIntroNoOneHere, []))
    mkNTB                                           = mkNTBroadcast i . nlnl
    helperIntroEitherInv _  _   a (Left msg       ) = ()# msg ? a :? (a & _2 <>~ mkNTB msg)
    helperIntroEitherInv ms ris a (Right targetIds) = foldl' tryIntro a targetIds
      where
        tryIntro a'@(pt, _, _) targetId = let targetSing = getSing targetId ms in case getType targetId ms of
          PCType -> let s           = getSing i ms
                        targetDesig = serialize . mkStdDesig targetId ms $ Don'tCap
                        msg         = "You introduce yourself to " <> targetDesig <> "."
                        logMsg      = "Introduced to " <> targetSing <> "."
                        srcMsg      = nlnl msg
                        pis         = findPCIds ms ris
                        srcDesig    = StdDesig { stdPCEntSing = Nothing
                                               , shouldCap    = DoCap
                                               , pcEntName    = mkUnknownPCEntName i ms
                                               , pcId         = i
                                               , pcIds        = pis }
                        himHerself  = mkReflexPro . getSex i $ ms
                        targetMsg   = nlnl . T.concat $ [ serialize srcDesig
                                                        , " introduces "
                                                        , himHerself
                                                        , " to you as "
                                                        , knownNameColor
                                                        , s
                                                        , dfltColor
                                                        , "." ]
                        othersMsg   = nlnl . T.concat $ [ serialize srcDesig { stdPCEntSing = Just s }
                                                        , " introduces "
                                                        , himHerself
                                                        , " to "
                                                        , targetDesig
                                                        , "." ]
                        cbs         = [ NonTargetBroadcast (srcMsg,    pure i                )
                                      , TargetBroadcast    (targetMsg, pure targetId         )
                                      , NonTargetBroadcast (othersMsg, pis \\ [ i, targetId ]) ]
                    in if s `elem` pt^.ind targetId.introduced
                      then let sorry = nlnl . sorryIntroAlready $ targetDesig
                           in a' & _2 <>~ mkNTBroadcast i sorry
                      else a' & _1.ind targetId.introduced %~ (sort . (s :)) & _2 <>~ cbs & _3 <>~ pure logMsg
          _      -> let b = head . mkNTB . sorryIntroType $ targetSing
                    in a' & _2 %~ (`appendIfUnique` b)
    helperIntroEitherCoins a (Left  msgs) = a & _1 <>~ (mkNTBroadcast i . T.concat $ [ nlnl msg | msg <- msgs ])
    helperIntroEitherCoins a (Right {}  ) =
        let cb = head . mkNTB $ sorryIntroCoin
        in first (`appendIfUnique` cb) a
    fromClassifiedBroadcast (TargetBroadcast    b) = b
    fromClassifiedBroadcast (NonTargetBroadcast b) = b
intro p = patternMatchFail "intro" [ showText p ]


-----


inv :: Action
inv (NoArgs   i mq cols   ) = getState >>= \ms@(getSing i -> s) -> send mq . nl . mkInvCoinsDesc i cols ms i $ s
inv (LowerNub i mq cols as) = getState >>= \ms ->
    let (inInvs, inEqs, inRms) = sortArgsInvEqRm InInv as
        invCoins               = getInvCoins i ms
        (eiss, ecs)            = uncurry (resolvePCInvCoins i ms inInvs) invCoins
        invDesc                = foldl' (helperEitherInv ms) "" eiss
        coinsDesc              = foldl' helperEitherCoins    "" ecs
    in send mq $ if ()!# invCoins
    then T.concat [ inEqs |!| sorryInEq, inRms |!| sorryInRm, invDesc, coinsDesc ]
      else wrapUnlinesNl cols dudeYourHandsAreEmpty
  where
    helperEitherInv _  acc (Left  msg ) = (acc <>) . wrapUnlinesNl cols $ msg
    helperEitherInv ms acc (Right is  ) = nl $ acc <> mkEntDescs i cols ms is
    helperEitherCoins  acc (Left  msgs) = (acc <>) . multiWrapNl cols . intersperse "" $ msgs
    helperEitherCoins  acc (Right c   ) = nl $ acc <> mkCoinsDesc cols c
    sorryInEq                           = wrapUnlinesNl cols . sorryEquipInvLook InvCmd $ EquipCmd
    sorryInRm                           = wrapUnlinesNl cols . sorryEquipInvLook InvCmd $ LookCmd
inv p = patternMatchFail "inv" [ showText p ]


-----


leave :: Action
leave p@AdviseNoArgs                   = advise p ["leave"] adviceLeaveNoArgs
leave (WithArgs i mq cols (nub -> as)) = helper |&| modifyState >=> \(ms, chanIdNameIsDels, sorryMsgs) ->
    let s                              = getSing i ms
        (chanIds, chanNames, chanRecs) = foldl' unzipper ([], [], []) chanIdNameIsDels
        unzipper acc (ci, cn, isDel)
          | isDel     = acc & _2 <>~ pure cn
                            & _3 <>~ (pure . ChanRec "" ci cn s . asteriskQuote $ "Channel deleted.")
          | otherwise = acc & _1 <>~ pure ci
                            & _2 <>~ pure cn
        toSelfMsgs = mkLeaveMsg chanNames
        msgs       = ()# sorryMsgs ? toSelfMsgs :? sorryMsgs ++ (toSelfMsgs |!| "" : toSelfMsgs)
        f bs ci    = let c        = getChan ci ms
                         otherIds = views chanConnTbl g c
                         g        = filter (`isAwake` ms) . map (`getIdForPCSing` ms) . M.keys . M.filter id
                     in (bs ++) <$> forM otherIds (\i' -> [ ( T.concat [ "You sense that "
                                                                       , n
                                                                       , " has left the "
                                                                       , views chanName dblQuote c
                                                                       , " channel." ]
                                                            , pure i' ) | n <- getRelativePCName ms (i', i) ])
    in do
        multiWrapSend mq cols msgs
        bcastNl =<< foldM f [] chanIds
        chanNames |#| logPla "leave" i . commas
        ts <- liftIO mkTimestamp
        forM_ chanRecs $ \cr -> withDbExHandler_ "leave" . insertDbTblChan $ cr { chanTimestamp = ts }
  where
    helper ms = let (ms', chanIdNameIsDels, sorryMsgs) = foldl' f (ms, [], []) as
                in (ms', (ms', chanIdNameIsDels, sorryMsgs))
      where
        f triple a@(T.toLower -> a') =
            let notFound     = triple & _3 <>~ (pure . sorryChanName $ a)
                found match  = let (cn, c) = getMatchingChanWithName match cns cs
                                   ci      = c^.chanId
                                   isDel   = views chanConnTbl ((== 1) . M.size) c
                               in (triple & _2 <>~ pure (ci, cn, isDel) |&|) $ if isDel
                                 then _1.chanTbl.at  ci                  .~ Nothing
                                 else _1.chanTbl.ind ci.chanConnTbl.at s .~ Nothing
                (cs, cns, s) = mkChanBindings i ms
            in findFullNameForAbbrev a' (map T.toLower cns) |&| maybe notFound found
    mkLeaveMsg []     = []
    mkLeaveMsg ns@[_] = pure    . mkMsgHelper False $ ns
    mkLeaveMsg ns     = T.lines . mkMsgHelper True  $ ns
    mkMsgHelper isPlur (map dblQuote -> ns) =
        T.concat [ focusingInnateMsg
                 , "you sever your telepathic connection"
                 , theLetterS isPlur
                 , " to the "
                 , isPlur ? "following channels:\n" <> commas ns :? head ns <> " channel"
                 , "." ]
leave p = patternMatchFail "leave" [ showText p ]


-----


-- TODO: Linking should cost psionic points.
-- TODO: Linking should award exp.
link :: Action
link (NoArgs i mq cols) = do
    ms  <- getState
    res <- helperLinkUnlink ms i mq cols
    flip maybeVoid res $ \(meLinkedToOthers, othersLinkedToMe, twoWays) ->
        let msgs             = intercalate [""] . dropEmpties $ [ twoWays       |!| twoWayMsgs
                                                                , oneWaysFromMe |!| oneWayFromMeMsgs
                                                                , oneWaysToMe   |!| oneWayToMeMsgs ]
            oneWaysFromMe    = meLinkedToOthers \\ twoWays
            oneWaysToMe      = othersLinkedToMe \\ twoWays
            twoWayMsgs       = [ "Two-way links:",                mkSingsList True  twoWays       ]
            oneWayFromMeMsgs = [ "One-way links from your mind:", mkSingsList False oneWaysFromMe ]
            oneWayToMeMsgs   = [ "One-way links to your mind:",   mkSingsList False oneWaysToMe   ]
            mkSingsList doStyle ss = let (awakes, asleeps) = sortAwakesAsleeps ss
                                         f                 = doStyle ? styleAbbrevs Don'tQuote :? id
                                     in commas $ f awakes ++ asleeps
            sortAwakesAsleeps      = foldr sorter ([], [])
            sorter linkSing acc    =
                let linkId   = head . filter ((== linkSing) . flip getSing ms) $ ms^.pcTbl.to IM.keys
                    linkPla  = getPla linkId ms
                    f lens x = acc & lens %~ (x' :)
                      where
                        x' = case view (at linkSing) . getTeleLinkTbl i $ ms of
                          Nothing  -> x
                          Just val -> val ? x :? (x <> " " <> parensQuote "tuned out")
                in (linkSing |&|) $ if and [ isLoggedIn linkPla, not . isIncognito $ linkPla ]
                  then f _1
                  else f _2
        in do
           multiWrapSend mq cols msgs
           logPla "link" i . slashes . dropEmpties $ [ twoWays       |!| "Two-way: "         <> commas twoWays
                                                     , oneWaysFromMe |!| "One-way from me: " <> commas oneWaysFromMe
                                                     , oneWaysToMe   |!| "One-way to me: "   <> commas oneWaysToMe ]
link (LowerNub i mq cols as) = getState >>= \ms -> if isIncognitoId i ms
  then wrapSend mq cols . sorryIncog $ "link"
  else helper |&| modifyState >=> \(bs, logMsgs, fs) ->
      bcast bs >> sequence_ fs >> logMsgs |#| (logPla "link" i . slashes)
  where
    helper ms =
        let (inInvs, inEqs, inRms) = sortArgsInvEqRm InRm as
            sorryInInv  = inInvs |!| (mkBroadcast i . nlnl $ sorryLinkInInv)
            sorryInEq   = inEqs  |!| (mkBroadcast i . nlnl $ sorryLinkInEq )
            invCoins    = first (i `delete`) . getPCRmNonIncogInvCoins i $ ms
            (eiss, ecs) = uncurry (resolveRmInvCoins i ms inRms) invCoins
            pt          = ms^.pcTbl
            tlmt        = ms^.teleLinkMstrTbl
            rnmt        = ms^.rndmNamesMstrTbl
            (pt', tlmt', rnmt', bs,  logMsgs, fs) = foldl' (helperLinkEitherInv ms)
                                                           (pt, tlmt, rnmt, [], [], [])
                                                           eiss
            (                   bs', logMsgs'   ) = foldl' helperLinkEitherCoins (bs, logMsgs) ecs
        in if ()!# invCoins
          then ( ms & pcTbl            .~ pt'
                    & teleLinkMstrTbl  .~ tlmt'
                    & rndmNamesMstrTbl .~ rnmt'
               , (sorryInInv ++ sorryInEq ++ bs', logMsgs', fs) )
          else (ms, (mkBroadcast i . nlnl $ sorryLinkNoOneHere, [], []))
    helperLinkEitherInv _  a (Left  sorryMsg ) = ()# sorryMsg ? a :? (a & _4 <>~ (mkBroadcast i . nlnl $ sorryMsg))
    helperLinkEitherInv ms a (Right targetIds) = foldl' tryLink a targetIds
      where
        tryLink a' targetId = let targetSing = getSing targetId ms in case getType targetId ms of
          PCType ->
            let (srcIntros, targetIntros) = f getIntroduced
                (srcLinks,  targetLinks ) = f getLinked
                f g                       = ((i |&|) *** (targetId |&|)) (dup $ uncurry g . (, ms))
                s                         = getSing i ms
                targetDesig               = serialize . mkStdDesig targetId ms $ Don'tCap
                srcMsg    = nlnl . T.concat $ [ focusingInnateMsg
                                              , "you establish a telepathic connection from your mind to "
                                              , targetSing
                                              , "'s mind."
                                              , twoWayMsg ]
                twoWayMsg = isTwoWay |?| " This completes the psionic circuit and you may now communicate with each \
                                         \other telepathically."
                isTwoWay  = targetSing `elem` srcLinks
                logMsg    = T.concat [ "Established a ", oneTwoWay, " link with ", targetSing, "." ]
                oneTwoWay | isTwoWay  = "two-way"
                          | otherwise = "one-way"
                targetMsg = nlnl . T.concat $ [ "You sense an ephemeral blip in your psionic energy field as "
                                              , knownNameColor
                                              , s
                                              , dfltColor
                                              , " establishes a telepathic connection from "
                                              , mkPossPro . getSex i $ ms
                                              , " mind to yours."
                                              , twoWayMsg ]
                bs            = [ (srcMsg, pure i), (targetMsg, pure targetId) ]
                msgHelper txt = a' & _4 <>~ (mkBroadcast i . nlnl $ txt)
            in if
              | targetSing `notElem` srcIntros    -> msgHelper . sorryLinkIntroTarget       $ targetDesig
              | s          `notElem` targetIntros -> msgHelper . sorryLinkIntroSelf         $ targetSing
              | s             `elem` targetLinks  -> msgHelper . sorryLinkAlready oneTwoWay $ targetDesig
              | act <- rndmDo (calcProbLinkFlinch targetId ms) . mkExpAction "flinch" . mkActionParams targetId ms $ [] ->
                  let g a'' | isTwoWay  = a''
                            | otherwise = a'' & _3.ind i       .at targetSing .~ Nothing
                                              & _3.ind targetId.at s          .~ Nothing
                  in g $ a' & _1.ind targetId.linked %~ (sort . (s :))
                            & _2.ind i       .at targetSing ?~ True
                            & _2.ind targetId.at s          ?~ True
                            & _4 <>~ bs
                            & _5 <>~ pure logMsg
                            & _6 <>~ pure act
          _  -> let b = (nlnl . sorryLinkType $ targetSing, pure i)
                in a' & _4 %~ (`appendIfUnique` b)
    helperLinkEitherCoins a (Left  msgs) = a & _1 <>~ (mkBroadcast i . T.concat $ [ nlnl msg | msg <- msgs ])
    helperLinkEitherCoins a (Right {}  ) =
        let b = (nlnl sorryLinkCoin, pure i)
        in first (`appendIfUnique` b) a
link p = patternMatchFail "link" [ showText p ]


-----


look :: Action
look (NoArgs i mq cols) = getState >>= \ms ->
    let ri        = getRmId i  ms
        r         = getRm   ri ms
        top       = fillerToSpcs . multiWrap cols $ theRmName : theRmDesc
        theRmName = views rmName (underline . quoteWith filler) r
        theRmDesc = views rmDesc formatRmDesc r
        bottom    = [ mkExitsSummary cols r, mkRmInvCoinsDesc i cols ms ri ]
    in send mq . nl . T.concat $ top : bottom
  where
    filler       = T.singleton indentFiller
    formatRmDesc = map (T.replicate rmDescIndentAmt filler <>) . T.lines
look (LowerNub i mq cols as) = helper |&| modifyState >=> \(msg, bs, maybeTargetDesigs) -> do
    send mq msg
    bcastIfNotIncog i bs
    let logHelper targetDesigs | targetSings <- [ fromJust . stdPCEntSing $ targetDesig
                                                | targetDesig <- targetDesigs ]
                               = logPla "look" i $ "looked at: " <> commas targetSings <> "."
    maybeVoid logHelper maybeTargetDesigs
  where
    helper ms = let invCoins = first (i `delete`) . getPCRmNonIncogInvCoins i $ ms in if ()!# invCoins
        then let (inInvs, inEqs, inRms) = sortArgsInvEqRm InRm as
                 sorryInInv             = wrapUnlinesNl cols . sorryEquipInvLook LookCmd $ InvCmd
                 sorryInEq              = wrapUnlinesNl cols . sorryEquipInvLook LookCmd $ EquipCmd
                 (eiss, ecs)            = uncurry (resolveRmInvCoins i ms inRms) invCoins
                 invDesc                = foldl' (helperLookEitherInv ms) "" eiss
                 coinsDesc              = foldl' helperLookEitherCoins    "" ecs
                 (pt, msg)              = firstLook i cols (ms^.plaTbl, T.concat [ inInvs |!| sorryInInv
                                                                                 , inEqs  |!| sorryInEq
                                                                                 , invDesc
                                                                                 , coinsDesc ])
                 selfDesig              = mkStdDesig i ms DoCap
                 selfDesig'             = serialize selfDesig
                 pis                    = i `delete` pcIds selfDesig
                 targetDesigs           = [ mkStdDesig targetId ms Don'tCap | targetId <- extractPCIdsFromEiss ms eiss ]
                 mkBroadcastsForTarget targetDesig acc =
                     let targetId = pcId targetDesig
                         toTarget = (nlnl $ selfDesig' <> " looks at you.", pure targetId)
                         toOthers = ( nlnl . T.concat $ [ selfDesig', " looks at ", serialize targetDesig, "." ]
                                    , targetId `delete` pis)
                     in toTarget : toOthers : acc
                 ms' = ms & plaTbl .~ pt
             in (ms', (msg, foldr mkBroadcastsForTarget [] targetDesigs, targetDesigs |!| Just targetDesigs))
        else let msg        = wrapUnlinesNl cols sorryLookNothingHere
                 (pt, msg') = firstLook i cols (ms^.plaTbl, msg)
                 ms'        = ms & plaTbl .~ pt
             in (ms', (msg', [], Nothing))
    helperLookEitherInv _  acc (Left  msg ) = acc <> wrapUnlinesNl cols msg
    helperLookEitherInv ms acc (Right is  ) = nl $ acc <> mkEntDescs i cols ms is
    helperLookEitherCoins  acc (Left  msgs) = (acc <>) . multiWrapNl cols . intersperse "" $ msgs
    helperLookEitherCoins  acc (Right c   ) = nl $ acc <> mkCoinsDesc cols c
look p = patternMatchFail "look" [ showText p ]


mkRmInvCoinsDesc :: Id -> Cols -> MudState -> Id -> T.Text
mkRmInvCoinsDesc i cols ms ri =
    let (ris, c)            = first (i `delete`) . getNonIncogInvCoins ri $ ms
        (pcNcbs, otherNcbs) = splitPCsOthers . mkIsPC_StyledName_Count_BothList i ms $ ris
        pcDescs             = T.unlines . concatMap (wrapIndent 2 cols . mkPCDesc   ) $ pcNcbs
        otherDescs          = T.unlines . concatMap (wrapIndent 2 cols . mkOtherDesc) $ otherNcbs
    in (pcNcbs |!| pcDescs) <> (otherNcbs |!| otherDescs) <> (c |!| mkCoinsSummary cols c)
  where
    splitPCsOthers                       = (both %~ map snd) . span fst
    mkPCDesc    (en, c, (s, _)) | c == 1 = (<> " " <> en) $ if isKnownPCSing s
                                             then knownNameColor   <> s       <> dfltColor
                                             else unknownNameColor <> aOrAn s <> dfltColor
    mkPCDesc    (en, c, b     )          = T.concat [ unknownNameColor
                                                    , showText c
                                                    , " "
                                                    , mkPlurFromBoth b
                                                    , dfltColor
                                                    , " "
                                                    , en ]
    mkOtherDesc (en, c, (s, _)) | c == 1 = aOrAnOnLower s <> " " <> en
    mkOtherDesc (en, c, b     )          = T.concat [ showText c, " ", mkPlurFromBoth b, " ", en ]


mkIsPC_StyledName_Count_BothList :: Id -> MudState -> Inv -> [(Bool, (T.Text, Int, BothGramNos))]
mkIsPC_StyledName_Count_BothList i ms targetIds =
  let isPCs   =                      [ getType targetId ms == PCType   | targetId <- targetIds ]
      styleds = styleAbbrevs DoQuote [ getEffName        i ms targetId | targetId <- targetIds ]
      boths   =                      [ getEffBothGramNos i ms targetId | targetId <- targetIds ]
      counts  = mkCountList boths
  in nub . zip isPCs . zip3 styleds counts $ boths


firstLook :: Id -> Cols -> (PlaTbl, T.Text) -> (PlaTbl, T.Text)
firstLook i cols a@(pt, _)
  | pt^.ind i.to isNotFirstLook = a
  | otherwise = a & _1.ind i %~ setPlaFlag IsNotFirstLook True & _2 <>~ wrapUnlinesNl cols hintLook


isKnownPCSing :: Sing -> Bool
isKnownPCSing s = case T.words s of [ "male",   _ ] -> False
                                    [ "female", _ ] -> False
                                    _               -> True


extractPCIdsFromEiss :: MudState -> [Either T.Text Inv] -> [Id]
extractPCIdsFromEiss ms = foldl' helper []
  where
    helper acc (Left  {})  = acc
    helper acc (Right is)  = acc ++ findPCIds ms is


-----


motd :: Action
motd (NoArgs i mq cols) = showMotd mq cols >> logPlaExec "motd" i
motd p                  = withoutArgs motd p


showMotd :: MsgQueue -> Cols -> MudStack ()
showMotd mq cols = send mq =<< helper
  where
    helper    = liftIO readMotd |&| try >=> eitherRet handler
    readMotd  = [ frame cols . multiWrap cols . T.lines . colorizeFileTxt motdColor $ cont
                | cont <- T.readFile motdFile ]
    handler e = do
        fileIOExHandler "showMotd" e
        return . wrapUnlinesNl cols $ motdErrorMsg


-----


-- TODO: Creating a new channel should cost psionic points.
newChan :: Action
newChan p@AdviseNoArgs                   = advise p ["newchannel"] adviceNewChanNoArgs
newChan (WithArgs i mq cols (nub -> as)) = helper |&| modifyState >=> \(unzip -> (newChanNames, chanRecs), sorryMsgs) ->
    let (sorryMsgs', otherMsgs) = (intersperse "" sorryMsgs, mkNewChanMsg newChanNames)
        msgs                    = ()# sorryMsgs' ? otherMsgs :? sorryMsgs' ++ (otherMsgs |!| "" : otherMsgs)
    in do
        multiWrapSend mq cols msgs
        newChanNames |#| logPla "newChan" i . commas
        ts <- liftIO mkTimestamp
        forM_ chanRecs $ \cr -> withDbExHandler_ "newChan" . insertDbTblChan $ cr { chanTimestamp = ts }
  where
    helper ms = let s                              = getSing i ms
                    (ms', newChanNames, sorryMsgs) = foldl' (f s) (ms, [], []) as
                in (ms', (newChanNames, sorryMsgs))
      where
        f s triple a@(T.toLower -> a')
          | T.length a > maxChanNameLen =
              let msg = "a channel name may not be more than " <> showText maxChanNameLen <> " characters long"
              in triple & _3 <>~ (pure . sorryNewChanName a $ msg)
          | T.any isNG a = triple & _3 <>~ (pure . sorryNewChanName a $ "a channel name may only contain alphabetic \
                                                                        \letters and digits")
          | a' `elem` illegalNames = triple & _3 <>~ (pure . sorryNewChanName a $ "this name is reserved or already in \
                                                                                  \use")
          | a' `elem` map T.toLower myChanNames
          , match <- head . filter ((== a') . T.toLower) $ myChanNames
          = triple & _3 <>~ (pure . sorryNewChanExisting $ match)
          | otherwise = let ci = views chanTbl (head . ([0..] \\) . IM.keys) $ triple^._1
                            c  = Chan ci a (M.fromList . pure $ (s, True)) []
                            cr = ChanRec "" ci a s . asteriskQuote $ "New channel created."
                        in triple & _1.chanTbl.at ci ?~ c
                                  & _2 <>~ pure (a, cr)
        isNG c           = not $ isLetter c || isDigit c
        illegalNames     = [ "admin", "all", "question" ] ++ pcNames
        pcNames          = map (uncapitalize . (`getSing` ms)) $ ms^.pcTbl.to IM.keys
        myChanNames      = map (view chanName) . getPCChans i $ ms
    mkNewChanMsg []     = []
    mkNewChanMsg ns@[_] = pure    . mkMsgHelper False $ ns
    mkNewChanMsg ns     = T.lines . mkMsgHelper True  $ ns
    mkMsgHelper isPlur (map dblQuote -> ns) =
        T.concat [ focusingInnateMsg
                 , "you create a "
                 , isPlur |?| "group of "
                 , "telepathic network"
                 , theLetterS isPlur
                 , " to which others may be connected. To "
                 , isPlur ? "these " :? "this "
                 , dblQuote . ("channel" <>) . theLetterS $ isPlur
                 , " you assign the "
                 , isPlur |?| "following "
                 , "name"
                 , isPlur ? "s:\n" <> commas ns :? " " <> head ns
                 , "." ]
newChan p = patternMatchFail "newChan" [ showText p ]


-----


plaDispCmdList :: Action
plaDispCmdList p@(LowerNub' i as) = dispCmdList plaCmds p >> logPlaExecArgs "?" as i
plaDispCmdList p                  = patternMatchFail "plaDispCmdList" [ showText p ]


-----


putAction :: Action
putAction p@AdviseNoArgs     = advise p ["put"] advicePutNoArgs
putAction p@(AdviseOneArg a) = advise p ["put"] . advicePutNoCon $ a
putAction (Lower' i as) = helper |&| modifyState >=> \(bs, logMsgs) ->
    bcastIfNotIncogNl i bs >> logMsgs |#| logPlaOut "put" i
  where
    helper ms | (d, pcInvCoins, rmInvCoins, conName, argsWithoutCon) <- mkPutRemoveBindings i ms as =
      if ()!# pcInvCoins
        then case singleArgInvEqRm InInv conName of
          (InInv, conName') -> shufflePut i ms d conName' False argsWithoutCon pcInvCoins pcInvCoins procGecrMisPCInv
          (InEq,  _       ) -> (ms, (mkBroadcast i . sorryConInEq $ Put, []))
          (InRm,  conName') -> if ()!# fst rmInvCoins
            then shufflePut i ms d conName' True argsWithoutCon rmInvCoins pcInvCoins procGecrMisRm
            else (ms, (mkBroadcast i sorryNoConHere, []))
        else (ms, (mkBroadcast i dudeYourHandsAreEmpty, []))
putAction p = patternMatchFail "putAction" [ showText p ]


type CoinsWithCon = Coins
type PCInv        = Inv
type PCCoins      = Coins


shufflePut :: Id
           -> MudState
           -> PCDesig
           -> ConName
           -> IsConInRm
           -> Args
           -> (InvWithCon, CoinsWithCon)
           -> (PCInv, PCCoins)
           -> ((GetEntsCoinsRes, Maybe Inv) -> Either T.Text Inv)
           -> (MudState, ([Broadcast], [T.Text]))
shufflePut i ms d conName icir as invCoinsWithCon@(invWithCon, _) pcInvCoins f =
    let (conGecrs, conMiss, conRcs) = uncurry (resolveEntCoinNames i ms (pure conName)) invCoinsWithCon
    in if ()# conMiss && ()!# conRcs
      then sorry sorryPutInCoin
      else case f . head . zip conGecrs $ conMiss of
        Left  msg     -> sorry msg
        Right [conId] -> let conSing = getSing conId ms in if getType conId ms /= ConType
          then sorry . sorryCon $ conSing
          else let (inInvs, inEqs, inRms) = sortArgsInvEqRm InInv as
                   sorryInEq = inEqs |!| mkBroadcast i sorryPutInEq
                   sorryInRm = inRms |!| mkBroadcast i sorryPutInRm
                   (gecrs, miss, rcs)  = uncurry (resolveEntCoinNames i ms inInvs) pcInvCoins
                   eiss                = zipWith (curry procGecrMisPCInv) gecrs miss
                   ecs                 = map procReconciledCoinsPCInv rcs
                   mnom                = mkMaybeNthOfM ms icir conId conSing invWithCon
                   (it, bs,  logMsgs ) = foldl' (helperPutRemEitherInv   i ms d Put mnom i conId conSing)
                                                (ms^.invTbl,   [], [])
                                                eiss
                   (ct, bs', logMsgs') =         helperPutRemEitherCoins i    d Put mnom i conId conSing
                                                (ms^.coinsTbl, bs, logMsgs)
                                                ecs
               in (ms & invTbl .~ it & coinsTbl .~ ct, (sorryInEq ++ sorryInRm ++ bs', logMsgs'))
        Right {} -> sorry sorryPutExcessCon
  where
    sorry msg = (ms, (mkBroadcast i msg, []))


-----


question :: Action
question (NoArgs' i mq) = getState >>= \ms ->
    let (plaIds,    adminIds) = (getLoggedInPlaIds ms, getNonIncogLoggedInAdminIds ms) & both %~ (i `delete`)
        (linkedIds, otherIds) = partition (isLinked ms . (i, )) plaIds
    in mapM (updateRndmName i) otherIds >>= \rndmNames ->
           let rndms   = zip3 otherIds rndmNames . repeat $ False
               linkeds = [ (li, getSing li ms, isAdminId li ms) | li <- linkedIds ]
               admins  = [ (ai, getSing ai ms, True           ) | ai <- adminIds  ]
               (tunedIns, tunedOuts) =
                 let xs = rndms ++ nubSort (linkeds ++ admins)
                 in partition (views _1 (`isTunedQuestionId` ms)) . sortBy (compare `on` view _2) $ xs
               styleds = styleAbbrevs Don'tQuote . map (view _2) $ tunedIns
               combo   = map f $ zipWith (\styled -> _2 .~ styled) styleds tunedIns ++ tunedOuts
                 where
                  f (i', n, ia) | ia           = (i', n <> asterisk)
                                | isRndmName n = (i', underline n  )
                                | otherwise    = (i', n            )
               mkDesc (i', n) = pad (succ namePadding) n <> (tunedInOut . isTunedQuestionId i' $ ms)
               descs          = mkDesc (i, getSing i ms <> (isAdminId i ms |?| asterisk)) : map mkDesc combo
               descs'         = "Question channel:" : descs
           in pager i mq descs' >> logPlaExecArgs "question" [] i
question (Msg i mq cols msg) = getState >>= \ms -> if
  | not . isTunedQuestionId i $ ms -> wrapSend mq cols . sorryTunedOutOOCChan $ "question"
  | isIncognitoId i ms             -> wrapSend mq cols . sorryChanIncog $ "the question"
  | otherwise                      -> getQuestionStyleds i ms >>= \triples -> if ()# triples
    then wrapSend mq cols . sorryChanNoOneListening $ "question"
    else let ioHelper (expandEmbeddedIdsToSings ms -> logMsg) bs = do
                 bcastNl =<< expandEmbeddedIds ms questionChanContext bs
                 logPlaOut "question" i . pure $ logMsg
                 ts <- liftIO mkTimestamp
                 withDbExHandler_ "question" . insertDbTblQuestion . QuestionRec ts s $ logMsg
             s    = getSing i ms
             f bs = let logMsg = dropANSI . fst . head $ bs
                    in ioHelper logMsg =<< g bs
             g    = concatMapM (formatQuestion i ms)
             ws   = wrapSend      mq cols
             mws  = multiWrapSend mq cols
          in case targetify i questionChanContext triples msg of
            Left  errorMsg   -> ws errorMsg
            Right (Right bs) -> f bs
            Right (Left  ()) -> case emotify i ms questionChanContext triples msg of
              Left  errorMsgs  -> mws errorMsgs
              Right (Right bs) -> f bs
              Right (Left  ()) -> case expCmdify i ms questionChanContext triples msg of
                Left  errorMsg     -> ws errorMsg
                Right (bs, logMsg) -> ioHelper logMsg =<< g bs
question p = patternMatchFail "question" [ showText p ]


-----


quit :: Action
quit (NoArgs' i mq)                        = logPlaExec "quit" i >> (liftIO . atomically . writeTQueue mq $ Quit)
quit ActionParams { plaMsgQueue, plaCols } = wrapSend plaMsgQueue plaCols adviceQuitExcessArgs


handleEgress :: Id -> MudStack ()
handleEgress i = liftIO getCurrentTime >>= \now -> do
    informEgress
    helper now |&| modifyState >=> \(s, bs, logMsgs) -> do
        throwWaitRegen i
        closePlaLog    i
        bcast bs
        bcastAdmins $ s <> " has left CurryMUD."
        forM_ logMsgs $ uncurry (logPla "handleEgress")
        logNotice "handleEgress" . T.concat $ [ "player ", showText i, " ", parensQuote s, " has left CurryMUD." ]
  where
    informEgress = getState >>= \ms -> let d = serialize . mkStdDesig i ms $ DoCap in
        unless (getRmId i ms == iWelcome) . bcastOthersInRm i . nlnl . egressMsg $ d
    helper now ms =
        let ri                 = getRmId i  ms
            s                  = getSing i  ms
            (ms', bs, logMsgs) = peepHelper ms s
            ms''               = if T.takeWhile (not . isDigit) s `elem` map showText (allValues :: [Race])
                                   then removeAdHoc i ms'
                                   else updateHostMap (movePC ms' ri) s now
        in (ms'', (s, bs, logMsgs))
    peepHelper ms s =
        let (peeperIds, peepingIds) = getPeepersPeeping i ms
            bs                      = [ (nlnl    . T.concat $ [ "You are no longer peeping "
                                                              , s
                                                              , " "
                                                              , parensQuote $ s <> " has disconnected"
                                                              , "." ], pure peeperId) | peeperId <- peeperIds ]
            logMsgs                 = [ (peeperId, T.concat   [ "no longer peeping "
                                                              , s
                                                              , " "
                                                              , parensQuote $ s <> " has disconnected"
                                                              , "." ]) | peeperId <- peeperIds ]
        in (ms & plaTbl %~ stopPeeping     peepingIds
               & plaTbl %~ stopBeingPeeped peeperIds
               & plaTbl.ind i.peeping .~ []
               & plaTbl.ind i.peepers .~ [], bs, logMsgs)
      where
        stopPeeping     peepingIds pt = let f peepedId ptAcc = ptAcc & ind peepedId.peepers %~ (i `delete`)
                                        in foldr f pt peepingIds
        stopBeingPeeped peeperIds  pt = let f peeperId ptAcc = ptAcc & ind peeperId.peeping %~ (i `delete`)
                                        in foldr f pt peeperIds
    movePC ms ri = ms & invTbl     .ind ri         %~ (i `delete`)
                      & invTbl     .ind iLoggedOut %~ (i :)
                      & msgQueueTbl.at  i          .~ Nothing
                      & pcTbl      .ind i.rmId     .~ iLoggedOut
                      & plaTbl     .ind i.lastRmId ?~ ri
    updateHostMap ms s now = flip (set $ hostTbl.at s) ms $ case getHostMap s ms of
      Nothing      -> Just . M.singleton host $ newRecord
      Just hostMap -> case hostMap^.at host of Nothing -> Just $ hostMap & at host ?~ newRecord
                                               Just r  -> Just $ hostMap & at host ?~ reviseRecord r
      where
        newRecord      = HostRecord { _noOfLogouts   = 1
                                    , _secsConnected = duration
                                    , _lastLogout    = now }
        reviseRecord r = r & noOfLogouts   +~ 1
                           & secsConnected +~ duration
                           & lastLogout    .~ now
        host           = getCurrHostName i ms
        duration       = round $ now `diffUTCTime` conTime
        conTime        = fromJust . getConnectTime i $ ms


-----


quitCan'tAbbrev :: Action
quitCan'tAbbrev (NoArgs _ mq cols) = wrapSend mq cols sorryQuitCan'tAbbrev
quitCan'tAbbrev p                  = withoutArgs quitCan'tAbbrev p


-----


ready :: Action
ready p@AdviseNoArgs   = advise p ["ready"] adviceReadyNoArgs
ready (LowerNub' i as) = helper |&| modifyState >=> \(bs, logMsgs) ->
    bcastIfNotIncogNl i bs >> logMsgs |#| logPlaOut "ready" i
  where
    helper ms =
        let (inInvs, inEqs, inRms) = sortArgsInvEqRm InInv as
            sorryInEq = inEqs |!| mkBroadcast i sorryReadyInEq
            sorryInRm = inRms |!| mkBroadcast i sorryReadyInRm
            invCoins@(is, _)          = getInvCoins i ms
            d                         = mkStdDesig  i ms DoCap
            (gecrs, mrols, miss, rcs) = resolveEntCoinNamesWithRols i ms inInvs is mempty
            eiss                      = zipWith (curry procGecrMisReady) gecrs miss
            bs                        = rcs |!| mkBroadcast i sorryReadyCoins
            (et, it, bs', logMsgs)    = foldl' (helperReady i ms d) (ms^.eqTbl, ms^.invTbl, bs, []) . zip eiss $ mrols
        in if ()!# invCoins
          then (ms & eqTbl .~ et & invTbl .~ it, (sorryInEq ++ sorryInRm ++ bs', logMsgs))
          else (ms, (mkBroadcast i dudeYourHandsAreEmpty, []))
ready p = patternMatchFail "ready" [ showText p ]


helperReady :: Id
            -> MudState
            -> PCDesig
            -> (EqTbl, InvTbl, [Broadcast], [T.Text])
            -> (Either T.Text Inv, Maybe RightOrLeft)
            -> (EqTbl, InvTbl, [Broadcast], [T.Text])
helperReady i _  _ a (Left  (mkBroadcast i -> b), _   ) = a & _3 <>~ b
helperReady i ms d a (Right targetIds,            mrol) = foldl' (readyDispatcher i ms d mrol) a targetIds


readyDispatcher :: Id
                -> MudState
                -> PCDesig
                -> Maybe RightOrLeft
                -> (EqTbl, InvTbl, [Broadcast], [T.Text])
                -> Id
                -> (EqTbl, InvTbl, [Broadcast], [T.Text])
readyDispatcher i ms d mrol a targetId = let targetSing = getSing targetId ms in
    helper |&| maybe (sorry targetSing) (\f -> f i ms d mrol a targetId targetSing)
  where
    helper = case getType targetId ms of
      ClothType -> Just readyCloth
      ConType   -> toMaybe (getIsCloth targetId ms) readyCloth
      WpnType   -> Just readyWpn
      ArmType   -> Just readyArm
      _         -> Nothing
    sorry targetSing = a & _3 <>~ (mkBroadcast i . sorryReadyType $ targetSing)


-- Readying clothing:


readyCloth :: Id
           -> MudState
           -> PCDesig
           -> Maybe RightOrLeft
           -> (EqTbl, InvTbl, [Broadcast], [T.Text])
           -> Id
           -> Sing
           -> (EqTbl, InvTbl, [Broadcast], [T.Text])
readyCloth i ms d mrol a@(et, _, _, _) clothId clothSing | em <- et ! i, cloth <- getCloth clothId ms =
  case mrol |&| maybe (getAvailClothSlot i ms cloth em) (getDesigClothSlot ms clothSing cloth em) of
      Left  (mkBroadcast i -> b) -> a & _3 <>~ b
      Right slot                 -> moveReadiedItem i a slot clothId . mkReadyClothMsgs slot $ cloth
  where
    mkReadyClothMsgs (pp -> slot) = \case
      Earring  -> wearMsgs
      NoseRing -> putOnMsgs i d clothSing
      Necklace -> putOnMsgs i d clothSing
      Bracelet -> wearMsgs
      Ring     -> slideMsgs
      Backpack -> putOnMsgs i d clothSing
      _        -> donMsgs   i d clothSing
      where
        wearMsgs   = (   T.concat [ "You wear the ",  clothSing, " on your ", slot, "." ]
                     , ( T.concat [ serialize d, " wears ",  aOrAn clothSing, " on ", poss, " ", slot, "." ]
                       , otherPCIds ) )
        slideMsgs  = (   T.concat [ "You slide the ", clothSing, " on your ", slot, "." ]
                     , ( T.concat [ serialize d, " slides ", aOrAn clothSing, " on ", poss, " ", slot, "." ]
                       , otherPCIds) )
        poss       = mkPossPro . getSex i $ ms
        otherPCIds = i `delete` pcIds d


getAvailClothSlot :: Id -> MudState -> Cloth -> EqMap -> Either T.Text Slot
getAvailClothSlot i ms cloth em | sexy <- getSex i ms, h <- getHand i ms =
    maybe (Left sorry) Right $ case cloth of
      Earring  -> getEarringSlotForSex sexy `mplus` (getEarringSlotForSex . otherSex $ sexy)
      NoseRing -> findAvailSlot em noseRingSlots
      Necklace -> findAvailSlot em necklaceSlots
      Bracelet -> getBraceletSlotForHand h  `mplus` (getBraceletSlotForHand . otherHand $ h)
      Ring     -> getRingSlot sexy h
      _        -> maybeSingleSlot em . clothToSlot $ cloth
  where
    getEarringSlotForSex sexy = findAvailSlot em $ case sexy of
      Male   -> lEarringSlots
      Female -> rEarringSlots
      _      -> patternMatchFail "getAvailClothSlot getEarringSlotForSex"   [ showText sexy ]
    getBraceletSlotForHand h  = findAvailSlot em $ case h of
      RHand  -> lBraceletSlots
      LHand  -> rBraceletSlots
      _      -> patternMatchFail "getAvailClothSlot getBraceletSlotForHand" [ showText h    ]
    getRingSlot sexy h        = findAvailSlot em $ case sexy of
      Male    -> case h of
        RHand -> [ RingLRS, RingLIS, RingRRS, RingRIS, RingLMS, RingRMS, RingLPS, RingRPS ]
        LHand -> [ RingRRS, RingRIS, RingLRS, RingLIS, RingRMS, RingLMS, RingRPS, RingLPS ]
        _     -> patternMatchFail "getAvailClothSlot getRingSlot" [ showText h ]
      Female  -> case h of
        RHand -> [ RingLRS, RingLIS, RingRRS, RingRIS, RingLPS, RingRPS, RingLMS, RingRMS ]
        LHand -> [ RingRRS, RingRIS, RingLRS, RingLIS, RingRPS, RingLPS, RingRMS, RingLMS ]
        _     -> patternMatchFail "getAvailClothSlot getRingSlot" [ showText h    ]
      _       -> patternMatchFail "getAvailClothSlot getRingSlot" [ showText sexy ]
    sorry | cloth `elem` [ Earring .. Ring ]                   = sorryReadyClothFull      . pp $ cloth
          | cloth `elem` [ Skirt, Dress, Backpack, Cloak ]     = sorryReadyAlreadyWearing . pp $ cloth
          | ci <- em M.! clothToSlot cloth, s <- getSing ci ms = sorryReadyAlreadyWearing        s


otherSex :: Sex -> Sex
otherSex Male   = Female
otherSex Female = Male
otherSex NoSex  = NoSex


rEarringSlots, lEarringSlots, noseRingSlots, necklaceSlots, rBraceletSlots, lBraceletSlots :: [Slot]
rEarringSlots  = [ EarringR1S,    EarringR2S  ]
lEarringSlots  = [ EarringL1S,    EarringL2S  ]
noseRingSlots  = [ NoseRing1S,    NoseRing2S  ]
necklaceSlots  = [ Necklace1S  .. Necklace2S  ]
rBraceletSlots = [ BraceletR1S .. BraceletR3S ]
lBraceletSlots = [ BraceletL1S .. BraceletL3S ]


getDesigClothSlot :: MudState -> Sing -> Cloth -> EqMap -> RightOrLeft -> Either T.Text Slot
getDesigClothSlot ms clothSing cloth em rol
  | cloth `elem` [ NoseRing, Necklace ] ++ [ Shirt .. Cloak ] = sorryRol
  | isRingRol rol, cloth /= Ring                              = sorryRol
  | cloth == Ring, not . isRingRol $ rol                      = Left ringHelp
  | otherwise = case cloth of
    Earring  -> findSlotFromList rEarringSlots  lEarringSlots  |&| maybe (Left sorryEarring ) Right
    Bracelet -> findSlotFromList rBraceletSlots lBraceletSlots |&| maybe (Left sorryBracelet) Right
    Ring     -> M.lookup slotFromRol em |&| maybe (Right slotFromRol)
                                                  (Left . sorryReadyAlreadyWearingRing slotFromRol . (`getSing` ms))
    _        -> patternMatchFail "getDesigClothSlot" [ showText cloth ]
  where
    findSlotFromList rs ls = findAvailSlot em $ case rol of
      R -> rs
      L -> ls
      _ -> patternMatchFail "getDesigClothSlot findSlotFromList" [ showText rol ]
    getSlotFromList  rs ls = head $ case rol of
      R -> rs
      L -> ls
      _ -> patternMatchFail "getDesigClothSlot getSlotFromList"  [ showText rol ]
    sorryRol         = Left . sorryReadyRol clothSing $ rol
    sorryEarring     = sorryReadyClothFullOneSide cloth . getSlotFromList rEarringSlots  $ lEarringSlots
    sorryBracelet    = sorryReadyClothFullOneSide cloth . getSlotFromList rBraceletSlots $ lBraceletSlots
    slotFromRol      = fromRol rol :: Slot


-- Readying weapons:


readyWpn :: Id
         -> MudState
         -> PCDesig
         -> Maybe RightOrLeft
         -> (EqTbl, InvTbl, [Broadcast], [T.Text])
         -> Id
         -> Sing
         -> (EqTbl, InvTbl, [Broadcast], [T.Text])
readyWpn i ms d mrol a@(et, _, _, _) wpnId wpnSing | em <- et ! i, wpn <- getWpn wpnId ms, sub <- wpn^.wpnSub =
    if not . isSlotAvail em $ BothHandsS
      then let b = mkBroadcast i sorryReadyAlreadyWieldingTwoHanded in a & _3 <>~ b
               else case mrol |&| maybe (getAvailWpnSlot ms i em) (getDesigWpnSlot ms wpnSing em) of
        Left  (mkBroadcast i -> b) -> a & _3 <>~ b
        Right slot  -> case sub of
          OneHanded -> let readyMsgs = (   T.concat [ "You wield the ", wpnSing, " with your ", pp slot, "." ]
                                       , ( T.concat [ serialize d
                                                    , " wields "
                                                    , aOrAn wpnSing
                                                    , " with "
                                                    , poss
                                                    , " "
                                                    , pp slot
                                                    , "." ]
                                         , otherPCIds ) )
                       in moveReadiedItem i a slot wpnId readyMsgs
          TwoHanded
            | all (isSlotAvail em) [ RHandS, LHandS ] ->
                let readyMsgs = ( "You wield the " <> wpnSing <> " with both hands."
                                , ( T.concat [ serialize d, " wields ", aOrAn wpnSing, " with both hands." ]
                                  , otherPCIds ) )
                in moveReadiedItem i a BothHandsS wpnId readyMsgs
            | otherwise -> let b = mkBroadcast i . sorryReadyWpnHands $ wpnSing
                           in a & _3 <>~ b
  where
    poss       = mkPossPro . getSex i $ ms
    otherPCIds = i `delete` pcIds d


getAvailWpnSlot :: MudState -> Id -> EqMap -> Either T.Text Slot
getAvailWpnSlot ms i em = let h@(otherHand -> oh) = getHand i ms in
    (findAvailSlot em . map getSlotForHand $ [ h, oh ]) |&| maybe (Left sorryReadyAlreadyWieldingTwoWpns) Right
  where
    getSlotForHand h = case h of RHand -> RHandS
                                 LHand -> LHandS
                                 _     -> patternMatchFail "getAvailWpnSlot getSlotForHand" [ showText h ]


getDesigWpnSlot :: MudState -> Sing -> EqMap -> RightOrLeft -> Either T.Text Slot
getDesigWpnSlot ms wpnSing em rol
  | isRingRol rol = Left . sorryReadyWpnRol $ wpnSing
  | otherwise     = M.lookup desigSlot em |&| maybe (Right desigSlot) (Left . sorry)
  where
    desigSlot = case rol of R -> RHandS
                            L -> LHandS
                            _ -> patternMatchFail "getDesigWpnSlot desigSlot" [ showText rol ]
    sorry i   = sorryReadyAlreadyWielding (getSing i ms) desigSlot


-- Readying armor:


readyArm :: Id
         -> MudState
         -> PCDesig
         -> Maybe RightOrLeft
         -> (EqTbl, InvTbl, [Broadcast], [T.Text])
         -> Id
         -> Sing
         -> (EqTbl, InvTbl, [Broadcast], [T.Text])
readyArm i ms d mrol a@(et, _, _, _) armId armSing | em <- et ! i, sub <- getArmSub armId ms =
    case mrol |&| maybe (getAvailArmSlot ms sub em) sorry of
      Left  (mkBroadcast i -> b) -> a & _3 <>~ b
      Right slot                 -> moveReadiedItem i a slot armId . mkReadyArmMsgs $ sub
  where
    sorry          = Left . sorryReadyRol armSing
    mkReadyArmMsgs = \case
      Head   -> putOnMsgs                     i d armSing
      Hands  -> putOnMsgs                     i d armSing
      Feet   -> putOnMsgs                     i d armSing
      Shield -> mkReadyMsgs "ready" "readies" i d armSing
      _      -> donMsgs                       i d armSing


getAvailArmSlot :: MudState -> ArmSub -> EqMap -> Either T.Text Slot
getAvailArmSlot ms (armSubToSlot -> slot) em = maybeSingleSlot em slot |&| maybe (Left sorry) Right
  where
    sorry | i <- em M.! slot, s <- getSing i ms = sorryReadyAlreadyWearing s


-----


remove :: Action
remove p@AdviseNoArgs     = advise p ["remove"] adviceRemoveNoArgs
remove p@(AdviseOneArg a) = advise p ["remove"] . adviceRemoveNoCon $ a
remove (Lower' i as) = helper |&| modifyState >=> \(bs, logMsgs) ->
    bcastIfNotIncogNl i bs >> logMsgs |#| logPlaOut "remove" i
  where
    helper ms | (d, pcInvCoins, rmInvCoins, conName, argsWithoutCon) <- mkPutRemoveBindings i ms as =
        case singleArgInvEqRm InInv conName of
          (InInv, conName') -> shuffleRem i ms d conName' False argsWithoutCon pcInvCoins procGecrMisPCInv
          (InEq,  _       ) -> (ms, (mkBroadcast i . sorryConInEq $ Rem, []))
          (InRm,  conName') -> if ()!# fst rmInvCoins
            then shuffleRem i ms d conName' True argsWithoutCon rmInvCoins procGecrMisRm
            else (ms, (mkBroadcast i sorryNoConHere, []))
remove p = patternMatchFail "remove" [ showText p ]


shuffleRem :: Id
           -> MudState
           -> PCDesig
           -> ConName
           -> IsConInRm
           -> Args
           -> (InvWithCon, CoinsWithCon)
           -> ((GetEntsCoinsRes, Maybe Inv) -> Either T.Text Inv)
           -> (MudState, ([Broadcast], [T.Text]))
shuffleRem i ms d conName icir as invCoinsWithCon@(invWithCon, _) f =
    let (conGecrs, conMiss, conRcs) = uncurry (resolveEntCoinNames i ms (pure conName)) invCoinsWithCon
    in if ()# conMiss && ()!# conRcs
      then sorry sorryRemCoin
      else case f . head . zip conGecrs $ conMiss of
        Left  msg     -> sorry msg
        Right [conId] -> let conSing = getSing conId ms in if getType conId ms /= ConType
          then sorry . sorryCon $ conSing
          else let (as', guessWhat)    = stripLocPrefs
                   invCoinsInCon       = getInvCoins conId ms
                   (gecrs, miss, rcs)  = uncurry (resolveEntCoinNames i ms as') invCoinsInCon
                   eiss                = zipWith (curry $ procGecrMisCon conSing) gecrs miss
                   ecs                 = map (procReconciledCoinsCon conSing) rcs
                   mnom                = mkMaybeNthOfM ms icir conId conSing invWithCon
                   (it, bs,  logMsgs ) = foldl' (helperPutRemEitherInv   i ms d Rem mnom conId i conSing)
                                                (ms^.invTbl, [], [])
                                                eiss
                   (ct, bs', logMsgs') =         helperPutRemEitherCoins i    d Rem mnom conId i conSing
                                                (ms^.coinsTbl, bs, logMsgs)
                                                ecs
               in if ()!# invCoinsInCon
                 then (ms & invTbl .~ it & coinsTbl .~ ct, (guessWhat ++ bs', logMsgs'))
                 else sorry . sorryRemEmpty $ conSing
        Right {} -> sorry sorryRemExcessCon
  where
    sorry msg                         = (ms, (mkBroadcast i msg, []))
    stripLocPrefs | any hasLocPref as = (map stripLocPref as, mkBroadcast i sorryRemIgnore)
                  | otherwise         = (as,                  []                          )


-----


say :: Action
say p@AdviseNoArgs                    = advise p ["say"] adviceSayNoArgs
say p@(WithArgs i mq cols args@(a:_)) = getState >>= \ms -> if
  | isIncognitoId i ms         -> wrapSend mq cols . sorryIncog $ "say"
  | T.head a == adverbOpenChar -> case parseAdverb . T.unwords $ args of
    Left  msg                    -> adviseHelper msg
    Right (adverb, rest@(T.words -> rs@(head -> r)))
      | T.head r == sayToChar, T.length r > 1 -> if length rs > 1
        then sayTo (Just adverb) (T.tail rest) |&| modifyState >=> bcastAndLog
        else adviseHelper adviceSayToNoUtterance
      | otherwise -> simpleSayHelper ms (Just adverb) rest >>= bcastAndLog
  | T.head a == sayToChar, T.length a > 1 -> if length args > 1
    then sayTo Nothing (T.tail . T.unwords $ args) |&| modifyState >=> bcastAndLog
    else adviseHelper adviceSayToNoUtterance
  | otherwise -> simpleSayHelper ms Nothing (T.unwords args) >>= bcastAndLog
  where
    adviseHelper                = advise p ["say"]
    parseAdverb (T.tail -> msg) = case T.break (== adverbCloseChar) msg of
      (_,   "")            -> Left  adviceAdverbCloseChar
      ("",  _ )            -> Left  adviceEmptyAdverb
      (" ", _ )            -> Left  adviceEmptyAdverb
      (_,   x ) | x == acl -> Left  adviceSayAdverbNoUtterance
      (adverb, right)      -> Right (adverb, T.drop 2 right)
    sayTo maybeAdverb (T.words -> (target:rest@(r:_))) ms =
        let d              = mkStdDesig i ms DoCap
            invCoins       = first (i `delete`) . getPCRmNonIncogInvCoins i $ ms
        in if ()!# invCoins
          then case singleArgInvEqRm InRm target of
            (InInv, _      ) -> sorry sorrySayInInv
            (InEq,  _      ) -> sorry sorrySayInEq
            (InRm,  target') -> case uncurry (resolveRmInvCoins i ms [target']) invCoins of
              (_,                    [ Left [msg] ]) -> sorry msg
              (_,                    Right  _:_    ) -> sorry sorrySayCoins
              ([ Left  msg        ], _             ) -> sorry msg
              ([ Right (_:_:_)    ], _             ) -> sorry sorrySayExcessTargets
              ([ Right [targetId] ], _             ) | targetSing <- getSing targetId ms -> case getType targetId ms of
                PCType  -> let targetDesig = serialize . mkStdDesig targetId ms $ Don'tCap
                           in parseRearAdverb |&| either sorry (sayToHelper d targetId targetDesig)
                MobType -> parseRearAdverb |&| either sorry (sayToMobHelper d targetSing)
                _       -> sorry . sorrySayTargetType $ targetSing
              x -> patternMatchFail "say sayTo" [ showText x ]
          else sorry sorrySayNoOneHere
      where
        sorry msg       = (ms, (mkBroadcast i . nlnl $ msg, []))
        parseRearAdverb = case maybeAdverb of
          Just adverb                          -> Right (adverb <> " ", "", formatMsg . T.unwords $ rest)
          Nothing | T.head r == adverbOpenChar -> case parseAdverb . T.unwords $ rest of
                      Right (adverb, rest') -> Right ("", " " <> adverb, formatMsg rest')
                      Left  msg             -> Left  msg
                  | otherwise -> Right ("", "", formatMsg . T.unwords $ rest)
        sayToHelper d targetId targetDesig (frontAdv, rearAdv, msg) =
            let toSelfMsg         = T.concat [ "You say ",            frontAdv, "to ", targetDesig, rearAdv, ", ", msg ]
                toSelfBroadcast   = (nlnl toSelfMsg, pure i)
                toTargetMsg       = T.concat [ serialize d, " says ", frontAdv, "to you",           rearAdv, ", ", msg ]
                toTargetBroadcast = (nlnl toTargetMsg, pure targetId)
                toOthersMsg       = T.concat [ serialize d, " says ", frontAdv, "to ", targetDesig, rearAdv, ", ", msg ]
                toOthersBroadcast = (nlnl toOthersMsg, pcIds d \\ [ i, targetId ])
            in (ms, ([ toSelfBroadcast, toTargetBroadcast, toOthersBroadcast ], [ parsePCDesig i ms toSelfMsg ]))
        sayToMobHelper d targetSing (frontAdv, rearAdv, msg) =
            let toSelfMsg         = T.concat [ "You say ", frontAdv, "to ", theOnLower targetSing, rearAdv, ", ", msg ]
                toOthersMsg       = T.concat [ serialize d
                                             , " says "
                                             , frontAdv
                                             , "to "
                                             , theOnLower targetSing
                                             , rearAdv
                                             , ", "
                                             , msg ]
                toOthersBroadcast = (nlnl toOthersMsg, i `delete` pcIds d)
                (pt, hint)        = firstMobSay i $ ms^.plaTbl
            in (ms & plaTbl .~ pt, ((toOthersBroadcast :) . mkBroadcast i . nlnl $ toSelfMsg <> hint, pure toSelfMsg))
    sayTo maybeAdverb msg _ = patternMatchFail "say sayTo" [ showText maybeAdverb, msg ]
    formatMsg                 = dblQuote . capitalizeMsg . punctuateMsg
    bcastAndLog (bs, logMsgs) = bcast bs >> logMsgs |#| logPlaOut "say" i
    simpleSayHelper ms (maybe "" (" " <>) -> adverb) (formatMsg -> msg) =
        let d                 = mkStdDesig i ms DoCap
            toSelfMsg         = T.concat [ "You say", adverb, ", ", msg ]
            toSelfBroadcast   = mkBroadcast i . nlnl $ toSelfMsg
            toOthersMsg       = T.concat [ serialize d, " says", adverb, ", ", msg ]
            toOthersBroadcast = (nlnl toOthersMsg, i `delete` pcIds d)
        in return (toOthersBroadcast : toSelfBroadcast, pure toSelfMsg)
say p = patternMatchFail "say" [ showText p ]


firstMobSay :: Id -> PlaTbl -> (PlaTbl, T.Text)
firstMobSay i pt | pt^.ind i.to isNotFirstMobSay = (pt, "")
                 | otherwise = (pt & ind i %~ setPlaFlag IsNotFirstMobSay True, nlnlPrefix hintSay)


-----


setAction :: Action
setAction (NoArgs i mq cols) = getState >>= \ms ->
    let (styleAbbrevs Don'tQuote -> names, values) = unzip . mkSettingPairs i $ ms
    in multiWrapSend mq cols [ padSettingName (n <> ": ") <> v | n <- names | v <- values ] >> logPlaExecArgs "set" [] i
setAction (Lower' i as) = helper |&| modifyState >=> \(bs, logMsgs) ->
    bcastNl bs >> logMsgs |#| logPlaOut "set" i
  where
    helper ms = let (p, msgs, logMsgs) = foldl' (helperSettings i ms) (getPla i ms, [], []) as
                in (ms & plaTbl.ind i .~ p, (mkBroadcast i . T.unlines $ msgs, logMsgs))
setAction p = patternMatchFail "setAction" [ showText p ]


mkSettingPairs :: Id -> MudState -> [(T.Text, T.Text)]
mkSettingPairs i ms = let p = getPla i ms
                      in pairs p |&| (isAdmin p ? (adminPair p :) :? id)
  where
    pairs p   = [ ("columns",  showText . getColumns   i  $ ms)
                , ("lines",    showText . getPageLines i  $ ms)
                , ("question", inOut    . isTunedQuestion $ p ) ]
    adminPair = ("admin", ) . inOut . isTunedAdmin


helperSettings :: Id -> MudState -> (Pla, [T.Text], [T.Text]) -> T.Text -> (Pla, [T.Text], [T.Text])
helperSettings _ _ a@(_, msgs, _) arg@(T.length . T.filter (== '=') -> noOfEqs)
  | or [ noOfEqs /= 1, T.head arg == '=', T.last arg == '=' ] =
      let msg    = sorryParseArg arg
          f      = any (adviceSettingsInvalid `T.isInfixOf`) msgs ?  (++ pure msg)
                                                                  :? (++ [ msg <> adviceSettingsInvalid ])
      in a & _2 %~ f
helperSettings i ms a (T.breakOn "=" -> (name, T.tail -> value)) =
    findFullNameForAbbrev name (map fst . mkSettingPairs i $ ms) |&| maybe notFound found
  where
    notFound    = appendMsg . sorrySetName $ name
    appendMsg m = a & _2 <>~ pure m
    found       = \case "admin"    -> alterTuning "admin" IsTunedAdmin
                        "columns"  -> procEither . alterNumeric minCols      maxCols      "columns" $ columns
                        "lines"    -> procEither . alterNumeric minPageLines maxPageLines "lines"   $ pageLines
                        "question" -> alterTuning "question" IsTunedQuestion
                        t          -> patternMatchFail "helperSettings found" [t]
      where
        procEither f = parseInt |&| either appendMsg f
        parseInt     = case (reads . T.unpack $ value :: [(Int, String)]) of [(x, "")] -> Right x
                                                                             _         -> sorryParse
        sorryParse   = Left . sorryParseSetting value $ name
    alterNumeric minVal maxVal settingName lens x
      | not . inRange (minVal, maxVal) $ x = appendMsg . sorrySetRange settingName minVal $ maxVal
      | otherwise = let msg = T.concat [ "Set ", settingName, " to ", showText x, "." ]
                    in appendMsg msg & _1.lens .~ x & _3 <>~ pure msg
    alterTuning n flag = case filter ((== value) . fst) inOutOnOffs of
      [(_, newBool)] -> let msg   = T.concat [ "Tuned ", inOut newBool, " the ", n, " channel." ]
                        in appendMsg msg & _1 %~ setPlaFlag flag newBool & _3 <>~ pure msg
      [] -> appendMsg . sorryParseInOut value $ n
      xs -> patternMatchFail "helperSettings alterTuning" [ showText xs ]


-----


showAction :: Action
showAction p@AdviseNoArgs     = advise p ["show"] adviceShowNoArgs
showAction p@(AdviseOneArg a) = advise p ["show"] . adviceShowNoName $ a
showAction (Lower i mq cols as) = getState >>= \ms -> if isIncognitoId i ms
  then wrapSend mq cols . sorryIncog $ "show"
  else let eqMap      = getEqMap    i ms
           invCoins   = getInvCoins i ms
           rmInvCoins = first (i `delete`) . getPCRmNonIncogInvCoins i $ ms
       in if
         | ()# eqMap && ()# invCoins -> wrapSend mq cols dudeYou'reScrewed
         | ()# rmInvCoins            -> wrapSend mq cols sorryNoOneHere
         | otherwise                 -> case singleArgInvEqRm InRm (last as) of
           (InInv, _     ) -> wrapSend mq cols $ sorryShowTarget "item in your inventory"         <> tryThisInstead
           (InEq,  _     ) -> wrapSend mq cols $ sorryShowTarget "item in your readied equipment" <> tryThisInstead
           (InRm,  target) ->
             let argsWithoutTarget                    = init $ case as of [_, _] -> as
                                                                          _      -> (++ pure target) . nub . init $ as
                 (targetGecrs, targetMiss, targetRcs) = uncurry (resolveEntCoinNames i ms (pure target)) rmInvCoins
             in if ()# targetMiss && ()!# targetRcs
               then wrapSend mq cols . sorryShowTarget $ "coin"
               else case procGecrMisRm . head . zip targetGecrs $ targetMiss of
                 Left  msg        -> wrapSend mq cols msg
                 Right [targetId] ->
                   let d         = mkStdDesig i ms DoCap
                       theTarget = IdSingTypeDesig { theId    = targetId
                                                   , theSing  = getSing targetId ms
                                                   , theType  = getType targetId ms
                                                   , theDesig = serialize . mkStdDesig targetId ms $ Don'tCap }
                       (inInvs, inEqs, inRms) = sortArgsInvEqRm InInv argsWithoutTarget
                       (invBs, invLog)        = inInvs |!| showInv ms d invCoins inInvs theTarget
                       (eqBs,  eqLog )        = inEqs  |!| showEq  ms d eqMap    inEqs  theTarget
                       rmBs                   = inRms  |!| mkBroadcast i sorryShowInRm
                   in if theType theTarget `notElem` [ MobType, PCType ]
                     then wrapSend mq cols . sorryShowTarget . theSing $ theTarget
                     else do
                         bcastNl $ rmBs ++ invBs ++ eqBs
                         let log = slashes . dropBlanks $ [ invLog |!| parensQuote "inv" <> " " <> invLog
                                                          , eqLog  |!| parensQuote "eq"  <> " " <> eqLog ]
                         log |#| logPla "show" i . (T.concat [ "showed to "
                                                             , theSing theTarget
                                                             , ": " ] <>)
                 Right _ -> wrapSend mq cols sorryShowExcessTargets
  where
    tryThisInstead = " Try showing something to someone in your current room."
    showInv ms d invCoins inInvs IdSingTypeDesig { .. } = if ()!# invCoins
      then let (eiss, ecs)                         = uncurry (resolvePCInvCoins i ms inInvs) invCoins
               showInvHelper                       = foldl' helperEitherInv ([], []) eiss
               helperEitherInv acc (Left  msg    ) = acc & _1 <>~ mkBroadcast i msg
               helperEitherInv acc (Right itemIds) = acc & _1 <>~ mkBs
                                                         & _2 <>~ pure mkLog
                 where
                   mkBs = concatMap (itemIds |&|) $ case theType of
                     PCType  -> [ mkToSelfInvBs, mkToTargetInvBs, mkToOthersInvBs ]
                     MobType -> [ mkToSelfInvBsMobs, mkToOthersInvBsMobs ]
                     x       -> patternMatchFail "showAction showInv helperEitherInv mkBs" [ showText x ]
                   mkLog = commas . map (`getSing` ms) $ itemIds
               mkToSelfInvBs       itemIds = [ ( T.concat [ "You show the "
                                                          , getSing itemId ms
                                                          , " to "
                                                          , theDesig
                                                          , "." ]
                                               , pure i )
                                             | itemId <- itemIds ]
               mkToSelfInvBsMobs   itemIds = [ ( T.concat [ "You show the "
                                                          , getSing itemId ms
                                                          , " to "
                                                          , theOnLower theSing
                                                          , "." ]
                                               , pure i )
                                             | itemId <- itemIds ]
               mkToTargetInvBs     itemIds = [ ( T.concat [ serialize d
                                                          , " shows you "
                                                          , underline . aOrAn . getSing itemId $ ms
                                                          , nl ":"
                                                          , getEntDesc itemId ms ]
                                               , pure theId )
                                             | itemId <- itemIds ]
               mkToOthersInvBs     itemIds = [ ( T.concat [ serialize d
                                                          , " shows "
                                                          , aOrAn . getSing itemId $ ms
                                                          , " to "
                                                          , theDesig
                                                          , "." ]
                                               , pcIds d \\ [ i, theId ] )
                                             | itemId <- itemIds ]
               mkToOthersInvBsMobs itemIds = [ ( T.concat [ serialize d
                                                          , " shows "
                                                          , aOrAn . getSing itemId $ ms
                                                          , " to "
                                                          , theOnLower theSing
                                                          , "." ]
                                               , i `delete` pcIds d )
                                             | itemId <- itemIds ]
               -----
               (canCoins, can'tCoinMsgs) = distillEcs ecs
               showCoinsHelper           = (mkBroadcast i . T.unlines $ can'tCoinMsgs) ++ mkCanCoinsBs
               mkCanCoinsBs              = case theType of
                 PCType  -> mkToSelfCoinsBs     ++ mkToTargetCoinsBs ++ mkToOthersCoinsBs
                 MobType -> mkToSelfCoinsBsMobs ++                      mkToOthersCoinsBsMobs
                 x       -> patternMatchFail "showAction mkCanCoinsBs" [ showText x ]
               coinTxt               = mkCoinTxt canCoins
               mkToSelfCoinsBs       = coinTxt |!| mkBroadcast i     . T.concat $ [ "You show "
                                                                                  , coinTxt
                                                                                  , " to "
                                                                                  , theDesig
                                                                                  , "." ]
               mkToSelfCoinsBsMobs   = coinTxt |!| mkBroadcast i     . T.concat $ [ "You show "
                                                                                  , coinTxt
                                                                                  , " to "
                                                                                  , theOnLower theSing
                                                                                  , "." ]
               mkToTargetCoinsBs     = coinTxt |!| mkBroadcast theId . T.concat $ [ serialize d
                                                                                  , " shows you "
                                                                                  , underline coinTxt
                                                                                  , "." ]
               mkToOthersCoinsBs     = coinTxt |!| [(T.concat [ serialize d
                                                              , " shows "
                                                              , aCoinSomeCoins canCoins
                                                              , " to "
                                                              , theDesig
                                                              , "." ], pcIds d \\ [ i, theId ])]
               mkToOthersCoinsBsMobs = coinTxt |!| [(T.concat [ serialize d
                                                              , " shows "
                                                              , aCoinSomeCoins canCoins
                                                              , " to "
                                                              , theOnLower theSing
                                                              , "." ], i `delete` pcIds d)]
           in let (invBs,   invLogs ) = showInvHelper
                  (coinsBs, coinsLog) = (showCoinsHelper, coinTxt)
              in (invBs ++ coinsBs, slashes . dropBlanks $ [ slashes invLogs, coinsLog ])
      else (mkBroadcast i dudeYourHandsAreEmpty, "")
    showEq ms d eqMap inEqs IdSingTypeDesig { .. } = if ()!# eqMap
      then let (gecrs, miss, rcs)                  = resolveEntCoinNames i ms inEqs (M.elems eqMap) mempty
               eiss                                = zipWith (curry procGecrMisPCEq) gecrs miss
               showEqHelper                        = foldl' helperEitherInv ([], []) eiss
               helperEitherInv acc (Left  msg    ) = acc & _1 <>~ mkBroadcast i msg
               helperEitherInv acc (Right itemIds) = acc & _1 <>~ mkBs
                                                         & _2 <>~ pure mkLog
                 where
                   mkBs = concatMap (itemIds |&|) $ case theType of
                     PCType  -> [ mkToSelfBs, mkToTargetBs, mkToOthersBs ]
                     MobType -> [ mkToSelfBsMobs, mkToOthersBsMobs ]
                     x       -> patternMatchFail "showAction showEq helperEitherInv mkBs" [ showText x ]
                   mkLog = commas . map (`getSing` ms) $ itemIds
               mkToSelfBs       itemIds = [ ( T.concat [ "You show the "
                                                       , getSing itemId ms
                                                       , " to "
                                                       , theDesig
                                                       , "." ]
                                            , pure i )
                                          | itemId <- itemIds ]
               mkToSelfBsMobs   itemIds = [ ( T.concat [ "You show the "
                                                       , getSing itemId ms
                                                       , " to "
                                                       , theOnLower theSing
                                                       , "." ]
                                            , pure i )
                                          | itemId <- itemIds ]
               mkToTargetBs     itemIds = [ ( T.concat [ serialize d
                                                       , " shows you "
                                                       , underline . aOrAn . getSing itemId $ ms
                                                       , " "
                                                       , parensQuote . mkSlotDesc i ms . reverseLookup itemId $ eqMap
                                                       , nl ":"
                                                       , getEntDesc itemId ms ]
                                            , pure theId )
                                          | itemId <- itemIds ]
               mkToOthersBs     itemIds = [ ( T.concat [ serialize d
                                                       , " shows "
                                                       , aOrAn . getSing itemId $ ms
                                                       , " "
                                                       , parensQuote . mkSlotDesc i ms . reverseLookup itemId $ eqMap
                                                       , " to "
                                                       , theDesig
                                                       , "." ]
                                            , pcIds d \\ [ i, theId ] )
                                          | itemId <- itemIds ]
               mkToOthersBsMobs itemIds = [ ( T.concat [ serialize d
                                                       , " shows "
                                                       , aOrAn . getSing itemId $ ms
                                                       , " "
                                                       , parensQuote . mkSlotDesc i ms . reverseLookup itemId $ eqMap
                                                       , " to "
                                                       , theOnLower theSing
                                                       , "." ]
                                            , i `delete` pcIds d )
                                          | itemId <- itemIds ]
               -----
               showCoinsInEqHelper = rcs |!| mkBroadcast i sorryEquipCoins
           in ((++ showCoinsInEqHelper) *** slashes) showEqHelper
      else (mkBroadcast i dudeYou'reNaked, "")
showAction p = patternMatchFail "showAction" [ showText p ]


mkSlotDesc :: Id -> MudState -> Slot -> T.Text
mkSlotDesc i ms s = case s of
  -- Clothing slots:
  EarringR1S  -> wornOn -- "right ear"
  EarringR2S  -> wornOn -- "right ear"
  EarringL1S  -> wornOn -- "left ear"
  EarringL2S  -> wornOn -- "left ear"
  NoseRing1S  -> wornOn -- "nose"
  NoseRing2S  -> wornOn -- "nose"
  Necklace1S  -> wornOn -- "neck"
  Necklace2S  -> wornOn -- "neck"
  Necklace3S  -> wornOn -- "neck"
  BraceletR1S -> wornOn -- "right wrist"
  BraceletR2S -> wornOn -- "right wrist"
  BraceletR3S -> wornOn -- "right wrist"
  BraceletL1S -> wornOn -- "left wrist"
  BraceletL2S -> wornOn -- "left wrist"
  BraceletL3S -> wornOn -- "left wrist"
  RingRIS     -> wornOn -- "right index finger"
  RingRMS     -> wornOn -- "right middle finger"
  RingRRS     -> wornOn -- "right ring finger"
  RingRPS     -> wornOn -- "right pinky finger"
  RingLIS     -> wornOn -- "left index finger"
  RingLMS     -> wornOn -- "left middle finger"
  RingLRS     -> wornOn -- "left ring finger"
  RingLPS     -> wornOn -- "left pinky finger"
  ShirtS      -> wornAs -- "shirt"
  SmockS      -> wornAs -- "smock"
  CoatS       -> wornAs -- "coat"
  TrousersS   -> "worn as trousers" -- "trousers"
  SkirtS      -> wornAs -- "skirt"
  DressS      -> wornAs -- "dress"
  FullBodyS   -> "worn about " <> hisHer <> " body" -- "about body"
  BackpackS   -> "worn on "    <> hisHer <> " back" -- "backpack"
  CloakS      -> wornAs -- "cloak"
  -- Armor slots:
  HeadS       -> wornOn -- "head"
  TorsoS      -> wornOn -- "torso"
  ArmsS       -> wornOn -- "arms"
  HandsS      -> wornOn -- "hands"
  LowerBodyS  -> wornOn -- "lower body"
  FeetS       -> wornOn -- "feet"
  -- Weapon/shield slots:
  RHandS      -> heldIn -- "right hand"
  LHandS      -> heldIn -- "left hand"
  BothHandsS  -> "wielding with both hands" -- "both hands"
  where
    hisHer = mkPossPro . getSex i $ ms
    wornOn = T.concat [ "worn on ", hisHer, " ", pp s ]
    wornAs = "worn as " <> (aOrAn . pp $ s)
    heldIn = "held in " <> hisHer <> pp s


-----


tele :: Action
tele p@AdviseNoArgs     = advise p ["telepathy"] adviceTeleNoArgs
tele p@(AdviseOneArg a) = advise p ["telepathy"] . adviceTeleNoMsg $ a
tele (MsgWithTarget i mq cols target msg) = getState >>= \ms ->
    let (s, p) = (getSing i ms, getPla i ms) in if isIncognito p
      then wrapSend mq cols . sorryIncog $ "telepathy"
      else let SingleTarget { .. } = mkSingleTarget mq cols target "The name of the person you wish to message"
               notFound            = sendFun . notFoundSuggestAsleeps target asleeps $ ms
               found targetSing    =
                   let helper targetId = case emotifyTwoWay "telepathy" i ms targetId msg of
                         Left  errorMsgs  -> multiSendFun errorMsgs
                         Right (Right bs) -> ioHelper targetId bs
                         Right (Left  ()) -> case expCmdifyTwoWay i ms targetId targetSing msg of
                           Left  errorMsg -> sendFun errorMsg
                           Right bs       -> ioHelper targetId bs
                       ioHelper targetId bs = let bs'@[(toSelf, _), _] = formatBs targetId bs in do
                           bcastNl . consSorryBroadcast i $ bs'
                           logPlaOut "tele" i . pure $ toSelf
                           ts <- liftIO mkTimestamp
                           withDbExHandler_ "tele" . insertDbTblTele . TeleRec ts s targetSing $ toSelf
                       formatBs targetId [toMe, toTarget] = let f n m = bracketQuote n <> " " <> m
                                                            in [ toMe     & _1 %~ f s
                                                               , toTarget & _1 %~ f (mkStyled targetId) ]
                       formatBs _        bs               = patternMatchFail "tele found formatBs" [ showText bs ]
                       mkStyled targetId = let (target'sAwakes, _) = getDblLinkedSings targetId ms
                                               styleds             = styleAbbrevs Don'tQuote target'sAwakes
                                           in head . filter ((== s) . dropANSI) $ styleds
                   in either sendFun helper . checkMutuallyTuned i ms $ targetSing
               (awakes, asleeps) = getDblLinkedSings i ms
           in findFullNameForAbbrev strippedTarget awakes |&| maybe notFound found
tele p = patternMatchFail "tele" [ showText p ]


getDblLinkedSings :: Id -> MudState -> ([Sing], [Sing])
getDblLinkedSings i ms = foldr helper ([], []) . getLinked i $ ms
  where
    helper s pair = let lens = isAwake (getIdForPCSing s ms) ms ? _1 :? _2
                    in pair & lens %~ (s :)


-----


tune :: Action
tune (NoArgs i mq cols) = getState >>= \ms ->
    let linkPairs   = map (first (`getIdForPCSing` ms) . dup) . getLinked i $ ms
        linkSings   = sort . map snd . filter (isDblLinked ms . (i, ) . fst) $ linkPairs
        styleds     = styleAbbrevs Don'tQuote linkSings
        linkTunings = foldr (\s -> (linkTbl M.! s :)) [] linkSings
        linkTbl     = getTeleLinkTbl i ms
        (chanNames, chanTunings)   = mkChanNamesTunings i ms
        helper title names tunings = let txts = mkConnTxts
                                     in [ title, ()!# txts ? commas txts :? "None." ]
          where
            mkConnTxts = [ n <> "=" <> inOut t | n <- names | t <- tunings ]
    in do
        let msgs = [ helper "Two-way telepathic links:" styleds linkTunings
                   , pure ""
                   , helper "Telepathic channels:" (styleAbbrevs Don'tQuote chanNames) chanTunings ]
        multiWrapSend mq cols . concat $ msgs
        logPlaExecArgs "tune" [] i
tune (Lower' i as) = helper |&| modifyState >=> \(bs, logMsgs) ->
    bcastNl bs >> logMsgs |#| logPlaOut "tune" i
  where
    helper ms = let s       = getSing i ms
                    linkTbl = getTeleLinkTbl i ms
                    chans   = getPCChans     i ms
                    (linkTbl', chans', msgs, logMsgs) = foldl' (helperTune s) (linkTbl, chans, [], []) as
                in ( ms & teleLinkMstrTbl.ind i .~ linkTbl'
                        & chanTbl %~ flip (foldr (\c -> ind (c^.chanId) .~ c)) chans'
                   , (mkBroadcast i . T.unlines $ msgs, logMsgs) )
tune p = patternMatchFail "tune" [ showText p ]


helperTune :: Sing -> (TeleLinkTbl, [Chan], [T.Text], [T.Text]) -> T.Text -> (TeleLinkTbl, [Chan], [T.Text], [T.Text])
helperTune _ a arg@(T.length . T.filter (== '=') -> noOfEqs)
  | or [ noOfEqs /= 1, T.head arg == '=', T.last arg == '=' ] = a & _3 %~ tuneInvalidArg arg
helperTune s a@(linkTbl, chans, _, _) arg@(T.breakOn "=" -> (name, T.tail -> value)) = case lookup value inOutOnOffs of
  Nothing  -> a & _3 %~ tuneInvalidArg arg
  Just val -> let connNames = "all" : linkNames ++ chanNames
              in findFullNameForAbbrev name connNames |&| maybe notFound (found val)
  where
    linkNames   = map uncapitalize . M.keys $ linkTbl
    chanNames   = map (views chanName T.toLower) chans
    notFound    = a & _3 <>~ (pure . sorryTuneName $ name)
    found val n = if n == "all"
                    then appendMsg "all telepathic connections" & _1 %~ M.map (const val)
                                                                & _2 %~ map (chanConnTbl.at s ?~ val)
                    else foundHelper
      where
        appendMsg connName = let msg = T.concat [ "You tune ", connName, " ", inOut val, "." ]
                             in a & _3 <>~ pure msg
                                  & _4 <>~ pure msg
        foundHelper
          | n `elem` linkNames = foundLink
          | n `elem` chanNames = foundChan
          | otherwise          = blowUp "helperTune found foundHelper" "connection name not found" . pure $ n
          where
            foundLink = let n' = capitalize n in appendMsg n' & _1.at n' ?~ val
            foundChan =
                let ([match], others) = partition (views chanName ((== n) . T.toLower)) chans
                in appendMsg (views chanName dblQuote match) & _2 .~ (match & chanConnTbl.at s ?~ val) : others


tuneInvalidArg :: T.Text -> [T.Text] -> [T.Text]
tuneInvalidArg arg msgs = let msg = sorryParseArg arg in
    msgs |&| (any (adviceTuneInvalid `T.isInfixOf`) msgs ? (++ pure msg) :? (++ [ msg <> adviceTuneInvalid ]))


-----


typo :: Action
typo p@AdviseNoArgs = advise p ["typo"] adviceTypoNoArgs
typo p              = bugTypoLogger p TypoLog


-----


-- TODO: Unlinking should cost psionic points.
unlink :: Action
unlink p@AdviseNoArgs          = advise p ["unlink"] adviceUnlinkNoArgs
unlink (LowerNub i mq cols as) =
    let (f, guessWhat) | any hasLocPref as = (stripLocPref, sorryUnlinkIgnore)
                       | otherwise         = (id,           ""               )
        g        = ()# guessWhat ? id :? ((guessWhat, pure i) :)
        as'      = map (capitalize . T.toLower . f) as
    in do
        tingleLoc <- rndmElem [ "behind your eyes"
                              , "deep in your lower back"
                              , "in your scalp"
                              , "on the back of your neck"
                              , "somewhere between your ears" ]
        ms        <- getState
        res       <- helperLinkUnlink ms i mq cols
        flip maybeVoid res $ \(meLinkedToOthers, othersLinkedToMe, twoWays) ->
            let helper ms' = let (ms'', bs, logMsgs) = foldl' procArg (ms', [], []) as'
                             in (ms'', (bs, logMsgs))
                procArg a@(ms', _, _) targetSing = if
                  | targetSing `elem` twoWays ++ meLinkedToOthers ++ othersLinkedToMe -> procArgHelper
                  | otherwise -> a & _2 <>~ (mkBroadcast i . nlnl $ sorryUnlinkName targetSing <> " " <> hintUnlink)
                  where
                    procArgHelper =
                        let targetId  = getIdForPCSing targetSing ms'
                            s         = getSing i ms
                            srcMsg    = T.concat [ focusingInnateMsg, "you sever your link with ", targetSing, "." ]
                            targetBs  = let bs = mkBroadcast targetId . nlnl . colorize . unlinkMsg tingleLoc $ s
                                        in (isLoggedIn . getPla targetId $ ms') |?| bs
                            colorize  = quoteWith' (unlinkColor, dfltColor)
                            ms''      = ms' & teleLinkMstrTbl.ind i       .at targetSing .~ Nothing
                                            & teleLinkMstrTbl.ind targetId.at s          .~ Nothing
                                            & pcTbl.ind i       .linked %~ (targetSing `delete`)
                                            & pcTbl.ind targetId.linked %~ (s          `delete`)
                        in a & _1 .~  ms''
                             & _2 <>~ (nlnl srcMsg, pure i) : targetBs
                             & _3 <>~ pure targetSing
            in helper |&| modifyState >=> \(bs, logMsgs) -> bcast (g bs) >> logMsgs |#| (logPla "unlink" i . slashes)
unlink p = patternMatchFail "unlink" [ showText p ]


-----


unready :: Action
unready p@AdviseNoArgs   = advise p ["unready"] adviceUnreadyNoArgs
unready (LowerNub' i as) = helper |&| modifyState >=> \(bs, logMsgs) ->
    bcastIfNotIncogNl i bs >> logMsgs |#| logPlaOut "unready" i
  where
    helper ms =
        let (inInvs, inEqs, inRms) = sortArgsInvEqRm InEq as
            sorryInInv             = inInvs |!| mkBroadcast i sorryUnreadyInInv
            sorryInRm              = inRms  |!| mkBroadcast i sorryUnreadyInRm
            d                      = mkStdDesig i ms DoCap
            is                     = M.elems . getEqMap i $ ms
            (gecrs, miss, rcs)     = resolveEntCoinNames i ms inEqs is mempty
            eiss                   = zipWith (curry procGecrMisPCEq) gecrs miss
            bs                     = rcs |!| mkBroadcast i sorryUnreadyCoins
            (et, it, bs', logMsgs) = foldl' (helperUnready i ms d) (ms^.eqTbl, ms^.invTbl, bs, []) eiss
        in if ()!# is
          then (ms & eqTbl .~ et & invTbl .~ it, (sorryInInv ++ sorryInRm ++ bs', logMsgs))
          else (ms, (mkBroadcast i dudeYou'reNaked, []))
unready p = patternMatchFail "unready" [ showText p ]


helperUnready :: Id
              -> MudState
              -> PCDesig
              -> (EqTbl, InvTbl, [Broadcast], [T.Text])
              -> Either T.Text Inv
              -> (EqTbl, InvTbl, [Broadcast], [T.Text])
helperUnready i ms d a = \case
  Left  (mkBroadcast i -> b) -> a & _3 <>~ b
  Right targetIds            -> let (bs, msgs) = mkUnreadyDescs i ms d targetIds
                                in a & _1.ind i %~ M.filter (`notElem` targetIds)
                                     & _2.ind i %~ (sortInv ms . (++ targetIds))
                                     & _3 <>~ bs
                                     & _4 <>~ msgs


mkUnreadyDescs :: Id
               -> MudState
               -> PCDesig
               -> Inv
               -> ([Broadcast], [T.Text])
mkUnreadyDescs i ms d targetIds = first concat . unzip $ [ helper icb | icb <- mkIdCountBothList i ms targetIds ]
  where
    helper (targetId, count, b@(targetSing, _)) = if count == 1
      then let toSelfMsg   = T.concat [ "You ",           mkVerb targetId SndPer, " the ",   targetSing, "." ]
               toOthersMsg = T.concat [ serialize d, " ", mkVerb targetId ThrPer, " ", aOrAn targetSing, "." ]
           in ((toOthersMsg, otherPCIds) : mkBroadcast i toSelfMsg, toSelfMsg)
      else let toSelfMsg   = T.concat [ "You "
                                      , mkVerb targetId SndPer
                                      , " "
                                      , showText count
                                      , " "
                                      , mkPlurFromBoth b
                                      , "." ]
               toOthersMsg = T.concat [ serialize d
                                      , " "
                                      , mkVerb targetId ThrPer
                                      , " "
                                      , showText count
                                      , " "
                                      , mkPlurFromBoth b
                                      , "." ]
           in ((toOthersMsg, otherPCIds) : mkBroadcast i toSelfMsg, toSelfMsg)
    mkVerb targetId person = case getType targetId ms of
      ClothType -> case getCloth targetId ms of
        Earring  -> mkVerbRemove  person
        NoseRing -> mkVerbRemove  person
        Necklace -> mkVerbTakeOff person
        Bracelet -> mkVerbTakeOff person
        Ring     -> mkVerbTakeOff person
        Backpack -> mkVerbTakeOff person
        _        -> mkVerbDoff    person
      ConType -> mkVerbTakeOff person
      WpnType | person == SndPer -> "stop wielding"
              | otherwise        -> "stops wielding"
      ArmType -> case getArmSub targetId ms of
        Head   -> mkVerbTakeOff person
        Hands  -> mkVerbTakeOff person
        Feet   -> mkVerbTakeOff person
        Shield -> mkVerbUnready person
        _      -> mkVerbDoff    person
      t -> patternMatchFail "mkUnreadyDescs mkVerb" [ showText t ]
    mkVerbRemove  = \case SndPer -> "remove"
                          ThrPer -> "removes"
    mkVerbTakeOff = \case SndPer -> "take off"
                          ThrPer -> "takes off"
    mkVerbDoff    = \case SndPer -> "doff"
                          ThrPer -> "doffs"
    mkVerbUnready = \case SndPer -> "unready"
                          ThrPer -> "unreadies"
    otherPCIds    = i `delete` pcIds d


mkIdCountBothList :: Id -> MudState -> Inv -> [(Id, Int, BothGramNos)]
mkIdCountBothList i ms targetIds =
    let boths@(mkCountList -> counts) = [ getEffBothGramNos i ms targetId | targetId <- targetIds ]
    in nubBy ((==) `on` dropFst) . zip3 targetIds counts $ boths


-----


uptime :: Action
uptime (NoArgs i mq cols) = do
    wrapSend mq cols =<< uptimeHelper =<< getUptime
    logPlaExec "uptime" i
uptime p = withoutArgs uptime p


getUptime :: MudStack Int64
getUptime = ((-) `on` sec) <$> (liftIO . getTime $ Monotonic) <*> asks (view startTime)


uptimeHelper :: Int64 -> MudStack T.Text
uptimeHelper up = helper <$> (fmap . fmap) getSum getRecordUptime
  where
    helper         = maybe mkUptimeTxt (\recUp -> up > recUp ? mkNewRecTxt :? mkRecTxt recUp)
    mkUptimeTxt    = mkTxtHelper "."
    mkNewRecTxt    = mkTxtHelper . T.concat $ [ " - "
                                              , newRecordColor
                                              , "it's a new record!"
                                              , dfltColor ]
    mkRecTxt recUp = mkTxtHelper $ " (record uptime: " <> renderIt recUp <> ")."
    mkTxtHelper    = ("Up " <>) . (renderIt up <>)
    renderIt       = T.pack . renderSecs . fromIntegral


getRecordUptime :: MudStack (Maybe (Sum Int64))
getRecordUptime = mIf (liftIO . doesFileExist $ uptimeFile)
                      (liftIO readUptime `catch` (emptied . fileIOExHandler "getRecordUptime"))
                      (return Nothing)
  where
    readUptime = Just . Sum . read <$> readFile uptimeFile


-----


who :: Action
who (NoArgs i mq cols) = getState >>= \ms ->
    (pager i mq . concatMap (wrapIndent namePadding cols) . mkWhoTxt i $ ms) >> logPlaExecArgs "who" [] i
who p@(ActionParams { plaId, args }) = getState >>= \ms ->
    (dispMatches p namePadding . mkWhoTxt plaId $ ms) >> logPlaExecArgs "who" args plaId


mkWhoTxt :: Id -> MudState -> [T.Text]
mkWhoTxt i ms = let txts = mkCharList i ms
                in (++ [ mkFooter i ms ]) $ txts |!| mkWhoHeader ++ txts


mkCharList :: Id -> MudState -> [T.Text]
mkCharList i ms =
    let plaIds                = i `delete` getLoggedInPlaIds ms
        (linkeds,  others   ) = partition (isLinked    ms . (i, )) plaIds
        (twoWays,  oneWays  ) = partition (isDblLinked ms . (i, )) linkeds
        (tunedIns, tunedOuts) = partition (isTunedIn   ms . (i, )) twoWays
        -----
        tunedIns'         = mkSingSexRaceLvls tunedIns
        mkSingSexRaceLvls = sortBy (compare `on` view _1) . map helper
        helper plaId      = let (s, r, l) = mkPrettifiedSexRaceLvl plaId ms in (getSing plaId ms, s, r, l)
        styleds           = styleAbbrevs Don'tQuote . map (view _1) $ tunedIns'
        -----
        tunedOuts' = mkSingSexRaceLvls (tunedOuts ++ oneWays)
        -----
        others' = sortBy raceLvlSex . map (`mkPrettifiedSexRaceLvl` ms) $ others
          where
            raceLvlSex (s, r, l) (s', r', l') = (r `compare` r') <> (l `compare` l') <> (s `compare` s')
        -----
        descTunedIns = zipWith (curry descThem) styleds tunedIns'
          where
            descThem (styled, (_, s, r, l)) = T.concat [ padName styled, padSex s, padRace r, l ]
        descTunedOuts = map descThem tunedOuts'
          where
            descThem (s, s', r, l) = T.concat [ padName s, padSex s', padRace r, l ]
        descOthers = map descThem others'
          where
            descThem (s, r, l) = T.concat [ padName "?", padSex  s, padRace r, l ]
    in concat [ descTunedIns, descTunedOuts, descOthers ]


isTunedIn :: MudState -> (Id, Id) -> Bool
isTunedIn ms (i, i') | s <- getSing i' ms = fromMaybe False (view (at s) . getTeleLinkTbl i $ ms)


mkFooter :: Id -> MudState -> T.Text
mkFooter i ms = let plaIds@(length -> x) = getLoggedInPlaIds ms
                    y                    = length . filter (== True) $ maruBatsus
                in T.concat [ showText x
                            , " "
                            , pluralize ("person", "people") x
                            , " awake"
                            , plaIds == pure i |?| ": you"
                            , y /= 0 |?| (" " <> (parensQuote . T.concat $ [ "excluding "
                                                                          , showText y
                                                                          , " administrator"
                                                                          , pluralize ("", "s") y ]))
                            , "." ]
  where
    maruBatsus = map (uncurry (&&) . (isLoggedIn *** not . isIncognito) . dup . (`getPla` ms)) ais
    ais        = getLoggedInAdminIds ms


-----


whoAmI :: Action
whoAmI (NoArgs i mq cols) = (wrapSend mq cols =<< helper =<< getState) >> logPlaExec "whoami" i
  where
    helper ms = let s         = getSing i ms
                    (sexy, r) = (uncapitalize . showText *** uncapitalize . showText) . getSexRace i $ ms
                in return . T.concat $ [ "You are ", knownNameColor, s, dfltColor, " (a ", sexy, " ", r, ")." ]
whoAmI p = withoutArgs whoAmI p
