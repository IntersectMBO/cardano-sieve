{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | CBOR encoding for an output's value (the ledger's @MaryValue@ shape), and
-- the matching decoder.
--
-- Both directions live here deliberately: they are a matched pair and a drift
-- between them is silent data loss. The write path
-- ("Cardano.Sieve.Node.Decode") uses 'encodeValue'; the query path
-- ("Cardano.Sieve.Server.Api.Matches") uses 'decodeValue'.
--
-- Replaced @aeson@ JSON, which averaged 134 bytes per output on a preview sync;
-- the CBOR encoding cut that by 52%. 'decodeValue' accepts both definite- and
-- indefinite-length maps, so values written by other encoders still read back.
module Cardano.Sieve.Value
  ( encodeValue
  , decodeValue
  )
where

import Cardano.Api
  ( AssetId (AdaAssetId, AssetId)
  , Quantity (Quantity)
  , Value
  , serialiseToRawBytes
  )

import Codec.CBOR.Decoding qualified as D
import Codec.CBOR.Encoding qualified as E
import Codec.CBOR.Read qualified as R
import Codec.CBOR.Write qualified as W
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import GHC.Exts (toList)

-- | Serialise a value to the compact CBOR the schema stores.
--
-- Only positive quantities are kept: a value in an output cannot legitimately
-- carry a zero or negative asset quantity, and dropping them keeps the encoding
-- canonical (the ledger does not represent them either).
encodeValue :: Value -> ByteString
encodeValue v = W.toStrictByteString (encodeCoinAssets ada assets)
 where
  ada = sum [q | (AdaAssetId, Quantity q) <- toList v]
  assets =
    Map.fromListWith
      (Map.unionWith (+))
      [ (serialiseToRawBytes pid, Map.singleton (serialiseToRawBytes name) q)
      | (AssetId pid name, Quantity q) <- toList v
      , q > 0
      ]

encodeCoinAssets :: Integer -> Map ByteString (Map ByteString Integer) -> E.Encoding
encodeCoinAssets ada assets
  | Map.null assets = E.encodeInteger ada
  | otherwise =
      E.encodeListLen 2
        <> E.encodeInteger ada
        <> encodeByteMap id (encodeByteMap E.encodeInteger <$> assets)

-- | A definite-length CBOR map keyed by byte strings, in ascending key order.
-- 'Map.toAscList' already gives that order, since 'ByteString' compares
-- lexicographically.
encodeByteMap :: (v -> E.Encoding) -> Map ByteString v -> E.Encoding
encodeByteMap encVal m =
  E.encodeMapLen (fromIntegral (Map.size m))
    <> foldMap (\(k, v) -> E.encodeBytes k <> encVal v) (Map.toAscList m)

-- | Recover the lovelace amount and the assets from a stored value.
--
-- Returns the assets flattened to @(policy id, asset name, quantity)@, sorted by
-- policy then name, which is the order the query layer renders them in. 'Left'
-- carries a human-readable reason so a decode failure is diagnosable rather than
-- silently becoming an empty value.
decodeValue :: ByteString -> Either String (Integer, [(ByteString, ByteString, Integer)])
decodeValue bs =
  case R.deserialiseFromBytes valueDecoder (LBS.fromStrict bs) of
    Left err -> Left (show err)
    Right (rest, r)
      | LBS.null rest -> Right r
      | otherwise -> Left ("trailing bytes after value: " <> show (LBS.length rest))

valueDecoder :: D.Decoder s (Integer, [(ByteString, ByteString, Integer)])
valueDecoder = do
  tk <- D.peekTokenType
  case tk of
    -- Ada-only values are written as a bare integer, so accept that shape first.
    D.TypeUInt -> adaOnly
    D.TypeUInt64 -> adaOnly
    D.TypeInteger -> adaOnly
    _ -> do
      _ <- D.decodeListLen
      ada <- D.decodeInteger
      assets <- decodeByteMap (decodeByteMap D.decodeInteger)
      pure
        ( ada
        , sortOn
            (\(p, n, _) -> (p, n))
            [(pid, name, q) | (pid, names) <- assets, (name, q) <- names]
        )
 where
  adaOnly = fmap (\ada -> (ada, [])) D.decodeInteger

-- | A CBOR map keyed by byte strings. Handles both the definite-length form
-- 'encodeByteMap' writes and the indefinite-length form other encoders may emit,
-- so a value written by a different tool still decodes.
decodeByteMap :: D.Decoder s v -> D.Decoder s [(ByteString, v)]
decodeByteMap decVal = do
  mLen <- D.decodeMapLenOrIndef
  case mLen of
    Just n -> replicateEntry n
    Nothing -> untilBreak
 where
  entry = (,) <$> D.decodeBytes <*> decVal
  replicateEntry n
    | n <= 0 = pure []
    | otherwise = (:) <$> entry <*> replicateEntry (n - 1)
  untilBreak = do
    stop <- D.decodeBreakOr
    if stop then pure [] else (:) <$> entry <*> untilBreak
