#!/usr/bin/env bash
# Print the CHANGELOG.md section for one version, without its heading.
# The changelog is written by herald, whose section headings look like
#   ## 0.1.0.0 -- 2026-09-10
#
#   scripts/ci/extract-changelog.sh 0.1.0.0
#
# Exits non-zero (with no output) when the section is missing or empty, so a
# release cannot be cut before the changelog has been batched.
set -euo pipefail

version="${1:?usage: extract-changelog.sh VERSION}"
changelog="${2:-CHANGELOG.md}"

body=$(awk -v v="$version" '
  /^## / { if (found) exit; found = ($0 ~ "^## " v "( |$)"); next }
  found { print }
' "$changelog")

# Trim leading/trailing blank lines.
body=$(printf '%s\n' "$body" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | sed '/./,$!d')

if [[ -z "$body" ]]; then
  echo "extract-changelog.sh: no changelog entry for version $version in $changelog" >&2
  exit 1
fi

printf '%s\n' "$body"
