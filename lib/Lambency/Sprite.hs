module Lambency.Sprite (
  SpriteFrame(..),
  Sprite(..),
  changeSpriteColor,
  loadStaticSprite,
  loadStaticSpriteWithTexture,
  loadStaticSpriteWithMask,
  loadAnimatedSprite,
  loadAnimatedSpriteWithTexture,
  loadAnimatedSpriteWithMask,
  loadFixedSizeAnimatedSprite,

  renderSprite,
  renderSpriteWithAlpha,
  renderUISprite,

  SpriteAnimationType(..),
  animatedWire,
) where

--------------------------------------------------------------------------------
import Control.Comonad
import Control.Wire hiding ((.))

import qualified Data.Map as Map

import Lambency.Material
import Lambency.Mesh
import Lambency.Render
import Lambency.Texture
import Lambency.Transform
import Lambency.Types
import Lambency.Utils

import Linear
--------------------------------------------------------------------------------

data SpriteFrame = SpriteFrame {
  offset :: V2 Float,
  spriteSize :: V2 Int,
  frameRO :: RenderObject
}

newtype Sprite = Sprite { getFrames :: CyclicList SpriteFrame }

curFrameOffset :: Sprite -> V2 Float
curFrameOffset = offset . extract . getFrames

updateScale :: V2 Float -> V2 Float -> ShaderMap -> ShaderMap
updateScale (V2 sx sy) (V2 tx ty) =
  Map.insert "texCoordMatrix" (Matrix3Val $
                               V3 (V3 sx 0 0) (V3 0 sy 0) (V3 tx ty 1))

-- !FIXME! This function shouldn't be here and we should really be using lenses
mapROMaterialVars :: (ShaderMap -> ShaderMap) -> RenderObject -> RenderObject
mapROMaterialVars fn ro = ro { materialVars = fn (materialVars ro) }

mapFrameRO :: (RenderObject -> RenderObject) -> SpriteFrame -> SpriteFrame
mapFrameRO fn sf = sf { frameRO = fn (frameRO sf) }

addTextFlag :: SpriteFrame -> SpriteFrame
addTextFlag = mapFrameRO $ \ro -> ro { flags = [Text, Transparent] }

changeSpriteColor :: V3 Float -> Sprite -> Sprite
changeSpriteColor c = Sprite . fmap (mapFrameRO $ mapROMaterialVars $ Map.insert "color" (Vector3Val c)) . getFrames

initStaticSprite :: Bool -> Texture -> IO (Sprite)
initStaticSprite isMask tex = do
  let mat = if isMask then createMaskedMaterial tex else createTexturedMaterial tex
  ro <- createRenderObject quad mat
  return . Sprite . cycleSingleton $ SpriteFrame {
    offset = zero,
    spriteSize = textureSize tex,
    frameRO = if isMask then ro { flags = [Text, Transparent] } else ro
  }

initAnimatedSprite :: Bool -> [V2 Int] -> [V2 Int] -> Texture -> IO (Sprite)
initAnimatedSprite isMask frameSzs offsets tex = do
  let mat = if isMask then createMaskedMaterial tex else createTexturedMaterial tex
  ro <- createRenderObject quad mat
  return . Sprite . cyclicFromList $ map (genFrame ro) (zip frameSzs offsets)
  where
    genFrame :: RenderObject -> (V2 Int, V2 Int) -> SpriteFrame
    genFrame ro (sz, off) =
      let texOff = changeRange off
      in SpriteFrame {
        offset = texOff,
        spriteSize = sz,
        frameRO = ro { materialVars = updateScale (changeRange sz) texOff (materialVars ro)}
        }

    changeRange :: V2 Int -> V2 Float
    changeRange (V2 ox oy) =
      let (V2 tx ty) = textureSize tex
      in V2
        (newRange (fromIntegral ox) (0, fromIntegral tx) (0, 1))
        (newRange (fromIntegral oy) (0, fromIntegral ty) (0, 1))

loadSpriteWith :: FilePath -> (Texture -> IO (Sprite)) -> IO (Maybe Sprite)
loadSpriteWith f initFn = do
  tex <- loadTexture f
  case tex of
    Nothing -> return Nothing
    (Just t@(Texture _ _)) -> initFn t >>= (return . Just)
    _ -> return Nothing

loadStaticSpriteWithTexture :: Texture -> IO (Sprite)
loadStaticSpriteWithTexture = initStaticSprite False

loadStaticSpriteWithMask :: Texture -> IO (Sprite)
loadStaticSpriteWithMask = initStaticSprite True

loadStaticSprite :: FilePath -> IO (Maybe Sprite)
loadStaticSprite f = loadSpriteWith f (initStaticSprite False)

loadAnimatedSprite :: FilePath -> [V2 Int] -> [V2 Int] -> IO (Maybe Sprite)
loadAnimatedSprite f frameSzs offsets = loadSpriteWith f $ initAnimatedSprite False frameSzs offsets

loadAnimatedSpriteWithTexture :: Texture -> [V2 Int] -> [V2 Int] -> IO (Maybe Sprite)
loadAnimatedSpriteWithTexture t frameSzs offsets =
  initAnimatedSprite False frameSzs offsets t >>= (return . Just)

loadAnimatedSpriteWithMask :: Texture -> [V2 Int] -> [V2 Int] -> IO (Maybe Sprite)
loadAnimatedSpriteWithMask t frameSzs offsets =
  initAnimatedSprite True frameSzs offsets t >>= (return . Just . Sprite . fmap addTextFlag . getFrames)

loadFixedSizeAnimatedSprite :: FilePath -> V2 Int -> [V2 Int] -> IO (Maybe Sprite)
loadFixedSizeAnimatedSprite f frameSz offsets = loadAnimatedSprite f (repeat frameSz) offsets

renderUISprite :: Sprite -> V2 Float -> GameMonad ()
renderUISprite s pos = addRenderUIAction pos ro
  where
    currentFrame = extract $ getFrames s
    (V2 sx sy) = spriteSize currentFrame
    ro = xformObject (nonuniformScale (fmap fromIntegral $ V3 sx sy 1) identity) $ frameRO currentFrame

renderFrameAt :: RenderObject -> V2 Int -> Float -> V2 Float -> GameMonad ()
renderFrameAt ro sc depth (V2 x y) = addRenderAction xf ro
  where
    (V2 sx sy) = fmap fromIntegral sc
    xf = translate (V3 x y depth) $
         nonuniformScale (V3 sx sy 1) identity

renderSprite :: Sprite -> V2 Int -> Float -> V2 Float -> GameMonad ()
renderSprite s = renderFrameAt $ frameRO $ extract . getFrames $ s

renderSpriteWithAlpha :: Sprite -> Float -> V2 Int -> Float -> V2 Float -> GameMonad ()
renderSpriteWithAlpha s a = renderFrameAt (setAlpha $ frameRO $ extract . getFrames $ s)
  where
    setAlpha ro = ro { materialVars = Map.insert "alpha" (FloatVal a) (materialVars ro),
                       flags = (Transparent : (flags ro)) }

data SpriteAnimationType
  = SpriteAnimationType'Forward
  | SpriteAnimationType'Backward
  | SpriteAnimationType'Loop
  | SpriteAnimationType'LoopBack
  | SpriteAnimationType'PingPong
    deriving(Eq, Ord, Show, Enum)

animatedWire :: Sprite -> V2 Int -> SpriteAnimationType -> GameWire (V2 Float) (V2 Float)
animatedWire sprite sz SpriteAnimationType'Forward = loop $ second (delay sprite) >>> loopW
  where
    loopW :: GameWire (V2 Float, Sprite) (V2 Float, Sprite)
    loopW = mkGenN $ \(p, s) -> do
      renderSprite s sz 0 p
      let nextSprite = Sprite . advance . getFrames $ s
          result = Right (p, nextSprite)
      if (curFrameOffset nextSprite) == curFrameOffset sprite
        then return (result, mkEmpty)
        else return (result, loopW)

animatedWire (Sprite (CyclicList p c n)) sz SpriteAnimationType'Backward =
   animatedWire (Sprite (CyclicList n c p)) sz SpriteAnimationType'Forward

animatedWire s sz SpriteAnimationType'Loop =
  let w = animatedWire s sz SpriteAnimationType'Forward
  in w --> w

animatedWire s sz SpriteAnimationType'LoopBack =
  let w = animatedWire s sz SpriteAnimationType'Backward
  in w --> w

animatedWire s sz SpriteAnimationType'PingPong =
  let f = animatedWire s sz SpriteAnimationType'Forward
      b = animatedWire s sz SpriteAnimationType'Backward
  in
   f --> b --> (animatedWire s sz SpriteAnimationType'PingPong)
