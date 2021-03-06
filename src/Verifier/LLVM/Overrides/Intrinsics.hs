{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}

{- |
Module           : $Header$
Description      : Symbolic execution tests
License          : BSD3
Stability        : provisional
Point-of-contact : atomb
-}
module Verifier.LLVM.Overrides.Intrinsics 
  ( registerLLVMIntrinsicOverrides
  ) where

import Control.Lens hiding (from)
import Control.Monad.IO.Class
import Control.Monad.State.Class
import Data.String
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>), align, line)
import Prelude ()
import Prelude.Compat

import Verifier.LLVM.Backend
import Verifier.LLVM.Codebase.DataLayout
import Verifier.LLVM.Simulator.Internals

llvm_add_with_overflow :: Monad m =>
                          String
                       -> (t -> SBETerm sbe -> SBETerm sbe -> TypedExpr (SBETerm sbe))
                       -> t
                       -> Override sbe m
llvm_add_with_overflow n f w = do
  override $ \args ->
    case args of
      [(_,x), (_,y)] -> do
        sbe <- gets symBE
        liftSBE $ applyTypedExpr sbe (f w x y)
      _ -> wrongArguments $ "llvm." ++ n ++ ".with.overflow"

memcpyIntrinsic :: BitWidth -> StdOvdEntry m sbe
memcpyIntrinsic w = do
  let nm = "llvm.memcpy.p0i8.p0i8.i" ++ show w
  let itp = IntType w
  voidOverrideEntry (fromString nm) [i8p, i8p, itp, i32, i1] $ \args -> do
    case snd <$> args of
      [dst, src, len, align, _] -> do
        Just m <- preuse currentPathMem
        (c,m') <- withSBE $ \sbe -> memCopy sbe m dst src w len align
        currentPathMem .= m'
        sbe <- gets symBE
        let pts = map (prettyTermD sbe) [dst,src,len]
        let fr = "memcopy operation was not valid: (dst,src,len) = "
                  ++ show (parens $ hcat $ punctuate comma $ pts)
        processMemCond fr c
      _ -> wrongArguments nm

memsetIntrinsic :: BitWidth -> StdOvdEntry sbe m
memsetIntrinsic lw = do
  let nm = fromString $ "llvm.memset.p0i8.i" ++ show lw
  let arg_types = [i8p, i8, IntType lw, i32, i1]
  voidOverrideEntry nm arg_types $ \args -> do
    case args of
      [(_,dst0), (_,val), (_,len), _, _] -> do
        memset (show nm) dst0 val lw len
      _ -> wrongArguments (show nm)


objectsizeIntrinsic :: BitWidth -> StdOvdEntry m sbe
objectsizeIntrinsic w = do
  let nm = "llvm.objectsize.i" ++ show w ++ ".p0i8"
  let itp = IntType w
  overrideEntry (fromString nm) itp [i8p, i1] $ \args ->
    case snd <$> args of
      [_, maxOrMin] -> do
        sbe <- gets symBE
        case asUnsignedInteger sbe 1 maxOrMin of
          Nothing -> errorPath $ "llvm.objectsize expects concrete 2nd paramete"
          Just v  -> liftSBE (termInt sbe w tv)
            where tv = if v == 0 then -1 else 0
      _ -> wrongArguments nm

bswapIntrinsic :: BitWidth -> StdOvdEntry sbe m
bswapIntrinsic w = do
  let nm = fromString $ "llvm.bswap.i" ++ show w
  overrideEntry (fromString nm) (IntType w) [IntType w] $ \args ->
    case snd <$> args of
      [x] | w `rem` 8 == 0 -> do
        sbe <- gets symBE
        liftSBE $ applyTypedExpr sbe (BSwap (w `div` 8) x)
      [_] -> errorPath $ "llvm.bswap requires argument size to be multiple of 8"
      _ -> wrongArguments nm

llvm_expect :: BitWidth -> StdOvdEntry m sbe
llvm_expect w = do
  let nm = "llvm.expect.i" ++ show w
  let itp = IntType w
  overrideEntry (fromString nm) itp [itp, itp] $ \args ->
    case snd <$> args of
      [val, _] -> return val
      _ -> wrongArguments nm

registerLLVMIntrinsicOverrides :: (Functor sbe, Functor m, MonadIO m)
                               => Simulator sbe m ()
registerLLVMIntrinsicOverrides = do
  let override_add_with_overflow n f w = do
        let nm = fromString $ "llvm." ++ n ++ ".with.overflow.i" ++ show w
        tryRegisterOverride nm $ \_ -> do
          return $ llvm_add_with_overflow n f w
  mapM_ (override_add_with_overflow "uadd" UAddWithOverflow) [16, 32, 64]
  mapM_ (override_add_with_overflow "sadd" SAddWithOverflow) [16, 32, 64]
  registerOverrides 
    [ llvm_expect 32
    , llvm_expect 64

    , memcpyIntrinsic 32
    , memcpyIntrinsic 64

    , memsetIntrinsic 32
    , memsetIntrinsic 64

    , objectsizeIntrinsic 32
    , objectsizeIntrinsic 64

    , bswapIntrinsic 16
    , bswapIntrinsic 32
    , bswapIntrinsic 48
    , bswapIntrinsic 64

    -- Do nothing.
    , voidOverrideEntry "llvm.lifetime.start" [i64, i8p] (\_ -> return ())
    , voidOverrideEntry "llvm.lifetime.end"   [i64, i8p] (\_ -> return ())
    ]
