module Generate.Monad
  ( Generate(..)
  , runGenerate
  , Context(..)
  , Random(..)
  , World(..)
  , noiseSample
  , noiseSampleWithScale
  , noiseToTheta
  , noiseToScale
  , runRand
  , randElem
  , randElemStable
  , scaledDimensions
  ) where

import Control.Monad.Reader
import Control.Monad.State as State
import Data.Maybe
import Data.RVar
import Data.Random.Distribution.Uniform
import Data.Random.Source.PureMT
import qualified Data.Vector as V
import Graphics.Rendering.Cairo
import Linear
import Math.Noise
import Math.Noise.Modules.Perlin

data World = World
  { width :: Double
  , height :: Double
  , scaleFactor :: Double
  } deriving (Eq, Show)

scaledDimensions :: World -> V2 Int
scaledDimensions World {width, height, scaleFactor, ..} =
  V2 (round $ width * scaleFactor) (round $ height * scaleFactor)

data Context = Context
  { world :: World
  , frame :: Int
  , frameCount :: Int
  , time :: Double
  , noise :: Perlin
  , seed :: Int
  }

type Generate = StateT PureMT (Reader Context)

noiseToTheta :: Double -> Double
noiseToTheta n = (n + 1) * pi

noiseToScale :: Double -> Double
noiseToScale n = (n + 1) / 2

noiseSample :: V3 Double -> Generate (Double)
noiseSample (V3 x y z) = do
  noiseSrc <- asks noise
  return $ fromJust $ getValue noiseSrc (x, y, z)

noiseSampleWithScale :: Double -> V3 Double -> Generate Double
noiseSampleWithScale scale v = noiseSample $ fmap (/ scale) v

runGenerate :: Context -> PureMT -> Generate a -> (a, PureMT)
runGenerate ctx rng scene = (flip runReader ctx) . (flip runStateT rng) $ scene

type Random a = State PureMT a

-- Chooses a random element from a vector.
randElem :: V.Vector a -> Generate a
randElem as = do
  i <- sampleRVar $ uniform 0 $ V.length as - 1
  return $ as V.! i

-- Chooses the same random element from a vector every invocation
-- for a given seed.
randElemStable :: V.Vector a -> Generate a
randElemStable vs = do
  seed_ <- asks seed
  let i = seed_ `mod` (V.length vs)
  return $ vs V.! i

runRand :: Random a -> Generate a
runRand rand = do
  rng <- State.get
  let (val, rng') = runState rand rng
  State.put rng'
  return val
