#!/usr/bin/env bash
#
# Produce a sync benchmark result fit to publish in BENCHMARKS.md.
#
# In order:
#   1. Refuse unless the machine is fit to benchmark
#      (node at tip, low load, no compiler running).
#   2. Build sieve and kupo, so we know exactly which code ran.
#   3. Write provenance.txt: commits, versions, hardware.
#   4. Run bench/run-sync-bench.sh once per kupo RTS setting. Every run
#      benchmarks BOTH tools, interleaved; sieve ships with a fixed RTS
#      (one capability, ADR-020) so only kupo's setting is varied.
#   5. Collect the result tables into RESULTS.md.
#
# Everything lands in bench/results/<UTC timestamp>/.
#
# Knobs (all optional, set as env vars):
#   UNTIL_SLOT        last slot of the range      default 4000000
#   RUNS              timed runs per tool         default 5
#   COOLDOWN          idle seconds before a run   default 30
#   KUPO_RTS_CONFIGS  kupo RTS settings to test   default "default -N2"
#                     "default" = kupo as shipped: its cabal file bakes in
#                     -with-rtsopts=-N -A16m -qb -qg (one capability per core).
#                     -N2 = kupo's documented minimum (README: "CPU 2+ cores"),
#                     so the second table is kupo on the hardware it asks for.
#   MAX_LOAD          refuse if 1-min load >= this default 1
#   FORCE=1           turn refusals into warnings
#   GHC               compiler for BOTH builds     default ghc-9.8.4
#                     (sieve's tested-with; kupo builds with it too)
#
# Example smoke run:  UNTIL_SLOT=2000000 RUNS=3 bench/run-published-bench.sh
set -euo pipefail

# ---------------------------------------------------------------- settings ----
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUPO_REPO="${KUPO_REPO:-$HOME/repos/kupo}"
NODE_SOCKET="${NODE_SOCKET:-$HOME/node.socket}"
TESTNET_MAGIC="${TESTNET_MAGIC:-2}"
KUPO_RTS_CONFIGS="${KUPO_RTS_CONFIGS:-default -N2}"
MAX_LOAD="${MAX_LOAD:-1}"
FORCE="${FORCE:-0}"
GHC="${GHC:-ghc-9.8.4}"

# These three are read by run-sync-bench.sh, so export them.
export UNTIL_SLOT="${UNTIL_SLOT:-4000000}"
export RUNS="${RUNS:-5}"
export COOLDOWN="${COOLDOWN:-30}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$REPO_ROOT/bench/results/$STAMP"
mkdir -p "$OUT"

say() { echo "[publish] $*"; }

# refuse <message>: stop the script, unless FORCE=1 in which case only warn.
refuse() {
  echo "REFUSED: $*" >&2
  if [ "$FORCE" = 1 ]; then echo "  (FORCE=1, carrying on)" >&2; return 0; fi
  exit 1
}

# ------------------------------------------------- 1. is the box fit to run? ----
# The node must be at the real chain tip. cardano-cli's syncProgress compares
# the tip slot to the wall clock, so 100.00 means "caught up", not merely
# "past UNTIL_SLOT". A still-syncing node competes for CPU and disk and
# invalidated a whole run once.
tip_json="$(cardano-cli query tip --socket-path "$NODE_SOCKET" --testnet-magic "$TESTNET_MAGIC")" \
  || refuse "node did not answer 'query tip' on $NODE_SOCKET"
tip_slot="$(echo "$tip_json" | jq -r .slot)"
sync_pct="$(echo "$tip_json" | jq -r .syncProgress)"
[ "$sync_pct" = "100.00" ] || refuse "node syncProgress is $sync_pct, not 100.00 (slot $tip_slot)"
say "node at tip: slot $tip_slot"

# 1-minute load average. Compare only the integer part: 0.9 passes, 1.2 fails.
# /proc/loadavg is "1min 5min 15min running/total last-pid"; keep the three averages.
loadavg_at_gate="$(cut -d' ' -f1-3 /proc/loadavg)"
load1="${loadavg_at_gate%% *}"
[ "${load1%%.*}" -lt "$MAX_LOAD" ] || refuse "load average is $load1, wanted below $MAX_LOAD"
say "load average $load1"

# No compiler running. -x matches the process name exactly (ghc may be ghc-9.8.4).
if pgrep -x 'cabal|ghc(-[0-9.]+)?|ghcid' >/dev/null; then
  refuse "a cabal/ghc process is running; finish or kill builds first"
fi

# ------------------------------------------------------- 2. build both tools ----
# Same compiler for both tools, chosen here rather than by whatever `ghc`
# happens to be first on PATH. -w is cabal's --with-compiler.
command -v "$GHC" >/dev/null || refuse "$GHC not on PATH (ghcup install ghc 9.8.4, or set GHC=)"
say "building sieve and kupo with $GHC"
(cd "$REPO_ROOT" && cabal build -w "$GHC" exe:cardano-sieve -j4)
(cd "$KUPO_REPO"  && cabal build -w "$GHC" exe:kupo -j4)
# Hand the binaries to run-sync-bench.sh and tell it not to build again.
# list-bin needs the same -w to find the right dist-newstyle path.
export BUILD=0
export SIEVE_BIN; SIEVE_BIN="$(cd "$REPO_ROOT" && cabal list-bin -w "$GHC" exe:cardano-sieve)"
export KUPO_BIN;  KUPO_BIN="$(cd "$KUPO_REPO"  && cabal list-bin -w "$GHC" exe:kupo)"

# ----------------------------------------------------------- 3. provenance ----
# commit <dir>: short hash, "-dirty" if tracked files are modified, branch.
commit() {
  local hash dirty branch
  hash="$(git -C "$1" rev-parse --short=12 HEAD)"
  dirty=""; [ -z "$(git -C "$1" status --porcelain --untracked-files=no)" ] || dirty="-dirty"
  branch="$(git -C "$1" rev-parse --abbrev-ref HEAD)"
  echo "$hash$dirty ($branch)"
}

# Version of the node that is actually serving the socket: find its pid,
# follow /proc/<pid>/exe to the binary, ask it.
node_version="unknown"
node_pid="$(pgrep -x cardano-node | head -1 || true)"
if [ -n "$node_pid" ]; then
  node_version="$("$(readlink -f "/proc/$node_pid/exe")" --version | head -1)"
fi

# Is the root filesystem on a spinning disk (1) or SSD (0)?
root_dev="$(findmnt -n -o SOURCE / | sed 's/\[.*//')"
root_rota="$(lsblk -n -d -o ROTA "$root_dev" 2>/dev/null | tr -d ' ' || echo '?')"

{
  echo "date_utc:        $STAMP"
  echo "network:         testnet-magic $TESTNET_MAGIC"
  echo "range:           origin..$UNTIL_SLOT (selector: everything)"
  echo "runs:            $RUNS per tool per config, interleaved, median; cooldown ${COOLDOWN}s"
  echo "kupo_rts:        $KUPO_RTS_CONFIGS"
  echo "sieve:           $(commit "$REPO_ROOT")"
  echo "kupo:            $(commit "$KUPO_REPO")"
  echo "cardano-node:    $node_version"
  echo "cardano-cli:     $(cardano-cli --version | head -1)"
  echo "ghc:             $("$GHC" --numeric-version) ($GHC)"
  echo "node_tip_slot:   $tip_slot"
  echo "cpu:             $(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
  echo "cores_visible:   $(nproc)"
  echo "ram:             $(free -g | awk '/^Mem:/ {print $2 " GiB"}')"
  echo "root_disk:       $root_dev (rotational=$root_rota)"
  echo "kernel:          $(uname -r)"
  echo "virtualisation:  $(systemd-detect-virt || true)"
  echo "loadavg_start:   $loadavg_at_gate   (1/5/15 min averages, read before the builds)"
} | tee "$OUT/provenance.txt"

# ------------------------------------------- 4. run the sync bench per config ----
# tag_of <config>: a filename-safe name ("-N1" -> "N1", "default" -> "default").
tag_of() { echo "${1#-}"; }

# elapsed <start-epoch>: seconds since <start-epoch>, as "12m34s".
elapsed() { local s=$(( $(date +%s) - $1 )); echo "$((s / 60))m$((s % 60))s"; }

all_start=$(date +%s)
for cfg in $KUPO_RTS_CONFIGS; do
  if [ "$cfg" = default ]; then export KUPO_RTS=""; else export KUPO_RTS="$cfg"; fi
  say "=== sync bench, kupo RTS: $cfg ==="
  cfg_start=$(date +%s)
  "$REPO_ROOT/bench/run-sync-bench.sh" 2>&1 | tee "$OUT/sync-$(tag_of "$cfg").log"
  say "config $cfg took $(elapsed "$cfg_start")"
  echo "elapsed_$(tag_of "$cfg"): $(elapsed "$cfg_start")" >> "$OUT/provenance.txt"
done
{
  echo "elapsed_total:   $(elapsed "$all_start")"
  echo "loadavg_end:     $(cut -d' ' -f1-3 /proc/loadavg)   (1/5/15 min averages)"
} | tee -a "$OUT/provenance.txt"

# ------------------------------------------------------------ 5. RESULTS.md ----
# Each log ends with a fixed-width table:
#   tool sync_wall_s sync_cpu_s CPU% derive_s ttq_wall_s peak_RSS_MiB db_MiB
#   sieve ...
#   kupo  ...
# table_rows <log>: print the two data rows of that table as markdown.
table_rows() {
  sed 's/\x1b\[[0-9;]*m//g' "$1" |                   # strip colour codes
    awk '
      /^tool +sync_wall_s/ { in_table = 1; next }     # header seen: rows follow
      in_table && ($1 == "sieve" || $1 == "kupo") {
        printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6,$7,$8
      }'
}

{
  echo "# Sync benchmark results, $STAMP"
  echo
  echo '```'
  cat "$OUT/provenance.txt"
  echo '```'
  for cfg in $KUPO_RTS_CONFIGS; do
    logf="$OUT/sync-$(tag_of "$cfg").log"
    echo
    echo "## kupo RTS: $cfg"
    echo
    echo "Correctness gate: $(grep -o 'outputs-ever:.*' "$logf" | tail -1)"
    if grep -q 'counts differ' "$logf"; then
      echo "**WARNING: correctness gate FAILED; the tools did different work.**"
    fi
    echo
    echo "| tool | sync wall (s) | sync CPU (s) | CPU % | derive (s) | time-to-queryable (s) | peak RSS (MiB) | db (MiB) |"
    echo "|---|---|---|---|---|---|---|---|"
    table_rows "$logf"
  done
} > "$OUT/RESULTS.md"

say "done: $OUT/RESULTS.md"
