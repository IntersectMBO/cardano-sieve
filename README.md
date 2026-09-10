# cardano-sieve

A pattern-filtered chain index for Cardano: given a set of patterns, it
tracks every matching UTxO — when it was created, when it was spent, and by
what. It follows a local node over node-to-client ChainSync, writes matches
into SQLite, and serves them over an HTTP API.

## Installation

Pre-built, fully static Linux binaries are attached to every
[GitHub Release](https://github.com/IntersectMBO/cardano-sieve/releases). They
have no runtime dependencies and run on any x86_64 or aarch64 Linux distribution.

| Platform        | Asset                                         |
| --------------- | --------------------------------------------- |
| `x86_64-linux`  | `cardano-sieve-A.B.C.D-x86_64-linux.tar.gz`  |
| `aarch64-linux` | `cardano-sieve-A.B.C.D-aarch64-linux.tar.gz` |
| macOS           | build from source (see below)                 |

```bash
V=0.1.0.0; ARCH=x86_64   # or aarch64
BASE=https://github.com/IntersectMBO/cardano-sieve/releases/download/cardano-sieve-$V
curl -fLO "$BASE/cardano-sieve-$V-$ARCH-linux.tar.gz"
curl -fLO "$BASE/cardano-sieve-$V-sha256sums.txt"
sha256sum --check --ignore-missing "cardano-sieve-$V-sha256sums.txt"
tar -xzf "cardano-sieve-$V-$ARCH-linux.tar.gz"
./bin/cardano-sieve --version
```

The tarball contains `bin/cardano-sieve`, the licence, and bash/zsh completion
scripts under `share/`.

## Building

A regular dynamic build needs GHC 9.8, cabal, and the IOG crypto libraries
(libsodium, libsecp256k1, libblst) on the linker path:

```bash
cabal build exe:cardano-sieve -j4
```

The static release binary is built with the same toolchain CI uses, IOG's
[devx](https://github.com/input-output-hk/devx) shell, via
`cabal.project.release`. See [RELEASING.md](RELEASING.md) for the exact
commands and for how releases are cut.

## Usage

One executable, three modes, decided by which options you pass:

| mode | options | what it does |
|---|---|---|
| sync | `--socket-path` + `--testnet-magic` + `--database` | follow the chain and index matches |
| sync + serve | the above + `--serve PORT` | index and answer queries from the same process |
| serve only | `--database` + `--serve PORT` (no `--socket-path`) | serve an already-synced database, no node needed |

There is also `--build-indexes`, which installs the deferred query indexes on
`--database` and then exits immediately — it does nothing else.

### Indexing

```bash
cardano-sieve \
  --socket-path ~/node.socket \
  --testnet-magic 2 \
  --database sieve.sqlite \
  --select 'addr_test1...' \
  --select 'f66d78b4a3cb3d37afa0ec36461e51ecbde00f26c8f0a68f94b69880.*'
```

Options:

- `--select SELECTOR` — repeatable; an output is indexed when it matches *any*
  selector. Omit it entirely to index every output. On a restart against an
  existing database, omitting `--select` adopts whatever selectors that
  database was built with.
- `--since SLOT.HEADERHASH` — start point (default `origin`).
- `--until SLOT` — stop after this slot, inclusive (default: follow the chain
  forever).
- `--batch-size N` — commit to SQLite every N written rows (default 50000,
  tuned for bulk sync).
- `--with-redeemers` — also store the redeemer that authorised each spend
  (opt-in: redeemers are the heavy bytes on the spend path).

A sync running alone (no `--serve`) does catch-up in bulk mode — journaling
off, guarded by a dirty flag — and switches to durable commits on reaching the
tip.

**Index building:** an unbounded sync builds the query indexes automatically
when it first reaches the tip and keeps running. A bounded `--until` run
deliberately skips index building (it never reaches the tip), so you need to
build them separately afterwards — `--build-indexes` does exactly that and
then exits:

```bash
cardano-sieve --database sieve.sqlite --build-indexes
```

### Serving queries

```bash
cardano-sieve --database sieve.sqlite --serve 1442
```

Serve-only mode never touches a node: `/health` reports the connection as
disconnected, and `/metadata/{slot-no}` (which is fetched from the node on
demand, never stored) answers 503.

Adding `--serve` to a sync invocation serves both from one process. Caveat:
while catching up, queries are only as fresh as the last committed batch —
at the tip a batch can sit unflushed for a while. Prefer this mode for a
bounded `--until` run (the final commit lands on exit), or serve a synced
database separately.

### Selectors

The same grammar is used by `--select` at ingest and by `/matches/{pattern}`
at query time, so the two cannot drift:

| syntax | matches | example |
|---|---|---|
| `*` | every output (Shelley and later) | `--select '*'` |
| an address (bech32/base58/base16) | that address | `--select 'addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3jcu5d8ps7zex2k2xt3uqxgjqnnj83ws8lhrn648jjxtwq2ytjqp'` |
| `payment/delegation` | address credential parts, hex or bech32; `*` in a slot leaves it free | `--select '*/stake1u9ylzsgxaa6xctf4juup682ar3juj85n8tx3hthnljg47zctvm3rc'` |
| `policyid.name` / `policyid.*` | one asset / a whole policy | `--select 'f666d78b4a3cb3d37afa0ec36461e51ecbde00f26c8f0a68f94b69880.*'` |
| `index@txid` / `*@txid` | one output / a whole transaction | `--select '0@a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2'` |
| `{n}` | metadata tag `n` | `--select '{721}'` |

Selectors are repeatable — an output is indexed if it matches any one of them:

```bash
--select 'addr1...' --select 'f666d78b4a3cb3d37afa0ec36461e51ecbde00f26c8f0a68f94b69880.*'
```

### HTTP API

Endpoints and response shapes:

| endpoint | description | example |
|---|---|---|
| `GET /matches` / `GET /matches/{pattern}` | matching outputs; thirteen filter parameters (unspent/spent, order, slot ranges, policy, asset, tx, output index, hash resolution) | `curl 'http://localhost:1442/matches/addr1...?unspent'` |
| `DELETE /matches/{pattern}` | prune matched outputs; refused if a live selector still covers the pattern | `curl -X DELETE 'http://localhost:1442/matches/addr1...'` |
| `GET /datums/{hash}` | datum preimage for a hash | `curl 'http://localhost:1442/datums/abc123...'` |
| `GET /scripts/{hash}` | script body and language for a hash | `curl 'http://localhost:1442/scripts/abc123...'` |
| `GET /checkpoints` | stored chain points, newest first | `curl 'http://localhost:1442/checkpoints'` |
| `GET /checkpoints/{slot-no}` | point at-or-before a slot; `?strict` demands exact match | `curl 'http://localhost:1442/checkpoints/9000000'` |
| `GET /patterns` / `GET /patterns/{pattern}` | configured selectors | `curl 'http://localhost:1442/patterns'` |
| `GET /health` | JSON health object | `curl 'http://localhost:1442/health'` |
| `GET /metrics` | Prometheus exposition format | `curl 'http://localhost:1442/metrics'` |
| `GET /metadata/{slot-no}` | transaction metadata for a block, fetched from the node on demand; `?transaction_id` filters | `curl 'http://localhost:1442/metadata/9000000'` |

`PUT` and `DELETE` on `/patterns/...` return 501 — reconfiguring selectors on
a live indexer is intentionally unsupported. To change what is indexed, stop
the process and restart with different `--select`s.

Responses carry at most 100 rows; when more exist, an `X-Next-Cursor` header
is set, and passing that value back as `?after` resumes the walk:

```bash
curl -i 'http://localhost:1442/matches?unspent'
# ...
# X-Next-Cursor: 0000000000cbb1930001

curl 'http://localhost:1442/matches?unspent&after=0000000000cbb1930001'
```

The cursor is opaque — hand back exactly what the header carried. Every match
is reachable this way.

