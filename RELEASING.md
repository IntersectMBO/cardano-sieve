# Releasing cardano-sieve

cardano-sieve follows the cardano-api release process, driven by
[herald](https://github.com/input-output-hk/cardano-dev/tree/main/herald),
minus the CHaP upload (cardano-sieve is an executable, not a library). The
binaries are then built and published by CI from the release tag.

## Versioning

Haskell [PVP](https://pvp.haskell.org/): `A.B.C.D`. Herald computes the bump
from the changelog fragments' kinds (see `.herald.yml`): `breaking` bumps `B`,
`feature`/`compatible` bump `C`, everything else bumps `D`. The git tag is
`cardano-sieve-A.B.C.D`.

## Every pull request: add a changelog fragment

Each PR commits a small YAML file under `.changes/` describing the change.
The **Check changelog fragments** workflow fails the PR otherwise.

```bash
nix run github:input-output-hk/cardano-dev/herald-0.2.0.0#herald -- new
```

Or copy `.changes/_TEMPLATE.yml`. Set `pr:` to the PR number.

## Cutting a release

1. Run the **Release** workflow
   (Actions > Release > Run workflow, or from the CLI):

   ```bash
   gh workflow run release.yml
   # or with an explicit version:
   gh workflow run release.yml -f version=0.1.0.0
   ```

   It creates a `release/cardano-sieve-A.B.C.D` branch that batches the
   fragments into `CHANGELOG.md`, bumps `version:` in `cardano-sieve.cabal`,
   removes the consumed fragments, and opens a release PR. The PR body
   contains the exact signing commands for the next step.

2. Review the release PR: it should contain only the changelog section, the
   version bump, and the removed fragments.

3. Sign and tag, following the commands in the PR body. In short:

   ```bash
   git fetch origin release/cardano-sieve-A.B.C.D
   git checkout -B release/cardano-sieve-A.B.C.D origin/release/cardano-sieve-A.B.C.D
   git rebase --force-rebase --gpg-sign HEAD~2
   git tag -s -m "cardano-sieve A.B.C.D" cardano-sieve-A.B.C.D HEAD~1
   git push --force origin release/cardano-sieve-A.B.C.D
   git push origin cardano-sieve-A.B.C.D
   ```

4. The tag push runs the **Build** workflow (it runs only on release tags, or
   by hand as a dry run), which builds the static binaries,
   checks that `cardano-sieve --version` matches the tag, and publishes the
   GitHub Release at
   <https://github.com/IntersectMBO/cardano-sieve/releases> with:

   - `cardano-sieve-A.B.C.D-x86_64-linux.tar.gz`
   - `cardano-sieve-A.B.C.D-aarch64-linux.tar.gz`
   - `cardano-sieve-A.B.C.D-sha256sums.txt`

   and the matching `CHANGELOG.md` section as release notes.

5. Merge the release PR.

## Building a release binary locally

CI gets the toolchain as a prebuilt closure from `ghcr.io/input-output-hk/devx`
(via `input-output-hk/actions/devx`). Locally the same shell comes from the devx
flake; note the IOG binary cache does not always carry every musl library for
the current devx revision, so the first entry may compile a few C libraries:

```bash
nix develop github:input-output-hk/devx#ghc98-static-minimal-iog --no-write-lock-file \
  --command bash -c '
    echo "$CABAL_PROJECT_LOCAL_TEMPLATE" > cabal.project.release.local
    cabal --project-file=cabal.project.release update
    cabal --project-file=cabal.project.release --builddir=dist-static build cardano-sieve:exe:cardano-sieve -j4'
file "$(cabal --project-file=cabal.project.release --builddir=dist-static list-bin cardano-sieve)"
```

`cabal.project.release` imports `cabal.project` and adds the flags that make a
static musl link work (`text -simdutf`, `formatting +no-double-conversion`,
`blockio +serialblockio`).
