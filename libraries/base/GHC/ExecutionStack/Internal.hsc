-----------------------------------------------------------------------------
-- |
-- Module      :  GHC.ExecutionStack.Internal
-- Copyright   :  (c) The University of Glasgow 2013-2015
-- License     :  see libraries/base/LICENSE
--
-- Maintainer  :  cvs-ghc@haskell.org
-- Stability   :  internal
-- Portability :  non-portable (GHC Extensions)
--
-- Internals of the `GHC.ExecutionStack` module
--
-- /Since: 4.11.0.0/
-----------------------------------------------------------------------------

module GHC.ExecutionStack.Internal (
  -- * Internal
    Location (..)
  , SrcLoc (..)
  , StackTrace
  , stackFrames
  , stackDepth
  , collectStackTrace
  , showStackFrames
  , invalidateDebugCache
  ) where

import Data.Word
import Foreign.C.String (peekCString)
import Foreign.Ptr (Ptr, nullPtr, castPtr, plusPtr, FunPtr)
import Foreign.ForeignPtr
import Foreign.ForeignPtr.Unsafe
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Storable (Storable(..))
import System.IO.Unsafe (unsafePerformIO)

-- N.B. See includes/rts/Libdw.h for notes on stack representation.

-- | A location in the original program source.
data SrcLoc = SrcLoc { sourceFile   :: String
                     , sourceLine   :: Int
                     , sourceColumn :: Int
                     }

-- | Location information about an addresss from a backtrace.
data Location = Location { objectName   :: String
                         , functionName :: String
                         , srcLoc       :: Maybe SrcLoc
                         }

-- | A chunk of backtrace frames
data Chunk = Chunk { chunkFrames     :: !Word
                   , chunkNext       :: !(Ptr Chunk)
                   , chunkFirstFrame :: !(Ptr Addr)
                   }

-- | The state of the execution stack
newtype StackTrace = StackTrace (ForeignPtr StackTrace)

-- | An address
type Addr = Ptr ()

-- | How many stack frames in the given 'StackTrace'
stackDepth :: StackTrace -> Int
stackDepth (StackTrace fptr) = unsafePerformIO $
    withForeignPtr fptr $ \ptr -> fromIntegral `fmap` peekWord (castPtr ptr)
  where
    peekWord = peek :: Ptr Word -> IO Word

-- | A pointer to the chunk containing the last frame of a 'StackTrace'.
lastChunk :: StackTrace -> IO (Ptr Chunk)
lastChunk (StackTrace fptr) =
    peek $ ptr `plusPtr` sizeOf (undefined :: Word)
  where ptr = unsafeForeignPtrToPtr fptr

peekChunk :: Ptr Chunk -> IO Chunk
peekChunk ptr =
    Chunk <$> peek (castPtr ptr)
          <*> peek (castPtr $ ptr `plusPtr` ptrSize)
          <*> return (castPtr $ ptr `plusPtr` (2*ptrSize))
  where
    ptrSize = sizeOf (undefined :: Word)

-- | Return a list of the chunks of a backtrace, from the outer-most to
-- inner-most chunk.
chunksList :: StackTrace -> IO [Chunk]
chunksList st = go [] =<< lastChunk st
  where
    go accum ptr
      | ptr == nullPtr = return accum
      | otherwise = do
            chunk <- peekChunk ptr
            go (chunk : accum) (chunkNext chunk)

-- | Unpack the given 'Location' in the Haskell representation
peekLocation :: Ptr Location -> IO Location
peekLocation ptr = do
    let ptrSize = sizeOf ptr
        peekCStringPtr :: Ptr Addr -> IO String
        peekCStringPtr p = do
            str <- peek p
            if str /= nullPtr
              then peekCString $ castPtr str
              else return ""
    objFile <- peekCStringPtr (castPtr ptr)
    function <- peekCStringPtr (castPtr ptr `plusPtr` (1*ptrSize))
    srcFile <- peekCStringPtr (castPtr ptr `plusPtr` (2*ptrSize))
    lineNo <- peek (castPtr ptr `plusPtr` (3*ptrSize)) :: IO Word32
    colNo <- peek (castPtr ptr `plusPtr` (3*ptrSize + sizeOf lineNo)) :: IO Word32
    let _srcLoc
          | null srcFile = Nothing
          | otherwise = Just $ SrcLoc { sourceFile = srcFile
                                      , sourceLine = fromIntegral lineNo
                                      , sourceColumn = fromIntegral colNo
                                      }
    return Location { objectName = objFile
                    , functionName = function
                    , srcLoc = _srcLoc
                    }

-- | The size in bytes of a 'locationSize'
locationSize :: Int
locationSize = 2*4 + 4*ptrSize
  where ptrSize = sizeOf (undefined :: Ptr ())

-- | List the frames of a stack trace.
stackFrames :: StackTrace -> [Location]
stackFrames st@(StackTrace fptr) =
    concatMap iterChunk $ reverse $ unsafePerformIO $ chunksList st
  where

    {-
    Here we lazily lookup the location information associated with each address
    as this can be rather costly. This does mean, however, that if the set of
    loaded modules changes between the time that we capture the stack and the
    time we reach here, we may end up with nonsense (mostly likely merely
    unknown symbols). I think this is a reasonable price to pay, however, as
    module loading/unloading is a rather rare event.

    Morover, we stand to gain a great deal by lazy lookups as the stack frames
    may never even be requested, meaning the only effort wasted is the
    collection of the stack frames themselves.

    The only slightly tricky thing here is to ensure that the ForeignPtr
    stays alive until we reach the end.
    -}
    iterChunk :: Chunk -> [Location]
    iterChunk chunk = iterFrames (chunkFrames chunk) (chunkFirstFrame chunk)
      where
        iterFrames :: Word -> Ptr Addr -> [Location]
        iterFrames 0 _ = []
        iterFrames n frame =
            unsafePerformIO this : iterFrames (n-1) frame'
          where
            frame' = frame `plusPtr` sizeOf (undefined :: Addr)
            this = withForeignPtr fptr $ const $ do
                pc <- peek frame :: IO Addr
                allocaBytes locationSize $ \buf -> do
                    libdw_cap_lookup_location pc buf
                    peekLocation buf

foreign import ccall unsafe "libdw_cap_get_backtrace"
    libdw_cap_get_backtrace :: IO (Ptr StackTrace)

foreign import ccall unsafe "libdw_cap_lookup_location"
    libdw_cap_lookup_location :: Addr -> Ptr Location -> IO ()

foreign import ccall unsafe "libdw_cap_free"
    libdw_cap_free :: IO ()

foreign import ccall unsafe "&backtrace_free"
    backtrace_free :: FunPtr (Ptr StackTrace -> IO ())

-- | Get an execution stack.
collectStackTrace :: IO StackTrace
collectStackTrace = do
    st <- libdw_cap_get_backtrace
    StackTrace <$> newForeignPtr backtrace_free st

-- | Free the cached debug data.
invalidateDebugCache :: IO ()
invalidateDebugCache = libdw_cap_free

-- | Render a stacktrace as a string
showStackFrames :: [Location] -> ShowS
showStackFrames frames =
    showString "Stack trace:\n"
    . foldr (.) id (map showFrame frames)
  where
    showFrame loc =
      showString "    " . showLocation loc . showChar '\n'

-- | Render a 'Location' as a string
showLocation :: Location -> ShowS
showLocation loc =
        showString (functionName loc)
      . maybe id showSrcLoc (srcLoc loc)
      . showString " in "
      . showString (objectName loc)
  where
    showSrcLoc :: SrcLoc -> ShowS
    showSrcLoc sloc =
        showString " ("
      . showString (sourceFile sloc)
      . showString ":"
      . shows (sourceLine sloc)
      . showString "."
      . shows (sourceColumn sloc)
      . showString ")"
