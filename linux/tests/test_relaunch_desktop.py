"""Durable UI receipts and model ownership; no application sessions involved."""

import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

from uniconnect.relaunch import RelaunchService
from uniconnect.relaunch_desktop import RelaunchDesktop
from uniconnect.relaunch_fleet import RelaunchFleet
from uniconnect.relaunch_history import RelaunchHistory
from uniconnect.mobile_protocol import RPCError
from test_relaunch import Adapter


class ReceiptTests(unittest.TestCase):
    def test_receipt_survives_reopen_without_token_or_ability_to_reapply(self):
        with tempfile.TemporaryDirectory() as folder:
            history = RelaunchHistory(Path(folder), clock=lambda: 100)
            target = {"key": "pane", "label": "Caja · Codex", "provider": "codex", "generation": 1}
            host_plan = {"operation_id": "00000000-0000-0000-0000-000000000002", "token": "private-token",
                         "targets": [target], "excluded": []}
            fleet = SimpleNamespace(hosts=[{"id": "100.64.0.2", "label": "Mac", "plan": host_plan}])
            plan = {"operation_id": "00000000-0000-0000-0000-000000000001", "verb": "agent.relaunch",
                    "targets": [target], "excluded": [], "token": "private-token", "fleet": fleet}
            history.remember(plan)
            receipt = RelaunchHistory(Path(folder)).recent()[0]
            self.assertNotIn("token", receipt)
            self.assertNotIn("token", receipt["hosts"][0]["plan"])
            self.assertEqual(next(Path(folder).glob("*.json")).stat().st_mode & 0o777, 0o600)
            calls = []
            restored = RelaunchFleet.restore(None, receipt["hosts"], call=lambda address, method, params:
                calls.append((method, params)) or {"operation_state": "terminada", "results": []})
            restored.operation("relaunch.status")
            self.assertEqual(calls, [("relaunch.status", {"operation_id": host_plan["operation_id"]})])
            with self.assertRaises(RPCError):
                restored.operation("relaunch.apply")
            self.assertEqual(len(calls), 1)


class DesktopModelTests(unittest.TestCase):
    def test_snapshot_never_downgrades_missing_ssh_credentials_and_rejects_changed_model(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            adapter = Adapter()
            observed = []
            probe = adapter.probe
            adapter.probe = lambda candidate, verb: observed.append(candidate) or probe(candidate, verb)
            service = RelaunchService(root / "operations", adapter, submit=lambda *args: None)
            workspace = {"id": "box", "name": "Caja", "kind": "ssh", "credentialId": "credential",
                         "windows": [{"id": "window", "name": "IA", "tmux": "tmux", "agent": "codex"}]}
            window = SimpleNamespace(store=SimpleNamespace(root=root, workspaces=[workspace]),
                mobile=SimpleNamespace(access=SimpleNamespace(machine_id="machine")), locked=False, _closed=False,
                connection=lambda box: None)
            desktop = RelaunchDesktop(window, lambda action: action(), service=service)
            desktop.dispatch("relaunch.plan", {"verb": "agent.relaunch", "scope": {"kind": "machine", "id": "machine"}})
            self.assertIsNone(observed[0]["record"]["tmux"])
            self.assertEqual(workspace["windows"][0]["tmux"], "tmux")
            snapshot = desktop.snapshot({"kind": "window", "id": "window"})[0]
            self.assertTrue(desktop.current(snapshot))
            workspace["credentialId"] = "changed"
            self.assertFalse(desktop.current(snapshot))
            window.locked = True
            with self.assertRaises(RPCError):
                desktop.snapshot({"kind": "machine", "id": "machine"})
