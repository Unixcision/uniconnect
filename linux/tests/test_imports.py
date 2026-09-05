"""Import selection, source diagnostics, read-only preflight and lossless recovery."""

import copy
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from uniconnect.imports import Importer, ImportError
from uniconnect.state import StateStore
from uniconnect.vault import Vault


class ImportWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory(prefix="uniconnect-import-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.vault = Vault(self.root)
        self.vault.initialize("isolated import password")
        self.store = StateStore(self.root, self.vault)
        self.importer = Importer(self.vault)

    @staticmethod
    def document():
        return {"version": 2, "workspaces": [
            {"name": "First", "kind": "ssh", "connect": "ssh first@example.test",
             "windows": [{"name": "worker_a", "tmux": "worker_a", "layout": {"ratio": 0.3}}]},
            {"name": "Second", "kind": "ssh", "connect": "ssh second@example.test",
             "windows": [{"name": "worker_b", "tmux": "worker_b"}]},
        ]}

    def persisted_bytes(self):
        return {str(path.relative_to(self.root)): path.read_bytes()
                for path in self.root.rglob("*") if path.is_file()}

    def test_selection_is_independent_secret_filtered_and_empty_selection_is_noop(self):
        preview = self.importer.preview(self.document())
        before = self.persisted_bytes()
        selected = preview.select_workspace_ids([preview.workspaces[1]["id"]])
        self.assertEqual(len(preview.workspaces), 2)
        self.assertEqual([item["name"] for item in selected.workspaces], ["Second"])
        self.assertEqual(len(selected._commands), 1)
        selected.workspaces[0]["windows"][0]["name"] = "changed in copy"
        self.assertEqual(preview.workspaces[1]["windows"][0]["name"], "worker_b")
        with self.assertRaises(ImportError):
            preview.select_workspace_ids(["unknown"])
        self.assertEqual(preview.select_workspace_ids([]).apply(self.store), [])
        self.assertEqual(before, self.persisted_bytes())

    def test_preflight_checks_only_selected_without_writing_or_leaking_commands(self):
        preview = self.importer.preview(self.document())
        selected = preview.select_workspace_ids([preview.workspaces[0]["id"]])
        before = self.persisted_bytes()
        inspected = []

        def check(workspace, window, command):
            inspected.append(window["tmux"])
            self.assertTrue(command.startswith("ssh "))
            workspace["name"] = "callback may not mutate the preview"
            return True

        rows = selected.preflight(self.store, check)
        self.assertEqual(inspected, ["worker_a"])
        self.assertEqual(rows[0]["action"], "create")
        self.assertTrue(rows[0]["windows"][0]["remoteReady"])
        self.assertNotIn("ssh ", repr(rows))
        self.assertEqual(selected.workspaces[0]["name"], "First")
        self.assertEqual(before, self.persisted_bytes())
        unavailable = selected.preflight(self.store, lambda *_: False)
        self.assertEqual(unavailable[0]["action"], "rejected")

    def test_preflight_detects_duplicate_remote_targets(self):
        document = self.document()
        document["workspaces"][1]["connect"] = document["workspaces"][0]["connect"]
        document["workspaces"][1]["windows"][0]["tmux"] = "worker_a"
        rows = self.importer.preview(document).preflight(self.store)
        self.assertEqual([row["action"] for row in rows], ["create", "conflict"])

    def test_connection_conflict_fails_before_checkpoint_or_vault_mutation(self):
        document = self.document()
        self.importer.preview(document).apply(self.store)
        document["workspaces"][0]["connect"] = "ssh different@example.test"
        preview = self.importer.preview(document)
        before = self.persisted_bytes()
        self.assertEqual(preview.preflight(self.store)[0]["action"], "conflict")
        with self.assertRaises(ImportError):
            preview.apply(self.store)
        self.assertEqual(before, self.persisted_bytes())

    def test_markdown_original_local_table_and_resume_blocks(self):
        markdown = '''# CONNECT
## 2. Cajas LOCALES
### 2.1 · Caja "Example Apps" — 2 ventanas
| Ventana | UUID de sesión | Ruta de arranque |
|---------|----------------|------------------|
| APP 1 | `11111111-1111-1111-1111-111111111111` | `~/Projects/One` |
| APP 2 | `22222222-2222-2222-2222-222222222222` | `~/Projects/Two` ⚠️ |
```bash
# APP 1
cd ~/Projects/One && claude --dangerously-skip-permissions --resume 11111111-1111-1111-1111-111111111111
# APP 2
cd ~/Projects/Two && codex resume -m gpt-6-astra 22222222-2222-2222-2222-222222222222
```
'''
        preview = self.importer.preview(markdown)
        self.assertEqual(preview.source_type, "connect-markdown")
        self.assertEqual(preview.diagnostics, [])
        workspace = preview.workspaces[0]
        self.assertEqual(workspace["name"], "Example Apps")
        self.assertEqual(workspace["sourceLine"], 3)
        self.assertEqual([window["agent"] for window in workspace["windows"]], ["claude", "codex"])
        self.assertEqual([window["sourceLine"] for window in workspace["windows"]], [6, 7])
        self.assertTrue(workspace["cwd"].endswith("/Projects"))
        self.assertNotIn("dangerously", repr(preview))
        self.assertNotIn("--yolo", repr(preview))

    def test_markdown_ssh_secrets_stay_private_and_rejected_rows_keep_source(self):
        markdown = '''# CONNECT
## SSH boxes
### Safe server
    sshpass -p 'in-memory-only-password' ssh -i /private/key ops@example.test
| Window | tmux |
|--------|------|
| worker | worker_a |
### Broken server
```sh
ssh ops@example.test ; touch /tmp/should-never-run
```
| Window | tmux |
|--------|------|
| broken | |
'''
        before = self.persisted_bytes()
        preview = self.importer.preview(markdown)
        self.assertEqual(len(preview.workspaces), 2)
        self.assertEqual(preview.workspaces[0]["windows"][0]["tmux"], "worker_a")
        self.assertNotIn("in-memory-only-password", repr(preview))
        self.assertNotIn("/private/key", repr(preview))
        self.assertTrue(preview.workspaces[1]["importRejected"])
        self.assertTrue(any("Line 10:" in note for note in preview.diagnostics))
        with self.assertRaises(ImportError):
            preview.apply(self.store)
        self.assertEqual(before, self.persisted_bytes())
        selected = preview.select_workspace_ids([preview.workspaces[0]["id"]])
        selected.apply(self.store)
        self.assertEqual(len(self.store.workspaces), 1)

    def test_snapshot_and_closed_only_credentials_survive_portable_roundtrip(self):
        self.importer.preview(self.document()).apply(self.store)
        first, second = self.store.workspaces
        first["customMetadata"] = {"display": "retained", "nested": [1, 2, 3]}
        first["windows"][0]["viewState"] = {"font": 13, "scrollPosition": 42}
        self.store.data["settings"] = {"locale": "ja", "shortcuts": {"new": "<Control>N"}}
        self.store.data["layout"] = {"ratio": 0.27, "direction": "vertical"}
        self.store.close_workspace(second["id"])
        self.store.save()
        exported = self.importer.export(self.store, self.root / "portable.uniconnect", "portable fixture")
        target_root = self.root / "target"
        target_vault = Vault(target_root)
        target_vault.initialize("another vault password")
        target_store = StateStore(target_root, target_vault)
        preview = Importer(target_vault).preview(exported, passphrase="portable fixture")
        preview.apply(target_store)
        self.assertEqual(target_store.workspaces[0]["customMetadata"], first["customMetadata"])
        self.assertEqual(target_store.workspaces[0]["windows"][0]["viewState"], first["windows"][0]["viewState"])
        self.assertEqual(target_store.data["settings"], self.store.data["settings"])
        self.assertEqual(target_store.data["layout"], self.store.data["layout"])
        self.assertEqual(target_store.closed, self.store.closed)
        target_store.restore_closed(target_store.closed[0]["id"])
        restored_second = next(item for item in target_store.workspaces if item["name"] == "Second")
        self.assertEqual(target_vault.get(restored_second["credentialId"]), "ssh second@example.test")

    def test_reimport_classifies_unchanged_then_updates_same_window_identity(self):
        document = self.document()
        self.importer.preview(document).apply(self.store)
        repeated = self.importer.preview(document)
        self.assertEqual([row["action"] for row in repeated.preflight(self.store)], ["unchanged", "unchanged"])
        workspace = self.store.workspaces[0]
        window = workspace["windows"][0]
        identifier = window["id"]
        exported = copy.deepcopy(self.store.data)
        exported["workspaces"][0]["windows"][0]["name"] = "New visible title"
        updated = self.importer.preview(exported)
        self.assertEqual(updated.preflight(self.store)[0]["action"], "update")
        updated.apply(self.store)
        self.assertEqual(self.store.workspaces[0]["windows"][0]["id"], identifier)
        self.assertEqual(self.store.workspaces[0]["windows"][0]["name"], "New visible title")


if __name__ == "__main__":
    unittest.main()
