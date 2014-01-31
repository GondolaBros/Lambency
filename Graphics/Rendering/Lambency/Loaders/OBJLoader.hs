module Graphics.Rendering.Lambency.Loaders.OBJLoader (
  loadOBJ
) where

--------------------------------------------------------------------------------

import Graphics.Rendering.Lambency.Mesh
import Graphics.Rendering.Lambency.Vertex

import qualified Data.Map as Map

import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Text (pack)

import Data.Vect.Float
import Data.Array.Unboxed (UArray, listArray, (!))

import Text.Parsec
import Text.Parsec.Text (Parser)

--------------------------------------------------------------------------------

type OBJVertex = Vec3
type OBJVertexList = [OBJVertex]

type OBJTexCoord = Vec2
type OBJTexCoordList = [OBJTexCoord]

emptyTexCoords :: OBJTexCoordList -> Bool
emptyTexCoords [] = True
emptyTexCoords _ = False

type OBJNormal = Normal3
type OBJNormalList = [OBJNormal]

emptyNormals :: OBJNormalList -> Bool
emptyNormals [] = True
emptyNormals _ = False

type OBJIndex = (Int, Maybe Int, Maybe Int) -- derives Eq, Ord
type OBJIndexList = [OBJIndex]
type OBJFace = OBJIndexList
type OBJFaceList = [OBJFace]

data OBJGeometry = OBJGeometry {
  objVerts :: OBJVertexList,
  objTexCoords :: OBJTexCoordList,
  objNormals :: OBJNormalList,
  objFaces :: OBJFaceList
} deriving (Show)

triangulate :: OBJFaceList -> OBJIndexList
triangulate fs = let
  tglte :: OBJFace -> [OBJFace] -> [OBJFace]
  tglte f faces
    | length f <= 3 = f : faces
    | otherwise =
      case f of
        (i1 : i2 : i3 : rest) -> tglte (i1 : i3 : rest) ([i1, i2, i3] : faces)
        _ -> error "Wat"
  in
   concat . concat $ map (flip tglte []) fs

simpleObj2Mesh :: OBJVertexList -> OBJFaceList -> Mesh
simpleObj2Mesh verts faces = Mesh {
  vertices = map mkVertex3 verts,
  indices = map (\(x, _, _) -> fromIntegral x) $ triangulate faces
}

mkVec2Lookup :: [Vec2] -> (Int -> Vec2)
mkVec2Lookup vecs = let
  arr :: UArray Int Float
  arr = listArray
        (1, (length vecs + 1) * 2)
        (concat $ map (\(Vec2 x y) -> [x, y]) vecs)
  in (\i -> Vec2 (arr ! (2*i-1)) (arr ! (2*i)))

mkVec3Lookup :: [Vec3] -> (Int -> Vec3)
mkVec3Lookup vecs = let
  arr :: UArray Int Float
  arr = listArray
        (1, (length vecs + 1)  * 3)
        (concat $ map (\(Vec3 x y z) -> [x, y, z]) vecs)
  in (\i -> Vec3 (arr ! (3*i - 2)) (arr ! (3*i-1)) (arr ! (3*i)))

genMesh :: OBJIndexList -> (OBJIndex -> Vertex) -> Mesh
genMesh idxs f = let
  genIdxMap :: OBJIndexList -> Map.Map OBJIndex (Int, Vertex) -> Int -> Map.Map OBJIndex (Int, Vertex)
  genIdxMap (idx : rest) m nVerts =
    case Map.lookup idx m of
      Just _ -> genIdxMap rest m nVerts
      Nothing -> genIdxMap rest (Map.insert idx (nVerts, f idx) m) (nVerts + 1)
  genIdxMap [] m _ = m

  idxMap :: Map.Map OBJIndex (Int, Vertex)
  idxMap = genIdxMap idxs Map.empty 0

  in Mesh {
    vertices = map snd $ sortBy (comparing fst) $ Map.elems idxMap,
    indices = map (fromIntegral . fst . (idxMap Map.!)) idxs
  }

normalObj2Mesh :: OBJVertexList -> OBJNormalList -> OBJFaceList -> Mesh
normalObj2Mesh verts normals faces = let
  ns = mkVec3Lookup $ map fromNormal normals
  vs = mkVec3Lookup verts

  idx2Vertex :: OBJIndex -> Vertex
  idx2Vertex (x, _, Just n) = mkNormVertex3 (vs x) (ns n)
  idx2Vertex i = error $ "Ill formatted index: " ++ (show i)

  in genMesh (triangulate faces) idx2Vertex

texturedObj2Mesh :: OBJVertexList -> OBJTexCoordList -> OBJFaceList -> Mesh
texturedObj2Mesh verts texcoords faces = let
  tcs = mkVec2Lookup $ texcoords
  vs = mkVec3Lookup verts

  idx2Vertex :: OBJIndex -> Vertex
  idx2Vertex (x, Just tc, _) = mkTexVertex3 (vs x) (tcs tc)
  idx2Vertex i = error $ "Ill formatted index: " ++ (show i)

  in genMesh (triangulate faces) idx2Vertex

normTexturedObj2Mesh :: OBJVertexList -> OBJTexCoordList -> OBJNormalList -> OBJFaceList -> Mesh
normTexturedObj2Mesh verts texcoords normals faces = let
  ns = mkVec3Lookup $ map fromNormal normals
  tcs = mkVec2Lookup texcoords
  vs = mkVec3Lookup verts

  idx2Vertex :: OBJIndex -> Vertex
  idx2Vertex (x, Just tc, Just n) = mkNormTexVertex3 (vs x) (ns n) (tcs tc)
  idx2Vertex i = error $ "Ill formatted index: " ++ (show i)

  in genMesh (triangulate faces) idx2Vertex

obj2Mesh :: OBJGeometry -> Mesh
obj2Mesh (OBJGeometry {objVerts=vs, objTexCoords=tcs, objNormals=ns, objFaces=fs})
  | emptyTexCoords tcs && (emptyNormals ns) = simpleObj2Mesh vs fs
  | emptyTexCoords tcs = normalObj2Mesh vs ns fs
  | emptyNormals ns = texturedObj2Mesh vs tcs fs
  | otherwise = normTexturedObj2Mesh vs tcs ns fs

data Value = Normal Vec3
           | Position Vec3
           | TexCoord Vec2
           | Face OBJFace
             deriving (Show)

parseFile :: Parser OBJGeometry
parseFile = let

  float :: Parser Float
  float = do
    spaces
    sign <- option 1 $ do s <- oneOf "+-"
                          return $ if s == '-' then (-1.0) else 1.0
    t <- many digit
    _ <- if t == [] then (char '.') else (try $ char '.')
    d <- many digit
    e <- option "0" $ do _ <- char 'e'
                         many1 digit

    return $ ((read t) + ((read d) / (10 ** (fromIntegral $ length d)))) * (10 ** (read e)) * sign

  vector2 :: Parser Vec2
  vector2 = do
    x <- float
    y <- float
    return $ Vec2 x y

  vector3 :: Parser Vec3
  vector3 = do
    x <- float
    y <- float
    z <- float
    return $ Vec3 x y z

  comment :: Parser ()
  comment = char '#' >> many (noneOf ['\n']) >> newline >> return ()

  -- FIXME -- 
  errata :: Parser ()
  errata = oneOf "osg" >> many (noneOf ['\n']) >> newline >> return ()

  blankLine :: Parser ()
  blankLine = (newline <|> (skipMany1 (tab <|> char ' ') >> newline)) >> return ()

  vert :: Parser Value
  vert =
    char 'v' >>
    ((char ' ' >> vector3 >>= return . Position)
     <|> (char 'n' >> vector3 >>= return . Normal)
     <|> (char 't' >> vector2 >>= return . TexCoord))

  integer :: Parser Int
  integer = do
    skipMany (tab <|> char ' ')
    v <- many1 digit
    return $ read v

  index :: Parser OBJIndex
  index = do
    skipMany (tab <|> char ' ')
    idx <- integer
    (tc, n) <- (do _ <- char '/'
                   mtc <- option Nothing $ integer >>= (return . Just)
                   mn <- (char '/' >> integer >>= (return.Just)) <|> (return Nothing)
                   return (mtc, mn))
               <|>
               (return (Nothing, Nothing))
    skipMany (tab <|> char ' ')
    return (idx, tc, n)

  face :: Parser Value
  face = do
    idxs <- char 'f' >> (many1 index)
    return $ Face idxs

  value :: Parser Value
  value = vert <|> face

  parseLine :: Parser Value
  parseLine = let
    ignorable = many (comment <|> blankLine <|> errata)
    in do
      v <- ignorable >> value
      ignorable >> return v

  initialGeom = OBJGeometry {
    objVerts = [],
    objTexCoords = [],
    objNormals = [],
    objFaces = []
    }

  constructGeometry :: [Value] -> OBJGeometry -> OBJGeometry
  constructGeometry (Normal n : rest) g =
    constructGeometry rest $ (\og -> og { objNormals = (mkNormal n) : (objNormals g) }) g
  constructGeometry (Position p : rest) g =
    constructGeometry rest $ (\og -> og { objVerts = p : (objVerts g) }) g
  constructGeometry (TexCoord tc : rest) g =
    constructGeometry rest $ (\og -> og { objTexCoords = tc : (objTexCoords g) }) g
  constructGeometry (Face f : rest) g =
    constructGeometry rest $ (\og -> og { objFaces = f : (objFaces g) }) g
  constructGeometry _ g = g

  in do
    vals <- many1 parseLine
    return $ constructGeometry (reverse vals) initialGeom

loadOBJ :: FilePath -> IO (Mesh)
loadOBJ filepath = let
  parseOBJ :: String -> OBJGeometry
  parseOBJ s =
    case parse parseFile filepath (pack s) of
      Left x -> error $ show x
      Right y -> y

  in
   readFile filepath >>= return . obj2Mesh . parseOBJ
