"""Failure-injection tests for coherent state/vault transactions and restart recovery."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from uniconnect.imports import Importer
from uniconnect.state import StateStore, StateError
from uniconnect.vault import Vault, VaultError, atomic_write


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = TemporaryDirectory(prefix="uniconnect-transaction-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.vault = Vault(self.root)
        self.vault.initialize("transaction fixture password")
        self.store = StateStore(self.root, self.vault)
        Importer(self.vault).preview(self.document("Original", "original")).apply(self.store)
        self.store.data["layout"] = {"orientation": "horizontal", "ratio": 0.3}
        self.store.workspaces[0]["windows"][0]["viewState"] = {"markdown": "preserved", "selection": [1, 4]}
        self.store.save()
        self.original_state = self.store.path.read_bytes()
        self.original_vault = self.vault.path.read_bytes()
        self.original_model = copy.deepcopy(self.store.data)
        self.workspace_reference = self.store.workspaces[0]
        self.window_reference = self.store.workspaces[0]["windows"][0]
        self.windows_reference = self.store.workspaces[0]["windows"]

    @staticmethod
    def document(name="Added", host="added"):
        return {"version": 2, "workspaces": [{"name": name, "kind": "ssh",
                "connect": f"ssh fixture@{host}.example.test", "windows": [{"name": "Worker", "tmux": "worker"}]}]}

    def assert_restored(self):
        self.assertEqual(self.store.path.read_bytes(), self.original_state)
        self.assertEqual(self.vault.path.read_bytes(), self.original_vault)
        self.assertEqual(self.store.data, self.original_model)
        self.assertIs(self.store.workspaces[0], self.workspace_reference)
        self.assertIs(self.store.workspaces[0]["windows"], self.windows_reference)
        self.assertIs(self.store.workspaces[0]["windows"][0], self.window_reference)
        self.assertFalse(self.store.journal_path.exists())

    def fail_at(self, expected, exception=RuntimeError):
        def fail(stage):
            if stage == expected:
                raise exception("injected failure")
        self.store._failpoint = fail

    def test_import_failure_after_vault_and_state_restores_exact_pair_and_references(self):
        for stage in ("vault:after", "model:after", "state:after", "commit:before"):
            with self.subTest(stage=stage):
                self.fail_at(stage)
                with self.assertRaises(RuntimeError):
                    Importer(self.vault).preview(self.document()).apply(self.store)
                self.assert_restored()

    def test_cancellation_rolls_back_instead_of_leaving_a_partial_import(self):
        self.fail_at("model:after", KeyboardInterrupt)
        with self.assertRaises(KeyboardInterrupt):
            Importer(self.vault).preview(self.document()).apply(self.store)
        self.assert_restored()

    def test_restore_failure_after_merging_vault_rolls_back_exactly(self):
        point = self.store.checkpoint()
        self.fail_at("state:after")
        with self.assertRaises(RuntimeError):
            self.store.restore_backup(point)
        self.assert_restored()

    def test_outer_runtime_readiness_failure_rolls_back_nested_import(self):
        with self.assertRaises(RuntimeError):
            with self.store.transaction("runtime-import") as transaction:
                Importer(self.vault).preview(self.document()).apply(self.store)
                with transaction.step("child-readiness"):
                    raise RuntimeError("replacement child did not become ready")
        self.assert_restored()

    def test_mutate_and_close_rollback_preserve_removed_window_object(self):
        with patch.object(self.store, "save", side_effect=OSError("injected storage failure")):
            with self.assertRaises(OSError):
                self.store.close_window(self.workspace_reference["id"], self.window_reference["id"])
        self.assert_restored()
        with patch.object(self.store, "save", side_effect=OSError("injected storage failure")):
            with self.assertRaises(OSError):
                self.store.mutate(lambda data: data["workspaces"].clear())
        self.assert_restored()

    def crash(self, stage):
        script = """
import json, os, sys
from uniconnect.vault import Vault
from uniconnect.state import StateStore
from uniconnect.imports import Importer
vault=Vault(sys.argv[1]); vault.unlock('transaction fixture password')
def fail(stage):
    if stage==sys.argv[2]: os._exit(73)
store=StateStore(sys.argv[1],vault,failpoint=fail)
Importer(vault).preview(json.loads(sys.stdin.read())).apply(store)
raise SystemExit(74)
"""
        result = subprocess.run([sys.executable, "-c", script, str(self.root), stage],
                                input=json.dumps(self.document()).encode(), stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=20, env=os.environ.copy())
        self.assertEqual(result.returncode, 73, result.stderr.decode())
        self.assertTrue(self.store.journal_path.exists())

    def test_process_exit_between_writes_recovers_before_loading_any_workspace(self):
        for stage in ("checkpoint:durable", "vault:after", "model:after", "state:after"):
            with self.subTest(stage=stage):
                self.crash(stage)
                journal = self.store.journal_path.read_bytes()
                self.assertNotIn(b"fixture@", journal)
                self.assertNotIn(b"ssh ", journal)
                recovered_vault = Vault(self.root)
                recovered_vault.unlock("transaction fixture password")
                recovered = StateStore(self.root, recovered_vault)
                self.assertEqual(recovered.last_recovery, "rolled-back")
                self.assertEqual(recovered.path.read_bytes(), self.original_state)
                self.assertEqual(recovered_vault.path.read_bytes(), self.original_vault)
                self.assertEqual(recovered.data, self.original_model)
                self.assertFalse(recovered.journal_path.exists())

    def test_crash_after_authenticated_commit_keeps_committed_pair(self):
        self.crash("commit:durable")
        committed_state = self.store.path.read_bytes()
        committed_vault = self.vault.path.read_bytes()
        recovered_vault = Vault(self.root)
        recovered_vault.unlock("transaction fixture password")
        recovered = StateStore(self.root, recovered_vault)
        self.assertEqual(recovered.last_recovery, "committed")
        self.assertEqual(recovered.path.read_bytes(), committed_state)
        self.assertEqual(recovered_vault.path.read_bytes(), committed_vault)
        self.assertEqual(len(recovered.workspaces), 2)
        self.assertFalse(recovered.journal_path.exists())

    def test_tampered_checkpoint_fails_closed_and_does_not_rewrite_either_file(self):
        self.crash("vault:after")
        journal = json.loads(self.store.journal_path.read_bytes())
        checkpoint = self.store.transaction_dir / (journal["id"] + ".checkpoint.uc")
        atomic_write(checkpoint, b"tampered encrypted checkpoint")
        previous_state, previous_vault = self.store.path.read_bytes(), self.vault.path.read_bytes()
        with self.assertRaises((VaultError, StateError)):
            StateStore(self.root, self.vault)
        self.assertEqual(self.store.path.read_bytes(), previous_state)
        self.assertEqual(self.vault.path.read_bytes(), previous_vault)
        self.assertTrue(self.store.journal_path.exists())

    def test_interrupted_rollback_preserves_capsule_and_succeeds_on_next_start(self):
        self.fail_at("model:after")
        actual_write = atomic_write

        def fail_rollback(path, content):
            if path == self.store.path and content == self.original_state:
                raise OSError("injected rollback write failure")
            return actual_write(path, content)

        with patch("uniconnect.state.atomic_write", side_effect=fail_rollback):
            with self.assertRaises(StateError):
                Importer(self.vault).preview(self.document()).apply(self.store)
        self.assertTrue(self.store.journal_path.exists())
        recovered = StateStore(self.root, self.vault)
        self.assertEqual(recovered.last_recovery, "rolled-back")
        self.assertEqual(recovered.path.read_bytes(), self.original_state)
        self.assertEqual(self.vault.path.read_bytes(), self.original_vault)


if __name__ == "__main__":
    unittest.main()
