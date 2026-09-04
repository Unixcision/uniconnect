#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <app-path> <app-entitlements> <signing-identity>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$1"
APP_ENTITLEMENTS="$2"
SIGNING_IDENTITY="$3"
HELPER_ENTITLEMENTS="${UNICONNECT_HELPER_ENTITLEMENTS:-$SCRIPT_DIR/../cmux-helper.entitlements}"

[[ -d "$APP_PATH" ]] || { echo "error: app bundle not found at $APP_PATH" >&2; exit 1; }
[[ -f "$APP_ENTITLEMENTS" ]] || { echo "error: app entitlements not found at $APP_ENTITLEMENTS" >&2; exit 1; }
[[ -f "$HELPER_ENTITLEMENTS" ]] || { echo "error: helper entitlements not found at $HELPER_ENTITLEMENTS" >&2; exit 1; }

if [[ "${UNICONNECT_TIMESTAMP:-}" == "none" ]]; then
  TIMESTAMP_FLAG=(--timestamp=none)
else
  TIMESTAMP_FLAG=(--timestamp)
fi
COMMON=(--force --options runtime "${TIMESTAMP_FLAG[@]}" --sign "$SIGNING_IDENTITY")

for helper in "$APP_PATH/Contents/Resources/bin"/*; do
  [[ -f "$helper" && -x "$helper" ]] || continue
  /usr/bin/codesign "${COMMON[@]}" --entitlements "$HELPER_ENTITLEMENTS" "$helper"
done

if [[ -d "$APP_PATH/Contents/PlugIns" ]]; then
  while IFS= read -r -d '' plugin; do
    /usr/bin/codesign "${COMMON[@]}" --deep "$plugin"
  done < <(/usr/bin/find "$APP_PATH/Contents/PlugIns" -mindepth 1 -maxdepth 1 -print0)
fi

if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
  "$SCRIPT_DIR/remove-sparkle-sandbox-xpc-services.sh" "$APP_PATH"
  while IFS= read -r -d '' framework; do
    /usr/bin/codesign "${COMMON[@]}" --deep "$framework"
  done < <(/usr/bin/find "$APP_PATH/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print0)
fi

/usr/bin/codesign "${COMMON[@]}" --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
"$SCRIPT_DIR/verify-command-palette-nucleo-ffi-artifact.sh" "$APP_PATH"
"$SCRIPT_DIR/verify-uniconnect-signature.sh" "$APP_PATH"

expected_app_id="$(
  /usr/bin/plutil -extract com.apple.application-identifier raw -o - "$APP_ENTITLEMENTS" 2>/dev/null \
    || true
)"
if [[ -n "$expected_app_id" ]]; then
  actual_app_id="$(
    /usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>/dev/null \
      | /usr/bin/plutil -extract com.apple.application-identifier raw -o - - 2>/dev/null \
      || true
  )"
  [[ "$actual_app_id" == "$expected_app_id" ]] || {
    echo "error: signed app is missing its expected application identifier" >&2
    exit 1
  }
fi

expected_webauthn="$(
  /usr/bin/plutil -extract com.apple.developer.web-browser.public-key-credential raw -o - \
    "$APP_ENTITLEMENTS" 2>/dev/null || true
)"
if [[ "$expected_webauthn" == "true" ]]; then
  actual_webauthn="$(
    /usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>/dev/null \
      | /usr/bin/plutil -extract com.apple.developer.web-browser.public-key-credential raw -o - - \
        2>/dev/null || true
  )"
  [[ "$actual_webauthn" == "true" ]] || {
    echo "error: signed app is missing the requested web-browser entitlement" >&2
    exit 1
  }
fi

for helper in "$APP_PATH/Contents/Resources/bin"/*; do
  [[ -f "$helper" && -x "$helper" ]] || continue
  helper_app_id="$(
    /usr/bin/codesign -d --entitlements :- "$helper" 2>/dev/null \
      | /usr/bin/plutil -extract com.apple.application-identifier raw -o - - 2>/dev/null \
      || true
  )"
  [[ -z "$helper_app_id" ]] || {
    echo "error: helper ${helper##*/} unexpectedly carries an application identifier" >&2
    exit 1
  }
done

echo "Signed UniConnect bundle: $APP_PATH"
