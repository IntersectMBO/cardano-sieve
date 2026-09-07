{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Reading the wire messages of the UTxO RPC @FollowTip@ stream. Every
-- protobuf lens lives here, so a @.proto@ change lands in one module.
module Cardano.Sieve.CardanoRpc.Response
  ( Action (..)
  , StreamedBlock (..)
  , RollbackPoint (..)
  , ServerTip (..)
  , responseAction
  , responseTip
  , intersectRequest
  , tipSlot
  )
where

import Cardano.Api
  ( ChainPoint (ChainPoint, ChainPointAtGenesis)
  , SlotNo (SlotNo)
  , serialiseToRawBytes
  )
import Cardano.Rpc.Proto.Api.UtxoRpc.Sync qualified as U5c

import Data.ByteString (ByteString)
import Data.Function ((&))
import Data.Word (Word64)
import Network.GRPC.Common.Protobuf (Proto (Proto), defMessage, getProto, (.~), (^.))

-- | What the server is telling us to do with the chain.
data Action
  = -- | Extend the chain by this block.
    Apply StreamedBlock
  | -- | Retract this block. Undos arrive newest-first.
    Undo StreamedBlock
  | -- | Reposition absolutely. Always the first message (the intersection),
    -- and how a rollback arrives when the blocks are no longer re-fetchable.
    Reset RollbackPoint
  deriving Show

-- | The raw CBOR to decode, plus the header the server derived from those same
-- bytes — an independent witness the follow loop checks its decoder against.
data StreamedBlock = StreamedBlock
  { sbNativeBytes :: !ByteString
  , sbSlot :: !SlotNo
  , sbHash :: !ByteString
  , sbHeight :: !Word64
  }
  deriving Show

-- | Where a 'Reset' or a run of 'Undo's leaves the chain.
data RollbackPoint = RollbackToGenesis | RollbackTo !SlotNo
  deriving Show

-- | The node's live tip, reported on every message — not our stream position,
-- which is what makes it usable as an at-the-tip signal.
data ServerTip = TipAtGenesis | ServerTip {stipSlot :: !SlotNo, stipHeight :: !Word64}
  deriving Show

tipSlot :: ServerTip -> Maybe SlotNo
tipSlot = \case
  TipAtGenesis -> Nothing
  ServerTip slot _ -> Just slot

blockRefPoint :: Proto U5c.BlockRef -> RollbackPoint
blockRefPoint ref = RollbackTo (SlotNo (ref ^. U5c.slot))

streamedBlock :: Proto U5c.AnyChainBlock -> StreamedBlock
streamedBlock block =
  StreamedBlock
    { sbNativeBytes = block ^. U5c.nativeBytes
    , sbSlot = SlotNo (header ^. U5c.slot)
    , sbHash = header ^. U5c.hash
    , sbHeight = header ^. U5c.height
    }
 where
  header = block ^. U5c.cardano . U5c.header

-- | 'Nothing' means the oneof was unset, which the server never does — but the
-- caller must handle it, since ignoring it would skip a block silently.
--
-- A @case@ over the constructors rather than three @maybe'@ probes, so a fourth
-- action added to the protocol breaks the build instead of being dropped.
responseAction :: Proto U5c.FollowTipResponse -> Maybe Action
responseAction resp =
  fmap describe (getProto <$> resp ^. U5c.maybe'action)
 where
  describe = \case
    U5c.FollowTipResponse'Apply block -> Apply (streamedBlock (Proto block))
    U5c.FollowTipResponse'Undo block -> Undo (streamedBlock (Proto block))
    U5c.FollowTipResponse'Reset ref -> Reset (blockRefPoint (Proto ref))

-- | Absent only at origin.
responseTip :: Proto U5c.FollowTipResponse -> ServerTip
responseTip resp =
  case getProto <$> (resp ^. U5c.maybe'tip) of
    Nothing -> TipAtGenesis
    Just ref -> ServerTip (SlotNo (ref ^. U5c.slot)) (ref ^. U5c.height)

-- | Open the stream at the first of these points on the node's chain. Genesis
-- becomes a ref with an empty hash, and 'startPoints' always ends its list with
-- genesis, so the intersection cannot fail.
intersectRequest :: [ChainPoint] -> Proto U5c.FollowTipRequest
intersectRequest points =
  defMessage & U5c.intersect .~ map blockRef points
 where
  blockRef :: ChainPoint -> Proto U5c.BlockRef
  blockRef = \case
    ChainPointAtGenesis -> defMessage & U5c.hash .~ ""
    ChainPoint (SlotNo slot) hash ->
      defMessage
        & U5c.slot .~ slot
        & U5c.hash .~ serialiseToRawBytes hash
