"""Import/recovery cannot grant or revoke this machine's mobile-listener consent."""

from pathlib import Path
import tempfile
import unittest
import uuid

from uniconnect.imports import Importer
from uniconnect.state import StateStore
from uniconnect.vault import Vault


class MobileConsentBoundaryTests(unittest.TestCase):
    @staticmethod
    def document(consent):
        return {"version": 1, "app": "UniConnect Linux", "closed": [],
                "settings": {"mobileHostEnabled": consent, "font": "Fixture Mono 12"},
                "workspaces": [{"id": str(uuid.uuid4()), "name": "Importada", "kind": "local",
                                "windows": [{"id": str(uuid.uuid4()), "name": "Consola", "agent": "shell", "cwd": "/tmp"}]}]}

    @staticmethod
    def store(root, consent=None):
        vault = Vault(root)
        vault.initialize("isolated-consent-fixture")
        store = StateStore(root, vault)
        if consent is not None:
            store.data["settings"]["mobileHostEnabled"] = consent
        store.save(scheduled=False)
        return store, vault

    def assert_local_consent(self, store, expected):
        # Reload proves what the desktop will consume at its next launch, not
        # merely a sanitized preview or a transient UI checkbox.
        loaded = StateStore(store.root, store.vault)
        for settings in (store.data["settings"], loaded.data["settings"]):
            if expected is None:
                self.assertNotIn("mobileHostEnabled", settings)
                self.assertFalse(settings.get("mobileHostEnabled", False))
            else:
                self.assertIs(settings.get("mobileHostEnabled"), expected)

    def test_import_preserves_local_absent_false_and_true_without_importing_consent(self):
        for current, incoming in ((None, True), (None, False), (False, True), (True, False)):
            with self.subTest(current=current, incoming=incoming), tempfile.TemporaryDirectory(prefix="uc-import-consent-") as folder:
                store, vault = self.store(Path(folder), current)
                preview = Importer(vault).preview(self.document(incoming))
                preview.preflight(store)
                applied = preview.apply(store)
                self.assertEqual(len(applied), 1)
                self.assertEqual(store.data["settings"]["font"], "Fixture Mono 12")
                self.assert_local_consent(store, current)

    def test_encrypted_portable_snapshot_does_not_enable_mobile_on_another_machine(self):
        with tempfile.TemporaryDirectory(prefix="uc-portable-consent-") as folder:
            root = Path(folder)
            source, source_vault = self.store(root / "source", True)
            Importer(source_vault).preview(self.document(True)).apply(source)
            exported = Importer(source_vault).export(source, root / "portable.uniconnect", "portable-consent-fixture")
            destination, destination_vault = self.store(root / "destination")
            preview = Importer(destination_vault).preview(exported, passphrase="portable-consent-fixture")
            self.assertEqual(len(preview.apply(destination)), 1)
            self.assert_local_consent(destination, None)

    def test_restore_recovery_point_keeps_the_current_local_decision(self):
        for current, archived in ((None, True), (False, True), (True, False)):
            with self.subTest(current=current, archived=archived), tempfile.TemporaryDirectory(prefix="uc-restore-consent-") as folder:
                store, vault = self.store(Path(folder), archived)
                Importer(vault).preview(self.document(archived)).apply(store)
                point = store.checkpoint("consent-fixture")
                if current is None:
                    store.data["settings"].pop("mobileHostEnabled", None)
                else:
                    store.data["settings"]["mobileHostEnabled"] = current
                store.save(scheduled=False)
                self.assertEqual(len(store.restore_backup(point)), 1)
                self.assert_local_consent(store, current)


if __name__ == "__main__":
    unittest.main()
