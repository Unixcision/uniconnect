#!/usr/bin/env bash
# Guards the app-icon path used by both tagged and untagged UniConnect Debug builds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PBXPROJ="$REPO_ROOT/cmux.xcodeproj/project.pbxproj"
ICON_COMPOSER_SOURCE="$REPO_ROOT/AppIcon.icon/Assets/uniconnect-icon.png"

app_icon_setting_count="$(grep -Ec '^[[:space:]]*ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;$' "$PBXPROJ" || true)"
if [[ "$app_icon_setting_count" -ne 2 ]]; then
    echo "::error file=cmux.xcodeproj/project.pbxproj::Debug and Release must both select AppIcon; found $app_icon_setting_count matching settings." >&2
    exit 1
fi

if grep -Eq '^[[:space:]]*ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon-Debug;$' "$PBXPROJ"; then
    echo "::error file=cmux.xcodeproj/project.pbxproj::UniConnect DEV must use AppIcon, not the legacy AppIcon-Debug asset." >&2
    exit 1
fi

if ! grep -Fq 'AppIcon.icon in Resources' "$PBXPROJ"; then
    echo "::error file=cmux.xcodeproj/project.pbxproj::AppIcon.icon is not wired into the app Resources phase." >&2
    exit 1
fi

if [[ ! -s "$ICON_COMPOSER_SOURCE" ]]; then
    echo "::error file=AppIcon.icon/Assets/uniconnect-icon.png::Icon Composer source is missing or empty." >&2
    exit 1
fi

matching_sources=(
    "$REPO_ROOT/Assets.xcassets/AppIcon.appiconset/512@2x.png"
    "$REPO_ROOT/Assets.xcassets/AppIcon.appiconset/512@2x_dark.png"
    "$REPO_ROOT/Assets.xcassets/AppIcon-Debug.appiconset/512@2x.png"
    "$REPO_ROOT/Assets.xcassets/AppIconDark.imageset/AppIconDark.png"
    "$REPO_ROOT/Assets.xcassets/AppIconLight.imageset/AppIconLight.png"
)
for source in "${matching_sources[@]}"; do
    if [[ ! -s "$source" ]] || ! cmp -s "$ICON_COMPOSER_SOURCE" "$source"; then
        relative_source="${source#"$REPO_ROOT/"}"
        echo "::error file=$relative_source::Icon source drifted from AppIcon.icon; regenerate it with scripts/generate_uniconnect_icons.py." >&2
        exit 1
    fi
done

python3 - "$REPO_ROOT/AppIcon.icon/icon.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
groups = document.get("groups", [])
fill = document.get("fill", {}).get("solid", "")
try:
    color_space, channels = fill.split(":", 1)
    red, green, blue, alpha = (float(value) for value in channels.split(","))
except (TypeError, ValueError):
    raise SystemExit(
        "::error file=AppIcon.icon/icon.json::Icon Composer must use an explicit solid sRGB fill."
    )

if color_space != "srgb" or alpha != 1 or max(red, green, blue) > 0.25:
    raise SystemExit(
        "::error file=AppIcon.icon/icon.json::Icon Composer backing fill must remain opaque and dark."
    )

if not groups or any(group.get("shadow", {}).get("opacity") != 0 for group in groups):
    raise SystemExit(
        "::error file=AppIcon.icon/icon.json::Icon Composer shadows must stay disabled to avoid a grey rim."
    )

for group in groups:
    if group.get("specular") is not False:
        raise SystemExit(
            "::error file=AppIcon.icon/icon.json::Icon Composer specular highlights must stay disabled."
        )
    if group.get("translucency", {}).get("enabled") is not False:
        raise SystemExit(
            "::error file=AppIcon.icon/icon.json::Icon Composer translucency must stay disabled."
        )
    if any(layer.get("glass") is not False for layer in group.get("layers", [])):
        raise SystemExit(
            "::error file=AppIcon.icon/icon.json::Icon Composer glass layers must stay disabled."
        )
PY
