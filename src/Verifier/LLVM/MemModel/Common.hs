{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeSynonymInstances #-}

{- |
Module           : $Header$
Description      : Symbolic execution tests
License          : BSD3
Stability        : provisional
Point-of-contact : jhendrix
-}
module Verifier.LLVM.MemModel.Common
 ( Addr
 , Size

   -- * Range declarations.
 , Range(..)
 , isDisjoint
 , containedBy
 , rSize

   -- * Term declarations
 , Term(..)
 , foldTermM
 , ShowF(..)

   -- * Type declarations
 , Type(..)
 , TypeF(..)
 , bitvectorType
 , floatType
 , doubleType
 , arrayType
 , mkStruct
 , typeEnd
 , Field
 , fieldVal
 , fieldPad

   -- * Pointer declarations
 , Value
 , ValueF(..)
 , store
 , typeOfValue
 , Cond(..)

 , Mux
 , MuxF(..)
 , muxCond
 , muxLeaf
 , reduceMux
 , subCount
 , atomCount
 , EvalContext
 , evalContext
 , evalV
 , eval

 , Var(..)

 , ValueCtor
 , ValueCtorF(..)
 , valueImports

 , BasePreference(..)

 , RangeLoad(..)
 , rangeLoadType
 , adjustOffset
 , rangeLoad
 , RangeLoadMux
 , fixedOffsetRangeLoad
 , fixedSizeRangeLoad
 , symbolicRangeLoad

 , ValueView
 , ViewF(..)

 , ValueLoad(..)
 , valueLoadType
 , valueLoad
 , ValueLoadMux
 , symbolicValueLoad

 ) where

import Control.Exception (assert)
import Control.Lens
import Control.Monad.State
import Data.Maybe
import Data.Vector (Vector)
import qualified Data.Vector as V
import Data.Word
import Prelude ()
import Prelude.Compat

type Addr = Word64

type Size = Addr

type Offset = Size

-- | @WR i j@ denotes that the write should store in range [i..j).
data Range = R { rStart :: Addr, _rEnd :: Addr }
  deriving (Eq, Show)

rSize :: Range -> Size
rSize (R l h) = h - l

containedBy :: Range -> Range -> Bool
containedBy (R xl xe) (R yl ye) = yl <= xl && xe <= ye

-- | Returns true if there are no bytes in intersetion of two ranges.
isDisjoint :: Range -> Range -> Bool
isDisjoint (R xl xe) (R yl ye) =
  xl == xe || yl == ye || xe <= yl || ye <= xl

-- Var

data Term f a = App (f (Term f a))
              | Var a
  deriving (Functor, Foldable, Traversable)

class ShowF f where
  showsPrecF :: Show a => Int -> f a -> ShowS

instance (ShowF f, Show a)  => Show (Term f a) where
  showsPrec p (App f) = showParen (p >= 10) (showString "App " . showsPrecF 10 f)
  showsPrec p (Var x) = showParen (p >= 10) (showString "Var " . showsPrec 10 x)

-- | Traverse over variables in term.
termVars:: Traversable f => Traversal (Term f a) (Term f b) a b
termVars f (App a) = App <$> traverse (termVars f) a
termVars f (Var a) = Var <$> f a

foldTermM :: (Applicative m, Monad m, Traversable f)
          => (a -> m r) -> (f r -> m r) -> Term f a -> m r 
foldTermM f _ (Var v) = f v
foldTermM f g (App v) = g =<< traverse (foldTermM f g) v

-- Value

data ValueF v = Add v v
              | Sub v v
              | CValue Integer
  deriving (Functor, Foldable, Traversable, Show)

instance ShowF ValueF where
  showsPrecF = showsPrec

type Value v = Term ValueF v

data Cond v = Eq (Value v) (Value v)
            | Le (Value v) (Value v)
            | And (Cond v) (Cond v)
  deriving (Show)

(.==) :: Value v -> Value v -> Cond v
infix 4 .==
(.==) = Eq

(.<=) :: Value v -> Value v -> Cond v
infix 4 .<=
(.<=) = Le

instance Num (Value v) where
  App (CValue 0) + x = x
  x + App (CValue 0) = x
  x + y = App (Add x y)

  (*)    = error "CValue (*) undefined"

  x - App (CValue 0) = x
  x - y = App (Sub x y)

  negate = error "CValue negate undefined"
  abs    = error "CValue abs undefined"
  signum = error "CValue signum undefined"
  fromInteger = App . CValue . fromInteger

-- Muxs

data MuxF c v = Mux c v v
 deriving (Functor, Foldable, Traversable, Show)

instance Show c => ShowF (MuxF c) where
  showsPrecF = showsPrec

type Mux c a = Term (MuxF c) a

-- | Traverse over conditions in mux.
muxCond :: Traversal (Mux c a) (Mux d a) c d
muxCond f (App (Mux c x y)) = App <$> (Mux <$> f c <*> muxCond f x <*> muxCond f y)
muxCond _ (Var a) = pure (Var a)

-- | Traverse over leafs in mux.
muxLeaf :: Traversal (Mux c x) (Mux c y) x y
muxLeaf = termVars

-- | Reduce a mux using the given function for ite.
reduceMux :: (Applicative m, Monad m) => (c -> a -> a -> m a) -> Mux c a -> m a
reduceMux f (App (Mux c x y)) = join $
  f c <$> reduceMux f x <*> reduceMux f y
reduceMux _ (Var a) = pure a

subCount :: Mux c a -> Int
subCount (App (Mux _ t f)) = 1 + subCount t + subCount f
subCount _ = 1

atomCount :: Mux c a -> Int
atomCount (App (Mux _ t f)) = atomCount t + atomCount f
atomCount _ = 1

data MuxCase c a
   = MuxCase c (Mux c a)
   | DefaultMux (Mux c a)

(|->) :: c -> Mux c a -> MuxCase c a
infix 3 |->
c |-> x = MuxCase c x

always :: Mux c a -> MuxCase c a
always = DefaultMux

try :: MuxCase c a -> Mux c a -> Mux c a
try (DefaultMux x) _ = x
try (MuxCase c x) y = App (Mux c x y)

-- | @iterDown i n f@ generates a formula generates from values starting
-- from @n@ and incrementing by i until an unconditional formula is returned by @f@.
iterBy :: (i -> i)
       -> i
       -> (i -> MuxCase c a)
       -> Mux c a
iterBy i n f =
  case f n of
    DefaultMux x -> x
    MuxCase c x -> App (Mux c x (iterBy i (i n) f))

-- | @iterDown n f@ generates a formula generates from values starting
-- from @n@ and counting down until an unconditional formula is returned by @f@.
iterDown :: Num i
         => i
         -> (i -> MuxCase c a)
         -> Mux c a
iterDown = iterBy (\s -> s - 1)

iterUp :: Num i
       => i
       -> (i -> MuxCase c a)
       -> Mux c a
iterUp = iterBy (\s -> s + 1)

-- Variable for mem model.

data Var = Load | Store | StoreSize
  deriving (Show)

load :: Value Var
load = Var Load

store :: Value Var
store = Var Store

storeSize :: Value Var
storeSize = Var StoreSize

loadOffset :: Size -> Value Var
loadOffset n = load + fromIntegral n

storeOffset :: Size -> Value Var
storeOffset n = store + fromIntegral n

storeEnd :: Value Var
storeEnd = store + storeSize

-- | @loadInStoreRange n@ returns predicate if Store <= Load && Load <= Store + n
loadInStoreRange :: Size -> Cond Var
loadInStoreRange 0 = load .== store
loadInStoreRange n = And (store .<= load)
                         (load .<= store + fromIntegral n)

-- | Contains load start and store range.
type EvalContext v = Var -> v

evalContext :: Addr -> Type -> Range -> EvalContext Integer
evalContext l _ (R s se) = assert (s <= se) $ fn
  where fn Load  = toInteger l
        fn Store = toInteger s
        fn StoreSize = toInteger (se - s)

evalV :: (v -> Integer) -> Value v -> Integer
evalV ec (Var v) = ec v
evalV ec (App vf) =
  case vf of
    Add x y -> evalV ec x + evalV ec y
    Sub x y -> evalV ec x - evalV ec y
    CValue c -> c

evalCond :: (v -> Integer) -> Cond v -> Bool
evalCond ec c =
 case c of
   Eq x y  -> evalV ec x == evalV ec y
   Le x y  -> evalV ec x <= evalV ec y
   And x y -> evalCond ec x && evalCond ec y

eval :: (v -> Integer) -> Mux (Cond v) a -> a
eval c = evalF
  where evalF (App (Mux b t f)) = evalF (if evalCond c b then t else f)
        evalF (Var a) = a

data Field v = Field { fieldOffset :: Offset
                     , _fieldVal    :: v
                     , fieldPad    :: Size 
                     }
 deriving (Eq, Show, Functor, Foldable, Traversable)

fieldVal :: Lens (Field a) (Field b) a b
fieldVal = lens _fieldVal (\s v -> s { _fieldVal = v })

data TypeF v
   = Bitvector Size -- ^ Size of bitvector in bytes (must be > 0).
   | Float
   | Double
   | Array Size v
   | Struct (Vector (Field v))
 deriving (Eq,Show)

data Type = Type { typeF :: TypeF Type
                 , typeSize :: Size
                 }
  deriving (Eq)

instance Show Type where
  showsPrec p t = showParen (p >= 10) $
    case typeF t of
      Bitvector w -> showString "bitvectorType " . shows w
      Float -> showString "float"
      Double -> showString "double"
      Array n tp -> showString "arrayType " . shows n . showString " " . showsPrec 10 tp
      Struct v -> showString "mkStruct " . shows (V.toList (fldFn <$> v))
        where fldFn f = (f^.fieldVal, fieldPad f)

mkType :: TypeF Type -> Type
mkType tf = Type tf $
  case tf of
    Bitvector w -> w
    Float -> 4
    Double -> 8
    Array n e -> n * typeSize e
    Struct flds -> if V.length flds == 0 then 0 else fieldEnd (V.last flds)

bitvectorType :: Size -> Type
bitvectorType w = Type (Bitvector w) w

floatType :: Type
floatType = mkType Float

doubleType :: Type
doubleType = mkType Double

arrayType :: Size -> Type -> Type
arrayType n e = Type (Array n e) (n * typeSize e)

structType :: V.Vector (Field Type) -> Type
structType flds = Type (Struct flds) w
  where w = if V.length flds == 0 then 0 else fieldEnd (V.last flds)

mkStruct :: V.Vector (Type,Size) -> Type
mkStruct l = structType (evalState (traverse fldFn l) 0)
  where fldFn (tp,p) = do
          o <- get
          put $! o + typeSize tp + p
          return Field { fieldOffset = o
                       , _fieldVal = tp
                       , fieldPad = p 
                       } 

-- | Returns end of actual type bytes (excluded padding from structs).
typeEnd :: Addr -> Type -> Addr
typeEnd a tp = seq a $
  case typeF tp of
    Bitvector w -> a + w
    Float -> a + 4
    Double -> a + 8
    Array n etp -> typeEnd (a + (n-1) * typeSize etp) etp
    Struct flds | V.null flds -> a
    Struct flds -> typeEnd (a + fieldOffset f) (f^.fieldVal)
      where f = V.last flds

-- | Returns end of field including padding bytes.
fieldEnd :: Field Type -> Size
fieldEnd f = fieldOffset f + typeSize (f^.fieldVal) + fieldPad f

-- Value constructor

data ValueCtorF v
   = -- | Concatentates two bitvectors.
     -- The first bitvector contains values stored at the low-order byes
     -- while the second contains values at the high-order bytes.  Thus, the
     -- meaning of this depends on the endianness of the target architecture.
     ConcatBV Size v Size v
   | BVToFloat v
   | BVToDouble v
     -- | Cons one value to beginning of array.
   | ConsArray Type v Integer v
   | AppendArray Type Integer v Integer v
   | MkArray Type (Vector v)
   | MkStruct (Vector (Field Type,v))
 deriving (Functor, Foldable, Traversable, Show)

instance ShowF ValueCtorF where
  showsPrecF = showsPrec

type ValueCtor a = Term ValueCtorF a

concatBV :: Size -> ValueCtor a -> Size -> ValueCtor a -> ValueCtor a
concatBV xw x yw y = App (ConcatBV xw x yw y)

singletonArray :: Type -> ValueCtor a -> ValueCtor a
singletonArray tp e = App (MkArray tp (V.singleton e))

-- | Returns imports in a Value Ctor
valueImports :: ValueCtor a -> [a]
valueImports = toListOf termVars

typeOfValueF :: ValueCtorF (TypeF Type) -> Maybe Type
typeOfValueF (ConcatBV xw xtp yw ytp)
  | Bitvector xw == xtp && Bitvector yw == ytp =
    return (bitvectorType (xw + yw))
typeOfValueF (BVToFloat (Bitvector 4)) = return $ mkType Float
typeOfValueF (BVToDouble (Bitvector 8)) = return $ mkType Double
typeOfValueF (ConsArray tp tp' n (Array n' etp))
  | typeF tp == tp' && (n,tp) == (toInteger n', etp) =
    return (arrayType (fromInteger (n+1)) etp)
typeOfValueF (AppendArray tp m (Array m' tp0) n (Array n' tp1))
  | (m,tp) == (toInteger m', tp0)
    && (n,tp) == (toInteger n', tp1) =
      return (arrayType (fromInteger (m+n)) tp0)
typeOfValueF (MkArray tp tps)
  | allOf folded (== typeF tp) tps =
    return (arrayType (fromIntegral (V.length tps)) tp) 
typeOfValueF (MkStruct ftps) 
  | V.length ftps > 0 = return (structType (fst <$> ftps))
typeOfValueF _ = Nothing

typeOfValue :: (a -> Maybe Type) -> ValueCtor a -> Maybe Type
typeOfValue f = foldTermM f (typeOfValueF . fmap typeF)

-- | Create value of type that splits at a particular byte offset.
splitTypeValue :: Type   -- ^ Type of value to create
               -> Offset -- ^ Bytes offset to slice type at.
               -> (Offset -> Type -> ValueCtor a) -- ^ Function for subtypes.
               -> ValueCtor a
splitTypeValue tp d subFn = assert (d > 0) $
  case typeF tp of
    Bitvector sz -> assert (d < sz) $
      concatBV d (subFn 0 (bitvectorType d))
               (sz - d) (subFn d (bitvectorType (sz - d)))
    Float -> App (BVToFloat (subFn 0 (bitvectorType 4)))
    Double -> App (BVToDouble (subFn 0 (bitvectorType 8)))
    Array n0 etp -> assert (n0 > 0) $ do
      let esz = typeSize etp
      let (c,part) = assert (esz > 0) $ d `divMod` esz
      let result
            | c > 0 = assert (c < n0) $
              App $ AppendArray etp
                                (toInteger c)
                                (subFn 0 (arrayType c etp))
                                (toInteger (n0 - c))
                                (consPartial (c * esz) (n0 - c)) 
            | otherwise = consPartial 0 n0
          consPartial o n
            | part == 0 = subFn o (arrayType n etp)
            | n > 1 =
                App $ ConsArray etp
                                (subFn o etp)
                                (toInteger (n-1))
                                (subFn (o+esz) (arrayType (n-1) etp))
            | otherwise = assert (n == 1) $
                singletonArray etp (subFn o etp)
      result
    Struct flds -> App $ MkStruct (fldFn <$> flds)
      where fldFn fld = (fld, subFn (fieldOffset fld) (fld^.fieldVal))


data BasePreference
   = FixedLoad
   | FixedStore
   | NeitherFixed
  deriving (Eq, Show)

-- RangeLoad

data RangeLoad a
      -- | Load value from old value.
    = OutOfRange a Type
      -- | In range includes offset relative to store and type.
    | InRange a Type
  deriving (Functor, Foldable, Traversable, Show)

rangeLoadType :: RangeLoad a -> Type
rangeLoadType (OutOfRange _ tp) = tp
rangeLoadType (InRange _ tp) = tp

adjustOffset :: (a -> b)
             -> (a -> b)
             -> RangeLoad a -> RangeLoad b
adjustOffset _ outFn (OutOfRange a tp) = OutOfRange (outFn a) tp
adjustOffset inFn _  (InRange a tp) = InRange (inFn a) tp

rangeLoad :: Addr -> Type -> Range -> ValueCtor (RangeLoad Addr)
rangeLoad lo ltp s@(R so se)
   | so == se  = loadFail
   | le <= so  = loadFail
   | se <= lo  = loadFail
   | lo < so   = splitTypeValue ltp (so - lo) (\o tp -> rangeLoad (lo+o) tp s)
   | se < le   = splitTypeValue ltp (se - lo) (\o tp -> rangeLoad (lo+o) tp s)
   | otherwise = assert (so <= lo && le <= se) $ Var (InRange (lo - so) ltp)
 where le = typeEnd lo ltp
       loadFail = Var (OutOfRange lo ltp)

type RangeLoadMux v = Mux (Cond Var) (ValueCtor (RangeLoad v))

fixedOffsetRangeLoad :: Addr
                     -> Type
                     -> Addr
                     -> RangeLoadMux Addr
fixedOffsetRangeLoad l tp s
   | s < l = do -- Store is before load.
     let sd = l - s -- Number of bytes load comes after store
     try (storeSize .<= fromIntegral sd |-> loadFail)
         (iterUp (sd+1) loadCase)
   | le <= s = loadFail -- No load if load ends before write.
   | otherwise = iterUp 0 loadCase
 where le = typeEnd l tp
       loadCase i | i < le-s  = storeSize .== fromIntegral i |-> loadVal i
                  | otherwise = always $ loadVal i
       loadVal ssz = Var $ rangeLoad l tp (R s (s+ssz))
       loadFail = Var $ Var (OutOfRange l tp)

-- | @fixLoadBeforeStoreOffset pref i k@ adjusts a pointer value that is relative
-- the load address into a global pointer.  The code assumes that @load + i == store@.
fixLoadBeforeStoreOffset :: BasePreference -> Offset -> Offset -> Value Var
fixLoadBeforeStoreOffset pref i k
  | pref == FixedStore = store + fromInteger (toInteger k - toInteger i)
  | otherwise = load + fromIntegral k

-- | @fixLoadAfterStoreOffset pref i k@ adjusts a pointer value that is relative
-- the load address into a global pointer.  The code assumes that @load == store + i@.
fixLoadAfterStoreOffset :: BasePreference -> Offset -> Offset -> Value Var
fixLoadAfterStoreOffset pref i k = assert (k >= i) $
  case pref of
    FixedStore -> store + fromIntegral k
    _          -> load  + fromIntegral (k - i)

-- | @loadFromStoreStart pref tp i j@ loads a value of type @tp@ from a range under the
-- assumptions that @load + i == store@ and @j = i + min(storeSize, typeEnd(tp)@. 
loadFromStoreStart :: BasePreference
                   -> Type
                   -> Offset
                   -> Offset
                   -> ValueCtor (RangeLoad (Value Var))
loadFromStoreStart pref tp i j = adjustOffset inFn outFn <$> rangeLoad 0 tp (R i j)
  where inFn = fromIntegral
        outFn = fixLoadBeforeStoreOffset pref i

fixedSizeRangeLoad :: BasePreference -- ^ Whether addresses are based on store or load.
                   -> Type
                   -> Size
                   -> RangeLoadMux (Value Var)
fixedSizeRangeLoad _ tp 0 = Var (Var (OutOfRange load tp))
fixedSizeRangeLoad pref tp ssz =
  try (loadOffset lsz .<= store |-> loadFail) $
  iterDown lsz prefixL
 where lsz = typeEnd 0 tp

       prefixL i
         | i > 0     = loadOffset i .== store |-> loadVal i
         -- Special case where we skip some offsets, it it won't
         -- make more splitting
         | lsz <= ssz && pref == NeitherFixed = always $
           -- Load is contained in storage.
           try (loadInStoreRange (ssz-lsz) |-> loadSucc) $
           -- Load extends past end of storage
           iterUp (ssz-lsz) suffixS
         | otherwise = always $ iterUp 0 suffixS

       suffixS i
         | i < ssz   = load .== storeOffset i |-> storeVal i
         | otherwise = always loadFail

       loadVal i = Var $ loadFromStoreStart pref tp i (i+ssz)

       storeVal i = Var $ adjustOffset inFn outFn <$> rangeLoad i tp (R 0 ssz)
         where inFn = fromIntegral
               outFn = fixLoadAfterStoreOffset pref i

       loadSucc = Var (Var (InRange (load - store) tp))
       loadFail = Var (Var (OutOfRange load tp))

symbolicRangeLoad :: BasePreference -> Type -> RangeLoadMux (Value Var)
symbolicRangeLoad pref tp =
   try (store .<= load |->
         try (loadOffset sz .<= storeEnd |-> loadVal0 sz)
             (iterDown (sz-1) loadIter0))
       (iterUp 1 storeAfterLoad)
  where sz = typeEnd 0 tp

        loadIter0 j | j > 0     = loadOffset j .== storeEnd |-> loadVal0 j
                    | otherwise = always loadFail

        loadVal0 j = Var $ adjustOffset inFn outFn <$> rangeLoad 0 tp (R 0 j)
          where inFn k  = load - store + fromIntegral k
                outFn k = load + fromIntegral k

        storeAfterLoad i
          | i < sz = loadOffset i .== store |-> loadFromOffset i
          | otherwise = always loadFail

        loadFromOffset i = assert (0 < i && i < sz) $ 
            try (fromIntegral (sz - i) .<= storeSize |-> loadVal i (i+sz))
                (iterDown (sz-1) f)
          where f j | j > i = fromIntegral (j-i) .== storeSize |-> loadVal i j
                    | otherwise = always loadFail

        loadVal i j = Var $ loadFromStoreStart pref tp i j
        loadFail = Var (Var (OutOfRange load tp))

-- ValueView

type ValueView v = Term ViewF v

data ViewF v
     -- | Select low-order bytes in the bitvector.
     -- The sizes include the number of low bytes, and the number of high bytes.
   = SelectLowBV Size Size v
     -- | Select the given number of high-order bytes in the bitvector.
     -- The sizes include the number of low bytes, and the number of high bytes.
   | SelectHighBV Size Size v
   | FloatToBV v
   | DoubleToBV v
   | ArrayElt Size Type Offset v

   | FieldVal (Vector (Field Type)) Int v
  deriving (Show, Functor, Foldable, Traversable)

instance ShowF ViewF where
  showsPrecF = showsPrec

viewOpType :: ViewF (TypeF Type) -> Maybe Type
viewOpType (SelectLowBV  u v tp) | Bitvector (u + v) == tp = pure $ bitvectorType u
viewOpType (SelectHighBV u v tp) | Bitvector (u + v) == tp = pure $ bitvectorType v
viewOpType (FloatToBV tp)        | Float == tp  = pure $ bitvectorType 4
viewOpType (DoubleToBV tp)       | Double == tp = pure $ bitvectorType 8
viewOpType (ArrayElt n etp i tp) | i < n && Array n etp == tp = pure $ etp
viewOpType (FieldVal v i     tp) | Struct v == tp          = view fieldVal <$> (v V.!? i)
viewOpType _ = Nothing

viewType :: ValueView Type -> Maybe Type
viewType = foldTermM return (viewOpType . fmap typeF)

-- ValueLoad

data ValueLoad v
  = -- Old memory that was used
    OldMemory v Type
  | LastStore (ValueView Type)
    -- | Indicates load touches memory that is invalid, and can't be
    -- read.
  | InvalidMemory Type
  deriving (Functor,Show)

valueLoadType :: ValueLoad a -> Maybe Type
valueLoadType (OldMemory _ tp) = Just tp
valueLoadType (LastStore v) = viewType v
valueLoadType (InvalidMemory tp) = Just tp

loadBitvector :: Addr -> Size -> Addr -> ValueView Type -> ValueCtor (ValueLoad Addr)
loadBitvector lo lw so v = do
  let le = lo + lw
  let ltp = bitvectorType lw
  let stp = fromMaybe (error ("loadBitvector given bad view " ++ show v)) (viewType v)
  let retValue eo v' = (sz',valueLoad lo' (bitvectorType sz') eo v')
        where etp = fromMaybe (error ("Bad view " ++ show v')) (viewType v')
              esz = typeSize etp
              lo' = max lo eo
              sz' = min le (eo+esz) - lo'
  case typeF stp of
    Bitvector sw
      | so < lo -> do
        -- Number of bits to drop.
        let d = lo - so
        -- Store is before load.
        valueLoad lo ltp lo (App (SelectHighBV d (sw - d) v))
      | otherwise -> assert (lo == so && lw < sw) $
        -- Load ends before store ends.
        valueLoad lo ltp so (App (SelectLowBV lw (sw - lw) v))
    Float -> valueLoad lo ltp lo (App (FloatToBV v))
    Double -> valueLoad lo ltp lo (App (DoubleToBV v))
    Array n tp -> snd $ foldl1 cv (val <$> r)
      where cv (wx,x) (wy,y) = (wx + wy, concatBV wx x wy y)
            esz = typeSize tp
            c0 = assert (esz > 0) $ (lo - so) `div` esz
            (c1,p1) = (le - so) `divMod` esz
            -- Get range of indices to read.
            r | p1 == 0 = assert (c1 > c0) [c0..c1-1]
              | otherwise = assert (c1 >= c0) [c0..c1]
            val i = retValue (so+i*esz) (App (ArrayElt n tp i v))
    Struct sflds -> assert (not (null r)) $ snd $ foldl1 cv r
      where cv (wx,x) (wy,y) = (wx+wy, concatBV wx x wy y)
            r = concat (zipWith val [0..] (V.toList sflds))
            val i f = v1
              where eo = so + fieldOffset f
                    ee = eo + typeSize (f^.fieldVal)
                    v1 | le <= eo = v2
                       | ee <= lo = v2
                       | otherwise = retValue eo (App (FieldVal sflds i v)) : v2
                    v2 | fieldPad f == 0 = []   -- Return no padding.
                       | le <= ee = [] -- Nothing of load ends before padding.
                         -- Nothing if padding ends before load begins.
                       | ee+fieldPad f <= lo = [] 
                       | otherwise = [(p,Var badMem)]
                      where p = min (ee+fieldPad f) le - (max lo ee)
                            tpPad  = bitvectorType p
                            badMem = InvalidMemory tpPad

-- | @valueLoad lo ltp so v@ returns a value with type @ltp@ from reading the
-- value @v@.  The load address is @lo@ and the stored address is @so@.
valueLoad :: Addr -> Type -> Addr -> ValueView Type -> ValueCtor (ValueLoad Addr)
valueLoad lo ltp so v
  | le <= so = Var (OldMemory lo ltp) -- Load ends before store
  | se <= lo = Var (OldMemory lo ltp) -- Store ends before load
    -- Load is before store.
  | lo < so  = splitTypeValue ltp (so - lo) (\o tp -> valueLoad (lo+o) tp so v)
    -- Load ends after store ends.
  | se < le  = splitTypeValue ltp (le - se) (\o tp -> valueLoad (lo+o) tp so v)
  | (lo,ltp) == (so,stp) = Var (LastStore v)
    -- 
  | otherwise =
    case typeF ltp of
      Bitvector lw -> loadBitvector lo lw so v
      Float  -> App $ BVToFloat  $ valueLoad 0 (bitvectorType 4) so v
      Double -> App $ BVToDouble $ valueLoad 0 (bitvectorType 8) so v
      Array ln tp ->
        let leSize = typeSize tp
            val i = valueLoad (lo+leSize*fromIntegral i) tp so v
         in App (MkArray tp (V.generate (fromIntegral ln) val))
      Struct lflds ->
        let val f = (f, valueLoad (lo+fieldOffset f) (f^.fieldVal) so v)
         in App (MkStruct (val <$> lflds))
 where stp = fromMaybe (error ("Coerce value given bad view " ++ show v)) (viewType v)
       le = typeEnd lo ltp
       se = so + typeSize stp

type ValueLoadMux = Mux (Cond Var) (ValueCtor (ValueLoad (Value Var)))

symbolicValueLoad :: BasePreference -- ^ Whether addresses are based on store or load.
                  -> Type
                  -> ValueView Type
                  -> ValueLoadMux
symbolicValueLoad pref tp v =
  try (loadOffset lsz .<= store |-> loadFail) $
  iterDown lsz prefixL
 where lsz = typeEnd 0 tp
       Just stp = viewType v

       prefixL i
           | i > 0 = 
             loadOffset i .== store |->
               Var (fmap adjustFn <$> valueLoad 0 tp i v)
           | otherwise = always (iterUp 0 suffixS)
         where adjustFn = fixLoadBeforeStoreOffset pref i

       suffixS i
           | i < typeSize stp =
             load .== storeOffset i |->
               Var (fmap adjustFn <$> valueLoad i tp 0 v)
           | otherwise = always loadFail
         where adjustFn = fixLoadAfterStoreOffset pref i

       loadFail = Var $ Var (OldMemory load tp)
