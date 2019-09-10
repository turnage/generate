module Main where

import qualified Data.Vector as V
import Linear hiding (rotate)
import System.IO.Unsafe

import Generate
import qualified Generate.Algo.QuadTree as Q
import qualified Generate.Algo.Vec as V
import Generate.Colour.SimplePalette
import Generate.Colour.THColours
import Generate.Geom.Frame
import Generate.Patterns.Grid
import Generate.Patterns.Maze
import Generate.Patterns.RecursiveSplit
import Generate.Patterns.Sampling
import Generate.Patterns.Water
import Petal
import qualified Streaming as S
import qualified Streaming.Prelude as S

ramp :: Int -> [Double]
ramp total = map valueOf [0 .. total]
  where
    valueOf i = (fromIntegral i) / (fromIntegral total)

mkPalette :: Generate SimplePalette
mkPalette =
  randElem $
  V.fromList
    [ jhoto
    , metroid
    , gurken
    , mote
    , mkSimplePalette "EFC271" ["3E8A79", "E9A931", "F03E4D", "CC3433"]
    ]

background :: SimplePalette -> Generate (Render ())
background palette = do
  World {..} <- asks world
  return $ do
    setColour $ bgColour palette
    rectangle 0 0 width height
    fill

bgStream :: Stream (Render ())
bgStream = do
  palette <- lift $ mkPalette
  render <- lift $ background palette
  S.yield render

data Dot =
  Dot
    { circle :: Circle
    , colour :: (RGB Double, Double)
    }

randomCircle :: State -> Generate Dot
randomCircle State {..} = do
  let fgColours = (\(SimplePalette _ fg) -> fg) palette
  let fgColourCount = V.length fgColours
  frame <- fullFrame >>= return . (scaleFromCenter 0.7)
  center@(V2 x y) <- spatialSample frame
  alpha <- sampleRVar $ uniform 0.1 6.0
  noise <- noiseSample $ fmap (/ noiseScale) $ V3 x y 1
  colourShift <- sampleRVar $ normal 0 1
  let colourIdx =
        floor $ (fromIntegral fgColourCount) * abs (noise + colourShift)
  let colour = fgColours V.! (colourIdx `mod` fgColourCount)
  let (h, s, _) = hsvView colour
  hueDelta <- sampleRVar $ normal 0 0.2
  let hue = h + hueDelta
  let value = abs noise / 2 + 0.5
  let theta = pi * noise
  let center' = circumPoint center theta (noise * 40)
  let alpha' =
        if (floor $ (y + bandPhase) / bandHeight) `mod` 2 == 0
          then alpha
          else 0.0
  return $ Dot (Circle center' 0.1) (hsv hue s value, alpha')

circles :: State -> Stream Dot
circles state@(State {..}) =
  streamGenerates $ map (const $ randomCircle state) [0 .. circleCount]

drawCircle :: Dot -> Render ()
drawCircle (Dot c col) = do
  setColour col
  draw c
  fill

circleStream :: State -> Stream (Render ())
circleStream state = S.map (drawCircle) $ circles state

data Box =
  Box
    { rect :: Generate [V2 Double]
    , colour :: (RGB Double, Double)
    }

instance Element Box where
  realize (Box rect colour) = do
    vs <- rect
    mode :: Double <- sampleRVar $ uniform 0 1
    let realizer =
          if mode < 0.1
            then fill
            else stroke
    return $ do
      setColour colour
      draw vs
      closePath
      setLineWidth 0.1
      realizer
      newPath

instance Translucent Box where
  setOpacity opacity box@(Box _ (c, _)) = box {colour = (c, opacity)}

instance Subdivisible Box where
  subdivide box@(Box rect _) = box {rect = rect >>= return . subdivide}

instance Wiggle Box where
  wiggle (Wiggler f) box@(Box rect _) = do
    return $ box {rect = rect >>= sequence . (map f)}

mkBox :: SimplePalette -> Rect -> Generate Box
mkBox palette rect = do
  colour <- fgColour palette
  return $ subdivideN 3 $ Box (pure $ points rect) (colour, 1.0)

boxStream :: State -> Stream Box
boxStream State {..} = S.concat water
  where
    water :: Stream [Box]
    water = S.mapM warper outlines
    outlines :: Stream Box
    outlines =
      S.mapM (mkBox palette) $ unfoldGenerates $ recursiveSplit splitCfg frame

data State =
  State
    { palette :: SimplePalette
    , noiseScale :: Double
    , circleCount :: Int
    , bandHeight :: Double
    , bandPhase :: Double
    , frame :: Rect
    , splitCfg :: RecursiveSplitCfg
    , warper :: Box -> Generate [Box]
    }

mkSplitCfg :: Generate RecursiveSplitCfg
mkSplitCfg = do
  meanDepth <- sampleRVar $ uniform 2 5
  depthVariance <- sampleRVar $ uniform 1 3
  let depthVar :: Generate Double = sampleRVar $ normal meanDepth depthVariance
  return $
    def
      { shouldContinue =
          \(SplitStatus p depth) -> do
            limit <- depthVar
            return $ (fromIntegral depth) < limit
      }

mkNoiseWiggler :: Double -> Double -> Double -> Wiggler
mkNoiseWiggler z strength smoothness =
  Wiggler $ \p@(V2 x y) -> do
    let scale = 1 / smoothness
    let fixSamplePoint = fmap (scale *)
    theta <-
      (noiseSample $ fixSamplePoint $ V3 x y z) >>= return . (\x -> x * 2 * pi)
    r <-
      (noiseSample $ fixSamplePoint $ V3 x y (negate z)) >>=
      return . (* strength)
    return $ circumPoint p theta r

mkWarper :: Box -> Generate [Box]
mkWarper =
  let layerWiggler _ = do
        z <- sampleRVar $ uniform 0 1000
        strength <- sampleRVar $ normal 0 10
        smoothness <- sampleRVar $ normal 200 40
        return $ mkNoiseWiggler z strength smoothness
   in flatWaterColour 0.02 400 layerWiggler

start :: Generate State
start = do
  palette <- mkPalette
  noiseScale <- sampleRVar $ uniform 100 400
  circleCount <- sampleRVar $ uniform 1000000 2000000
  bandPhase <- sampleRVar $ uniform 0 200
  bandHeight <- sampleRVar $ uniform 5 200
  frameScale <- sampleRVar $ uniform 0.4 0.9
  frame <- fullFrame >>= return . (scaleFromCenter frameScale)
  splitCfg <- mkSplitCfg
  return $
    State
      palette
      noiseScale
      circleCount
      bandHeight
      bandPhase
      frame
      splitCfg
      mkWarper

sketch :: State -> Stream (Render ())
sketch state@(State {..}) =
  streamGenerates [background palette] >> S.mapM realize (boxStream state)

main :: IO ()
main = do
  runStatefulInvocation start sketch return
