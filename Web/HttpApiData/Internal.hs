{-# LANGUAGE CPP #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeSynonymInstances #-}
-- |
-- Convert Haskell values to and from HTTP API data
-- such as URL pieces, headers and query parameters.
module Web.HttpApiData.Internal where

import Control.Applicative
import Control.Arrow ((&&&))

import Data.Monoid
import Data.ByteString (ByteString)

import Data.Int
import Data.Word

import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Data.Text.Read (signed, decimal, rational, Reader)
import qualified Data.Text as T
import qualified Data.Text.Lazy as L

import Data.Time (Day)
import Data.Version

#if MIN_VERSION_base(4,8,0)
import Data.Void
#endif

import Text.Read (readMaybe)
import Text.ParserCombinators.ReadP (readP_to_S)

#if USE_TEXT_SHOW
import TextShow (TextShow, showt)
#endif

-- | Convert value to HTTP API data.
class ToHttpApiData a where
  {-# MINIMAL toUrlPiece | toQueryParam #-}
  -- | Convert to URL path piece.
  toUrlPiece :: a -> Text
  toUrlPiece = toQueryParam

  -- | Convert to HTTP header value.
  toHeader :: a -> ByteString
  toHeader = encodeUtf8 . toUrlPiece

  -- | Convert to query param value.
  toQueryParam :: a -> Text
  toQueryParam = toUrlPiece

-- | Parse value from HTTP API data.
class FromHttpApiData a where
  {-# MINIMAL parseUrlPiece | parseQueryParam #-}
  -- | Parse URL path piece.
  parseUrlPiece :: Text -> Either Text a
  parseUrlPiece = parseQueryParam

  -- | Parse HTTP header value.
  parseHeader :: ByteString -> Either Text a
  parseHeader = parseUrlPiece . decodeUtf8

  -- | Parse query param value.
  parseQueryParam :: Text -> Either Text a
  parseQueryParam = parseUrlPiece

-- | Parse URL path piece in a @'Maybe'@.
--
-- >>> parseUrlPieceMaybe "12" :: Maybe Int
-- Just 12
parseUrlPieceMaybe :: FromHttpApiData a => Text -> Maybe a
parseUrlPieceMaybe = either (const Nothing) Just . parseUrlPiece

-- | Parse HTTP header value in a @'Maybe'@.
--
-- >>> parseHeaderMaybe "hello" :: Maybe Text
-- Just "hello"
parseHeaderMaybe :: FromHttpApiData a => ByteString -> Maybe a
parseHeaderMaybe = either (const Nothing) Just . parseHeader

-- | Parse query param value in a @'Maybe'@.
--
-- >>> parseQueryParamMaybe "true" :: Maybe Bool
-- Just True
parseQueryParamMaybe :: FromHttpApiData a => Text -> Maybe a
parseQueryParamMaybe = either (const Nothing) Just . parseQueryParam

-- | Default parsing error.
defaultParseError :: Text -> Either Text a
defaultParseError input = Left ("could not parse: `" <> input <> "'")

-- | Convert @'Maybe'@ parser into @'Either' 'Text'@ parser with default error message.
parseMaybeTextData :: (Text -> Maybe a) -> (Text -> Either Text a)
parseMaybeTextData parse input =
  case parse input of
    Nothing  -> defaultParseError input
    Just val -> Right val

#if USE_TEXT_SHOW
-- | Convert to URL piece using @'TextShow'@ instance.
-- The result is always lower cased.
--
-- >>> showTextData True
-- "true"
--
-- This can be used as a default implementation for enumeration types:
--
-- @
-- data MyData = Foo | Bar | Baz deriving (Generic)
-- 
-- instance TextShow MyData where
--   showt = genericShowt
--
-- instance ToHttpApiData MyData where
--   toUrlPiece = showTextData
-- @
showTextData :: TextShow a => a -> Text
showTextData = T.toLower . showt
#else
-- | Convert to URL piece using @'Show'@ instance.
-- The result is always lower cased.
--
-- >>> showTextData True
-- "true"
--
-- This can be used as a default implementation for enumeration types:
--
-- >>> data MyData = Foo | Bar | Baz deriving (Show)
-- >>> instance ToHttpApiData MyData where toUrlPiece = showTextData
-- >>> toUrlPiece Foo
-- "foo"
showTextData :: Show a => a -> Text
showTextData = T.toLower . showt

-- | Like @'show'@, but returns @'Text'@.
showt :: Show a => a -> Text
showt = T.pack . show
#endif

-- | Parse given text case insensitive and return the rest of the input.
--
-- >>> parseUrlPieceWithPrefix "Just " "just 10" :: Either Text Int
-- Right 10
-- >>> parseUrlPieceWithPrefix "Left " "left" :: Either Text Bool
-- Left "could not parse: `left'"
--
-- This can be used to implement @'FromHttpApiData'@ for single field constructors:
--
-- >>> data Foo = Foo Int deriving (Show)
-- >>> instance FromHttpApiData Foo where parseUrlPiece s = Foo <$> parseUrlPieceWithPrefix "Foo " s
-- >>> parseUrlPiece "foo 1" :: Either Text Foo
-- Right (Foo 1)
parseUrlPieceWithPrefix :: FromHttpApiData a => Text -> Text -> Either Text a
parseUrlPieceWithPrefix pattern input
  | T.toLower pattern == T.toLower prefix = parseUrlPiece rest
  | otherwise                             = defaultParseError input
  where
    (prefix, rest) = T.splitAt (T.length pattern) input

#if USE_TEXT_SHOW
-- | Parse values case insensitively based on @'TextShow'@ instance.
--
-- >>> parseBoundedCaseInsensitiveTextData "true" :: Either Text Bool
-- Right True
-- >>> parseBoundedCaseInsensitiveTextData "FALSE" :: Either Text Bool
-- Right False
--
-- This can be used as a default implementation for enumeration types:
--
-- @
-- data MyData = Foo | Bar | Baz deriving (Show, Bounded, Enum, Generic)
--
-- instance TextShow MyData where
--   showt = genericShowt
--
-- instance FromHttpApiData MyData where
--   parseUrlPiece = parseBoundedCaseInsensitiveTextData
-- @
parseBoundedCaseInsensitiveTextData :: forall a. (TextShow a, Bounded a, Enum a) => Text -> Either Text a
#else
-- | Parse values case insensitively based on @'Show'@ instance.
--
-- >>> parseBoundedCaseInsensitiveTextData "true" :: Either Text Bool
-- Right True
-- >>> parseBoundedCaseInsensitiveTextData "FALSE" :: Either Text Bool
-- Right False
--
-- This can be used as a default implementation for enumeration types:
--
-- >>> data MyData = Foo | Bar | Baz deriving (Show, Bounded, Enum)
-- >>> instance FromHttpApiData MyData where parseUrlPiece = parseBoundedCaseInsensitiveTextData
-- >>> parseUrlPiece "foo" :: Either Text MyData
-- Right Foo
parseBoundedCaseInsensitiveTextData :: forall a. (Show a, Bounded a, Enum a) => Text -> Either Text a
#endif
parseBoundedCaseInsensitiveTextData = parseMaybeTextData (flip lookup values . T.toLower)
  where
    values = map (showTextData &&& id) [minBound..maxBound :: a]

-- | Parse URL piece using @'Read'@ instance.
readMaybeTextData :: Read a => Text -> Maybe a
readMaybeTextData = readMaybe . T.unpack

-- | Parse URL piece using @'Read'@ instance.
readEitherTextData :: Read a => Text -> Either Text a
readEitherTextData = parseMaybeTextData readMaybeTextData

-- | Run @'Reader'@ as HTTP API data parser.
runReader :: Reader a -> Text -> Either Text a
runReader reader input =
  case reader input of
    Left err          -> Left (T.pack err)
    Right (x, rest)
      | T.null rest -> Right x
      | otherwise   -> defaultParseError input

-- | Run @'Reader'@ to parse bounded integral value with bounds checking.
--
-- >>> parseBounded decimal "256" :: Either Text Word8
-- Left "out of bounds: `256' (should be between 0 and 255)"
parseBounded :: forall a. (Bounded a, Integral a) => Reader Integer -> Text -> Either Text a
parseBounded reader input = do
  n <- runReader reader input
  if (n > h || n < l)
    then Left  ("out of bounds: `" <> input <> "' (should be between " <> T.pack (show l) <> " and " <> T.pack (show h) <> ")")
    else Right (fromInteger n)
  where
    l = toInteger (minBound :: a)
    h = toInteger (maxBound :: a)

-- |
-- >>> toUrlPiece ()
-- "_"
instance ToHttpApiData () where
  toUrlPiece () = "_"

instance ToHttpApiData Char     where toUrlPiece = T.singleton

-- |
-- >>> toUrlPiece (Version [1, 2, 3] [])
-- "1.2.3"
instance ToHttpApiData Version where
  toUrlPiece = T.pack . showVersion

#if MIN_VERSION_base(4,8,0)
instance ToHttpApiData Void where
  toUrlPiece = absurd
#endif

instance ToHttpApiData Bool     where toUrlPiece = showTextData
instance ToHttpApiData Ordering where toUrlPiece = showTextData

instance ToHttpApiData Double   where toUrlPiece = showt
instance ToHttpApiData Float    where toUrlPiece = showt
instance ToHttpApiData Int      where toUrlPiece = showt
instance ToHttpApiData Int8     where toUrlPiece = showt
instance ToHttpApiData Int16    where toUrlPiece = showt
instance ToHttpApiData Int32    where toUrlPiece = showt
instance ToHttpApiData Int64    where toUrlPiece = showt
instance ToHttpApiData Integer  where toUrlPiece = showt
instance ToHttpApiData Word     where toUrlPiece = showt
instance ToHttpApiData Word8    where toUrlPiece = showt
instance ToHttpApiData Word16   where toUrlPiece = showt
instance ToHttpApiData Word32   where toUrlPiece = showt
instance ToHttpApiData Word64   where toUrlPiece = showt
instance ToHttpApiData Day      where toUrlPiece = T.pack . show

instance ToHttpApiData String   where toUrlPiece = T.pack
instance ToHttpApiData Text     where toUrlPiece = id
instance ToHttpApiData L.Text   where toUrlPiece = L.toStrict

instance ToHttpApiData All where toUrlPiece = toUrlPiece . getAll
instance ToHttpApiData Any where toUrlPiece = toUrlPiece . getAny

instance ToHttpApiData a => ToHttpApiData (Dual a)    where toUrlPiece = toUrlPiece . getDual
instance ToHttpApiData a => ToHttpApiData (Sum a)     where toUrlPiece = toUrlPiece . getSum
instance ToHttpApiData a => ToHttpApiData (Product a) where toUrlPiece = toUrlPiece . getProduct
instance ToHttpApiData a => ToHttpApiData (First a)   where toUrlPiece = toUrlPiece . getFirst
instance ToHttpApiData a => ToHttpApiData (Last a)    where toUrlPiece = toUrlPiece . getLast

-- |
-- >>> toUrlPiece (Just "Hello")
-- "just Hello"
instance ToHttpApiData a => ToHttpApiData (Maybe a) where
  toUrlPiece (Just x) = "just " <> toUrlPiece x
  toUrlPiece Nothing  = "nothing"

-- |
-- >>> toUrlPiece (Left "err" :: Either String Int)
-- "left err"
-- >>> toUrlPiece (Right 3 :: Either String Int)
-- "right 3"
instance (ToHttpApiData a, ToHttpApiData b) => ToHttpApiData (Either a b) where
  toUrlPiece (Left x)  = "left " <> toUrlPiece x
  toUrlPiece (Right x) = "right " <> toUrlPiece x

-- |
-- >>> parseUrlPiece "_" :: Either Text ()
-- Right ()
instance FromHttpApiData () where
  parseUrlPiece "_" = return ()
  parseUrlPiece s   = defaultParseError s

instance FromHttpApiData Char where
  parseUrlPiece s =
    case T.uncons s of
      Just (c, s') | T.null s' -> return c
      _                        -> defaultParseError s

-- |
-- >>> showVersion <$> parseUrlPiece "1.2.3"
-- Right "1.2.3"
instance FromHttpApiData Version where
  parseUrlPiece s =
    case reverse (readP_to_S parseVersion (T.unpack s)) of
      ((x, ""):_) -> return x
      _           -> defaultParseError s

#if MIN_VERSION_base(4,8,0)
instance FromHttpApiData Void where
  parseUrlPiece _ = Left "Void cannot be parsed!"
#endif

instance FromHttpApiData Bool     where parseUrlPiece = parseBoundedCaseInsensitiveTextData
instance FromHttpApiData Ordering where parseUrlPiece = parseBoundedCaseInsensitiveTextData
instance FromHttpApiData Double   where parseUrlPiece = runReader rational
instance FromHttpApiData Float    where parseUrlPiece = runReader rational
instance FromHttpApiData Int      where parseUrlPiece = parseBounded (signed decimal)
instance FromHttpApiData Int8     where parseUrlPiece = parseBounded (signed decimal)
instance FromHttpApiData Int16    where parseUrlPiece = parseBounded (signed decimal)
instance FromHttpApiData Int32    where parseUrlPiece = parseBounded (signed decimal)
instance FromHttpApiData Int64    where parseUrlPiece = parseBounded (signed decimal)
instance FromHttpApiData Integer  where parseUrlPiece = runReader (signed decimal)
instance FromHttpApiData Word     where parseUrlPiece = parseBounded decimal
instance FromHttpApiData Word8    where parseUrlPiece = parseBounded decimal
instance FromHttpApiData Word16   where parseUrlPiece = parseBounded decimal
instance FromHttpApiData Word32   where parseUrlPiece = parseBounded decimal
instance FromHttpApiData Word64   where parseUrlPiece = parseBounded decimal
instance FromHttpApiData String   where parseUrlPiece = Right . T.unpack
instance FromHttpApiData Text     where parseUrlPiece = Right
instance FromHttpApiData L.Text   where parseUrlPiece = Right . L.fromStrict
instance FromHttpApiData Day      where parseUrlPiece = readEitherTextData

instance FromHttpApiData All where parseUrlPiece = fmap All . parseUrlPiece
instance FromHttpApiData Any where parseUrlPiece = fmap Any . parseUrlPiece

instance FromHttpApiData a => FromHttpApiData (Dual a)    where parseUrlPiece = fmap Dual    . parseUrlPiece
instance FromHttpApiData a => FromHttpApiData (Sum a)     where parseUrlPiece = fmap Sum     . parseUrlPiece
instance FromHttpApiData a => FromHttpApiData (Product a) where parseUrlPiece = fmap Product . parseUrlPiece
instance FromHttpApiData a => FromHttpApiData (First a)   where parseUrlPiece = fmap First   . parseUrlPiece
instance FromHttpApiData a => FromHttpApiData (Last a)    where parseUrlPiece = fmap Last    . parseUrlPiece

-- |
-- >>> parseUrlPiece "Just 123" :: Either Text (Maybe Int)
-- Right (Just 123)
instance FromHttpApiData a => FromHttpApiData (Maybe a) where
  parseUrlPiece s
    | T.toLower (T.take 7 s) == "nothing" = return Nothing
    | otherwise                           = Just <$> parseUrlPieceWithPrefix "Just " s

-- |
-- >>> parseUrlPiece "Right 123" :: Either Text (Either String Int)
-- Right (Right 123)
instance (FromHttpApiData a, FromHttpApiData b) => FromHttpApiData (Either a b) where
  parseUrlPiece s =
        Right <$> parseUrlPieceWithPrefix "Right " s
    <!> Left  <$> parseUrlPieceWithPrefix "Left " s
    where
      infixl 3 <!>
      Left _ <!> y = y
      x      <!> _ = x
