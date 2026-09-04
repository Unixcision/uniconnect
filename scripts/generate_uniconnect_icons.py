#!/usr/bin/env python3
"""Regenerate every macOS UniConnect icon from the canonical 1024 px artwork.

The canonical, repo-owned source is
``design/UniConnect.icon/Assets/uniconnect-icon.png``.  It is a crop-only
derivative of the user-provided source recorded in ``SOURCE.md``; this script
never redraws, recolours, or composites legacy cmux artwork.
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image


REPOSITORY = Path(__file__).resolve().parent.parent
CANONICAL_ICON = (
    REPOSITORY / "design" / "UniConnect.icon" / "Assets" / "uniconnect-icon.png"
)

SIZES = (
    ("16.png", 16),
    ("16@2x.png", 32),
    ("32.png", 32),
    ("32@2x.png", 64),
    ("128.png", 128),
    ("128@2x.png", 256),
    ("256.png", 256),
    ("256@2x.png", 512),
    ("512.png", 512),
    ("512@2x.png", 1024),
)


def resized(source: Image.Image, size: int) -> Image.Image:
    """Return a high-quality square resize of the canonical RGBA artwork."""
    if source.size == (size, size):
        return source.copy()
    return source.resize((size, size), Image.Resampling.LANCZOS)


def write_app_icon_set(source: Image.Image, name: str, include_dark: bool) -> None:
    """Write one macOS app-icon set while preserving its Xcode manifest."""
    directory = REPOSITORY / "Assets.xcassets" / f"{name}.appiconset"
    manifest = directory / "Contents.json"
    with manifest.open(encoding="utf-8") as handle:
        json.load(handle)

    for filename, size in SIZES:
        image = resized(source, size)
        image.save(directory / filename, "PNG", optimize=True)
        if include_dark:
            stem = Path(filename).stem
            image.save(directory / f"{stem}_dark.png", "PNG", optimize=True)


def main() -> None:
    with Image.open(CANONICAL_ICON) as opened:
        source = opened.convert("RGBA")
    if source.size != (1024, 1024):
        raise SystemExit(f"canonical icon must be 1024x1024, got {source.size}")

    write_app_icon_set(source, "AppIcon", include_dark=True)
    write_app_icon_set(source, "AppIcon-Debug", include_dark=False)
    write_app_icon_set(source, "AppIcon-Nightly", include_dark=False)

    destinations = (
        REPOSITORY / "AppIcon.icon" / "Assets" / "uniconnect-icon.png",
        REPOSITORY / "Assets.xcassets" / "AppIconLight.imageset" / "AppIconLight.png",
        REPOSITORY / "Assets.xcassets" / "AppIconDark.imageset" / "AppIconDark.png",
        REPOSITORY / "docs" / "assets" / "logo.png",
    )
    for destination in destinations:
        source.save(destination, "PNG", optimize=True)
    resized(source, 256).save(
        REPOSITORY / "docs" / "assets" / "logo-256.png",
        "PNG",
        optimize=True,
    )


if __name__ == "__main__":
    main()
