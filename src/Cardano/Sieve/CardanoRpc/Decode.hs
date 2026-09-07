{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Turn the raw CBOR cardano-rpc streams into a 'BlockInMode'.
--
-- ChainSync decodes inside @connectToLocalNode@; over UTxO RPC the client gets
-- @AnyChainBlock.native_bytes@ and must decode it itself. Using those bytes
-- rather than the parsed block in the same message is what lets
-- "Cardano.Sieve.Node.Decode" and ".Encode" be reused unchanged.
module Cardano.Sieve.CardanoRpc.Decode
  ( decodeNativeBytes
  , BlockDecodeError (..)
  , cardanoCodecConfig
  , mainnetByronEpochSlots
  )
where

import Cardano.Api (BlockInMode, EpochSlots (EpochSlots))
import Cardano.Api.Block (fromConsensusBlock)
import Cardano.Api.Consensus
  ( CardanoBlock
  , ProtocolClient (protocolClientInfo)
  , ProtocolClientInfoArgs (ProtocolClientInfoArgsCardano)
  , StandardCrypto
  )
import Cardano.Api.Serialise.Cbor (DecoderError)

import Ouroboros.Consensus.Block (CodecConfig)
import Ouroboros.Consensus.Node.ProtocolInfo (ProtocolClientInfo (pClientInfoCodecConfig))
import Ouroboros.Consensus.Storage.Serialisation (DecodeDisk (decodeDisk))

import Codec.CBOR.Decoding (Decoder)
import Codec.CBOR.Read (DeserialiseFailure)
import Codec.CBOR.Read qualified as CBOR
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)

-- | Why a block's bytes could not be turned into a 'BlockInMode'.
--
-- Two failures rather than one because they mean different things: the CBOR
-- itself being unreadable points at the wrong bytes (a truncated message, or a
-- field other than @native_bytes@), whereas a decoder error on well-formed
-- CBOR points at a config or version mismatch between this client and the node
-- that served it.
data BlockDecodeError
  = -- | Not valid CBOR.
    MalformedCbor DeserialiseFailure
  | -- | A block decoded but bytes were left over. Rejected, as consensus does
    -- (@TrailingDataError@): a block is the whole payload, so leftovers mean
    -- these are not the bytes we think they are.
    TrailingBytes Int64
  | -- | Valid CBOR the block decoder rejected — usually an era this build does
    -- not know.
    BlockDecoderError DecoderError
  deriving Show

-- | Byron slots-per-epoch, consumed only by the Byron decoder arms. Same value
-- and same reasoning as 'Cardano.Sieve.Node.Fetch'\'s @LocalNodeConnectInfo@.
mainnetByronEpochSlots :: EpochSlots
mainnetByronEpochSlots = EpochSlots 21600

-- | Built the same way cardano-api builds it for its own ChainSync codecs.
cardanoCodecConfig :: EpochSlots -> CodecConfig (CardanoBlock StandardCrypto)
cardanoCodecConfig epochSlots =
  pClientInfoCodecConfig (protocolClientInfo (ProtocolClientInfoArgsCardano epochSlots))

-- | Decode @AnyChainBlock.native_bytes@.
--
-- The bytes are the ChainDB's on-disk serialisation (@GetRawBlock@), so the
-- disk codec applies and the era tag it carries makes one decoder work for
-- every era. The two-step shape is forced by the instance: 'decodeDisk' yields
-- a function from the block's own bytes to the block (the annotation trick),
-- not the block itself.
decodeNativeBytes
  :: CodecConfig (CardanoBlock StandardCrypto) -> ByteString -> Either BlockDecodeError BlockInMode
decodeNativeBytes codecConfig bytes = do
  let lazyBytes = LBS.fromStrict bytes
      decoder :: forall s. Decoder s (LBS.ByteString -> Either DecoderError (CardanoBlock StandardCrypto))
      decoder = decodeDisk codecConfig
  (unconsumed, mkBlock) <-
    either (Left . MalformedCbor) Right (CBOR.deserialiseFromBytes decoder lazyBytes)
  unless (LBS.null unconsumed) (Left (TrailingBytes (LBS.length unconsumed)))
  -- The WHOLE buffer, not what is left: sub-decoders kept offsets into it.
  block <- either (Left . BlockDecoderError) Right (mkBlock lazyBytes)
  pure (fromConsensusBlock block)
