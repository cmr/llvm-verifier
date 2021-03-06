{- |
Module           : $Header$
Description      : Implementation details for the command line driver;
                   primarily to facilitate programmatic invocation
License          : BSD3
Stability        : provisional
Point-of-contact : jhendrix
-}

{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ImplicitParams             #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ViewPatterns               #-}
{-# LANGUAGE ExistentialQuantification  #-}

module LSSImpl where

import           Control.Lens
import           Control.Monad.State
import           Data.Char
import           Data.Int
import qualified Data.Vector as V
import           Numeric
import           System.Console.CmdArgs.Implicit hiding (args, setVerbosity, verbosity)
import           Prelude ()
import           Prelude.Compat
import qualified Text.LLVM                       as L

import Verifier.LLVM.Backend
import Verifier.LLVM.Codebase
import Verifier.LLVM.Debugger
import Verifier.LLVM.MemModel.Geometry
import Verifier.LLVM.Simulator

data LSS = LSS
  { dbug          :: DbugLvl
  , argv          :: String
  , backend       :: Maybe String
  , errpaths      :: Bool
  , xlate         :: Bool
  , mname         :: Maybe String
  , startDebugger :: Bool
  , satBranches   :: Bool
  } deriving (Show, Data, Typeable)

mkLssOpts :: LSS -> LSSOpts
mkLssOpts lss = LSSOpts (errpaths lss) (satBranches lss) False

newtype DbugLvl = DbugLvl { unD :: Int32 }
  deriving (Data, Enum, Eq, Integral, Num, Ord, Real, Show, Typeable)
instance Default DbugLvl where def = DbugLvl 1

-- newtype StackSz = StackSz { unS :: Int32 }
--   deriving (Data, Enum, Eq, Integral, Num, Ord, Real, Show, Typeable)
-- instance Default StackSz where def = StackSz 8

data BackendType = BitBlastBuddyAlloc
                 | BitBlastDagBased
                 | SAWBackendType
  deriving (Show)

data ExecRslt sbe crt
  = NoMainRV [ErrorPath sbe] (Maybe (SBEMemory sbe))
  | SymRV    [ErrorPath sbe] (Maybe (SBEMemory sbe)) (SBETerm sbe)
  | ConcRV   [ErrorPath sbe] (Maybe (SBEMemory sbe)) crt

execRsltErrorPaths :: Simple Lens (ExecRslt sbe crt) [ErrorPath sbe]
execRsltErrorPaths = lens g s
  where g (NoMainRV e _) = e
        g (SymRV  e _ _) = e
        g (ConcRV e _ _) = e
        s (NoMainRV _ m) e = NoMainRV e m
        s (SymRV _ m r)  e = SymRV  e m r
        s (ConcRV _ m r) e = ConcRV e m r

lssImpl :: (Functor sbe, Ord (SBETerm sbe))
        => SBE sbe
        -> SBEMemory sbe
        -> Codebase sbe
        -> [String]
        -> LSS
        -> IO (ExecRslt sbe Integer)
lssImpl sbe mem cb argv0 args = do
  runSimulator cb sbe mem (Just (mkLssOpts args)) $ do
    when (dbug args >=5) $ do
      let mg    = defaultMemGeom (cbDataLayout cb)
      let sr (a,b) = "[0x" ++ showHex a "" ++ ", 0x" ++ showHex b "" ++ ")"
      dbugM $ "Memory model regions:"
      dbugM $ "Stack range : " ++ sr (mgStack mg)
      dbugM $ "Code range  : " ++ sr (mgCode mg)
      dbugM $ "Data range  : " ++ sr (mgData mg)
      dbugM $ "Heap range  : " ++ sr (mgHeap mg)
    setVerbosity $ fromIntegral $ dbug args
    void $ initializeDebugger
    let mainDef =
          case lookupDefine (L.Symbol "main") cb of
            Nothing -> error "Provided bitcode does not contain main()."
            Just md -> md
    when (startDebugger args) $ do
      breakOnEntry mainDef
    runMainFn mainDef ("lss" : argv0)

-- | Runs a function whose signature matches main.
runMainFn :: (Functor sbe, Functor m, MonadIO m, MonadException m)
        => SymDefine (SBETerm sbe)
        -> [String] -- ^ argv
        -> Simulator sbe m (ExecRslt sbe Integer)
runMainFn mainDef argv' = do
  --TODO: Verify main has expected signature.
  argsv <- buildArgv (snd <$> sdArgs mainDef) argv'
  void $ callDefine (sdName mainDef) (sdRetType mainDef) argsv
  case sdRetType mainDef of
    Nothing -> do
      liftM2 NoMainRV (use errorPaths) getProgramFinalMem
    Just (IntType w) -> do
      sbe <- gets symBE
      eps <- use errorPaths
      mm  <- getProgramFinalMem
      mrv <- getProgramReturnValue
      case mrv of
        Nothing -> return $ NoMainRV eps mm
        Just rv -> return $ maybe (SymRV eps mm rv) (ConcRV eps mm) mval
          where mval = asUnsignedInteger sbe w rv
    Just _ -> error "internal: Unsupported return type of main()"

buildArgv ::
  ( MonadIO m
  , Functor sbe
  , Functor m
  )
  => [MemType] -- ^ Types of arguments expected by main.
  -> [String] -- ^ Arguments
  -> Simulator sbe m [(MemType,SBETerm sbe)]
buildArgv [] argv' = do
  liftIO $ when (length argv' > 1) $ do
    putStrLn $ "WARNING: main() takes no argv; ignoring provided arguments:\n" ++ show argv'
  return []
buildArgv [IntType argcw, ptype@PtrType{}] argv'
  | fromIntegral (length argv') < (2 :: Integer) ^ argcw = do
  sbe <- gets symBE
  argc     <- liftSBE $ termInt sbe argcw (toInteger (length argv'))
  aw <- withDL ptrBitwidth
  one <- liftSBE $ termInt sbe aw 1
  strPtrs  <- V.forM (V.fromList argv') $ \str -> do
     let len = length str + 1
     let tp = ArrayType len (IntType 8)
     let ?sbe = sbe
     sv <- liftIO $ liftStringValue (str ++ [chr 0])
     v <- evalExprInCC "buildArgv" sv
     p <- alloca tp aw one 0
     store tp v p 0
     return p
  argvBase <- alloca i8p argcw argc 0
  argvArr  <- liftSBE $ termArray sbe i8p strPtrs
  -- Write argument string data and argument string pointers
  store (ArrayType (length argv') i8p) argvArr argvBase 0
  return [ (IntType argcw, argc)
         , (ptype, argvBase)
         ]
buildArgv _ _ = fail "Unexpected arguments expected by main()."

warnNoArgv :: IO ()
warnNoArgv = putStrLn "WARNING: main() takes no argv; ignoring provided arguments."
