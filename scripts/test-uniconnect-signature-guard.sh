#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGNING_IDENTITY="${UNICONNECT_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>&1 \
    | /usr/bin/awk '/"Apple Development:/ {print $2; exit}')"
fi
[[ -n "$SIGNING_IDENTITY" ]] || { echo "SKIP: no Apple Development identity"; exit 0; }

FIXTURE_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/uniconnect-signature-test.XXXXXX")"
trap '/bin/rm -rf -- "$FIXTURE_ROOT"' EXIT INT TERM

make_app() {
  local path="$1"
  local identifier="$2"
  /bin/mkdir -p "$path/Contents/MacOS"
  /bin/cp /usr/bin/true "$path/Contents/MacOS/UniConnect"
  /usr/bin/plutil -create xml1 "$path/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$identifier" "$path/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string UniConnect "$path/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$path/Contents/Info.plist"
}

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    echo "FAIL: command unexpectedly succeeded: $*" >&2
    exit 1
  fi
  [[ "$output" == *"$expected"* ]] || {
    echo "FAIL: expected $expected, got: $output" >&2
    exit 1
  }
}

STABLE_APP="$FIXTURE_ROOT/stable.app"
make_app "$STABLE_APP" com.unixcision.uniconnect
/usr/bin/codesign --force --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$STABLE_APP" >/dev/null
"$SCRIPT_DIR/verify-uniconnect-signature.sh" "$STABLE_APP" >/dev/null
"$SCRIPT_DIR/verify-uniconnect-signature.sh" "$STABLE_APP" --installed "$STABLE_APP" >/dev/null

ADHOC_APP="$FIXTURE_ROOT/adhoc.app"
make_app "$ADHOC_APP" com.unixcision.uniconnect
/usr/bin/codesign --force --timestamp=none --sign - "$ADHOC_APP" >/dev/null
expect_failure REJECT_CANDIDATE_ADHOC "$SCRIPT_DIR/verify-uniconnect-signature.sh" "$ADHOC_APP"
expect_failure REJECT_INSTALLED_ADHOC "$SCRIPT_DIR/verify-uniconnect-signature.sh" "$STABLE_APP" --installed "$ADHOC_APP"
"$SCRIPT_DIR/verify-uniconnect-signature.sh" \
  "$STABLE_APP" \
  --installed "$ADHOC_APP" \
  --allow-one-time-adhoc-migration >/dev/null

WRONG_ID_APP="$FIXTURE_ROOT/wrong-id.app"
make_app "$WRONG_ID_APP" com.example.not-uniconnect
/usr/bin/codesign --force --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$WRONG_ID_APP" >/dev/null
expect_failure REJECT_CANDIDATE_IDENTIFIER "$SCRIPT_DIR/verify-uniconnect-signature.sh" "$WRONG_ID_APP"

TAMPERED_APP="$FIXTURE_ROOT/tampered.app"
/usr/bin/ditto "$STABLE_APP" "$TAMPERED_APP"
/usr/bin/touch "$TAMPERED_APP/Contents/modified-after-signing"
expect_failure REJECT_CANDIDATE_INVALID "$SCRIPT_DIR/verify-uniconnect-signature.sh" "$TAMPERED_APP"

INVALID_INSTALLED_APP="$FIXTURE_ROOT/invalid-installed.app"
/usr/bin/ditto "$STABLE_APP" "$INVALID_INSTALLED_APP"
/usr/bin/touch "$INVALID_INSTALLED_APP/Contents/modified-after-signing"
expect_failure REJECT_INSTALLED_INVALID \
  "$SCRIPT_DIR/verify-uniconnect-signature.sh" "$STABLE_APP" --installed "$INVALID_INSTALLED_APP"
"$SCRIPT_DIR/verify-uniconnect-signature.sh" \
  "$STABLE_APP" \
  --installed "$INVALID_INSTALLED_APP" \
  --allow-one-time-adhoc-migration >/dev/null

echo "PASS: stable continuity, ad-hoc/invalid migration, identifier, and tamper guards"
