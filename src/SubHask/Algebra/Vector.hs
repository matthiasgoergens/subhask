{-# LANGUAGE BangPatterns #-}
module SubHask.Algebra.Vector
    (
    -- * Vectors
    VS.Vector
    , BoxedVector
    , UnboxedVector

    -- * Arrays
    , Array
    , UnboxedArray
    , StorableArray
    , ArrayT (..)
    , ArrayTM (..)
    )
    where

import Foreign.Storable
import qualified Data.Vector.Generic as VG
import qualified Data.Vector.Generic.Mutable as VGM
import qualified Data.Vector.Storable as VS
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector as V

import Control.Monad
import Test.QuickCheck (frequency)

import SubHask.Internal.Prelude
import SubHask.Algebra
import SubHask.Category

import Control.Monad.Primitive
import Control.Monad.ST
import Data.IORef
import Data.STRef

--------------------------------------------------------------------------------
-- Mutability

type family MutableVersion a :: * -> *
type family ImmutableVersion (a :: * -> *) :: *

class Mutable a ma | a -> ma, ma -> a where
    unsafeFreeze :: PrimMonad m => ma (PrimState m) -> m a
    unsafeThaw :: PrimMonad m => a -> m (ma (PrimState m))

    freeze :: PrimMonad m => ma (PrimState m) -> m a
    thaw :: PrimMonad m => a -> m (ma (PrimState m))


class
    ( Semigroup g
    , Mutable g mg
    ) => SemigroupM g mg
        where

    infixl 6 +=
    (+=) :: PrimMonad m
            => mg (PrimState m)
            -> mg (PrimState m)
            -> m (mg (PrimState m))

defn_SemigroupM :: forall g mg.
    ( Eq g
    , SemigroupM g mg
    , Mutable g mg
    ) => g -> g -> Bool
defn_SemigroupM g1 g2 = g1+g2 == res
    where
        res = runST ( do
            g1thaw <- thaw g1
            g2thaw <- thaw g2
            g1thaw += g2thaw
            unsafeFreeze g1thaw
            )

newtype MBoxedVector a s = MBoxedVector (V.MVector s a)

instance Mutable (V.Vector a) (MBoxedVector a) where
    unsafeThaw v = liftM MBoxedVector $ VG.unsafeThaw v
    unsafeFreeze (MBoxedVector mv) = VG.unsafeFreeze mv

    thaw v = liftM MBoxedVector $ VG.thaw v
    freeze (MBoxedVector mv) = VG.freeze mv

instance Semigroup g => SemigroupM (BoxedVector g) (MBoxedVector g) where
    (+=) (MBoxedVector mv1) (MBoxedVector mv2)
        | VGM.length mv1 == 0 = return $ MBoxedVector mv2
        | VGM.length mv2 == 0 = return $ MBoxedVector mv1
        | VGM.length mv2 /= VGM.length mv2 = error "BoxedVector.SemigroupM: vectors have unequal length"
        | otherwise = do
            go 0
            return (MBoxedVector mv1)
        where
            go i = if i == VGM.length mv1
                then return ()
                else do
                    g1 <- VGM.unsafeRead mv1 i
                    g2 <- VGM.unsafeRead mv2 i
                    VGM.unsafeWrite mv1 i (g1 + g2)
                    go (i+1)

-------------------------------------------------------------------------------

type Array = ArrayT BoxedVector
type UnboxedArray = ArrayT UnboxedVector
type StorableArray = ArrayT VS.Vector

newtype ArrayT v r = ArrayT (v r)
    deriving (Eq,Read,Show,Arbitrary)

type instance Scalar (ArrayT v r) = Int
type instance Elem (ArrayT v r) = r

instance NFData (v r) => NFData (ArrayT v r) where
    rnf (ArrayT v) = rnf v

-- instance Eq (v r) => Eq (ArrayT v r) where
--     (ArrayT v1)==(ArrayT v2) = v1==v2

instance VG.Vector v r => Normed (ArrayT v r) where
    abs = VG.length

instance VG.Vector v a => VG.Vector (ArrayT v) a where
    {-# INLINE basicUnsafeFreeze #-}
    {-# INLINE basicUnsafeThaw #-}
    {-# INLINE basicLength #-}
    {-# INLINE basicUnsafeSlice #-}
    {-# INLINE basicUnsafeIndexM #-}
    {-# INLINE basicUnsafeCopy #-}
    {-# INLINE elemseq #-}
    basicUnsafeFreeze (ArrayTM v) = liftM ArrayT $ VG.basicUnsafeFreeze v
    basicUnsafeThaw (ArrayT v) = liftM ArrayTM $ VG.basicUnsafeThaw v
    basicLength (ArrayT v) = VG.basicLength v
    basicUnsafeSlice s t (ArrayT v) = ArrayT $ VG.basicUnsafeSlice s t v
    basicUnsafeIndexM (ArrayT v) i = VG.basicUnsafeIndexM v i
    basicUnsafeCopy (ArrayTM vm) (ArrayT v) = VG.basicUnsafeCopy vm v
    elemseq (ArrayT v) a b = VG.elemseq v a b

newtype ArrayTM v s a = ArrayTM { unArrayTM :: v s a }

instance VGM.MVector v a => VGM.MVector (ArrayTM v) a where
    {-# INLINE basicLength #-}
    {-# INLINE basicUnsafeSlice #-}
    {-# INLINE basicOverlaps #-}
    {-# INLINE basicUnsafeNew #-}
    {-# INLINE basicUnsafeReplicate #-}
    {-# INLINE basicUnsafeRead #-}
    {-# INLINE basicUnsafeWrite #-}
    basicLength (ArrayTM v) = VGM.basicLength v
    basicUnsafeSlice s t (ArrayTM v) = ArrayTM $ VGM.basicUnsafeSlice s t v
    basicOverlaps (ArrayTM v1) (ArrayTM v2) = VGM.basicOverlaps v1 v2
    basicUnsafeNew n = liftM ArrayTM $ VGM.basicUnsafeNew n
    basicUnsafeReplicate i a = liftM ArrayTM $ VGM.basicUnsafeReplicate i a
    basicUnsafeRead (ArrayTM v) i = VGM.basicUnsafeRead v i
    basicUnsafeWrite (ArrayTM v) i a = VGM.basicUnsafeWrite v i a

type instance VG.Mutable (ArrayT v) = ArrayTM (VG.Mutable v)

instance VG.Vector v r => Semigroup (ArrayT v r) where
    (ArrayT v1)+(ArrayT v2) = ArrayT $ v1 VG.++ v2

instance VG.Vector v r => Monoid (ArrayT v r) where
    zero = ArrayT $ VG.empty

instance (VG.Vector v r, Eq r) => Container (ArrayT v r) where
    elem r (ArrayT v) = elem r $ VG.toList v

instance VG.Vector v r => Unfoldable (ArrayT v r) where
    singleton r = ArrayT $ VG.singleton r

    fromList = ArrayT . VG.fromList

    fromListN n = ArrayT . VG.fromListN n

instance VG.Vector v r => Foldable (ArrayT v r) where

    {-# INLINE toList #-}
    toList (ArrayT v) = VG.toList v

    unCons (ArrayT v) = if VG.null v
        then Nothing
        else Just (VG.head v, ArrayT $ VG.tail v)
    unSnoc (ArrayT v) = if VG.null v
        then Nothing
        else Just (ArrayT $ VG.init v, VG.last v)

    foldMap f   (ArrayT v) = VG.foldl' (\a e -> a + f e) zero v

    {-# INLINE foldr #-}
    {-# INLINE foldr' #-}
    {-# INLINE foldr1 #-}
    {-# INLINE foldr1' #-}
    {-# INLINE foldl #-}
    {-# INLINE foldl' #-}
    {-# INLINE foldl1 #-}
    {-# INLINE foldl1' #-}
    foldr   f x (ArrayT v) = VG.foldr   f x v
    foldr'  f x (ArrayT v) = VG.foldr'  f x v
--     foldr'  f x (ArrayT v) = vecfold  f x v
    foldr1  f   (ArrayT v) = VG.foldr1  f   v
    foldr1' f   (ArrayT v) = VG.foldr1' f   v
    foldl   f x (ArrayT v) = VG.foldl   f x v
    foldl'  f x (ArrayT v) = VG.foldl'  f x v
    foldl1  f   (ArrayT v) = VG.foldl1  f   v
    foldl1' f   (ArrayT v) = VG.foldl1' f   v

{-# INLINE vecfold #-}
-- vecfold :: VG.Vector v a => (a -> b -> a) -> b -> v a -> b
vecfold !f !tot !v = {-# SCC vecfold #-} if VG.length v > 0
    then goEach 0 tot
    else tot
    where
        goEach !i !tot = if i>=VG.length v
            then tot
            else goEach (i+1) $ f (v `VG.unsafeIndex` i) tot

instance (POrd r, VG.Vector v r) => InfSemilattice (ArrayT v r) where
    inf (ArrayT v1) (ArrayT v2) = ArrayT $ VG.fromList $ inf (VG.toList v1) (VG.toList v2)

instance (POrd r, VG.Vector v r) => MinBound (ArrayT v r) where
    minBound = zero

instance (Eq (v r), POrd r, VG.Vector v r) => POrd (ArrayT v r) where
    pcompare (ArrayT v1) (ArrayT v2) = pcompare (VG.toList v1) (VG.toList v2)

-------------------------------------------------------------------------------

type UnboxedVector = VU.Vector

instance (VU.Unbox r, Arbitrary r) => Arbitrary (VU.Vector r) where
    arbitrary = liftM VG.fromList arbitrary
    shrink v = map VG.fromList $ shrink (VG.toList v)


-- instance (VU.Unbox r, Eq r) => Eq (VU.Vector r) where
--     {-# INLINABLE (==) #-}
--     v1==v2 = if VG.length v1 /= VG.length v2
--         then False
--         else go 0
--         where
--             go !i = if i == VG.length v1
--                 then True
--                 else if v1 `VG.unsafeIndex` i /= v2 `VG.unsafeIndex` i
--                     then False
--                     else go (i+1)

instance (VU.Unbox r, Ord r) => Lattice (VU.Vector r)
instance (VU.Unbox r, Ord r) => InfSemilattice (VU.Vector r) where inf = min
instance (VU.Unbox r, Ord r) => SupSemilattice (VU.Vector r) where sup = max

instance (VU.Unbox r, Ord r) => POrd (VU.Vector r) where
    {-# INLINABLE pcompare #-}
    pcompare v1 v2 = pcompare (Lexical (ArrayT v1)) (Lexical (ArrayT v2))

instance (VU.Unbox r, Ord r) => Ord (VU.Vector r)

instance (VU.Unbox r,  Semigroup r) => Semigroup (VU.Vector r) where
    {-# INLINE (+) #-}
    v1 + v2 = if VG.length v1 == 0
        then v2
        else if VG.length v2 == 0
            then v1
            else if VG.length v1 /= VG.length v2
                then error "VU.Vector + two different non-zero lengths"
                else VG.generate (VG.length v1) go
        where
            go i = v1 `VG.unsafeIndex` i + v2 `VG.unsafeIndex` i

instance (VU.Unbox r,  Monoid r) => Monoid (VU.Vector r) where
    {-# INLINE zero #-}
    zero = VG.empty

instance (VU.Unbox r,  Abelian r) => Abelian (VU.Vector r)

instance (VU.Unbox r,  Cancellative r) => Cancellative (VU.Vector r) where
    {-# INLINE (-) #-}
    v1 - v2 = if VG.length v1 == 0
        then v2
        else if VG.length v2 == 0
            then v1
            else if VG.length v1 /= VG.length v2
                then error "VU.Vector - two different non-zero lengths"
                else VG.generate (VG.length v1) go
        where
            go i = v1 `VG.unsafeIndex` i - v2 `VG.unsafeIndex` i


instance (VU.Unbox r,  Group r) => Group (VU.Vector r) where
    {-# INLINE negate #-}
    negate v = VG.map negate v

type instance Scalar (VU.Vector r) = Scalar r

instance (VU.Unbox r,  Module r, IsScalar (Scalar r)) => Module (VU.Vector r) where
    {-# INLINE (*.) #-}
    r *. v = VG.map (r*.) v

    {-# INLINE (.*.) #-}
    u .*. v = if VG.length u == VG.length v
        then VG.zipWith (.*.) u v
        else error "(.*.): u and v have different lengths"

instance (VU.Unbox r, VectorSpace r, IsScalar (Scalar r)) => VectorSpace (VU.Vector r) where
    {-# INLINE (./) #-}
    v ./ r = VG.map (./r) v

    {-# INLINE (./.) #-}
    u ./. v = if VG.length u == VG.length v
        then VG.zipWith (./.) u v
        else error "(./.): u and v have different lengths"

instance
    ( IsScalar r
    , Normed r
    , VectorSpace r
    , Floating r
    , VU.Unbox r
    ) => Normed (VU.Vector r)
        where
    abs = innerProductNorm

instance
    ( IsScalar r
    , Normed r
    , VectorSpace r
    , Floating r
    , VU.Unbox r
    ) => MetricSpace (VU.Vector r)
        where
    distance = innerProductDistance

instance
    ( IsScalar r
    , Normed r
    , VectorSpace r
    , Floating r
    , VU.Unbox r
    ) => InnerProductSpace (VU.Vector r)
        where
    v1 <> v2 = if VG.length v1 == 0
        then zero
        else if VG.length v2 == 0
            then zero
            else if VG.length v1 /= VG.length v2
                then error "inner product on storable vectors of different sizes"
                else VG.foldl' (+) zero $ VG.zipWith (*) v1 v2

-------------------------------------------------------------------------------

type BoxedVector = V.Vector

instance Arbitrary r => Arbitrary (V.Vector r) where
    arbitrary = liftM VG.fromList arbitrary
    shrink v = map VG.fromList $ shrink (VG.toList v)

-- instance ( Eq r) => Eq (V.Vector r) where
--     {-# INLINABLE (==) #-}
--     v1==v2 = if VG.length v1 /= VG.length v2
--         then False
--         else go 0
--         where
--             go i = if i == VG.length v1
--                 then True
--                 else if v1 `VG.unsafeIndex` i /= v2 `VG.unsafeIndex` i
--                     then False
--                     else go (i+1)

instance (VG.Vector V.Vector r, Ord r) => Lattice (V.Vector r)
instance (VG.Vector V.Vector r, Ord r) => InfSemilattice (V.Vector r) where inf = min
instance (VG.Vector V.Vector r, Ord r) => SupSemilattice (V.Vector r) where sup = max

instance (VG.Vector V.Vector r, Ord r) => POrd (V.Vector r) where
    {-# INLINABLE pcompare #-}
    pcompare v1 v2 = pcompare (Lexical (ArrayT v1)) (Lexical (ArrayT v2))

instance (VG.Vector V.Vector r, Ord r) => Ord (V.Vector r)

instance ( Semigroup r) => Semigroup (V.Vector r) where
    {-# INLINE (+) #-}
    v1 + v2 = if VG.length v1 == 0
        then v2
        else if VG.length v2 == 0
            then v1
            else if VG.length v1 /= VG.length v2
                then error "V.Vector + two different non-zero lengths"
                else VG.generate (VG.length v1) go
        where
            go i = v1 `VG.unsafeIndex` i + v2 `VG.unsafeIndex` i

instance ( Monoid r) => Monoid (V.Vector r) where
    {-# INLINE zero #-}
    zero = VG.empty

instance ( Abelian r) => Abelian (V.Vector r)

instance ( Cancellative r) => Cancellative (V.Vector r) where
    {-# INLINE (-) #-}
    v1 - v2 = if VG.length v1 == 0
        then v2
        else if VG.length v2 == 0
            then v1
            else if VG.length v1 /= VG.length v2
                then error "V.Vector - two different non-zero lengths"
                else VG.generate (VG.length v1) go
        where
            go i = v1 `VG.unsafeIndex` i - v2 `VG.unsafeIndex` i


instance ( Group r) => Group (V.Vector r) where
    {-# INLINE negate #-}
    negate v = VG.map negate v

type instance Scalar (V.Vector r) = Scalar r

instance ( Module r, IsScalar (Scalar r)) => Module (V.Vector r) where
    {-# INLINE (*.) #-}
    r *. v = VG.map (r*.) v

    {-# INLINE (.*.) #-}
    u .*. v = if VG.length u == VG.length v
        then VG.zipWith (.*.) u v
        else error "(.*.): u and v have different lengths"

instance ( VectorSpace r, IsScalar (Scalar r)) => VectorSpace (V.Vector r) where
    {-# INLINE (./) #-}
    v ./ r = VG.map (./r) v

    {-# INLINE (./.) #-}
    u ./. v = if VG.length u == VG.length v
        then VG.zipWith (./.) u v
        else error "(./.): u and v have different lengths"

instance
    ( IsScalar r
    , Normed r
    , VectorSpace r
    , Floating r
    ) => Normed (V.Vector r)
        where
    abs = innerProductNorm

instance
    ( IsScalar r
    , Normed r
    , VectorSpace r
    , Floating r
    ) => MetricSpace (V.Vector r)
        where
    distance = innerProductDistance

instance
    ( IsScalar r
    , Normed r
    , VectorSpace r
    , Floating r
    ) => InnerProductSpace (V.Vector r)
        where
    v1 <> v2 = if VG.length v1 == 0
        then zero
        else if VG.length v2 == 0
            then zero
            else if VG.length v1 /= VG.length v2
                then error "inner product on storable vectors of different sizes"
                else VG.foldl' (+) zero $ VG.zipWith (*) v1 v2


-------------------------------------------------------------------------------

u = VG.fromList [1..3] :: VS.Vector Float
v = VG.fromList [1..2] :: VS.Vector Float

instance (Storable r, Arbitrary r) => Arbitrary (VS.Vector r) where
--     arbitrary = liftM VG.fromList arbitrary
--     shrink v = map VG.fromList $ shrink (VG.toList v)
    arbitrary = frequency
        [ (7, VG.replicateM 10 arbitrary)
--         , (1, return VG.empty)
        ]

-- instance (Storable r, Eq r) => Eq (VS.Vector r) where
--     {-# INLINABLE (==) #-}
--     v1==v2 = if VG.length v1 /= VG.length v2
--         then False
--         else go 0
--         where
--             go i = if i == VG.length v1
--                 then True
--                 else if v1 `VG.unsafeIndex` i /= v2 `VG.unsafeIndex` i
--                     then False
--                     else go (i+1)

instance (VG.Vector VS.Vector r, Ord r, Storable r) => Lattice (VS.Vector r)
instance (VG.Vector VS.Vector r, Ord r, Storable r) => InfSemilattice (VS.Vector r) where inf = min
instance (VG.Vector VS.Vector r, Ord r, Storable r) => SupSemilattice (VS.Vector r) where sup = max

instance (VG.Vector VS.Vector r, Ord r, Storable r) => POrd (VS.Vector r) where
    {-# INLINABLE pcompare #-}
    pcompare v1 v2 = pcompare (Lexical (ArrayT v1)) (Lexical (ArrayT v2))

instance (VG.Vector VS.Vector r, Ord r, Storable r) => Ord (VS.Vector r)

instance (Storable r, Semigroup r) => Semigroup (VS.Vector r) where
    {-# INLINE (+) #-}
    v1 + v2 = if VG.length v1 == 0
        then v2
        else if VG.length v2 == 0
            then v1
            else if VG.length v1 /= VG.length v2
                then error "VS.Vector + two different non-zero lengths"
                else VG.generate (VG.length v1) go
        where
            go i = v1 `VG.unsafeIndex` i + v2 `VG.unsafeIndex` i

instance (Storable r, Monoid r) => Monoid (VS.Vector r) where
    {-# INLINE zero #-}
    zero = VG.empty

instance (Storable r, Abelian r) => Abelian (VS.Vector r)

instance (Storable r, Cancellative r) => Cancellative (VS.Vector r) where
    {-# INLINE (-) #-}
    v1 - v2 = if VG.length v1 == 0
        then v2
        else if VG.length v2 == 0
            then v1
            else if VG.length v1 /= VG.length v2
                then error "VS.Vector - two different non-zero lengths"
                else VG.generate (VG.length v1) go
        where
            go i = v1 `VG.unsafeIndex` i - v2 `VG.unsafeIndex` i


instance (Storable r, Group r) => Group (VS.Vector r) where
    {-# INLINE negate #-}
    negate v = VG.map negate v

type instance Scalar (VS.Vector r) = Scalar r

instance (Storable r, Module r, IsScalar (Scalar r)) => Module (VS.Vector r) where
    {-# INLINE (*.) #-}
    r *. v = VG.map (r*.) v

    {-# INLINE (.*.) #-}
    u .*. v = if VG.length u == VG.length v
        then VG.zipWith (.*.) u v
        else error "(.*.): u and v have different lengths"

instance (Storable r, VectorSpace r, IsScalar (Scalar r)) => VectorSpace (VS.Vector r) where
    {-# INLINE (./) #-}
    v ./ r = VG.map (./r) v

    {-# INLINE (./.) #-}
    u ./. v = if VG.length u == VG.length v
        then VG.zipWith (./.) u v
        else error "(./.): u and v have different lengths"

instance
    ( IsScalar r
    , Normed r
    , VectorSpace r
    , Floating r
    , VS.Storable r
    ) => Normed (VS.Vector r)
        where
    abs = innerProductNorm

instance
    ( IsScalar r
    , Normed r
    , VectorSpace r
    , Floating r
    , VS.Storable r
    ) => MetricSpace (VS.Vector r)
        where
    distance = innerProductDistance

instance
    ( IsScalar r
    , Normed r
    , VectorSpace r
    , Floating r
    , VS.Storable r
    ) => InnerProductSpace (VS.Vector r)
        where
    v1 <> v2 = if VG.length v1 == 0
        then zero
        else if VG.length v2 == 0
            then zero
            else if VG.length v1 /= VG.length v2
                then error "inner product on storable vectors of different sizes"
                else VG.foldl' (+) zero $ VG.zipWith (*) v1 v2


