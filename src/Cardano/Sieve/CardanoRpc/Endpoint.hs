{-# LANGUAGE ImportQualifiedPost #-}

-- | Where the UTxO RPC server is, and how to connect to it. Separate from the
-- follow loop so grapesy's connection types stay in one place.
module Cardano.Sieve.CardanoRpc.Endpoint
  ( RpcEndpoint (..)
  , describeEndpoint
  , defaultRpcSocketFor
  , parseRpcAddress
  , toGrpcServer
  , rpcConnParams
  )
where

import Data.Default (def)
import Network.GRPC.Client (Address (Address), Server (ServerInsecure, ServerUnix))
import Network.GRPC.Client qualified as GRPC
import Network.GRPC.Common.HTTP2Settings
  ( http2ConnectionWindowSize
  , http2StreamWindowSize
  )
import System.FilePath (takeDirectory, (</>))
import Text.Read (readMaybe)

-- | How to reach the node's UTxO RPC server. TLS is absent for now: it needs
-- its own CLI surface for certificates, and adding it later is additive.
data RpcEndpoint
  = -- | A unix socket. cardano-rpc's own default, so the common case.
    RpcUnixSocket FilePath
  | -- | Host and port, cleartext HTTP/2 (h2c).
    RpcAddress String Int
  deriving (Eq, Show)

-- | For the startup banner.
describeEndpoint :: RpcEndpoint -> String
describeEndpoint = \case
  RpcUnixSocket path -> path
  RpcAddress host port -> host <> ":" <> show port

-- | Where cardano-rpc puts its socket by default: @rpc.sock@ beside the node
-- socket. Reproduced rather than imported to avoid pulling in the server's
-- whole configuration module for two lines.
defaultRpcSocketFor :: FilePath -> FilePath
defaultRpcSocketFor nodeSocket = takeDirectory nodeSocket </> "rpc.sock"

-- | Parse @HOST:PORT@. Splits on the last colon so IPv6 literals survive.
parseRpcAddress :: String -> Either String RpcEndpoint
parseRpcAddress raw =
  case break (== ':') (reverse raw) of
    (revPort, ':' : revHost)
      | not (null revHost)
      , Just port <- readMaybe (reverse revPort)
      , port > 0
      , port <= 65535 ->
          Right (RpcAddress (reverse revHost) port)
    _ -> Left ("expected HOST:PORT, got " <> show raw)

toGrpcServer :: RpcEndpoint -> Server
toGrpcServer = \case
  RpcUnixSocket path -> ServerUnix path
  -- No authority: there is no TLS name to check against.
  RpcAddress host port -> ServerInsecure (Address host (fromIntegral port) Nothing)

-- | Connection parameters, almost entirely to raise the HTTP/2 windows.
--
-- This is the counterpart of ChainSync's @maxInFlight@, but bounded in bytes
-- rather than blocks. grapesy defaults to 256KiB per stream, which is small
-- against a mainnet block — and today every block also carries a parsed copy
-- sieve discards, since the server ignores @field_mask@
-- (IntersectMBO/cardano-api#1273). Too small means a WINDOW_UPDATE round trip
-- per block during catch-up.
--
-- 8MiB is roughly 50 blocks, picked to match ChainSync's depth rather than from
-- measurement: sweep this first if throughput disappoints. Connection window
-- must be >= stream window or the two deadlock.
rpcConnParams :: GRPC.ConnParams
rpcConnParams =
  def
    { GRPC.connHTTP2Settings =
        def
          { http2StreamWindowSize = 8 * 1024 * 1024
          , http2ConnectionWindowSize = 16 * 1024 * 1024
          }
    }
