#!/usr/bin/env bash
# The installer keeps a copy of the replaced UniConnect.app (about 330 MB) for a rollback. Only
# the newest copies may stay: 25 installs left 4 GB behind that nothing ever removed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRUNE="$SCRIPT_DIR/prune-uniconnect-install-backups.sh"
FIXTURE_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/uniconnect-install-backups-test.XXXXXX")"
trap '/bin/rm -rf -- "$FIXTURE_ROOT"' EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }

ROOT="$FIXTURE_ROOT/install"
for stamp in 20260904T203725Z 20260905T103603Z 20260906T111907Z 20260924T205420Z 20260925T210702Z; do
  /bin/mkdir -p "$ROOT/$stamp/UniConnect.app/Contents"
  echo "$stamp" > "$ROOT/$stamp/UniConnect.app/Contents/Info.plist"
done
/bin/mkdir -p "$ROOT/notas-de-dani"
echo "no es una copia" > "$ROOT/LEEME.txt"

output="$("$PRUNE" "$ROOT" 2)" || fail "pruning failed: $output"
[[ "$output" == *"removed=3"* ]] || fail "expected three copies removed, got: $output"
kept="$(/bin/ls -1 "$ROOT" | /usr/bin/tr '\n' ' ')"
[[ "$kept" == "20260924T205420Z 20260925T210702Z LEEME.txt notas-de-dani " ]] \
  || fail "the two newest copies and anything that is not a copy must stay, got: $kept"

"$PRUNE" "$ROOT" 2 >/dev/null || fail "pruning again must be harmless"
[[ "$(/bin/ls -1 "$ROOT" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "4" ]] || fail "pruning again removed something"

"$PRUNE" "$FIXTURE_ROOT/no-existe" 2 >/dev/null || fail "a missing folder is not an error"

if "$PRUNE" "$ROOT" 0 >/dev/null 2>&1; then fail "keeping zero copies would leave no rollback"; fi

echo "PASS: prune-uniconnect-install-backups"
