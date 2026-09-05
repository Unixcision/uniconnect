"""Behavioural coverage for the one shared, Spanish-only interface catalogue."""

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect.__main__ import argument_parser
from uniconnect.actions import ACTIONS
from uniconnect.i18n import Translator, shared_key


class SpanishOnlyTranslatorTests(unittest.TestCase):
    def test_spanish_only_catalogue_works_without_english_lookup(self):
        with tempfile.TemporaryDirectory(prefix="uc-es-catalogue-") as directory:
            path = Path(directory) / "Localizable.xcstrings"
            path.write_text(json.dumps({"sourceLanguage": "es", "strings": {
                "uniconnect.shared.new.workspace": {"localizations": {
                    "es": {"stringUnit": {"state": "translated", "value": "Nueva caja"}}}},
                "uniconnect.shared.workspace.number": {"localizations": {
                    "es": {"stringUnit": {"state": "translated", "value": "Caja {number}"}}}},
            }}), encoding="utf-8")
            for old_preference in (None, "en", "ja", "es", "en_US", "ja-JP"):
                with self.subTest(preference=old_preference):
                    translate = Translator(old_preference, catalog_path=path)
                    self.assertEqual(translate.language, "es")
                    self.assertEqual(translate("New workspace"), "Nueva caja")
                    self.assertEqual(translate("uniconnect.shared.new.workspace"), "Nueva caja")
                    self.assertEqual(translate("Workspace {number}").format(number=9), "Caja 9")
                    self.assertEqual(translate("user@host:/my-project"), "user@host:/my-project")

    def test_actions_and_menu_groups_resolve_from_actual_shared_catalogue(self):
        translate = Translator("en")
        labels = [action.label for action in ACTIONS
                  if not action.name.rsplit("_", 1)[-1].isdigit()]
        labels += ["File", "Edit", "View", "Workspace", "Help", "Workspace {number}", "Window {number}"]
        for label in labels:
            with self.subTest(label=label):
                key = shared_key(label)
                self.assertIn(key, translate.translations)
                self.assertEqual(translate(label), translate.translations[key])
        self.assertEqual(translate("New window"), "Nueva ventana")
        self.assertEqual(translate("Settings"), "Ajustes")
        self.assertEqual(translate("Reconnect"), "Reconectar")

    def test_cli_defaults_to_spanish_and_rejects_removed_language_choices(self):
        parser = argument_parser()
        self.assertEqual(parser.parse_args([]).locale, "es")
        self.assertEqual(parser.parse_args(["--locale", "es"]).locale, "es")
        for removed in ("en", "ja"):
            with self.subTest(locale=removed), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    parser.parse_args(["--locale", removed])
                self.assertEqual(raised.exception.code, 2)

    def test_shared_legacy_labels_have_no_identifier_collisions(self):
        labels = [action.label for action in ACTIONS]
        labels += ["File", "Edit", "View", "Workspace", "Help", "Workspace {number}", "Window {number}",
                   "Unpin workspace", "Unpin window", "Restore pane"]
        seen = {}
        for label in labels:
            key = shared_key(label)
            self.assertTrue(key.removeprefix("uniconnect.shared."))
            self.assertIn(seen.get(key, label), (label,))
            seen[key] = label


if __name__ == "__main__":
    unittest.main()
