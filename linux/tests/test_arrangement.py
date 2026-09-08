"""Observable pin/order contract with real persistence and the RPC boundary."""

import copy
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect.arrangement import WorkspaceArrangement
from uniconnect.mobile_protocol import RPCError
from uniconnect.mobile_rpc import MobileRPC
from uniconnect.state import StateStore


class ArrangementTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-arrangement-")
        self.addCleanup(self.directory.cleanup)
        self.store = StateStore(Path(self.directory.name))
        self.box = {"id": "box", "name": "Caja", "kind": "local", "splitAxis": "horizontal",
                    "splitPosition": 379, "selectedWindowId": "a", "windows": [
                        {"id": "a", "name": "A", "paneId": "left", "tmux": "a"},
                        {"id": "b", "name": "B", "paneId": "right", "tmux": "b"},
                        {"id": "c", "name": "C", "paneId": "left", "tmux": "c", "pinned": True},
                        {"id": "d", "name": "D", "paneId": "right", "tmux": "d"}]}
        self.store.workspaces.extend([self.box, {"id": "other", "name": "Otra", "kind": "local", "windows": []},
                                      {"id": "pin", "name": "Fijada", "kind": "local", "pinned": True, "windows": []}])
        self.store.data["selectedWorkspaceId"] = "other"
        self.store.save()
        self.arrangement = WorkspaceArrangement(self.store)
        self.window = types.SimpleNamespace(store=self.store, locked=False, surfaces={}, focused_surface=None,
                                            update_arrangement=self.arrangement.update)
        self.rpc = MobileRPC(self.window, None, lambda fn: fn())
        self.addCleanup(self.rpc.close_attachments)

    def call(self, method, **params):
        return self.rpc.dispatch("mobile." + method, params, "peer")

    def test_snapshot_stable_pinned_first_no_read_mutation_and_full_update(self):
        before = copy.deepcopy(self.store.data)
        snapshot = self.call("workspace.list")
        self.assertIn("box_update", snapshot["capabilities"])
        self.assertEqual([b["id"] for b in snapshot["workspaces"]], ["pin", "box", "other"])
        box = next(b for b in snapshot["workspaces"] if b["id"] == "box")
        self.assertEqual([t["id"] for t in box["terminals"]], ["c", "a", "b", "d"])
        self.assertTrue(all(type(t["is_pinned"]) is bool for t in box["terminals"]))
        self.assertEqual(before, self.store.data)
        result = self.call("workspace.update", workspace_id="other", is_pinned=True, position=0)
        self.assertEqual(result, self.call("workspace.list"))
        self.assertEqual([b["id"] for b in result["workspaces"]], ["other", "pin", "box"])
        self.assertEqual(self.store.data["selectedWorkspaceId"], "other")

    def test_pin_then_group_position_clamps_and_retry_does_not_toggle(self):
        result = self.call("terminal.update", workspace_id="box", terminal_id="d", is_pinned=True, position=-20)
        boxes = result["workspaces"]
        box = next(b for b in boxes if b["id"] == "box")
        self.assertEqual([t["id"] for t in box["terminals"]], ["d", "c", "a", "b"])
        with patch.object(self.store, "save", wraps=self.store.save) as save:
            self.assertEqual(result, self.call("terminal.update", workspace_id="box", terminal_id="d", is_pinned=True, position=0))
            save.assert_not_called()
        self.call("terminal.update", workspace_id="box", terminal_id="d", is_pinned=False, position=999)
        self.assertEqual([r["id"] for r in self.box["windows"]], ["c", "a", "b", "d"])
        self.assertEqual(self.box["paneOrder"], ["left", "right"])

    def test_roundtrip_order_preserves_dictionary_identity_focus_and_split_geometry(self):
        refs = {w["id"]: w for w in self.box["windows"]}
        identities = {key: (value["paneId"], value["tmux"]) for key, value in refs.items()}
        self.call("terminal.update", workspace_id="box", terminal_id="b", position=0)
        self.assertEqual([r["id"] for r in self.box["windows"]], ["c", "b", "a", "d"])
        self.assertEqual(self.box["selectedWindowId"], "a")
        self.assertEqual(self.box["splitPosition"], 379)
        self.assertEqual(self.box["splitAxis"], "horizontal")
        for record in self.box["windows"]:
            self.assertIs(record, refs[record["id"]])
            self.assertEqual((record["paneId"], record["tmux"]), identities[record["id"]])
        restored = StateStore(Path(self.directory.name))
        self.assertEqual(restored.workspaces, self.store.workspaces)
        self.assertEqual(WorkspaceArrangement.pane_ids(restored.workspaces[0]), ["left", "right"])

    def test_failure_rolls_back_model_and_disk_including_new_metadata(self):
        before = copy.deepcopy(self.store.data)
        disk = self.store.path.read_bytes()
        for method, params in [("workspace.update", {"workspace_id": "other", "is_pinned": True}),
                               ("terminal.update", {"workspace_id": "box", "terminal_id": "b", "is_pinned": True})]:
            with self.subTest(method=method), patch.object(self.store, "save", side_effect=OSError("fixture disk full")):
                with self.assertRaises(Exception):
                    self.call(method, **params)
                self.assertEqual(before, self.store.data)
                self.assertEqual(disk, self.store.path.read_bytes())

    def test_invalid_ids_types_and_noop_do_not_mutate(self):
        invalid = [{}, {"workspace_id": "missing"}, {"workspace_id": "box", "is_pinned": 1},
                   {"workspace_id": "box", "is_pinned": None}, {"workspace_id": "box", "position": True},
                   {"workspace_id": "box", "position": 1.5}, {"workspace_id": "box", "position": "0"}]
        before = copy.deepcopy(self.store.data)
        for params in invalid:
            with self.subTest(params=params), self.assertRaises(RPCError) as error:
                self.call("workspace.update", **params)
            self.assertEqual(error.exception.code, "invalid_params")
        for terminal_id in (None, "", "missing", 42):
            with self.subTest(terminal=terminal_id), self.assertRaises(RPCError) as error:
                self.call("terminal.update", workspace_id="box", terminal_id=terminal_id, is_pinned=True)
            self.assertEqual(error.exception.code, "invalid_params")
        with patch.object(self.store, "save", wraps=self.store.save) as save:
            self.call("workspace.update", workspace_id="box")
            save.assert_not_called()
        self.assertEqual(before, self.store.data)

    def test_revocation_lock_and_pending_transaction_block_update(self):
        before = copy.deepcopy(self.store.data)
        params = {"workspace_id": "box", "is_pinned": True}
        with self.assertRaises(RPCError) as error:
            self.rpc.dispatch("mobile.workspace.update", params, "peer", authorized=lambda: False)
        self.assertEqual(error.exception.code, "approval_required")
        self.window.locked = True
        with self.assertRaises(RPCError) as error:
            self.call("workspace.update", **params)
        self.assertEqual(error.exception.code, "locked")
        self.window.locked = False
        self.window._runtime_operation = types.SimpleNamespace(active=True)
        with self.assertRaises(RPCError) as error:
            self.call("workspace.update", **params)
        self.assertEqual(error.exception.code, "busy")
        self.window._runtime_operation = None
        self.store._active_transaction = object()
        try:
            with self.assertRaises(RPCError) as error:
                self.call("workspace.update", **params)
            self.assertEqual(error.exception.code, "busy")
        finally:
            self.store._active_transaction = None
        self.assertEqual(before, self.store.data)
