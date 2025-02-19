{- HLINT ignore "Unused LANGUAGE pragma" -}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskellQuotes #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}

-- This template expects CPP definitions for:
--     MODULE_NAME = Posix | Windows
--     IS_WINDOWS  = False | True
--
#if defined(WINDOWS)
#define WINDOWS_DOC
#else
#define POSIX_DOC
#endif

module System.OsString.MODULE_NAME
  (
  -- * Types
#ifdef WINDOWS
    WindowsString
  , WindowsChar
#else
    PosixString
  , PosixChar
#endif

  -- * String construction
  , encodeUtf
  , unsafeEncodeUtf
  , encodeWith
  , encodeFS
  , fromBytes
  , pstr
  , singleton
  , empty
  , pack

  -- * String deconstruction
  , decodeUtf
  , decodeWith
  , decodeFS
  , unpack

  -- * Word construction
  , unsafeFromChar

  -- * Word deconstruction
  , toChar

  -- * Basic interface
  , snoc
  , cons
  , last
  , tail
  , uncons
  , head
  , init
  , unsnoc
  , null
  , length

  -- * Transforming OsString
  , map
  , reverse
  , intercalate

  -- * Reducing OsStrings (folds)
  , foldl
  , foldl'
  , foldl1
  , foldl1'
  , foldr
  , foldr'
  , foldr1
  , foldr1'

  -- ** Special folds
  , all
  , any
  , concat

  -- ** Generating and unfolding OsStrings
  , replicate
  , unfoldr
  , unfoldrN

  -- * Substrings
  -- ** Breaking strings
  , take
  , takeEnd
  , takeWhileEnd
  , takeWhile
  , drop
  , dropEnd
  , dropWhileEnd
  , dropWhile
  , break
  , breakEnd
  , span
  , spanEnd
  , splitAt
  , split
  , splitWith
  , stripSuffix
  , stripPrefix

  -- * Predicates
  , isInfixOf
  , isPrefixOf
  , isSuffixOf
  -- ** Search for arbitrary susbstrings
  , breakSubstring

  -- * Searching OsStrings
  -- ** Searching by equality
  , elem
  , find
  , filter
  , partition

  -- * Indexing OsStrings
  , index
  , indexMaybe
  , (!?)
  , elemIndex
  , elemIndices
  , count
  , findIndex
  , findIndices
  )
where



import System.OsString.Internal.Types (
#ifdef WINDOWS
  WindowsString(..), WindowsChar(..)
#else
  PosixString(..), PosixChar(..)
#endif
  )

import Data.Coerce
import Data.Char
import Control.Monad.Catch
    ( MonadThrow, throwM )
import Data.ByteString.Internal
    ( ByteString )
import Control.Exception
    ( SomeException, try, displayException )
import Control.DeepSeq ( force )
import Data.Bifunctor ( first )
import GHC.IO
    ( evaluate, unsafePerformIO )
import qualified GHC.Foreign as GHC
import Language.Haskell.TH.Quote
    ( QuasiQuoter (..) )
import Language.Haskell.TH.Syntax
    ( Lift (..), lift )


import GHC.IO.Encoding.Failure ( CodingFailureMode(..) )
#ifdef WINDOWS
import System.OsString.Encoding
import System.IO
    ( TextEncoding, utf16le )
import GHC.IO.Encoding.UTF16 ( mkUTF16le )
import qualified System.OsString.Data.ByteString.Short.Word16 as BSP
#else
import System.OsString.Encoding
import System.IO
    ( TextEncoding, utf8 )
import GHC.IO.Encoding.UTF8 ( mkUTF8 )
import qualified System.OsString.Data.ByteString.Short as BSP
#endif
import GHC.Stack (HasCallStack)
import Prelude (Bool(..), Int, Maybe(..), IO, String, Either(..), fmap, ($), (.), mconcat, fromEnum, fromInteger, mempty, fromIntegral, fail, (<$>), show, either, pure, const, flip, error, id)
import Data.Bifunctor ( bimap )
import qualified System.OsString.Data.ByteString.Short.Word16 as BS16
import qualified System.OsString.Data.ByteString.Short as BS8



#ifdef WINDOWS_DOC
-- | Partial unicode friendly encoding.
--
-- This encodes as UTF16-LE (strictly), which is a pretty good guess.
--
-- Throws an 'EncodingException' if encoding fails. If the input does not
-- contain surrogate chars, you can use @unsafeEncodeUtf@.
#else
-- | Partial unicode friendly encoding.
--
-- This encodes as UTF8 (strictly), which is a good guess.
--
-- Throws an 'EncodingException' if encoding fails. If the input does not
-- contain surrogate chars, you can use 'unsafeEncodeUtf'.
#endif
encodeUtf :: MonadThrow m => String -> m PLATFORM_STRING
#ifdef WINDOWS
encodeUtf = either throwM pure . encodeWith utf16le
#else
encodeUtf = either throwM pure . encodeWith utf8
#endif

-- | Unsafe unicode friendly encoding.
--
-- Like 'encodeUtf', except it crashes when the input contains
-- surrogate chars. For sanitized input, this can be useful.
unsafeEncodeUtf :: HasCallStack => String -> PLATFORM_STRING
#ifdef WINDOWS
unsafeEncodeUtf = either (error . displayException) id . encodeWith utf16le
#else
unsafeEncodeUtf = either (error . displayException) id . encodeWith utf8
#endif

#ifdef WINDOWS
-- | Encode a 'String' with the specified encoding.
--
-- Note: We expect a "wide char" encoding (e.g. UCS-2 or UTF-16). Anything
-- that works with @Word16@ boundaries. Picking an incompatible encoding may crash
-- filepath operations.
encodeWith :: TextEncoding  -- ^ text encoding (wide char)
           -> String
           -> Either EncodingException PLATFORM_STRING
encodeWith enc str = unsafePerformIO $ do
  r <- try @SomeException $ GHC.withCStringLen enc str $ \cstr -> WindowsString <$> BS8.packCStringLen cstr
  evaluate $ force $ first (flip EncodingError Nothing . displayException) r
#else
-- | Encode a 'String' with the specified encoding.
encodeWith :: TextEncoding
           -> String
           -> Either EncodingException PLATFORM_STRING
encodeWith enc str = unsafePerformIO $ do
  r <- try @SomeException $ GHC.withCStringLen enc str $ \cstr -> PosixString <$> BSP.packCStringLen cstr
  evaluate $ force $ first (flip EncodingError Nothing . displayException) r
#endif

#ifdef WINDOWS_DOC
-- | This mimics the behavior of the base library when doing filesystem
-- operations, which does permissive UTF-16 encoding, where coding errors generate
-- Chars in the surrogate range.
--
-- The reason this is in IO is because it unifies with the Posix counterpart,
-- which does require IO. This is safe to 'unsafePerformIO'/'unsafeDupablePerformIO'.
#else
-- | This mimics the behavior of the base library when doing filesystem
-- operations, which uses shady PEP 383 style encoding (based on the current locale,
-- but PEP 383 only works properly on UTF-8 encodings, so good luck).
--
-- Looking up the locale requires IO. If you're not worried about calls
-- to 'setFileSystemEncoding', then 'unsafePerformIO' may be feasible (make sure
-- to deeply evaluate the result to catch exceptions).
#endif
encodeFS :: String -> IO PLATFORM_STRING
#ifdef WINDOWS
encodeFS = fmap WindowsString . encodeWithBaseWindows
#else
encodeFS = fmap PosixString . encodeWithBasePosix
#endif


#ifdef WINDOWS_DOC
-- | Partial unicode friendly decoding.
--
-- This decodes as UTF16-LE (strictly), which is a pretty good.
--
-- Throws a 'EncodingException' if decoding fails.
#else
-- | Partial unicode friendly decoding.
--
-- This decodes as UTF8 (strictly), which is a good guess. Note that
-- filenames on unix are encoding agnostic char arrays.
--
-- Throws a 'EncodingException' if decoding fails.
#endif
decodeUtf :: MonadThrow m => PLATFORM_STRING -> m String
#ifdef WINDOWS
decodeUtf = either throwM pure . decodeWith utf16le
#else
decodeUtf = either throwM pure . decodeWith utf8
#endif

#ifdef WINDOWS
-- | Decode a 'WindowsString' with the specified encoding.
--
-- The String is forced into memory to catch all exceptions.
decodeWith :: TextEncoding
           -> PLATFORM_STRING
           -> Either EncodingException String
decodeWith winEnc (WindowsString ba) = unsafePerformIO $ do
  r <- try @SomeException $ BS8.useAsCStringLen ba $ \fp -> GHC.peekCStringLen winEnc fp
  evaluate $ force $ first (flip EncodingError Nothing . displayException) r
#else
-- | Decode a 'PosixString' with the specified encoding.
--
-- The String is forced into memory to catch all exceptions.
decodeWith :: TextEncoding
       -> PLATFORM_STRING
       -> Either EncodingException String
decodeWith unixEnc (PosixString ba) = unsafePerformIO $ do
  r <- try @SomeException $ BSP.useAsCStringLen ba $ \fp -> GHC.peekCStringLen unixEnc fp
  evaluate $ force $ first (flip EncodingError Nothing . displayException) r
#endif


#ifdef WINDOWS_DOC
-- | Like 'decodeUtf', except this mimics the behavior of the base library when doing filesystem
-- operations, which does permissive UTF-16 encoding, where coding errors generate
-- Chars in the surrogate range.
--
-- The reason this is in IO is because it unifies with the Posix counterpart,
-- which does require IO. 'unsafePerformIO'/'unsafeDupablePerformIO' are safe, however.
#else
-- | This mimics the behavior of the base library when doing filesystem
-- operations, which uses shady PEP 383 style encoding (based on the current locale,
-- but PEP 383 only works properly on UTF-8 encodings, so good luck).
--
-- Looking up the locale requires IO. If you're not worried about calls
-- to 'setFileSystemEncoding', then 'unsafePerformIO' may be feasible (make sure
-- to deeply evaluate the result to catch exceptions).
#endif
decodeFS :: PLATFORM_STRING -> IO String
#ifdef WINDOWS
decodeFS (WindowsString ba) = decodeWithBaseWindows ba
#else
decodeFS (PosixString ba) = decodeWithBasePosix ba
#endif


#ifdef WINDOWS_DOC
-- | Constructs a platform string from a ByteString.
--
-- This ensures valid UCS-2LE.
-- Note that this doesn't expand Word8 to Word16 on windows, so you may get invalid UTF-16.
--
-- Throws 'EncodingException' on invalid UCS-2LE (although unlikely).
#else
-- | Constructs a platform string from a ByteString.
--
-- This is a no-op.
#endif
fromBytes :: MonadThrow m
          => ByteString
          -> m PLATFORM_STRING
#ifdef WINDOWS
fromBytes bs =
  let ws = WindowsString . BS16.toShort $ bs
  in either throwM (const . pure $ ws) $ decodeWith ucs2le ws
#else
fromBytes = pure . PosixString . BSP.toShort
#endif


#ifdef WINDOWS_DOC
-- | QuasiQuote a 'WindowsString'. This accepts Unicode characters
-- and encodes as UTF-16LE on windows.
#else
-- | QuasiQuote a 'PosixString'. This accepts Unicode characters
-- and encodes as UTF-8 on unix.
#endif
pstr :: QuasiQuoter
pstr =
  QuasiQuoter
#ifdef WINDOWS
  { quoteExp = \s -> do
      ps <- either (fail . show) pure $ encodeWith (mkUTF16le ErrorOnCodingFailure) s
      lift ps
  , quotePat = \s -> do
      osp' <- either (fail . show) pure . encodeWith (mkUTF16le ErrorOnCodingFailure) $ s
      [p|((==) osp' -> True)|]
  , quoteType = \_ ->
      fail "illegal QuasiQuote (allowed as expression or pattern only, used as a type)"
  , quoteDec  = \_ ->
      fail "illegal QuasiQuote (allowed as expression or pattern only, used as a declaration)"
  }
#else
  { quoteExp = \s -> do
      ps <- either (fail . show) pure $ encodeWith (mkUTF8 ErrorOnCodingFailure) s
      lift ps
  , quotePat = \s -> do
      osp' <- either (fail . show) pure . encodeWith (mkUTF8 ErrorOnCodingFailure) $ s
      [p|((==) osp' -> True)|]
  , quoteType = \_ ->
      fail "illegal QuasiQuote (allowed as expression or pattern only, used as a type)"
  , quoteDec  = \_ ->
      fail "illegal QuasiQuote (allowed as expression or pattern only, used as a declaration)"
  }
#endif


-- | Unpack a platform string to a list of platform words.
unpack :: PLATFORM_STRING -> [PLATFORM_WORD]
unpack = coerce BSP.unpack


-- | Pack a list of platform words to a platform string.
--
-- Note that using this in conjunction with 'unsafeFromChar' to
-- convert from @[Char]@ to platform string is probably not what
-- you want, because it will truncate unicode code points.
pack :: [PLATFORM_WORD] -> PLATFORM_STRING
pack = coerce BSP.pack

singleton :: PLATFORM_WORD -> PLATFORM_STRING
singleton = coerce BSP.singleton

empty :: PLATFORM_STRING
empty = mempty


#ifdef WINDOWS
-- | Truncates to 2 octets.
unsafeFromChar :: Char -> PLATFORM_WORD
unsafeFromChar = WindowsChar . fromIntegral . fromEnum
#else
-- | Truncates to 1 octet.
unsafeFromChar :: Char -> PLATFORM_WORD
unsafeFromChar = PosixChar . fromIntegral . fromEnum
#endif

-- | Converts back to a unicode codepoint (total).
toChar :: PLATFORM_WORD -> Char
#ifdef WINDOWS
toChar (WindowsChar w) = chr $ fromIntegral w
#else
toChar (PosixChar w) = chr $ fromIntegral w
#endif

-- | /O(n)/ Append a byte to the end of a 'OsString'
--
-- @since 1.4.200.0
snoc :: PLATFORM_STRING -> PLATFORM_WORD -> PLATFORM_STRING
snoc = coerce BSP.snoc

-- | /O(n)/ 'cons' is analogous to (:) for lists.
--
-- @since 1.4.200.0
cons :: PLATFORM_WORD -> PLATFORM_STRING -> PLATFORM_STRING
cons = coerce BSP.cons


-- | /O(1)/ Extract the last element of a OsString, which must be finite and non-empty.
-- An exception will be thrown in the case of an empty OsString.
--
-- This is a partial function, consider using 'unsnoc' instead.
--
-- @since 1.4.200.0
last :: HasCallStack => PLATFORM_STRING -> PLATFORM_WORD
last = coerce BSP.last

-- | /O(n)/ Extract the elements after the head of a OsString, which must be non-empty.
-- An exception will be thrown in the case of an empty OsString.
--
-- This is a partial function, consider using 'uncons' instead.
--
-- @since 1.4.200.0
tail :: HasCallStack => PLATFORM_STRING -> PLATFORM_STRING
tail = coerce BSP.tail

-- | /O(n)/ Extract the 'head' and 'tail' of a OsString, returning 'Nothing'
-- if it is empty.
--
-- @since 1.4.200.0
uncons :: PLATFORM_STRING -> Maybe (PLATFORM_WORD, PLATFORM_STRING)
uncons = coerce BSP.uncons

-- | /O(1)/ Extract the first element of a OsString, which must be non-empty.
-- An exception will be thrown in the case of an empty OsString.
--
-- This is a partial function, consider using 'uncons' instead.
--
-- @since 1.4.200.0
head :: HasCallStack => PLATFORM_STRING -> PLATFORM_WORD
head = coerce BSP.head

-- | /O(n)/ Return all the elements of a 'OsString' except the last one.
-- An exception will be thrown in the case of an empty OsString.
--
-- This is a partial function, consider using 'unsnoc' instead.
--
-- @since 1.4.200.0
init :: HasCallStack => PLATFORM_STRING -> PLATFORM_STRING
init = coerce BSP.init

-- | /O(n)/ Extract the 'init' and 'last' of a OsString, returning 'Nothing'
-- if it is empty.
--
-- @since 1.4.200.0
unsnoc :: PLATFORM_STRING -> Maybe (PLATFORM_STRING, PLATFORM_WORD)
unsnoc = coerce BSP.unsnoc

-- | /O(1)/. The empty 'OsString'.
--
-- @since 1.4.200.0
null :: PLATFORM_STRING -> Bool
null = coerce BSP.null

-- | /O(1)/ The length of a 'OsString'.
--
-- This returns the number of code units
-- (@Word8@ on unix and @Word16@ on windows), not
-- bytes.
--
-- >>> length "abc"
-- 3
--
-- @since 1.4.200.0
length :: PLATFORM_STRING -> Int
#ifdef WINDOWS
length = coerce BSP.numWord16
#else
length = coerce BSP.length
#endif

-- | /O(n)/ 'map' @f xs@ is the OsString obtained by applying @f@ to each
-- element of @xs@.
--
-- @since 1.4.200.0
map :: (PLATFORM_WORD -> PLATFORM_WORD) -> PLATFORM_STRING -> PLATFORM_STRING
map = coerce BSP.map

-- | /O(n)/ 'reverse' @xs@ efficiently returns the elements of @xs@ in reverse order.
--
-- @since 1.4.200.0
reverse :: PLATFORM_STRING -> PLATFORM_STRING
reverse = coerce BSP.reverse

-- | /O(n)/ The 'intercalate' function takes a 'OsString' and a list of
-- 'OsString's and concatenates the list after interspersing the first
-- argument between each element of the list.
--
-- @since 1.4.200.0
intercalate :: PLATFORM_STRING -> [PLATFORM_STRING] -> PLATFORM_STRING
intercalate = coerce BSP.intercalate

-- | 'foldl', applied to a binary operator, a starting value (typically
-- the left-identity of the operator), and a OsString, reduces the
-- OsString using the binary operator, from left to right.
--
-- @since 1.4.200.0
foldl :: forall a. (a -> PLATFORM_WORD -> a) -> a -> PLATFORM_STRING -> a
foldl = coerce (BSP.foldl @a)

-- | 'foldl'' is like 'foldl', but strict in the accumulator.
--
-- @since 1.4.200.0
foldl'
  :: forall a. (a -> PLATFORM_WORD -> a) -> a -> PLATFORM_STRING -> a
foldl' = coerce (BSP.foldl' @a)

-- | 'foldl1' is a variant of 'foldl' that has no starting value
-- argument, and thus must be applied to non-empty 'OsString's.
-- An exception will be thrown in the case of an empty OsString.
--
-- @since 1.4.200.0
foldl1 :: (PLATFORM_WORD -> PLATFORM_WORD -> PLATFORM_WORD) -> PLATFORM_STRING -> PLATFORM_WORD
foldl1 = coerce BSP.foldl1

-- | 'foldl1'' is like 'foldl1', but strict in the accumulator.
-- An exception will be thrown in the case of an empty OsString.
--
-- @since 1.4.200.0
foldl1'
  :: (PLATFORM_WORD -> PLATFORM_WORD -> PLATFORM_WORD) -> PLATFORM_STRING -> PLATFORM_WORD
foldl1' = coerce BSP.foldl1'

-- | 'foldr', applied to a binary operator, a starting value
-- (typically the right-identity of the operator), and a OsString,
-- reduces the OsString using the binary operator, from right to left.
--
-- @since 1.4.200.0
foldr :: forall a. (PLATFORM_WORD -> a -> a) -> a -> PLATFORM_STRING -> a
foldr = coerce (BSP.foldr @a)

-- | 'foldr'' is like 'foldr', but strict in the accumulator.
--
-- @since 1.4.200.0
foldr'
  :: forall a. (PLATFORM_WORD -> a -> a) -> a -> PLATFORM_STRING -> a
foldr' = coerce (BSP.foldr' @a)

-- | 'foldr1' is a variant of 'foldr' that has no starting value argument,
-- and thus must be applied to non-empty 'OsString's
-- An exception will be thrown in the case of an empty OsString.
--
-- @since 1.4.200.0
foldr1 :: (PLATFORM_WORD -> PLATFORM_WORD -> PLATFORM_WORD) -> PLATFORM_STRING -> PLATFORM_WORD
foldr1 = coerce BSP.foldr1

-- | 'foldr1'' is a variant of 'foldr1', but is strict in the
-- accumulator.
--
-- @since 1.4.200.0
foldr1'
  :: (PLATFORM_WORD -> PLATFORM_WORD -> PLATFORM_WORD) -> PLATFORM_STRING -> PLATFORM_WORD
foldr1' = coerce BSP.foldr1'

-- | /O(n)/ Applied to a predicate and a 'OsString', 'all' determines
-- if all elements of the 'OsString' satisfy the predicate.
--
-- @since 1.4.200.0
all :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> Bool
all = coerce BSP.all

-- | /O(n)/ Applied to a predicate and a 'OsString', 'any' determines if
-- any element of the 'OsString' satisfies the predicate.
--
-- @since 1.4.200.0
any :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> Bool
any = coerce BSP.any

-- /O(n)/ Concatenate a list of OsStrings.
--
-- @since 1.4.200.0
concat :: [PLATFORM_STRING] -> PLATFORM_STRING
concat = mconcat

-- | /O(n)/ 'replicate' @n x@ is a OsString of length @n@ with @x@
-- the value of every element. The following holds:
--
-- > replicate w c = unfoldr w (\u -> Just (u,u)) c
--
-- @since 1.4.200.0
replicate :: Int -> PLATFORM_WORD -> PLATFORM_STRING
replicate = coerce BSP.replicate

-- | /O(n)/, where /n/ is the length of the result.  The 'unfoldr'
-- function is analogous to the List \'unfoldr\'.  'unfoldr' builds a
-- OsString from a seed value.  The function takes the element and
-- returns 'Nothing' if it is done producing the OsString or returns
-- 'Just' @(a,b)@, in which case, @a@ is the next byte in the string,
-- and @b@ is the seed value for further production.
--
-- This function is not efficient/safe. It will build a list of @[Word8]@
-- and run the generator until it returns `Nothing`, otherwise recurse infinitely,
-- then finally create a 'OsString'.
--
-- If you know the maximum length, consider using 'unfoldrN'.
--
-- Examples:
--
-- >    unfoldr (\x -> if x <= 5 then Just (x, x + 1) else Nothing) 0
-- > == pack [0, 1, 2, 3, 4, 5]
--
-- @since 1.4.200.0
unfoldr :: forall a. (a -> Maybe (PLATFORM_WORD, a)) -> a -> PLATFORM_STRING
unfoldr = coerce (BSP.unfoldr @a)

-- | /O(n)/ Like 'unfoldr', 'unfoldrN' builds a OsString from a seed
-- value.  However, the length of the result is limited by the first
-- argument to 'unfoldrN'.  This function is more efficient than 'unfoldr'
-- when the maximum length of the result is known.
--
-- The following equation relates 'unfoldrN' and 'unfoldr':
--
-- > fst (unfoldrN n f s) == take n (unfoldr f s)
--
-- @since 1.4.200.0
unfoldrN :: forall a. Int -> (a -> Maybe (PLATFORM_WORD, a)) -> a -> (PLATFORM_STRING, Maybe a)
unfoldrN = coerce (BSP.unfoldrN @a)

-- | /O(n)/ 'take' @n@, applied to a OsString @xs@, returns the prefix
-- of @xs@ of length @n@, or @xs@ itself if @n > 'length' xs@.
--
-- @since 1.4.200.0
take :: Int -> PLATFORM_STRING -> PLATFORM_STRING
take = coerce BSP.take

-- | /O(n)/ @'takeEnd' n xs@ is equivalent to @'drop' ('length' xs - n) xs@.
-- Takes @n@ elements from end of bytestring.
--
-- >>> takeEnd 3 "abcdefg"
-- "efg"
-- >>> takeEnd 0 "abcdefg"
-- ""
-- >>> takeEnd 4 "abc"
-- "abc"
--
-- @since 1.4.200.0
takeEnd :: Int -> PLATFORM_STRING -> PLATFORM_STRING
takeEnd = coerce BSP.takeEnd

-- | Returns the longest (possibly empty) suffix of elements
-- satisfying the predicate.
--
-- @'takeWhileEnd' p@ is equivalent to @'reverse' . 'takeWhile' p . 'reverse'@.
--
-- @since 1.4.200.0
takeWhileEnd :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> PLATFORM_STRING
takeWhileEnd = coerce BSP.takeWhileEnd

-- | Similar to 'Prelude.takeWhile',
-- returns the longest (possibly empty) prefix of elements
-- satisfying the predicate.
--
-- @since 1.4.200.0
takeWhile :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> PLATFORM_STRING
takeWhile = coerce BSP.takeWhile

-- | /O(n)/ 'drop' @n@ @xs@ returns the suffix of @xs@ after the first n elements, or 'empty' if @n > 'length' xs@.
--
-- @since 1.4.200.0
drop :: Int -> PLATFORM_STRING -> PLATFORM_STRING
drop = coerce BSP.drop

-- | /O(n)/ @'dropEnd' n xs@ is equivalent to @'take' ('length' xs - n) xs@.
-- Drops @n@ elements from end of bytestring.
--
-- >>> dropEnd 3 "abcdefg"
-- "abcd"
-- >>> dropEnd 0 "abcdefg"
-- "abcdefg"
-- >>> dropEnd 4 "abc"
-- ""
--
-- @since 1.4.200.0
dropEnd :: Int -> PLATFORM_STRING -> PLATFORM_STRING
dropEnd = coerce BSP.dropEnd

-- | Similar to 'Prelude.dropWhile',
-- drops the longest (possibly empty) prefix of elements
-- satisfying the predicate and returns the remainder.
--
-- @since 1.4.200.0
dropWhile :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> PLATFORM_STRING
dropWhile = coerce BSP.dropWhile

-- | Similar to 'Prelude.dropWhileEnd',
-- drops the longest (possibly empty) suffix of elements
-- satisfying the predicate and returns the remainder.
--
-- @'dropWhileEnd' p@ is equivalent to @'reverse' . 'dropWhile' p . 'reverse'@.
--
-- @since 1.4.200.0
dropWhileEnd :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> PLATFORM_STRING
dropWhileEnd = coerce BSP.dropWhileEnd

-- | Returns the longest (possibly empty) suffix of elements which __do not__
-- satisfy the predicate and the remainder of the string.
--
-- 'breakEnd' @p@ is equivalent to @'spanEnd' (not . p)@ and to @('takeWhileEnd' (not . p) &&& 'dropWhileEnd' (not . p))@.
--
-- @since 1.4.200.0
breakEnd :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> (PLATFORM_STRING, PLATFORM_STRING)
breakEnd = coerce BSP.breakEnd

-- | Similar to 'Prelude.break',
-- returns the longest (possibly empty) prefix of elements which __do not__
-- satisfy the predicate and the remainder of the string.
--
-- 'break' @p@ is equivalent to @'span' (not . p)@ and to @('takeWhile' (not . p) &&& 'dropWhile' (not . p))@.
--
-- @since 1.4.200.0
break :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> (PLATFORM_STRING, PLATFORM_STRING)
break = coerce BSP.break

-- | Similar to 'Prelude.span',
-- returns the longest (possibly empty) prefix of elements
-- satisfying the predicate and the remainder of the string.
--
-- 'span' @p@ is equivalent to @'break' (not . p)@ and to @('takeWhile' p &&& 'dropWhile' p)@.
--
-- @since 1.4.200.0
span :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> (PLATFORM_STRING, PLATFORM_STRING)
span = coerce BSP.span

-- | Returns the longest (possibly empty) suffix of elements
-- satisfying the predicate and the remainder of the string.
--
-- 'spanEnd' @p@ is equivalent to @'breakEnd' (not . p)@ and to @('takeWhileEnd' p &&& 'dropWhileEnd' p)@.
--
-- We have
--
-- > spanEnd (not . isSpace) "x y z" == ("x y ", "z")
--
-- and
--
-- > spanEnd (not . isSpace) sbs
-- >    ==
-- > let (x, y) = span (not . isSpace) (reverse sbs) in (reverse y, reverse x)
--
-- @since 1.4.200.0
spanEnd :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> (PLATFORM_STRING, PLATFORM_STRING)
spanEnd = coerce BSP.spanEnd

-- | /O(n)/ 'splitAt' @n sbs@ is equivalent to @('take' n sbs, 'drop' n sbs)@.
--
-- @since 1.4.200.0
splitAt :: Int -> PLATFORM_STRING -> (PLATFORM_STRING, PLATFORM_STRING)
splitAt = coerce BSP.splitAt

-- | /O(n)/ Break a 'OsString' into pieces separated by the byte
-- argument, consuming the delimiter. I.e.
--
-- > split 10  "a\nb\nd\ne" == ["a","b","d","e"]   -- fromEnum '\n' == 10
-- > split 97  "aXaXaXa"    == ["","X","X","X",""] -- fromEnum 'a' == 97
-- > split 120 "x"          == ["",""]             -- fromEnum 'x' == 120
-- > split undefined ""     == []                  -- and not [""]
--
-- and
--
-- > intercalate [c] . split c == id
-- > split == splitWith . (==)
--
-- @since 1.4.200.0
split :: PLATFORM_WORD -> PLATFORM_STRING -> [PLATFORM_STRING]
split = coerce BSP.split

-- | /O(n)/ Splits a 'OsString' into components delimited by
-- separators, where the predicate returns True for a separator element.
-- The resulting components do not contain the separators.  Two adjacent
-- separators result in an empty component in the output.  eg.
--
-- > splitWith (==97) "aabbaca" == ["","","bb","c",""] -- fromEnum 'a' == 97
-- > splitWith undefined ""     == []                  -- and not [""]
--
-- @since 1.4.200.0
splitWith :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> [PLATFORM_STRING]
splitWith = coerce BSP.splitWith

-- | /O(n)/ The 'stripSuffix' function takes two OsStrings and returns 'Just'
-- the remainder of the second iff the first is its suffix, and otherwise
-- 'Nothing'.
--
-- @since 1.4.200.0
stripSuffix :: PLATFORM_STRING -> PLATFORM_STRING -> Maybe PLATFORM_STRING
stripSuffix = coerce BSP.stripSuffix

-- | /O(n)/ The 'stripPrefix' function takes two OsStrings and returns 'Just'
-- the remainder of the second iff the first is its prefix, and otherwise
-- 'Nothing'.
--
-- @since 1.4.200.0
stripPrefix :: PLATFORM_STRING -> PLATFORM_STRING -> Maybe PLATFORM_STRING
stripPrefix = coerce BSP.stripPrefix


-- | Check whether one string is a substring of another.
--
-- @since 1.4.200.0
isInfixOf :: PLATFORM_STRING -> PLATFORM_STRING -> Bool
isInfixOf = coerce BSP.isInfixOf

-- |/O(n)/ The 'isPrefixOf' function takes two OsStrings and returns 'True'
--
-- @since 1.4.200.0
isPrefixOf :: PLATFORM_STRING -> PLATFORM_STRING -> Bool
isPrefixOf = coerce BSP.isPrefixOf

-- | /O(n)/ The 'isSuffixOf' function takes two OsStrings and returns 'True'
-- iff the first is a suffix of the second.
--
-- The following holds:
--
-- > isSuffixOf x y == reverse x `isPrefixOf` reverse y
--
-- @since 1.4.200.0
isSuffixOf :: PLATFORM_STRING -> PLATFORM_STRING -> Bool
isSuffixOf = coerce BSP.isSuffixOf


-- | Break a string on a substring, returning a pair of the part of the
-- string prior to the match, and the rest of the string.
--
-- The following relationships hold:
--
-- > break (== c) l == breakSubstring (singleton c) l
--
-- For example, to tokenise a string, dropping delimiters:
--
-- > tokenise x y = h : if null t then [] else tokenise x (drop (length x) t)
-- >     where (h,t) = breakSubstring x y
--
-- To skip to the first occurrence of a string:
--
-- > snd (breakSubstring x y)
--
-- To take the parts of a string before a delimiter:
--
-- > fst (breakSubstring x y)
--
-- Note that calling `breakSubstring x` does some preprocessing work, so
-- you should avoid unnecessarily duplicating breakSubstring calls with the same
-- pattern.
--
-- @since 1.4.200.0
breakSubstring :: PLATFORM_STRING -> PLATFORM_STRING -> (PLATFORM_STRING, PLATFORM_STRING)
breakSubstring = coerce BSP.breakSubstring

-- | /O(n)/ 'elem' is the 'OsString' membership predicate.
--
-- @since 1.4.200.0
elem :: PLATFORM_WORD -> PLATFORM_STRING -> Bool
elem = coerce BSP.elem

-- | /O(n)/ The 'find' function takes a predicate and a OsString,
-- and returns the first element in matching the predicate, or 'Nothing'
-- if there is no such element.
--
-- > find f p = case findIndex f p of Just n -> Just (p ! n) ; _ -> Nothing
--
-- @since 1.4.200.0
find :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> Maybe PLATFORM_WORD
find = coerce BSP.find

-- | /O(n)/ 'filter', applied to a predicate and a OsString,
-- returns a OsString containing those characters that satisfy the
-- predicate.
--
-- @since 1.4.200.0
filter :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> PLATFORM_STRING
filter = coerce BSP.filter

-- | /O(n)/ The 'partition' function takes a predicate a OsString and returns
-- the pair of OsStrings with elements which do and do not satisfy the
-- predicate, respectively; i.e.,
--
-- > partition p bs == (filter p sbs, filter (not . p) sbs)
--
-- @since 1.4.200.0
partition :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> (PLATFORM_STRING, PLATFORM_STRING)
partition = coerce BSP.partition

-- | /O(1)/ 'OsString' index (subscript) operator, starting from 0.
--
-- @since 1.4.200.0
index :: HasCallStack => PLATFORM_STRING -> Int -> PLATFORM_WORD
index = coerce BSP.index

-- | /O(1)/ 'OsString' index, starting from 0, that returns 'Just' if:
--
-- > 0 <= n < length bs
--
-- @since 1.4.200.0
indexMaybe :: PLATFORM_STRING -> Int -> Maybe PLATFORM_WORD
indexMaybe = coerce BSP.indexMaybe

-- | /O(1)/ 'OsString' index, starting from 0, that returns 'Just' if:
--
-- > 0 <= n < length bs
--
-- @since 1.4.200.0
(!?) :: PLATFORM_STRING -> Int -> Maybe PLATFORM_WORD
(!?) = indexMaybe

-- | /O(n)/ The 'elemIndex' function returns the index of the first
-- element in the given 'OsString' which is equal to the query
-- element, or 'Nothing' if there is no such element.
--
-- @since 1.4.200.0
elemIndex :: PLATFORM_WORD -> PLATFORM_STRING -> Maybe Int
elemIndex = coerce BSP.elemIndex

-- | /O(n)/ The 'elemIndices' function extends 'elemIndex', by returning
-- the indices of all elements equal to the query element, in ascending order.
--
-- @since 1.4.200.0
elemIndices :: PLATFORM_WORD -> PLATFORM_STRING -> [Int]
elemIndices = coerce BSP.elemIndices

-- | count returns the number of times its argument appears in the OsString
--
-- @since 1.4.200.0
count :: PLATFORM_WORD -> PLATFORM_STRING -> Int
count = coerce BSP.count

-- | /O(n)/ The 'findIndex' function takes a predicate and a 'OsString' and
-- returns the index of the first element in the OsString
-- satisfying the predicate.
--
-- @since 1.4.200.0
findIndex :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> Maybe Int
findIndex = coerce BSP.findIndex

-- | /O(n)/ The 'findIndices' function extends 'findIndex', by returning the
-- indices of all elements satisfying the predicate, in ascending order.
--
-- @since 1.4.200.0
findIndices :: (PLATFORM_WORD -> Bool) -> PLATFORM_STRING -> [Int]
findIndices = coerce BSP.findIndices
