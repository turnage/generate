module Algo.QuadTree
  ( QuadTree(..)
  , Quad(..)
  , Leaf(..)
  , Heuristic(..)
  , new
  , insert
  , insertMany
  , nearest
  , empty
  , defaultNodeUpdater
  ) where

import Linear

import qualified Data.List as L
import Data.Maybe
import Data.Ord
import qualified Data.Vector as V
import Geom.Rect
import Test.Hspec

data QuadTree v
  = LeafNode (Maybe (Leaf v) -> Leaf v -> Maybe (Leaf v))
             Rect
             (Leaf v)
  | QuadNode (Quad v)

data Leaf v = Leaf
  { leafPosition :: V2 Double
  , leafTag :: v
  } deriving (Eq, Show)

data Heuristic v = Heuristic
  {- Distance between leaves. -}
  { heuristicDistance :: Leaf v -> Leaf v -> Double
  {- Given the current best candidate leaf in search, determine whether the 
     subtree is worth searching. Returning Nothing will fall back on region
     heuristic. 
  
     Best -> SearchLeaf -> Candidate Quad -> Eligible?
  
  -}
  , heuristicFilter :: Leaf v -> Leaf v -> Quad v -> Bool
  }

data Quad v = Quad
  { quadRepUpdate :: Maybe (Leaf v) -> Leaf v -> Maybe (Leaf v)
  , quadRegion :: Rect
  , quadRepresentative :: Maybe (Leaf v)
  , quadChildren :: ( Maybe (QuadTree v)
                    , Maybe (QuadTree v)
                    , Maybe (QuadTree v)
                    , Maybe (QuadTree v))
  }

data Quadrant
  = Q1
  | Q2
  | Q3
  | Q4
  deriving (Eq, Show)

defaultNodeUpdater :: Maybe (Leaf v) -> Leaf v -> Maybe (Leaf v)
defaultNodeUpdater v@(Just _) _ = v
defaultNodeUpdater Nothing v = Just v

-- Returns a new QuadTree representing the given Rect.
new :: (Maybe (Leaf v) -> Leaf v -> Maybe (Leaf v)) -> Rect -> QuadTree v
new repUpdate rect = QuadNode $ _newQuad repUpdate rect

_newQuad :: (Maybe (Leaf v) -> Leaf v -> Maybe (Leaf v)) -> Rect -> Quad v
_newQuad repUpdate rect =
  Quad repUpdate rect Nothing (Nothing, Nothing, Nothing, Nothing)

-- Returns (True, Tree with leaf inserted) if the leaf position is within
-- the domain of the quadtree. Returns (False, Tree unchanged otherwise).
insert :: Leaf v -> QuadTree v -> (Bool, QuadTree v)
insert leaf@(Leaf position _) tree =
  if withinRect (_region tree) position
    then (True, ) $ _insert leaf tree
    else (False, tree)

_region :: QuadTree v -> Rect
_region (QuadNode (Quad _ reg _ _)) = reg
_region (LeafNode _ reg _) = reg

_insert :: Leaf v -> QuadTree v -> QuadTree v
_insert leaf@(Leaf p _) (QuadNode quad@(Quad ru reg _ _)) =
  let q = _quadrantOf reg p
   in QuadNode $ _updateChild quad leaf q
_insert leaf@(Leaf p _) (LeafNode ru reg oldLeaf) =
  let branch = new ru reg
   in insertMany [oldLeaf, leaf] branch

insertMany :: [Leaf v] -> QuadTree v -> QuadTree v
insertMany [] tree = tree
insertMany (leaf:remaining) tree = insertMany remaining $ _insert leaf tree

_updateChild :: Quad v -> Leaf v -> Quadrant -> Quad v
_updateChild (Quad ru reg rep (c1, c2, c3, c4)) leaf q =
  let subRegion = _subRegion reg q
      fallback = LeafNode ru subRegion leaf
      (constructor, child) =
        case q of
          Q1 -> (\c -> (c, c2, c3, c4), c1)
          Q2 -> (\c -> (c1, c, c3, c4), c2)
          Q3 -> (\c -> (c1, c2, c, c4), c3)
          Q4 -> (\c -> (c1, c2, c3, c), c4)
      child' = fromMaybe fallback $ fmap (_insert leaf) child
      rep' = ru rep leaf
   in Quad ru reg rep' $ constructor $ Just child'

_subRegion :: Rect -> Quadrant -> Rect
_subRegion (Rect (V2 tlx tly) w h) q =
  case q of
    Q1 -> Rect (V2 (tlx + w / 2) (tly + h / 2)) (w / 2) (h / 2)
    Q2 -> Rect (V2 tlx (tly + h / 2)) (w / 2) (h / 2)
    Q3 -> Rect (V2 tlx tly) (w / 2) (h / 2)
    Q4 -> Rect (V2 (tlx + w / 2) tly) (w / 2) (h / 2)

_quadrantOf :: Rect -> V2 Double -> Quadrant
_quadrantOf r (V2 x y) =
  let (V2 cx cy) = rectCenter r
   in if x >= cx
        then if y >= cy
               then Q1
               else Q4
        else if y >= cy
               then Q2
               else Q3

-- Returns the nearest point in the QuadTree to the given leaf.
-- Uses the provided distance function.
nearest :: Heuristic v -> Leaf v -> QuadTree v -> Maybe (Leaf v)
nearest heuristic p tree =
  _nearest heuristic (_treeLeaf tree) p $ V.fromList [tree]

_nearest ::
     Heuristic v
  -> (Maybe (Leaf v))
  -> Leaf v
  -> V.Vector (QuadTree v)
  -> Maybe (Leaf v)
_nearest h@(Heuristic distanceF eligibleF) best searchLeaf trees =
  let treesWithChildren =
        V.mapMaybe
          (\tree ->
             case tree of
               QuadNode quad -> Just quad
               _ -> Nothing)
          trees
      treesWithLeaves = V.filter (isJust . _treeLeaf) trees
      candidateLeaves = V.mapMaybe (_treeLeaf) treesWithLeaves
      candidateLeaves' =
        case best of
          Just best -> V.cons best $ candidateLeaves
          Nothing -> candidateLeaves
      best' =
        if V.null candidateLeaves'
          then Nothing
          else Just $
               V.minimumBy (comparing $ distanceF searchLeaf) candidateLeaves'
   in case best' of
        Nothing -> Nothing
        Just best' ->
          let eligible = V.filter (eligibleF best' searchLeaf) treesWithChildren
              next = V.concatMap (_nextLevel) eligible
           in if V.null next
                then Just best'
                else _nearest h (Just best') searchLeaf next

_treeLeaf :: QuadTree v -> Maybe (Leaf v)
_treeLeaf (QuadNode (Quad _ _ rep _)) = rep
_treeLeaf (LeafNode _ _ leaf) = Just leaf

-- Returns True iff the QuadTree contains no points.
empty :: QuadTree v -> Bool
empty (QuadNode (Quad _ _ rep _)) = isNothing rep
empty (LeafNode _ _ _) = False

_nextLevel :: Quad v -> V.Vector (QuadTree v)
_nextLevel (Quad _ _ _ (c1, c2, c3, c4)) =
  V.fromList $ catMaybes [c1, c2, c3, c4]

_distanceToNode :: V2 Double -> QuadTree v -> Maybe (Double)
_distanceToNode p (QuadNode (Quad _ reg rep _)) =
  case rep of
    Just _ -> Just $ distanceToRect reg p
    Nothing -> Nothing
_distanceToNode p (LeafNode _ _ (Leaf leaf _)) = Just $ distance p leaf
