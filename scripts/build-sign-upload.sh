#!/usr/bin/env bash
set -euo pipefail

# Build, sign, notarize, create DMG, generate appcast, and upload to GitHub release.
# Usage: ./scripts/build-sign-upload.sh <tag> [--allow-overwrite]
# Requires: source the private release environment and export SPARKLE_PRIVATE_KEY plus
# UNICONNECT_DEVELOPER_IDENTITY (the Developer ID Application SHA-1 or exact identity).

usage() {
  cat <<'EOF'
Usage: ./scripts/build-sign-upload.sh <tag> [--allow-overwrite]

Options:
  --allow-overwrite   Permit replacing existing release assets for the same tag.
                      Use only for emergency rerolls.
EOF
}

ALLOW_OVERWRITE="false"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-overwrite)
      ALLOW_OVERWRITE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 1
fi

TAG="$1"

# This legacy all-in-one publisher performs irreversible external writes. Keep it
# unavailable during ordinary local development; CI remains the normal release path.
if [[ "${UNICONNECT_ALLOW_LOCAL_PUBLISH:-}" != "I_UNDERSTAND_THIS_PUBLISHES_A_RELEASE" ]]; then
  echo "REFUSED: local publishing is locked; use the reviewed GitHub release workflow." >&2
  echo "For an emergency owner-run release, set UNICONNECT_ALLOW_LOCAL_PUBLISH=I_UNDERSTAND_THIS_PUBLISHES_A_RELEASE." >&2
  exit 1
fi

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
  || { echo "INVALID: release tag must be an explicit vMAJOR.MINOR.PATCH tag" >&2; exit 1; }
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
[[ "$ORIGIN_URL" =~ github\.com[:/]Unixcision/uniconnect(\.git)?$ ]] \
  || { echo "INVALID: origin is not Unixcision/uniconnect" >&2; exit 1; }
TAG_COMMIT="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" 2>/dev/null || true)"
[[ -n "$TAG_COMMIT" && "$TAG_COMMIT" == "$(git rev-parse HEAD)" ]] \
  || { echo "INVALID: $TAG must already exist and point at HEAD" >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=no)" ]] \
  || { echo "INVALID: tracked worktree changes must be committed before publishing" >&2; exit 1; }

ENTITLEMENTS="Resources/UniConnect.entitlements"
APP_PATH="build/Build/Products/Release/UniConnect.app"
GHOSTTYKIT_CRASH_REPORT_SUBDIR="uniconnect/crash"

# --- Pre-flight ---
if [[ -f "$HOME/.secrets/uniconnect.env" ]]; then
  source "$HOME/.secrets/uniconnect.env"
fi
export SPARKLE_PRIVATE_KEY
SIGNING_IDENTITY="${UNICONNECT_DEVELOPER_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "MISSING: UNICONNECT_DEVELOPER_IDENTITY" >&2
  exit 1
fi
if ! /usr/bin/security find-identity -v -p codesigning 2>&1 \
  | /usr/bin/awk -v expected="$SIGNING_IDENTITY" '
      index($0, "\"Developer ID Application:") && ($2 == expected || index($0, expected) > 0) { found=1 }
      END { exit found ? 0 : 1 }
    '; then
  echo "INVALID: UNICONNECT_DEVELOPER_IDENTITY is not an available Developer ID Application identity" >&2
  exit 1
fi
for tool in zig xcodebuild create-dmg xcrun codesign ditto gh; do
  command -v "$tool" >/dev/null || { echo "MISSING: $tool" >&2; exit 1; }
done
echo "Pre-flight checks passed"

# --- Build GhosttyKit ---
echo "Building GhosttyKit..."
rm -rf GhosttyKit.xcframework ghostty/macos/GhosttyKit.xcframework
(
  cd ghostty
  zig build -Dcrash-report-subdir="$GHOSTTYKIT_CRASH_REPORT_SUBDIR" -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=universal -Doptimize=ReleaseFast
)
cp -R ghostty/macos/GhosttyKit.xcframework GhosttyKit.xcframework

# --- Build app (Release, unsigned) ---
echo "Building app..."
rm -rf build/
xcodebuild -scheme cmux -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
echo "Build succeeded"

HELPER_PATH="$APP_PATH/Contents/Resources/bin/ghostty"
if [ ! -x "$HELPER_PATH" ]; then
  echo "Ghostty theme picker helper not found at $HELPER_PATH" >&2
  exit 1
fi

# --- Inject Sparkle keys ---
echo "Injecting Sparkle keys..."
SPARKLE_PUBLIC_KEY_DERIVED=$(swift scripts/derive_sparkle_public_key.swift "$SPARKLE_PRIVATE_KEY")
APP_PLIST="$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY_DERIVED" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/Unixcision/uniconnect/releases/latest/download/appcast.xml" "$APP_PLIST"
echo "Sparkle keys injected"

# UniConnect is a non-sandboxed app. Sparkle's sandbox-only XPC services make the
# installer handoff wait for an agent connection that never arrives.
./scripts/remove-sparkle-sandbox-xpc-services.sh "$APP_PATH"

# --- Codesign ---
echo "Codesigning..."
./scripts/sign-uniconnect-bundle.sh "$APP_PATH" "$ENTITLEMENTS" "$SIGNING_IDENTITY"
echo "Codesign verified"

# --- Notarize app ---
echo "Notarizing app..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" uniconnect-notary.zip
xcrun notarytool submit uniconnect-notary.zip \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
rm -f uniconnect-notary.zip
echo "App notarized"

# --- Create and notarize DMG ---
echo "Creating DMG..."
rm -f uniconnect-macos.dmg
create-dmg --codesign "$SIGNING_IDENTITY" uniconnect-macos.dmg "$APP_PATH"
echo "Notarizing DMG..."
xcrun notarytool submit uniconnect-macos.dmg \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
xcrun stapler staple uniconnect-macos.dmg
xcrun stapler validate uniconnect-macos.dmg
echo "DMG notarized"

# --- Generate Sparkle appcast ---
echo "Generating appcast..."
./scripts/sparkle_generate_appcast.sh uniconnect-macos.dmg "$TAG" appcast.xml

# --- Create GitHub release (if needed) and upload ---
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists"
  EXISTING_ASSETS="$(gh release view "$TAG" --json assets --jq '.assets[].name' || true)"
  HAS_CONFLICTING_ASSET="false"
  for asset in uniconnect-macos.dmg appcast.xml; do
    if printf '%s\n' "$EXISTING_ASSETS" | grep -Fxq "$asset"; then
      HAS_CONFLICTING_ASSET="true"
      break
    fi
  done

  if [[ "$HAS_CONFLICTING_ASSET" == "true" && "$ALLOW_OVERWRITE" != "true" ]]; then
    echo "ERROR: Refusing to overwrite signed release assets for existing tag $TAG." >&2
    echo "Use a new tag, or rerun with --allow-overwrite for an emergency reroll." >&2
    exit 1
  fi

  if [[ "$ALLOW_OVERWRITE" == "true" ]]; then
    echo "Uploading with overwrite enabled for existing release $TAG..."
    gh release upload "$TAG" uniconnect-macos.dmg appcast.xml --clobber
  else
    echo "Uploading to existing release $TAG..."
    gh release upload "$TAG" uniconnect-macos.dmg appcast.xml
  fi
else
  echo "Creating release $TAG and uploading..."
  gh release create "$TAG" uniconnect-macos.dmg appcast.xml --title "$TAG" --notes "See CHANGELOG.md for details"
fi

# --- Verify ---
gh release view "$TAG"

# --- Update Homebrew cask (skip for nightlies) ---
if [[ "$TAG" != *"-nightly"* ]]; then
  VERSION="${TAG#v}"
  DMG_SHA256=$(shasum -a 256 uniconnect-macos.dmg | cut -d' ' -f1)
  echo "Updating homebrew cask to $VERSION (SHA: $DMG_SHA256)..."
  CASK_FILE="homebrew-uniconnect/Casks/uniconnect.rb"
  if [ -f "$CASK_FILE" ]; then
    cat > "$CASK_FILE" << CASKEOF
cask "uniconnect" do
  version "${VERSION}"
  sha256 "${DMG_SHA256}"

  url "https://github.com/Unixcision/uniconnect/releases/download/v#{version}/uniconnect-macos.dmg"
  name "UniConnect"
  desc "Native macOS workspace for local and remote Claude sessions"
  homepage "https://github.com/Unixcision/uniconnect"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "UniConnect.app"
  binary "#{appdir}/UniConnect.app/Contents/Resources/bin/cmux"

  # Preserve sessions, encrypted SSH credentials and the seven-day recovery
  # archive even during `brew uninstall --zap`; only disposable caches are removed.
  zap trash: "~/Library/Caches/com.unixcision.uniconnect"
end
CASKEOF
    cd homebrew-uniconnect
    git add Casks/uniconnect.rb
    if git diff --staged --quiet; then
      echo "Homebrew cask already up to date"
    else
      git commit -m "Update UniConnect to ${VERSION}"
      git push
      echo "Homebrew cask updated"
    fi
    cd ..
  else
    echo "WARNING: homebrew-uniconnect checkout not found, skipping cask update"
  fi
fi

# --- Cleanup ---
rm -rf build/ uniconnect-macos.dmg appcast.xml
echo ""
echo "=== Release $TAG complete ==="
say "UniConnect release complete"
