-- | Bounded candidates and deterministic held-out selection, without model calls.
module Shikumi.Optimize.ReAnchor.Fit (gaps, tidy, folds, pickBest, selectKept, thresholdCandidates, cutCandidates, weightCandidates) where

import Data.List (maximumBy, nub, sort, sortOn)
import Data.Ord (comparing)
import Data.Word (Word64)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)

tidy :: Double -> Double -> Double -> Double
tidy lo hi midpoint = case [x | digits <- [1 .. 11 :: Int], let scale = 10 ^^ digits, let x = fromInteger (round (midpoint * scale)) / scale, x > lo, x < hi] of
  x : _ -> x
  [] -> midpoint

gaps :: Int -> Bool -> [Double] -> Double -> Double -> [(Double, Double)]
gaps limit geometric values lo hi
  | lo >= hi || (geometric && lo <= 0) = []
  | otherwise = [(tidy a b mid, width a b) | (a, b) <- zip points (drop 1 points), let mid = if geometric then sqrt (a * b) else (a + b) / 2, mid > a, mid < b]
  where
    inner = nub (sort [x | x <- values, x > lo, x < hi])
    count = max 1 (limit - 1)
    thinned
      | length inner <= count = inner
      | count == 1 = [inner !! (length inner `div` 2)]
      | otherwise = nub [inner !! round (fromIntegral i * fromIntegral (length inner - 1) / fromIntegral (count - 1) :: Double) | i <- [0 .. count - 1]]
    points = lo : thinned ++ [hi]
    width a b = if geometric then log (b / a) else b - a

-- | A fixed-seed shuffle followed by round-robin fold assignment. It is stable
-- across runs and independent of candidate order or mutable random state.
folds :: Int -> Int -> [[Int]]
folds requested n = [[x | (i, x) <- zip [0 :: Int ..] shuffled, i `mod` k == j] | j <- [0 .. k - 1]]
  where
    k = min (max 1 requested) n
    shuffled = shuffle (1 :: Word64) [0 .. n - 1]
    shuffle _ [] = []
    shuffle seed xs =
      let seed' = seed * 6364136223846793005 + 1442695040888963407
          ix = fromIntegral (seed' `mod` fromIntegral (length xs))
          (a, b) = splitAt ix xs
       in case b of y : ys -> y : shuffle seed' (a ++ ys); [] -> []

-- | Strict improvement; on equal score and tie key the earliest trial wins.
pickBest :: [Int] -> [Double] -> [([Double], [Double], a)] -> Maybe ([Double], [Double], a)
pickBest rows start tried = case filter (\(scores, _, _) -> total scores > total start) tried of
  [] -> Nothing
  x : xs -> Just (foldl choose x xs)
  where
    total scores = sum [scores !! i | i <- rows]
    key (scores, tie, _) = (total scores, tie)
    choose a b = if key b > key a then b else a

selectKept :: Int -> [Double] -> [([Double], [Double], a)] -> (Maybe ([Double], [Double], a), Bool)
selectKept k start tried = case pickBest rows start tried of
  Nothing -> (Nothing, False)
  Just best
    | held > sum start -> (Just best, False)
    | otherwise -> (Nothing, True)
  where
    rows = [0 .. length start - 1]
    held = sum [sum [scores !! i | i <- fold] | fold <- folds k (length start), let outside = filter (`notElem` fold) rows, let scores = maybe start (\(s, _, _) -> s) (pickBest outside start tried)]

thresholdCandidates :: Int -> [Double] -> Double -> [(Double, [Double])]
thresholdCandidates limit observed start = [(t, [w, negate (abs (t - start)), t]) | (t, w) <- candidates, t /= start]
  where
    sorted = nub (sort observed)
    adjacent = [(b, b - a) | (a, b) <- zip sorted (drop 1 sorted), a >= 0, castWord64ToDouble (castDoubleToWord64 a + 1) == b]
    candidates = gaps limit False observed 0 1 ++ adjacent ++ [(0, 0) | 0 `elem` observed]

cutCandidates :: Int -> [Double] -> Double -> Double -> Double -> [(Double, [Double])]
cutCandidates limit means lo hi current = [(c, [w]) | (c, w) <- gaps limit False means lo hi, c /= current]

weightCandidates :: Int -> [Double] -> Double -> [(Double, [Double])]
weightCandidates limit flips current = [(c, [w]) | (c, w) <- gaps limit True flips low high, c /= current]
  where
    low = case flips of [] -> 1e-3; _ -> max 1e-3 (minimum flips / 4)
    high = case flips of [] -> 1e3; _ -> min 1e3 (maximum flips * 4)
