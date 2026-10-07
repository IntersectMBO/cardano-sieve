# Benchmarks

How cardano-sieve performs on a bulk sync, measured alongside other Cardano
chain indexers doing the same job, one reference indexer per section. Every
reference indexes every output over the same fixed range from the same local
node as sieve, in the same session, and is reported only when a correctness
gate shows the two indexed identical data.

References so far:

1. [kupo](#reference-kupo)

Every number in this document is copied from a `RESULTS.md` under
`bench/results/`, produced by the scripts in `bench/`; the raw per-run logs
are alongside it. Numbers from any other source do not belong here.

## What is measured

One bounded, cold-start sync per run, from an empty database to `--until`,
repeated `RUNS` times per tool, sieve and the reference alternating, median
reported.

| column | meaning |
|---|---|
| sync wall | seconds from start to the last block of the range indexed |
| sync CPU | user+system seconds across all threads of the process |
| CPU % | sync CPU / sync wall; above 100 means more than one core busy |
| peak RSS | kernel high-water mark of resident memory (VmHWM), MiB |
| db | on-disk database size including any sidecar files, MiB, after sieve's index build |

Sieve defers secondary indexes during ingest by design; its index build is
timed separately (`derive`) and folded into time-to-queryable. Each reference
section states how that indexer was configured to match, and what could not
be matched.

**Correctness gate.** A run is reported only if sieve and the reference indexed
the same data: identical counts of outputs ever created, unspent outputs, and
distinct (output, policy) pairs.

## Reference: kupo

[kupo](https://github.com/CardanoSolutions/kupo) is a pattern-matched
UTxO indexer with an HTTP API and an embedded SQLite database, the closest
existing tool to sieve in scope and deployment shape. Run of 2026-09-18:
[`bench/results/20260918T150204Z/RESULTS.md`](bench/results/20260918T150204Z/RESULTS.md).

Both tools defer secondary indexes during ingest (kupo via `--defer-db-indexes`),
so `sync wall` / `sync CPU` is the like-for-like pair. Kupo's own index build
fires only at its real chain tip and is not measurable in a bounded replay, so
time-to-queryable is pessimistic for sieve. Neither tool prunes.

### Setup

| | |
|---|---|
| network | preview (`--testnet-magic 2`) |
| range | origin to slot 4,000,000, selector `*` |
| runs | 5 per tool per configuration, median |
| sieve | 0.1.0.0, source identical to `master` at `b02828e599b0` (this branch changes only scripts and docs; `provenance.txt` records the pre-squash harness commit) |
| kupo | 2.11.0.1, `2a8d635216ef` (branch `setup-for-hydra`, builds against node 11) |
| cardano-node | 11.0.1; cardano-cli 11.2.3.0 |
| GHC | 9.8.4 for both tools |
| CPU | Intel i7-1260P (4 performance + 8 efficiency cores, 16 threads visible) |
| RAM | 62 GiB |
| disk | NVMe SSD |
| kernel / virtualisation | Linux 6.18.7, bare metal |
| load average | 2.72 at start, 2.77 at end (the node and an editor were running) |
| date | 2026-09-18 |

Both tools run as shipped in the first table: sieve with one capability
(ADR-020), kupo with its cabal-file RTS `-N -A16m -qb -qg`, one capability per
visible core. Kupo publishes no RTS guidance; its README asks for 2+ cores and
256 MB to 2 GB of RAM. Kupo's peak RSS grows with `-N`, so a second table runs
it at `-N2`, the minimum hardware it documents, to show the result on a box
that meets its stated requirements rather than only on a many-core host.

### Results

#### kupo as shipped (compiled-in `-N -A16m -qb -qg`, one capability per core)

Correctness gate: passed. outputs 1,627,464 = 1,627,464; unspent 386,569 =
386,569; (output, policy) pairs 1,852,726 = 1,852,726.

| tool | sync wall (s) | sync CPU (s) | CPU % | derive (s) | time-to-queryable (s) | peak RSS (MiB) | db (MiB) |
|---|---|---|---|---|---|---|---|
| sieve | 104.6 | 110.9 | 106% | 10.6 | 115.2 | 124 | 1097 |
| kupo | 142.8 | 121.9 | 85% | - | 142.8 | 454 | 922 |

Per-run spread: sieve wall 102.6 to 106.5 s, RSS 120 to 127 MiB; kupo wall
139.6 to 143.7 s, RSS 435 to 466 MiB.

#### kupo at `-N2` (its documented minimum: README says 2+ cores)

Correctness gate: passed, same counts as above.

| tool | sync wall (s) | sync CPU (s) | CPU % | derive (s) | time-to-queryable (s) | peak RSS (MiB) | db (MiB) |
|---|---|---|---|---|---|---|---|
| sieve | 105.8 | 111.3 | 105% | 10.8 | 116.5 | 124 | 1097 |
| kupo | 131.4 | 131.8 | 100% | - | 131.4 | 453 | 922 |

Per-run spread: sieve wall 104.7 to 106.9 s, RSS 122 to 129 MiB; kupo wall
128.4 to 133.5 s, RSS 430 to 480 MiB.

#### Reading

Medians of five. **Lower is better in every row.** Each session ran sieve and
kupo alternately, so sieve has its own medians per session; each pair below is
sieve and the kupo it ran alongside.

| dimension | session 1: sieve | kupo as shipped | session 2: sieve | kupo `-N2` | sieve relative to kupo (session 1 / 2) |
|---|---|---|---|---|---|
| peak memory | 124 MiB | 454 MiB | 124 MiB | 453 MiB | **73% less memory**, about a third of kupo's |
| sync wall | 104.6 s | 142.8 s | 105.8 s | 131.4 s | **27% / 19% less time** to index the range |
| sync CPU | 110.9 s | 121.9 s | 111.3 s | 131.8 s | **9% / 16% fewer CPU-seconds** |
| time-to-queryable | 115.2 s | 142.8 s | 116.5 s | 131.4 s | **19% / 11% less time**, even after building its indexes |
| disk | 1097 MiB | 922 MiB | 1097 MiB | 922 MiB | **19% more disk** |

The `-N2` session answers whether kupo's memory is a thread-count artefact:
it is not. Kupo's peak RSS was 454 MiB with 16 capabilities and 453 MiB with
two. Sieve's two sessions agree within 1% on every column, which is the
repeatability check. Kupo was faster at `-N2` than
with 16 capabilities, and used less than one core on average as shipped, so
its wall time is not limited by parallelism.

Disk is where sieve's footprint is the larger. Sieve stores each output's
value as JSON and keeps append-only spend history; both are known,
unexploited levers.

### Not measured against kupo

- **Query latency.** Earlier comparisons exist but a fair one needs both
  servers on checkpointed databases and identical response shapes; not yet
  published.
- **Steady-state following at tip.** Only bounded historical replay is measured.

### Reproduce

Requirements: `cardano-cli`, GNU `time`, `curl`, `jq`, `sqlite3`, and kupo
checked out at `~/repos/kupo` on a branch that builds against the same node
stack. The node itself is provisioned by the launcher: on a fresh machine it
downloads the release bundle and bootstraps the preview DB from a Mithril
snapshot, then runs.

```bash
bench/run-node.sh            # leave running; wait for syncProgress 100.00
# quiet box: no builds, no desktop load, node at tip; the script refuses otherwise
bench/run-published-bench.sh
# or a shorter range for a smoke run
UNTIL_SLOT=2000000 RUNS=3 bench/run-published-bench.sh
```

Output lands in `bench/results/<UTC stamp>/` with the raw logs, a
`provenance.txt`, and a `RESULTS.md` whose tables are pasted here verbatim.

Known sources of noise, all observed on the reference box: page-cache warming
(one discarded warm-up run), a node still syncing, concurrent GHC builds, and
desktop load. Absolute numbers move by tens of percent between days on the
same machine; only ratios within one interleaved run are meaningful.
