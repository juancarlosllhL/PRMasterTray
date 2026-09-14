#!/usr/bin/env bash
# TAG comes from the environment because a tag name may contain backticks.
set -euo pipefail

file="${CHANGELOG:-Resources/CHANGELOG.md}"
version="${TAG#v}"

[ -n "$version" ] || { echo "TAG is not set" >&2; exit 1; }
[ -f "$file" ] || { echo "no changelog at $file" >&2; exit 1; }

awk -v want="$version" '
  /^## / {
    heading = $2
    sub(/^v/, "", heading)
    inside = (heading == want)
    next
  }
  inside { print }
' "$file" | awk 'NF { seen = 1 } seen'
