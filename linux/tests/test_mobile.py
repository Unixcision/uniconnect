"""Behavioural mobile protocol, approval and existing-pane coverage for CI."""

import base64
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import types
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect.mobile_access import MobileAccess, tailnet_address
from uniconnect.mobile_host import MobileHost, _Client, verified_tailscale_address
from uniconnect.mobile_protocol import FrameDecoder, RPCError, encode_frame
from uniconnect.mobile_rpc import MobileRPC


class ProtocolTests(unittest.TestCase):
    def test_split_headers_bodies_and_multiple_frames(self):
        messages = [{"id": "1", "method": "mobile.workspace.list", "params": {}},
                    {"id": "2", "ok": True, "result": {"title": "Ventana española"}}]
        wire = b"".join(encode_frame(message) for message in messages)
        for split in range(len(wire)):
            decoder = FrameDecoder()
            self.assertEqual(decoder.feed(wire[:split]) + decoder.feed(wire[split:]), messages)
        with self.assertRaises(ValueError):
            FrameDecoder().feed(b"\xff\xff\xff\xff")

    def test_peer_identity_is_numeric_tailnet_not_a_json_claim(self):
        self.assertEqual(tailnet_address("::ffff:100.64.0.1"), "100.64.0.1")
        for candidate in ("127.0.0.1", "192.168.1.2", "10.0.0.1", "100.63.255.255", "example.ts.net", None):
            self.assertIsNone(tailnet_address(candidate))

    def test_no_read_or_mutation_before_local_approval_and_revocation_closes_peer(self):
        with tempfile.TemporaryDirectory(prefix="uc-mobile-access-") as folder:
            access = MobileAccess(Path(folder))
            calls = []
            rpc = types.SimpleNamespace(dispatch=lambda *args, **kwargs: calls.append(args) or {"workspaces": []},
                                        disconnected=lambda identifier: None)
            host = MobileHost(access, rpc)
            left, right = socket.socketpair()
            client = _Client(host, left, "100.64.0.2")
            host.clients.add(client)
            try:
                request = {"id": "probe", "method": "mobile.workspace.list",
                           "params": {"address": "100.64.0.9", "device_name": "Mi teléfono"},
                           "auth": {"stack_access_token": "not-an-approval"}}
                client.handle(request)
                response = FrameDecoder().feed(client.queue.pop()[1])[0]
                self.assertEqual(response["error"]["code"], "approval_required")
                self.assertEqual(calls, [])
                self.assertEqual(access.snapshot()[1][0]["address"], "100.64.0.2")
                self.assertTrue(access.approve("100.64.0.2"))
                client.handle(request)
                self.assertEqual(len(calls), 1)
                self.assertTrue(MobileAccess(Path(folder)).authorize("100.64.0.2"))
                access.revoke("100.64.0.2")
                self.assertTrue(client.closed)
                self.assertFalse(MobileAccess(Path(folder)).authorize("100.64.0.2"))
            finally:
                client.close()
                right.close()

    def test_approval_failure_never_grants_access_and_pending_requests_expire(self):
        with tempfile.TemporaryDirectory(prefix="uc-mobile-access-") as folder:
            now = [100.0]
            access = MobileAccess(Path(folder), clock=lambda: now[0])
            for number in range(1, 20):
                self.assertFalse(access.authorize(f"100.64.0.{number}"))
            self.assertEqual(len(access.snapshot()[1]), 8)
            def fail(*args):
                raise OSError("fixture write failure")
            access.writer = fail
            with self.assertRaises(OSError):
                access.approve("100.64.0.1")
            self.assertFalse(access.authorize("100.64.0.1"))
            now[0] = 221.0
            self.assertEqual(access.snapshot()[1], [])
            self.assertFalse(access.approve("100.64.0.1"))

    def test_status_and_kernel_interface_must_agree(self):
        def result(argv, **kwargs):
            data = ({"BackendState": "Running", "Self": {"TailscaleIPs": ["100.64.0.7"]}}
                    if "status" in argv else [{"addr_info": [{"local": "100.64.0.8"}]}])
            return types.SimpleNamespace(stdout=json.dumps(data))
        from unittest.mock import patch
        with patch("uniconnect.mobile_host.shutil.which", return_value="/fixture/tailscale"):
            with self.assertRaises(RuntimeError):
                verified_tailscale_address(run=result)


class FixtureTerminal:
    def __init__(self):
        self.columns, self.rows = 160, 50
        self.sizes = []

    def get_column_count(self):
        return self.columns

    def get_row_count(self):
        return self.rows

    def set_size(self, columns, rows):
        self.columns, self.rows = columns, rows
        self.sizes.append((columns, rows))


class ExistingDesktopTests(unittest.TestCase):
    def setUp(self):
        self.record = {"id": "window", "name": "Existente", "tmux": "fixture", "tmuxSocket": "uc-fixture",
                       "cwd": "/tmp", "agent": "claude", "sessionId": str(uuid.uuid4())}
        self.workspace = {"id": "workspace", "name": "Trabajo", "kind": "local", "cwd": "/tmp", "windows": [self.record]}
        self.sent, self.launched = [], []
        self.surface = types.SimpleNamespace(record=self.record, pid=42, disposed=False, terminal=FixtureTerminal(),
                                             send=self.sent.append, launch=lambda: self.launched.append(True))
        self.window = types.SimpleNamespace(
            store=types.SimpleNamespace(workspaces=[self.workspace], data={"selectedWorkspaceId": "other"}),
            locked=False, surfaces={"window": self.surface}, focused_surface=None)
        self.commands = []
        def transport(*args, **kwargs):
            def run(script, **options):
                self.commands.append(script)
                return types.SimpleNamespace(stdout="\x1b[31mExistente\x1b[0m\n\nUC_META\t80\t24\t2\t1\t1\t0\n")
            return types.SimpleNamespace(run=run)
        self.rpc = MobileRPC(self.window, None, lambda callback: callback(), transport_factory=transport)
        self.params = {"workspace_id": "workspace", "surface_id": "window"}

    def test_list_replay_and_input_preserve_identity_and_desktop_selection(self):
        before = json.dumps(self.record, sort_keys=True)
        boxes = self.rpc.dispatch("mobile.workspace.list", {}, "peer")
        self.assertFalse(boxes["workspaces"][0]["is_selected"])
        self.assertEqual(boxes["workspaces"][0]["terminals"][0]["tmux_binding"]["name"], "fixture")
        replay = self.rpc.dispatch("mobile.terminal.replay", self.params, "peer")
        self.assertEqual(replay["snapshot_format"], "tmux.active.vt")
        self.assertIn(b"\x1b[31mExistente", base64.b64decode(replay["snapshot_data_b64"]))
        self.assertEqual(self.rpc.dispatch("mobile.terminal.replay", self.params, "peer")["seq"], replay["seq"])
        result = self.rpc.dispatch("mobile.terminal.input", {**self.params, "text": "hola\r"}, "peer")
        self.assertTrue(result["queued"])
        self.assertEqual(self.sent, ["hola\r"])
        self.assertEqual(self.launched, [])
        self.assertEqual(json.dumps(self.record, sort_keys=True), before)
        self.assertEqual(self.window.store.data["selectedWorkspaceId"], "other")
        self.assertTrue(all("capture-pane" in script and "new-session" not in script and "attach-session" not in script
                            for script in self.commands))

    def test_conflicting_or_absent_target_never_falls_back_to_selected_surface(self):
        for params in ({"text": "bad"}, {**self.params, "terminal_id": "other", "text": "bad"},
                       {**self.params, "workspace_id": "other", "text": "bad"}):
            with self.assertRaises(RPCError):
                self.rpc.dispatch("mobile.terminal.input", params, "peer")
        self.assertEqual(self.sent, [])
        self.assertEqual(self.launched, [])

    def test_disconnected_input_is_rejected_not_queued_or_auto_restarted(self):
        self.surface.pid = 0
        with self.assertRaises(RPCError) as issue:
            self.rpc.dispatch("mobile.terminal.input", {**self.params, "text": "test"}, "peer")
        self.assertEqual(issue.exception.code, "process_exited")
        self.assertEqual(self.sent, [])
        self.assertEqual(self.launched, [])

    def test_revoked_queued_input_is_rejected_at_the_desktop_boundary(self):
        with self.assertRaises(RPCError) as issue:
            self.rpc.dispatch("mobile.terminal.input", {**self.params, "text": "late"}, "peer", authorized=lambda: False)
        self.assertEqual(issue.exception.code, "approval_required")
        self.assertEqual(self.sent, [])

    def test_replay_completed_after_lock_or_target_replacement_is_not_published(self):
        for mutation in (lambda: setattr(self.window, "locked", True),
                         lambda: self.record.update(tmux="replacement")):
            self.window.locked = False
            self.record["tmux"] = "fixture"
            def transport(*args, **kwargs):
                def run(*args, **kwargs):
                    mutation()
                    return types.SimpleNamespace(stdout="private\nUC_META\t80\t24\t0\t0\t1\t0\n")
                return types.SimpleNamespace(run=run)
            self.rpc.transport_factory = transport
            with self.assertRaises(RPCError):
                self.rpc.dispatch("mobile.terminal.replay", self.params, "peer")

    def test_disconnect_releases_only_that_peers_viewport_and_final_peer_restores_size(self):
        for peer, columns in (("first", 80), ("second", 60)):
            self.rpc.dispatch("mobile.terminal.viewport", {**self.params, "client_id": "same-name",
                              "viewport_columns": columns, "viewport_rows": 20}, peer)
        self.assertEqual(self.surface.terminal.columns, 60)
        self.rpc.disconnected("second")
        self.assertEqual(self.surface.terminal.columns, 80)
        self.rpc.disconnected("first")
        self.assertEqual((self.surface.terminal.columns, self.surface.terminal.rows), (160, 50))

    def test_notifications_cursor_survives_removing_older_items(self):
        values = [{"id": str(number), "created_at_ms": number} for number in range(10)]
        self.window.store.data["notificationHistory"] = values
        first = self.rpc.dispatch("mobile.notifications.list", {"limit": 2}, "peer")
        self.assertEqual([item["id"] for item in first["notifications"]], ["9", "8"])
        values.remove(values[-3])  # Item 7 disappears between pages.
        second = self.rpc.dispatch("mobile.notifications.list", {"limit": 2, "before": first["next_cursor"]}, "peer")
        self.assertEqual([item["id"] for item in second["notifications"]], ["6", "5"])


@unittest.skipUnless(os.environ.get("CI") == "true" and shutil.which("tmux"), "Real tmux runs only in CI")
class RealTmuxReplayTests(unittest.TestCase):
    def test_replay_reads_exact_existing_pane_without_starting_another_process(self):
        socket_name = "uc-mobile-ci-" + uuid.uuid4().hex[:12]
        with tempfile.TemporaryDirectory(prefix="uc-mobile-tmux-") as folder:
            args = ["tmux", "-f", "/dev/null", "-L", socket_name]
            try:
                subprocess.run(args + ["new-session", "-d", "-s", "fixture", "-x", "80", "-y", "24",
                                       "printf '\\033[31mUC_EXISTING\\033[0m\\n'; sleep 30"], check=True, timeout=5)
                pid = subprocess.check_output(args + ["display-message", "-p", "-t", "=fixture:", "#{pane_pid}"], text=True).strip()
                record = {"id": "window", "name": "Prueba", "tmux": "fixture", "tmuxSocket": socket_name, "cwd": folder}
                workspace = {"id": "workspace", "name": "Fixture", "kind": "local", "windows": [record]}
                window = types.SimpleNamespace(locked=False, store=types.SimpleNamespace(workspaces=[workspace]), surfaces={})
                rpc = MobileRPC(window, None, lambda callback: callback())
                deadline = time.monotonic() + 5
                while True:
                    result = rpc.dispatch("mobile.terminal.replay", {"workspace_id": "workspace", "surface_id": "window"}, "peer")
                    if "UC_EXISTING" in base64.b64decode(result["snapshot_data_b64"]).decode():
                        break
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.04)
                self.assertEqual(pid, subprocess.check_output(args + ["display-message", "-p", "-t", "=fixture:", "#{pane_pid}"], text=True).strip())
                self.assertEqual(subprocess.check_output(args + ["list-sessions", "-F", "#{session_name}"], text=True).splitlines(), ["fixture"])
            finally:
                subprocess.run(args + ["kill-server"], capture_output=True, timeout=5)


if __name__ == "__main__":
    unittest.main()
