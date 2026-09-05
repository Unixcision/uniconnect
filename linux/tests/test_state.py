"""Behavioral coverage for persistence, macOS interchange and encrypted recovery."""

import copy
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
import uuid

from uniconnect.imports import Importer, ImportError
from uniconnect.state import StateStore, StateError
from uniconnect.vault import Envelope, Vault, VaultError, VaultLocked, atomic_write


class PersistenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory(prefix="uniconnect-state-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.vault = Vault(self.root)
        self.vault.initialize("test-only vault password")
        self.now = 1_800_000_000.0
        self.store = StateStore(self.root, self.vault, clock=lambda: self.now)
        self.importer = Importer(self.vault)

    def document(self):
        return {"version": 2, "workspaces": [{"name": "Project", "kind": "ssh", "cwd": "/project",
                "connect": "sshpass -p 'password never in a preview' ssh -i /private/key user@example.test",
                "windows": [{"name": "Code", "tmux": "exact_saved_session", "agent": "codex",
                             "sessionId": "01a070d7-5f44-7f33-aee1-867c845860ef", "cwd": "/project"}]}]}

    def test_preview_is_secret_free_and_has_no_side_effects(self):
        before = {p.name: p.read_bytes() for p in self.root.iterdir() if p.is_file()}
        preview = self.importer.preview(self.document())
        self.assertNotIn("password never", repr(preview))
        self.assertNotIn("/private/key", repr(preview))
        after = {p.name: p.read_bytes() for p in self.root.iterdir() if p.is_file()}
        self.assertEqual(before, after)
        self.assertEqual(preview.workspaces[0]["hostLabel"], "user@example.test")

    def test_state_and_archive_never_contain_connection_material(self):
        preview = self.importer.preview(self.document())
        preview.apply(self.store)
        self.store.checkpoint("manual")
        for path in self.root.rglob("*"):
            if path.is_file():
                content = path.read_bytes()
                self.assertNotIn(b"password never in a preview", content)
                self.assertNotIn(b"/private/key", content)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)

    def test_lock_wrong_password_and_immutable_revisions(self):
        identifier = self.vault.put("ssh user@one.example")
        with self.assertRaises(VaultError):
            self.vault.put("ssh user@other.example", identifier)
        self.vault.lock()
        with self.assertRaises(VaultLocked):
            self.vault.get(identifier)
        with self.assertRaises(VaultError):
            self.vault.unlock("wrong password")
        self.assertTrue(self.vault.locked)
        self.vault.unlock("test-only vault password")
        self.assertEqual(self.vault.get(identifier), "ssh user@one.example")

    @unittest.skipUnless(Vault.automatic_unlock_available(), "root systemd-creds backend required")
    def test_automatic_vault_restarts_without_password_or_desktop_keyring(self):
        automatic_root = self.root / "automatic"
        with patch.object(Vault, "_desktop_key", side_effect=AssertionError("must not prompt desktop")):
            vault = Vault(automatic_root)
            vault.initialize()
            identifier = vault.put("ssh automatic@example.test")
            original_key = vault._key
            self.assertEqual(vault.mode, "systemd-creds")
            self.assertFalse(vault.key_path.exists())
            for path in automatic_root.iterdir():
                if path.is_file():
                    self.assertNotIn(original_key, path.read_bytes())
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            reopened = Vault(automatic_root)
            reopened.unlock()
            self.assertEqual(reopened.get(identifier), "ssh automatic@example.test")
            reopened.lock()
            reopened.unlock()
            self.assertEqual(reopened.get(identifier), "ssh automatic@example.test")

    @unittest.skipUnless(Vault.automatic_unlock_available(), "root systemd-creds backend required")
    def test_automatic_migration_preserves_credentials_and_original_key_wrapper(self):
        identifier = self.vault.put("ssh migrated@example.test")
        original_vault = self.vault.path.read_bytes()
        original_wrapper = self.vault.key_path.read_bytes()
        self.vault.enable_automatic_unlock()
        self.assertEqual(self.vault.path.read_bytes(), original_vault)
        self.assertEqual(self.vault.key_path.read_bytes(), original_wrapper)
        self.assertEqual(self.vault.mode, "systemd-creds")
        with patch.object(Vault, "_desktop_key", side_effect=AssertionError("must not prompt desktop")):
            reopened = Vault(self.root)
            reopened.unlock()
            self.assertEqual(reopened.get(identifier), "ssh migrated@example.test")

    @unittest.skipUnless(Vault.automatic_unlock_available(), "root systemd-creds backend required")
    def test_damaged_automatic_wrapper_does_not_fall_back_to_a_password_prompt(self):
        self.vault.enable_automatic_unlock()
        atomic_write(self.vault.automatic_key_path, b"tampered host credential")
        with patch.object(Vault, "_desktop_key", side_effect=AssertionError("must not prompt desktop")):
            reopened = Vault(self.root)
            with self.assertRaises(VaultError):
                reopened.unlock()
            self.assertTrue(reopened.locked)

    def test_close_and_reopen_preserve_identity_and_conversation(self):
        self.importer.preview(self.document()).apply(self.store)
        workspace = self.store.workspaces[0]
        window = workspace["windows"][0]
        expected_id, expected_history = window["id"], copy.deepcopy(window["history"])
        entry = self.store.close_window(workspace["id"], window["id"])
        self.store.load()
        self.store.restore_closed(entry["id"])
        restored = self.store.workspaces[0]["windows"][0]
        self.assertEqual(restored["id"], expected_id)
        self.assertEqual(restored["history"], expected_history)
        self.assertEqual(restored["tmux"], "exact_saved_session")
        self.assertTrue(restored["restoreOnly"])
        self.assertEqual(self.store.closed, [])

    def test_save_preserves_live_dictionary_identity_and_detects_other_writer(self):
        self.importer.preview(self.document()).apply(self.store)
        workspace = self.store.workspaces[0]
        self.store.save()
        self.assertIs(workspace, self.store.workspaces[0])
        other = StateStore(self.root, self.vault)
        other.data["settings"]["locale"] = "es"
        other.save(scheduled=False)
        self.store.data["settings"]["locale"] = "en"
        with self.assertRaises(StateError):
            self.store.save()
        self.assertEqual(json.loads(self.store.path.read_bytes())["settings"]["locale"], "es")

    def test_scheduled_archive_spacing_and_retention(self):
        self.importer.preview(self.document()).apply(self.store)
        scheduled = lambda: [p for p in self.store.backups() if p["reason"] == "scheduled"]
        self.assertEqual(len(scheduled()), 1)
        self.now += 6 * 3600 - 1
        self.assertIsNone(self.store.checkpoint("scheduled"))
        self.now += 1
        self.store.checkpoint("scheduled")
        self.assertEqual(len(scheduled()), 2)
        for _ in range(33):
            self.now += 6 * 3600
            self.store.checkpoint("scheduled")
        self.assertLessEqual(len(scheduled()), 28)
        self.assertTrue(all(self.now - p["createdAt"] <= 7 * 86400 for p in scheduled()))
        self.assertTrue(any(p["reason"] == "before-import" for p in self.store.backups()))

    def test_tampered_or_missing_companion_cannot_restore(self):
        self.importer.preview(self.document()).apply(self.store)
        point = self.store.checkpoint()
        metadata = json.loads(point.read_bytes())["recovery"]
        companion = self.store.backup_dir / metadata["vaultFile"]
        atomic_write(companion, b"damaged")
        previous = self.store.path.read_bytes()
        with self.assertRaises(StateError):
            self.store.restore_backup(point)
        self.assertEqual(previous, self.store.path.read_bytes())

    def test_portable_ciphertext_roundtrip_and_authentication(self):
        self.importer.preview(self.document()).apply(self.store)
        path = self.importer.export(self.store, self.root / "export.uniconnect", "portable password")
        envelope = json.loads(path.read_bytes())
        self.assertEqual(envelope["format"], "uniconnect-aesgcm")
        self.assertEqual(envelope["iterations"], 600_000)
        preview = self.importer.preview(path, passphrase="portable password")
        self.assertEqual(preview.window_count, 1)
        with self.assertRaises(ImportError):
            self.importer.preview(path, passphrase="wrong")
        envelope["ciphertext"] = "AAAA" + envelope["ciphertext"][4:]
        with self.assertRaises(VaultError):
            Envelope.open_with_passphrase(envelope, "portable password")

    def test_reimport_is_idempotent_and_mutated_preview_rejected(self):
        self.importer.preview(self.document()).apply(self.store)
        self.importer.preview(self.document()).apply(self.store)
        self.assertEqual(len(self.store.workspaces), 1)
        self.assertEqual(len(self.store.workspaces[0]["windows"]), 1)
        preview = self.importer.preview(self.document())
        preview.workspaces[0]["windows"][0]["tmux"] = "other_session"
        with self.assertRaises(ImportError):
            preview.apply(self.store)

    def test_native_macos_snapshot_retains_panel_and_history(self):
        workspace_id, panel_id, record_id = [str(uuid.uuid4()) for _ in range(3)]
        snapshot = {"version": 1, "windows": [{"tabManager": {"workspaces": [{
            "workspaceId": workspace_id, "customTitle": "Native Mac", "currentDirectory": "/project",
            "uniConnect": {"kind": "local", "localRoot": "/project"},
            "focusedPanelId": panel_id, "panels": [{"id": panel_id, "title": "Codex", "terminal": {
                "uniConnectLocalWindow": {"id": panel_id, "boxRoot": "/project", "workingDirectory": "/project",
                    "conversations": [{"id": record_id, "kind": "codex", "sessionID": "native-session"}],
                    "latestConversationID": record_id}}}]}]}}]}
        preview = self.importer.preview(snapshot)
        self.assertEqual(preview.source_type, "macos-session")
        self.assertEqual(preview.workspaces[0]["id"], workspace_id)
        window = preview.workspaces[0]["windows"][0]
        self.assertEqual(window["id"], panel_id)
        self.assertEqual(window["agent"], "codex")
        self.assertEqual(window["sessionId"], "native-session")

    def test_unsafe_import_connection_fails_before_persistence(self):
        for command in ("ssh user@host ; touch /tmp/anything", "ssh -oProxyCommand=evil user@host", "bash -c ssh"):
            document = self.document()
            document["workspaces"][0]["connect"] = command
            with self.assertRaises(ImportError):
                self.importer.preview(document)
        self.assertFalse(self.store.path.exists())


if __name__ == "__main__":
    unittest.main()
