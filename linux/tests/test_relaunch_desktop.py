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
from uniconnect.machine_directory import MachineDirectory, endpoint
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
            window.connection = lambda box: "ssh user@100.64.0.2"
            snapshot = desktop.snapshot({"kind": "window", "id": "window"})[0]
            self.assertTrue(desktop.current(snapshot))
            window.connection = lambda box: "ssh user@100.64.0.3"
            self.assertFalse(desktop.current(snapshot))
            window.connection = lambda box: "ssh user@100.64.0.2"
            workspace["credentialId"] = "changed"
            self.assertFalse(desktop.current(snapshot))
            window.locked = True
            with self.assertRaises(RPCError):
                desktop.snapshot({"kind": "machine", "id": "machine"})


class DirectoryTests(unittest.TestCase):
    def test_inventory_has_explicit_routes_independent_of_incoming_approvals(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = MachineDirectory(Path(folder))
            self.assertEqual(directory.snapshot(), [])
            saved = directory.save("Mac", "mac.tail123.ts.net", "59001")
            original = saved[0]["id"]
            self.assertEqual(saved[0]["port"], 59001)
            self.assertEqual(MachineDirectory(Path(folder)).snapshot(), saved)
            changed = directory.save("Mac renombrado", "mac.tail123.ts.net", 59001)
            self.assertEqual(len(changed), 1)
            self.assertEqual(changed[0]["id"], original)
            self.assertEqual(directory.remove(original), [])
            self.assertEqual(directory.path.stat().st_mode & 0o777, 0o600)
        for host, port in (("example.com", 58465), ("127.0.0.1", 123), ("100.64.0.2", 0),
                           ("100.64.0.2", 65536), ("x;echo", 58465)):
            with self.assertRaises(ValueError):
                endpoint(host, port)


class MobileOwnerTests(unittest.TestCase):
    def test_actual_peer_owns_operation_across_tcp_reconnect_but_not_revocation(self):
        from uniconnect.mobile_access import MobileAccess
        from uniconnect.mobile_rpc import MobileRPC
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            access = MobileAccess(root)
            for address in ("100.64.0.2", "100.64.0.3"):
                access.authorize(address)
                access.approve(address)
            jobs, adapter = [], Adapter()
            service = RelaunchService(root / "operations", adapter, submit=lambda *job: jobs.append(job))
            workspace = {"id": "box", "name": "Caja", "kind": "local", "windows": [
                {"id": "window", "name": "Codex", "agent": "codex", "tmux": "fixture"}]}
            window = SimpleNamespace(store=SimpleNamespace(root=root, workspaces=[workspace], data={}),
                                     mobile=SimpleNamespace(access=access), locked=False, _closed=False, surfaces={}, focused_surface=None)
            window.relaunch = RelaunchDesktop(window, lambda action: action(), service=service)
            rpc = MobileRPC(window, access, lambda action: action(), file_put=SimpleNamespace(),
                            remote_inbox=SimpleNamespace(), transcription=SimpleNamespace())
            rpc.host = SimpleNamespace(peer_of=lambda connection: "100.64.0.3" if connection == "other" else "100.64.0.2",
                                       address="100.64.0.1", port=58465)
            self.assertIn("relaunch.v1", rpc.dispatch("mobile.host.status", {}, "first")["capabilities"])
            self.assertIn("relaunch.v1", rpc.dispatch("mobile.workspace.list", {}, "first")["capabilities"])
            plan = rpc.dispatch("mobile.relaunch.plan", {"verb": "agent.relaunch",
                "scope": {"kind": "machine", "id": access.machine_id}, "owner": "spoof"}, "first")
            params = {"operation_id": plan["operation_id"], "token": plan["token"]}
            with self.assertRaises(RPCError):
                rpc.dispatch("mobile.relaunch.apply", params, "other")
            self.assertEqual(jobs, [])
            rpc.dispatch("mobile.relaunch.apply", params, "second-connection-same-peer")
            self.assertEqual(len(jobs), 1)
            access.revoke("100.64.0.2")
            jobs[0][0](*jobs[0][1:])
            self.assertEqual(adapter.calls, [])
            with self.assertRaises(RPCError):
                rpc.dispatch("mobile.relaunch.status", {"operation_id": plan["operation_id"]}, "third-connection")
