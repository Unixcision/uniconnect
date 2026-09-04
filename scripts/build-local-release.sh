#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA_PATH="${UNICONNECT_DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData/UniConnect-Stable}"
SIGNING_IDENTITY="${UNICONNECT_SIGNING_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  IDENTITIES=()
  while IFS= read -r identity; do
    [[ -n "$identity" ]] && IDENTITIES+=("$identity")
  done < <(/usr/bin/security find-identity -v -p codesigning 2>&1 \
    | /usr/bin/awk '/"Apple Development:/ {print $2}')

  if [[ ${#IDENTITIES[@]} -ne 1 ]]; then
    echo "error: expected exactly one Apple Development identity; set UNICONNECT_SIGNING_IDENTITY explicitly" >&2
    exit 1
  fi
  SIGNING_IDENTITY="${IDENTITIES[0]}"
fi

if ! /usr/bin/security find-identity -v -p codesigning 2>&1 \
  | /usr/bin/awk -v expected="$SIGNING_IDENTITY" '
      {
        quoted = $0
        sub(/^[^"]*"/, "", quoted)
        sub(/".*$/, "", quoted)
        if ($2 == expected || quoted == expected) found = 1
      }
      END { exit found ? 0 : 1 }
    '; then
  echo "error: the requested signing identity is not available with its private key" >&2
  exit 1
fi

cd "$REPO_ROOT"
./scripts/ensure-ghosttykit.sh

/usr/bin/xcodebuild \
  -project cmux.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/UniConnect.app"
[[ -d "$APP_PATH" ]] || { echo "error: Release app was not produced" >&2; exit 1; }

for relative_path in \
  Contents/MacOS/UniConnect \
  Contents/Resources/bin/cmux \
  Contents/Resources/bin/ghostty; do
  binary="$APP_PATH/$relative_path"
  [[ -f "$binary" ]] || { echo "error: required binary is missing: $relative_path" >&2; exit 1; }
  architectures="$(/usr/bin/lipo -archs "$binary")"
  if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
    echo "error: required binary is not universal: $relative_path ($architectures)" >&2
    exit 1
  fi
done

UNICONNECT_TIMESTAMP=none \
  "$SCRIPT_DIR/sign-uniconnect-bundle.sh" \
  "$APP_PATH" \
  "$REPO_ROOT/Resources/UniConnect.entitlements" \
  "$SIGNING_IDENTITY"

echo "App path:"
echo "  $APP_PATH"
echo "The signed app was not installed or launched."
