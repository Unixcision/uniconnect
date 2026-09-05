"""Read the original shared macOS/Linux catalogue; no parallel translations."""

import json
from pathlib import Path


class Translator:
    def __init__(self, language=None):
        # Spanish-first personal installation; saved choices use the same catalogue.
        self.language = (language or "es").replace("_", "-")
        if self.language not in ("pt-BR", "zh-Hans", "zh-Hant"):
            self.language = self.language.split("-")[0]
        self.original = {}
        source = Path(__file__).resolve().parents[2] / "Resources/Localizable.xcstrings"
        if source.exists():
            for key, entry in json.loads(source.read_text()).get("strings", {}).items():
                translations = entry.get("localizations", {})
                english = translations.get("en", {}).get("stringUnit", {}).get("value", key)
                value = translations.get(self.language, {}).get("stringUnit", {}).get("value")
                if value and (value != english or self.language == "en"):
                    self.original[english] = value

    def __call__(self, value):
        return self.original.get(value, value)
