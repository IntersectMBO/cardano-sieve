# Changelog for cardano-sieve
## 0.1.0.0 -- 2026-09-10

- Initial release. A pattern-filtered chain index for Cardano: follows a local node over node-to-client chain-sync from Byron onwards, indexes matching outputs, spends, datums, scripts and (opt-in) redeemers into SQLite, and serves the HTTP query API (/matches, /datums, /scripts, /checkpoints, /patterns, /health, /metrics, /metadata) from the same process or read-only from an existing database. Static Linux binaries for x86_64 and aarch64 are published on every release tag.
  (feature)
  [PR 7](https://github.com/IntersectMBO/cardano-sieve/pull/7)

