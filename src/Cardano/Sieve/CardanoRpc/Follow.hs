{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Index the chain over UTxO RPC: the gRPC counterpart of
-- "Cardano.Sieve.Node.Fetch".
--
-- @FollowTip@ is one server-streaming call, opened with intersection candidates
-- and then pushing @apply@\/@undo@\/@reset@ until the client stops reading.
-- Despite the name it replays history from the intersection, so it drives a
-- full sync.
--
-- Everything below the transport is shared with the ChainSync producer
-- ('sieveBlock', 'startPoints', "Cardano.Sieve.Node.Insert"), so both write
-- identical databases.
module Cardano.Sieve.CardanoRpc.Follow
  ( followTip
  )
where

import Cardano.Api (BlockHeader (BlockHeader), ChainPoint, SlotNo (SlotNo), serialiseToRawBytes)
import Cardano.Rpc.Proto.Api.UtxoRpc.Sync qualified as U5c

import Cardano.Sieve.CardanoRpc.Decode
  ( cardanoCodecConfig
  , decodeNativeBytes
  , mainnetByronEpochSlots
  )
import Cardano.Sieve.CardanoRpc.Endpoint
  ( RpcEndpoint
  , describeEndpoint
  , rpcConnParams
  , toGrpcServer
  )
import Cardano.Sieve.CardanoRpc.Response
  ( Action (Apply, Reset, Undo)
  , RollbackPoint (RollbackTo, RollbackToGenesis)
  , ServerTip (ServerTip, TipAtGenesis)
  , StreamedBlock (sbHash, sbHeight, sbNativeBytes, sbSlot)
  , intersectRequest
  , responseAction
  , responseTip
  , tipSlot
  )
import Cardano.Sieve.Node.Fetch (describeSelectors, sieveBlock, startPoints)
import Cardano.Sieve.Node.Insert
  ( DbHandle
  , Durability (Durable, UnsafeBulk)
  , PolicyIndexing (DeferPolicies, MaintainPolicies)
  , RedeemerCapture
  , buildIndexesOn
  , closeDatabase
  , flushBatch
  , openDatabase
  , reconcileSelectors
  , rollbackAbove
  )
import Cardano.Sieve.Node.Progress
  ( Progress
  , commas
  , duration
  , heartbeatSeconds
  , logLine
  , newProgress
  , summarise
  )
import Cardano.Sieve.Selector (Selector)

import Control.Exception (bracket, throwIO)
import Control.Monad (unless, void, when)
import Data.Default (def)
import Data.Functor ((<&>))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Proxy (Proxy (Proxy))
import GHC.Clock (getMonotonicTime)
import Network.GRPC.Client (recvOutput, sendFinalInput, withConnection, withRPC)
import Network.GRPC.Common.Protobuf (Protobuf)
import Network.GRPC.Common.StreamElem qualified as StreamElem

-- | The RPC being called: @/utxorpc.v1beta.sync.SyncService/FollowTip@.
type FollowTip = Protobuf U5c.SyncService "followTip"

-- | As the ChainSync producer tracks it.
data IndexState = IndexesPending | IndexesBuilt

-- | Follow the chain over UTxO RPC, indexing matches, until interrupted.
followTip
  :: RpcEndpoint
  -> FilePath
  -> Int
  -> Durability
  -> RedeemerCapture
  -> [Selector]
  -> ChainPoint
  -> IO ()
followTip endpoint dbPath batchSize durability redeemerCapture cliSelectors since =
  bracket
    (openDatabase durability dbPath batchSize)
    closeDatabase
    ( \dbHandle -> do
        selectors <- reconcileSelectors dbHandle cliSelectors
        progress <- newProgress
        built <- newIORef IndexesPending
        logLine
          ( "sync starting  db "
              <> dbPath
              <> "  batch-size "
              <> commas batchSize
              <> "  (heartbeat every "
              <> duration heartbeatSeconds
              <> ")"
          )
        logLine ("indexing selectors: " <> describeSelectors selectors)
        logLine ("following " <> describeEndpoint endpoint <> " over UTxO RPC")
        case durability of
          UnsafeBulk ->
            logLine
              "bulk mode: journaling off for catch-up — a clean exit (Ctrl-C) is safe, \
              \but a crash means delete the database and resync"
          Durable -> pure ()
        points <- startPoints dbHandle since
        withConnection rpcConnParams (toGrpcServer endpoint) $ \conn ->
          withRPC conn def (Proxy @FollowTip) $ \call -> do
            sendFinalInput call (intersectRequest points)
            -- 'recvOutput', not 'serverStreaming': that helper discards the
            -- stream's trailers, so a server-side NOT_FOUND — the answer to a
            -- --since point not on this chain — would look like a clean end of
            -- stream and the sync would exit having indexed nothing.
            void $
              StreamElem.whileNext_
                (recvOutput call)
                (handleResponse dbHandle progress built redeemerCapture selectors)
        summarise progress
    )
 where
  codecConfig = cardanoCodecConfig mainnetByronEpochSlots

  handleResponse dbHandle progress built capture selectors resp = do
    let tip = responseTip resp
    case responseAction resp of
      -- Fatal rather than ignored: an unset action would skip a block silently.
      Nothing -> throwIO (userError "FollowTip response carried no action")
      Just (Reset point) -> rollbackTo dbHandle point
      -- Undos arrive newest-first, so the deepest lands last and wins. The
      -- earlier calls delete over an already-empty range, which is cheap.
      Just (Undo block) -> rollbackTo dbHandle (RollbackTo (sbSlot block))
      Just (Apply block) ->
        applyStreamed dbHandle progress built capture selectors tip block

  rollbackTo dbHandle = \case
    RollbackToGenesis -> rollbackAbove dbHandle Nothing
    -- Keeps the named point: it is on our chain. Same as MsgRollBackward.
    RollbackTo (SlotNo slot) -> rollbackAbove dbHandle (Just (fromIntegral slot :: Int64))

  applyStreamed dbHandle progress built capture selectors tip block = do
    blockInMode <-
      either (throwIO . userError . ("could not decode a streamed block: " <>) . show) pure $
        decodeNativeBytes codecConfig (sbNativeBytes block)
    indexing <-
      readIORef built <&> \case
        IndexesPending -> DeferPolicies
        IndexesBuilt -> MaintainPolicies
    header <-
      sieveBlock dbHandle progress capture indexing selectors (tipSlot tip) blockInMode
    agreesWithServer block header
    when (atTip tip block) $ do
      buildIndexesOnce built dbHandle
      -- At the tip a block lands every ~20s, so the batch counter would leave
      -- it unqueryable until 50,000 rows accumulated — never, at that rate.
      flushBatch dbHandle

  -- The node reports its live tip on every message, so unlike ChainSync this
  -- needs no inference from an empty pipeline. Height, not slot: slots can be
  -- empty, and a slot comparison would claim the tip early.
  atTip TipAtGenesis _ = False
  atTip (ServerTip _ tipHeight) block = sbHeight block >= tipHeight

  -- The message carries the slot and hash the server derived from these same
  -- bytes, so two comparisons per block turn "the decoder is right" from an
  -- assumption into something proved continuously. Matters while the
  -- post-Byron arms have no golden fixtures.
  agreesWithServer block (BlockHeader slot hash _) =
    unless (slot == sbSlot block && serialiseToRawBytes hash == sbHash block) $
      throwIO . userError $
        "decoded block disagrees with the server: decoded slot "
          <> show slot
          <> ", server said "
          <> show (sbSlot block)

  buildIndexesOnce built dbHandle =
    readIORef built >>= \case
      IndexesBuilt -> pure ()
      IndexesPending -> do
        logLine
          "reached tip — deriving the policy index and building query indexes (this can take a few minutes)"
        t0 <- getMonotonicTime
        buildIndexesOn dbHandle
        t1 <- getMonotonicTime
        logLine
          ( "policy + query indexes built in "
              <> duration (t1 - t0)
              <> " — database now durable (WAL), following the tip"
          )
        writeIORef built IndexesBuilt
