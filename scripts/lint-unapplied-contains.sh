#!/usr/bin/env bash
# Lint: never pass `.contains` as an unapplied method reference in app Swift code.
#
# Swift 6.4 (Xcode 27) miscompiles `x.unicodeScalars.contains(where: CharacterSet.newlines.contains)`
# and `allSatisfy(allowed.contains)` under -O when one file references the `contains` of two
# different CharacterSets: one reference silently uses the other set. Debug builds and the unit
# tests (-Onone) are correct, so only the Release app breaks. In UniConnect 9f99c015f the SSH
# command validator then rejected every saved connection as `lineBreak` and every SSH window came
# back disconnected. Write the closure instead: `contains(where: { set.contains($0) })`.
#
# Usage:
#   ./scripts/lint-unapplied-contains.sh [--repo-root <path>]
#
# Exit codes:
#   0 — no unapplied `.contains` references
#   1 — at least one reference found (listed on stderr)
#   2 — invocation error

set -euo pipefail

REPO_ROOT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '1,17p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT"

# Test targets run at -Onone and may keep the terse form.
matches="$(
  git ls-files -z -- '*.swift' ':!:cmuxTests/**' ':!:cmuxUITests/**' ':!:**/Tests/**' \
    | xargs -0 grep -HnE '[A-Za-z0-9_)]\.contains[[:space:]]*($|[]),;])' 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true
)"

if [ -n "$matches" ]; then
  echo "Unapplied .contains method references (miscompiled by Swift 6.4 at -O); write a closure:" >&2
  echo "$matches" >&2
  exit 1
fi
echo "OK: no unapplied .contains method references"
