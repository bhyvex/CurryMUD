{-# LANGUAGE FlexibleContexts, LambdaCase, MonadComprehensions, OverloadedStrings, RankNTypes, ViewPatterns #-}

module Mud.Util.Misc ( atLst1
                     , blowUp
                     , boolToMaybe
                     , concatMapM
                     , divide
                     , dropFst
                     , dropIrrelevantFilenames
                     , dropThr
                     , dup
                     , dup3
                     , eitherRet
                     , emptied
                     , fromEither
                     , fromLeft
                     , fromRight
                     , ifThenElse
                     , ind
                     , isVowel
                     , listToMaybe
                     , maybeRet
                     , maybeVoid
                     , mIf
                     , minusQuarter
                     , minusThird
                     , mkDateTimeTxt
                     , mkTimestamp
                     , mUnless
                     , mWhen
                     , onFalse
                     , onLeft
                     , onTrue
                     , patternMatchFail
                     , plusQuarter
                     , plusThird
                     , reverseLookup
                     , sortEithers
                     , unadulterated
                     , uncurry3
                     , uncurry4
                     , uncurry5
                     , unit ) where

import Mud.Util.Operators
import Mud.Util.Quoting

import Control.Lens (_1, _2, lens, Lens')
import Control.Lens.Operators ((%~), (&))
import Control.Monad (guard)
import Data.Function (on)
import Data.IntMap.Lazy ((!))
import Data.List (delete)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Time (getZonedTime)
import qualified Data.IntMap.Lazy as IM (IntMap, insert)
import qualified Data.Map.Lazy as M (Map, assocs)
import qualified Data.Text as T


infixl 7 `divide`


-- ==================================================


atLst1 :: (Eq a, Num a) => a -> a
atLst1 x = case signum x of -1 -> 1
                            0  -> 1
                            _  -> x


boolToMaybe :: Bool -> a -> Maybe a
boolToMaybe b = (guard b >>) . return


concatMapM  :: (Monad m, Traversable t) => (a -> m [b]) -> t a -> m [b]
concatMapM f = fmap concat . mapM f


blowUp :: Text -> Text -> Text -> [Text] -> a
blowUp modName funName msg (T.intercalate ", " . map backQuote -> vals) =
    error . T.unpack . T.concat $ [ modName, " ", funName, ": ", msg, "; values: ", vals ]


divide :: (Integral a, Fractional b) => a -> a -> b
divide = (/) `on` fromIntegral


dropFst :: (a, b, c) -> (b, c)
dropFst (_, x, y) = (x, y)


dropIrrelevantFilenames :: [FilePath] -> [FilePath]
dropIrrelevantFilenames = foldr ((.) . delete) id [ ".", "..", ".DS_Store" ]


dropThr :: (a, b, c) -> (a, b)
dropThr (a, b, _) = (a, b)


dup :: a -> (a, a)
dup x = (x, x)


dup3 :: a -> (a, a, a)
dup3 x = (x, x, x)


eitherRet :: (Monad m) => (a -> m b) -> Either a b -> m b
eitherRet = flip either return


emptied :: (Monad m, Monoid b) => m a -> m b
emptied m = m >> return mempty


fromEither :: Either a a -> a
fromEither (Right a) = a
fromEither (Left  a) = a


fromLeft :: (Show a, Show b) => Either a b -> a
fromLeft (Left x) = x
fromLeft x        = blowUp "Mud.Util.Misc" "fromLeft" "Right" [ T.pack . show $ x ]


fromRight :: (Show a, Show b) => Either a b -> b
fromRight (Right x) = x
fromRight x         = blowUp "Mud.Util.Misc" "fromRight" "Left" [ T.pack . show $ x ]


onFalse :: Bool -> (a -> a) -> a -> a
onFalse = onHelper id


onHelper :: (Bool -> Bool) -> Bool -> (a -> a) -> a -> a
onHelper g b f = g b ? id :? f


onTrue :: Bool -> (a -> a) -> a -> a
onTrue = onHelper not


ifThenElse :: Bool -> a -> a -> a
ifThenElse True  x _ = x
ifThenElse False _ y = y


ind :: Int -> Lens' (IM.IntMap a) a
ind k = lens (! k) (flip (IM.insert k))


isVowel :: Char -> Bool
isVowel = (`elem` ("aeiou" :: String))


listToMaybe :: (Show a) => [a] -> Maybe a
listToMaybe []  = Nothing
listToMaybe [a] = Just a
listToMaybe xs  = patternMatchFail "Mud.Util.Misc" "listToMaybe" [ T.pack . show $ xs ]


maybeRet :: (Monad m) => m a -> Maybe a -> m a
maybeRet = flip maybe return


maybeVoid :: (Monad m) => (a -> m ()) -> Maybe a -> m ()
maybeVoid = maybe unit


mIf :: (Monad m) => m Bool -> m a -> m a -> m a
mIf p x y = p >>= \case True  -> x
                        False -> y


minusQuarter :: Int -> Int
minusQuarter x = round (fromIntegral x * 0.75 :: Double)


minusThird :: Int -> Int
minusThird x = round (fromIntegral x * 0.66 :: Double)


mUnless :: (Monad m) => m Bool -> m () -> m ()
mUnless p = mIf p unit


mWhen :: (Monad m) => m Bool -> m () -> m ()
mWhen p x = mIf p x unit


mkDateTimeTxt :: IO (Text, Text)
mkDateTimeTxt = helper <$> (T.words . T.pack . show) `fmap` getZonedTime
  where
    helper = (,) <$> head <*> (T.init . T.dropWhileEnd (/= '.') . head . tail)


mkTimestamp :: IO Text
mkTimestamp = [ bracketQuote $ date <> " " <> time | (date, time) <- mkDateTimeTxt ]


onLeft :: (Show a, Show b) => (a -> c) -> Either a b -> Either c b
onLeft f (Left  a) = Left . f $ a
onLeft _ x         = blowUp "Mud.Util.Misc" "onLeft" "Right" [ T.pack . show $ x ]


patternMatchFail :: Text -> Text -> [Text] -> a
patternMatchFail modName funName = blowUp modName funName "pattern match failure"


plusQuarter :: Int -> Int
plusQuarter x = round (fromIntegral x * 1.25 :: Double)


plusThird :: Int -> Int
plusThird x = round (fromIntegral x * 1.33 :: Double)


reverseLookup :: (Eq v) => v -> M.Map k v -> k
reverseLookup v = fst . head . filter ((== v) . snd) . M.assocs


sortEithers :: [Either l r] -> ([r], [l])
sortEithers = foldr helper ([], [])
  where
    helper (Right a) acc = acc & _1 %~ (a :)
    helper (Left  b) acc = acc & _2 %~ (b :)


unadulterated :: (Monad m) => (Applicative f) => a -> m (f a)
unadulterated = return . pure


uncurry3 :: (a -> b -> c -> d) -> (a, b, c) -> d
uncurry3 f (a, b, c) = f a b c


uncurry4 :: (a -> b -> c -> d -> e) -> (a, b, c, d) -> e
uncurry4 f (a, b, c, d) = f a b c d


uncurry5 :: (a -> b -> c -> d -> e -> f) -> (a, b, c, d, e) -> f
uncurry5 f (a, b, c, d, e) = f a b c d e


unit :: (Monad m) => m ()
unit = return $ let in ()
