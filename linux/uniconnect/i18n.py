"""Read the original shared macOS/Linux catalogue; no parallel translations."""

import json
import re
from pathlib import Path


def shared_key(label):
    """Resolve a legacy label to its stable, shared catalogue identifier."""
    return "uniconnect.shared." + re.sub(r"[^a-z0-9]+", ".", label.lower()).strip(".")


class Translator:
    def __init__(self, language=None, *, catalog_path=None):
        # Old imports may contain en/ja preferences; the product now has one language.
        # Keys, not removed English translations, connect GTK labels to the shared file.
        self.language = "es"
        source = Path(catalog_path) if catalog_path is not None else (
            Path(__file__).resolve().parents[2] / "Resources/Localizable.xcstrings"
        )
        self.translations = {}
        if source.is_file():
            for key, entry in json.loads(source.read_text(encoding="utf-8")).get("strings", {}).items():
                value = entry.get("localizations", {}).get("es", {}).get("stringUnit", {}).get("value")
                if value:
                    self.translations[key] = value

    def __call__(self, value):
        return self.translations.get(value, self.translations.get(shared_key(value), value))
