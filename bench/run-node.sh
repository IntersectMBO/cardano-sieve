#!/usr/bin/env bash
#
# Provision (if needed) and launch the preview cardano-node that the benchmark
# scripts replay from. Zero-config on a fresh machine: downloads the node
# release bundle (binaries + matching preview config), bootstraps the DB from
# a Mithril snapshot when none exists, then runs the node. Re-runs reuse
# everything already on disk.
#
# Defaults (override via env):
#   NODE_VERSION   11.0.1                 cardano-node release to fetch
#   BIN_ROOT       ~/cardano-bin          bundle root -> $BIN_ROOT/$NODE_VERSION
#   NODE_BIN       $BIN_ROOT/$NODE_VERSION/bin/cardano-node
#   NODE_CONFIG    $BIN_ROOT/$NODE_VERSION/share/preview/config.json
#   TOPOLOGY       <NODE_CONFIG dir>/topology.json
#   DB_DIR         ~/preview.db
#   NODE_SOCKET    ~/node.socket           (same var the bench scripts read)
#   NODE_PORT      3000
#   TESTNET_MAGIC  2                       informational; the bundle is preview
#   SKIP_MITHRIL   0                       1 = sync from genesis instead
#   MITHRIL_VERSION 2617.0
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-11.0.1}"
BIN_ROOT="${BIN_ROOT:-$HOME/cardano-bin}"
BIN_DIR="$BIN_ROOT/$NODE_VERSION"
NODE_BIN="${NODE_BIN:-$BIN_DIR/bin/cardano-node}"
NODE_CONFIG="${NODE_CONFIG:-$BIN_DIR/share/preview/config.json}"
DB_DIR="${DB_DIR:-$HOME/preview.db}"
NODE_SOCKET="${NODE_SOCKET:-$HOME/node.socket}"
NODE_PORT="${NODE_PORT:-3000}"
TESTNET_MAGIC="${TESTNET_MAGIC:-2}"
SKIP_MITHRIL="${SKIP_MITHRIL:-0}"
MITHRIL_VERSION="${MITHRIL_VERSION:-2617.0}"
MITHRIL_DIR="$BIN_ROOT/mithril-$MITHRIL_VERSION"
MITHRIL_BIN="$MITHRIL_DIR/mithril-client"
MITHRIL_AGGREGATOR="${MITHRIL_AGGREGATOR:-https://aggregator.pre-release-preview.api.mithril.network/aggregator}"
MITHRIL_KEYS="https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/pre-release-preview"

die() { echo "FATAL: $*" >&2; exit 1; }
log() { echo "==> $*"; }
for t in curl tar; do command -v "$t" >/dev/null || die "need $t on PATH"; done

# ---- node bundle: binaries + share/preview config in one tarball -------------
if [ ! -x "$NODE_BIN" ] || [ ! -f "$NODE_CONFIG" ]; then
  tarball="cardano-node-${NODE_VERSION}-linux-amd64.tar.gz"
  log "fetching cardano-node $NODE_VERSION bundle into $BIN_DIR"
  mkdir -p "$BIN_DIR"
  tmp="$(mktemp -t "$tarball.XXXXXX")"
  curl -fL --progress-bar -o "$tmp" \
    "https://github.com/IntersectMBO/cardano-node/releases/download/${NODE_VERSION}/${tarball}"
  tar -xzf "$tmp" -C "$BIN_DIR"; rm -f "$tmp"
fi
[ -x "$NODE_BIN" ]   || die "cardano-node still not at $NODE_BIN after fetch"
[ -f "$NODE_CONFIG" ] || die "preview config still not at $NODE_CONFIG after fetch"
CONFIG_DIR="$(cd "$(dirname "$NODE_CONFIG")" && pwd)"
TOPOLOGY="${TOPOLOGY:-$CONFIG_DIR/topology.json}"
[ -f "$TOPOLOGY" ] || die "topology missing at $TOPOLOGY"
log "node: $("$NODE_BIN" --version | head -1)"

# ---- DB: bootstrap from Mithril when empty -----------------------------------
if [ ! -d "$DB_DIR/immutable" ]; then
  if [ "$SKIP_MITHRIL" = 1 ]; then
    log "no DB at $DB_DIR and SKIP_MITHRIL=1: syncing from genesis (slow)"
  else
    log "no DB at $DB_DIR: bootstrapping from a Mithril snapshot"
    if [ ! -x "$MITHRIL_BIN" ]; then
      mtar="mithril-${MITHRIL_VERSION}-linux-x64.tar.gz"
      log "fetching mithril-client $MITHRIL_VERSION into $MITHRIL_DIR"
      mkdir -p "$MITHRIL_DIR"
      tmp="$(mktemp -t "$mtar.XXXXXX")"
      curl -fL --progress-bar -o "$tmp" \
        "https://github.com/input-output-hk/mithril/releases/download/${MITHRIL_VERSION}/${mtar}"
      tar -xzf "$tmp" -C "$MITHRIL_DIR"; rm -f "$tmp"
    fi
    gkey="$(curl -fsSL "$MITHRIL_KEYS/genesis.vkey")"
    akey="$(curl -fsSL "$MITHRIL_KEYS/ancillary.vkey")"
    dl="$(mktemp -d -p "$(dirname "$DB_DIR")" mithril-dl-XXXXXX)"
    trap 'rm -rf "$dl"' EXIT
    # --include-ancillary brings the ledger snapshot so the node needn't replay
    # from genesis to rebuild it.
    "$MITHRIL_BIN" cardano-db download latest \
      --aggregator-endpoint "$MITHRIL_AGGREGATOR" \
      --genesis-verification-key "$gkey" \
      --include-ancillary --ancillary-verification-key "$akey" \
      --download-dir "$dl"
    if   [ -d "$dl/db/immutable" ]; then src="$dl/db"
    elif [ -d "$dl/immutable" ];    then src="$dl"
    else ls -la "$dl" >&2; die "unrecognised mithril output layout in $dl"; fi
    mkdir -p "$DB_DIR"; mv "$src"/* "$DB_DIR/"
    log "snapshot restored to $DB_DIR"
  fi
fi
mkdir -p "$DB_DIR"

# ---- don't clobber a node already running on this socket --------------------
if [ -S "$NODE_SOCKET" ]; then
  if pgrep -af "cardano-node.*$NODE_SOCKET" >/dev/null 2>&1; then
    pgrep -af "cardano-node.*$NODE_SOCKET" | sed 's/^/    /' >&2
    die "a cardano-node already serves $NODE_SOCKET — stop it with: pkill -f \"cardano-node.*$NODE_SOCKET\""
  fi
  log "removing stale socket $NODE_SOCKET"; rm -f "$NODE_SOCKET"
fi

log "starting cardano-node (preview, testnet-magic $TESTNET_MAGIC)"
echo "    db:     $DB_DIR"
echo "    socket: $NODE_SOCKET"
echo "    config: $NODE_CONFIG"
echo "    watch:  $BIN_DIR/bin/cardano-cli query tip --socket-path $NODE_SOCKET --testnet-magic $TESTNET_MAGIC"
echo ""
exec "$NODE_BIN" run \
  --port "$NODE_PORT" \
  --database-path "$DB_DIR" \
  --topology "$TOPOLOGY" \
  --config "$NODE_CONFIG" \
  --socket-path "$NODE_SOCKET" \
  +RTS -T -I0 -N2 -A16m -qb -qg --disable-delayed-os-memory-return -RTS
