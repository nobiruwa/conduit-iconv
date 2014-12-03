{-# LANGUAGE ForeignFunctionInterface #-}

-- | A "Data.Conduit#t:Conduit" based on the iconv library for
-- converting a "Data.ByteString" from one character set encoding to another
module Data.Conduit.IConv
    (
      convert
    ) where

import Data.Conduit
import qualified Data.ByteString as B
import qualified Data.ByteString.Unsafe as BU

import Control.Applicative ((<$>))

import Foreign hiding (unsafePerformIO)
import Foreign.C
import System.IO.Unsafe (unsafePerformIO)
import Control.Exception (mask_)

-- | Convert text from one named character encoding to another.
--
-- Encoding names can be e.g. @\"UTF-8\"@ or @\"ISO-8559-1\"@. Appending
-- @\"\/\/IGNORE\"@ to the output encoding will cause encoding errors to be
-- ignored and the characters to be dropped, @\"\/\/IGNORE,TRANSLIT\"@ will
-- cause them to be replaced by a replacement character.
--
-- Without this encoding errors will cause an exception.
--
-- On errors this will call "Control.Monad#v:fail"
convert :: Monad m => String -- ^ Name of input character encoding
                   -> String -- ^ Name of output character encoding
                   -> Conduit B.ByteString m B.ByteString
convert inputEncoding outputEncoding = run initialConvert
  where
    initialConvert = iconvConvert inputEncoding outputEncoding

    run f = do
        maybeInput <- await
        case maybeInput of
            Nothing    -> return ()
            Just input -> do
                            let res = f input
                            case res of
                                ConvertSuccess c f'                -> yield c >> run f'
                                ConvertUnsupportedConversionError  -> fail "Unsupported conversion"
                                ConvertUnexpectedOpenError s       -> fail ("Unexpected open error: " ++ s)
                                ConvertInvalidInputError           -> fail "Invalid input"
                                ConvertUnexpectedConversionError s -> fail ("Unexpected conversion error: " ++ s)

-- Stream based API around iconv()
data ConvertResult =
    ConvertSuccess B.ByteString (B.ByteString -> ConvertResult)
  | ConvertUnsupportedConversionError
  | ConvertUnexpectedOpenError String
  | ConvertInvalidInputError
  | ConvertUnexpectedConversionError String

iconvConvert :: String -> String -> B.ByteString -> ConvertResult
iconvConvert inputEncoding outputEncoding input =
    let eCtx = iconvOpen inputEncoding outputEncoding
    in
        case eCtx of
            Left UnsupportedConversion               -> ConvertUnsupportedConversionError
            Left (UnexpectedOpenError (Errno errno)) -> ConvertUnexpectedOpenError (show errno)
            Right ctx                                -> convertInput ctx B.empty input

  where
    convertInput ctx converted newInput
      | B.null newInput  =
            ConvertSuccess converted (convertInput ctx B.empty)

      | otherwise =
            let res = iconv ctx newInput converted
            in
                case res of
                    Converted                 c r -> ConvertSuccess c (convertInputWithRemaining ctx r)
                    MoreData                  c r -> ConvertSuccess c (convertInputWithRemaining ctx r)
                    InvalidInput              c _ -> if B.null c then
                                                         ConvertInvalidInputError
                                                     else
                                                         ConvertSuccess c (const ConvertInvalidInputError)
                    UnexpectedError (Errno errno) -> ConvertUnexpectedConversionError (show errno)

    convertInputWithRemaining ctx remaining newInput
      | B.null remaining =
            convertInput ctx B.empty newInput

      | B.null newInput  =
            ConvertSuccess B.empty (convertInputWithRemaining ctx remaining)

      | otherwise =
            let tmpInput = remaining `B.append` B.take 32 newInput
                res      = iconv ctx tmpInput B.empty
            in
                case res of
                    Converted                 c r -> if processed < B.length remaining then
                                                         ConvertSuccess B.empty (convertInputWithRemaining ctx (remaining `B.append` newInput))
                                                     else
                                                         convertInput ctx c (B.drop consumedInput newInput)

                                                     where
                                                         processed = B.length tmpInput - B.length r
                                                         consumedInput = processed - B.length remaining
                    MoreData                  c r -> if processed < B.length remaining then
                                                         ConvertSuccess B.empty (convertInputWithRemaining ctx (remaining `B.append` newInput))
                                                     else
                                                         convertInput ctx c (B.drop consumedInput newInput)

                                                     where
                                                         processed = B.length tmpInput - B.length r
                                                         consumedInput = processed - B.length remaining
                    InvalidInput              c _ -> if B.null c then
                                                         ConvertInvalidInputError
                                                     else
                                                         ConvertSuccess c (const ConvertInvalidInputError)
                    UnexpectedError (Errno errno) -> ConvertUnexpectedConversionError (show errno)


-- Thin wrapper around iconv_open()
data IConvT = IConvT (ForeignPtr IConvT)
data IConvOpenError =
    UnsupportedConversion
  | UnexpectedOpenError Errno

iconvOpen :: String -> String -> Either IConvOpenError IConvT
iconvOpen inputEncoding outputEncoding = unsafePerformIO $
    mask_ $ do
    ptr <- withCString inputEncoding  $ \inputEncodingPtr  ->
           withCString outputEncoding $ \outputEncodingPtr ->
                c_iconv_open outputEncodingPtr inputEncodingPtr
    case ptrToIntPtr ptr of
        (-1) -> do
                    errno <- getErrno
                    return $ Left $
                        if errno == eINVAL then
                            UnsupportedConversion
                        else
                            UnexpectedOpenError errno
        _    -> do
                    fPtr <- newForeignPtr c_iconv_close ptr
                    return $ Right (IConvT fPtr)

-- Thin wrapper around iconv()
data IConvResult =
    Converted B.ByteString B.ByteString
  | MoreData B.ByteString B.ByteString
  | InvalidInput B.ByteString B.ByteString
  | UnexpectedError Errno

iconv :: IConvT -> B.ByteString -> B.ByteString -> IConvResult
iconv (IConvT fPtr) input outputPrefix = unsafePerformIO $ mask_ $ do
    let outputPrefixLen = B.length outputPrefix
        inputLen        = B.length input
        outputLen       = inputLen * 4 + 16 + outputPrefixLen
        convertLen      = outputLen - outputPrefixLen

    outputPtr <- mallocBytes outputLen
    BU.unsafeUseAsCString outputPrefix $ \outputPrefixPtr ->
        copyBytes outputPtr outputPrefixPtr outputPrefixLen

    let outputConvPtr = plusPtr outputPtr outputPrefixLen

    (res, readCount, writeCount) <-
        withForeignPtr fPtr            $ \ptr              ->
        BU.unsafeUseAsCString input    $ \inputPtr         ->
        with inputPtr                  $ \inputPtrPtr      ->
        with (fromIntegral inputLen)   $ \inputLenPtr      ->
        with outputConvPtr             $ \outputConvPtrPtr ->
        with (fromIntegral convertLen) $ \convertLenPtr    -> do
            res        <- c_iconv ptr inputPtrPtr inputLenPtr outputConvPtrPtr convertLenPtr
            readCount  <- (`subtract` inputLen)   . fromIntegral <$> peek inputLenPtr
            writeCount <- (`subtract` convertLen) . fromIntegral <$> peek convertLenPtr
            return (res, readCount, writeCount)

    let remaining    = B.drop readCount input
        convertedLen = outputPrefixLen + writeCount

    -- Shadowing outputPtr to prevent accidential usage of old outputPtr
    outputPtr <- reallocBytes outputPtr convertedLen
    output <- BU.unsafePackCStringLen (outputPtr, convertedLen)

    if res /= (-1) then
        return $ Converted output remaining
    else do
        errno <- getErrno
        case () of
            _ | errno == e2BIG  -> return $
                                       if writeCount == 0 then          -- we processed nothing and it's still too big?!
                                           UnexpectedError errno
                                       else
                                           MoreData output remaining

              | errno == eINVAL -> return $ Converted output remaining  -- nothing converted here is no error as with future data we might be able to convert
              | errno == eILSEQ -> return $
                                       if writeCount == 0 then          -- we processed nothing
                                           UnexpectedError errno
                                       else
                                           InvalidInput output remaining
              | otherwise       -> return $ UnexpectedError errno


-- Taken from Codec.Text.IConv
foreign import ccall unsafe "hsiconv.h hs_wrap_iconv_open"
  c_iconv_open :: CString  -- to code
               -> CString  -- from code
               -> IO (Ptr IConvT)

foreign import ccall unsafe "hsiconv.h hs_wrap_iconv"
  c_iconv :: Ptr IConvT
          -> Ptr (Ptr CChar)  -- in buf
          -> Ptr CSize        -- in buf bytes left
          -> Ptr (Ptr CChar)  -- out buf
          -> Ptr CSize        -- out buf bytes left
          -> IO CSize

foreign import ccall unsafe "hsiconv.h &hs_wrap_iconv_close"
  c_iconv_close :: FinalizerPtr IConvT

