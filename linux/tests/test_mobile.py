"""Behavioural mobile protocol, approval and existing-pane coverage for CI."""

import base64
import json
import os
from pathlib import Path
import shutil
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect.mobile_access import MobileAccess, tailnet_address
from uniconnect.mobile_host import MobileHost, _Client, verified_tailscale_address
from uniconnect.mobile_protocol import FrameDecoder, RPCError, encode_frame
from uniconnect.mobile_rpc import MobileRPC


def fixture_profile():
    return {"palette": ("#000000", "#c11c22", "#26a269", "#a2734c", "#12488b", "#a347ba", "#2aa1b3", "#d0cfcc",
                        "#5e5c64", "#f66151", "#33d17a", "#e9ad0c", "#2a7bde", "#c061cb", "#33c7de", "#ffffff"),
            "foreground": "#dce2ed", "background": "#020a33"}


def capture_output(script, screen, *, metadata="80\t24\t2\t1\t1\t0"):
    marker = next(value for value in shlex.split(script) if value.startswith("UC_CAPTURE_"))
    return types.SimpleNamespace(stdout="Mensaje del shell, no de la pantalla\n" + marker + "\n" + screen
                                 + "\nUC_META\t" + metadata + "\n")


def grid_text(result):
    return "".join(span["text"] for span in result["render_grid"]["row_spans"])


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


class DesktopPaletteTests(unittest.TestCase):
    def test_desktop_color_application_and_mobile_profile_share_actual_rgba_values(self):
        try:
            import gi
            gi.require_version("Gdk", "3.0")
            from gi.repository import Gdk
            from uniconnect.terminal import TerminalSurface
        except (ImportError, ValueError):
            self.skipTest("GTK/VTE is required for the desktop color adapter")
        applied, changed = [], []
        background = Gdk.RGBA()
        background.parse("#020a33")
        context = types.SimpleNamespace(has_class=lambda name: name == "uc-dark",
                                         lookup_color=lambda name: (True, background))
        owner = types.SimpleNamespace(store=types.SimpleNamespace(data={"settings": {}}), font_scale=1,
                                      get_style_context=lambda: context)
        terminal = types.SimpleNamespace(set_font=lambda value: None, set_font_scale=lambda value: None,
                                         set_colors=lambda *values: applied.append(values))
        surface = types.SimpleNamespace(owner=owner, terminal=terminal,
                                         on_mobile_content_changed=lambda: changed.append(True))
        TerminalSurface.apply_appearance(surface)
        def rgb(color):
            return "#" + "".join(f"{round(value * 255):02x}" for value in (color.red, color.green, color.blue))
        foreground, background, colors = applied[0]
        self.assertEqual(surface.mobile_color_profile["foreground"], rgb(foreground))
        self.assertEqual(surface.mobile_color_profile["background"], rgb(background))
        self.assertEqual(surface.mobile_color_profile["palette"], tuple(map(rgb, colors)))
        self.assertEqual(len(colors), 16)
        self.assertEqual(changed, [True])


class ExistingDesktopTests(unittest.TestCase):
    def setUp(self):
        self.record = {"id": "window", "name": "Existente", "tmux": "fixture", "tmuxSocket": "uc-fixture",
                       "cwd": "/tmp", "agent": "claude", "sessionId": str(uuid.uuid4())}
        self.workspace = {"id": "workspace", "name": "Trabajo", "kind": "local", "cwd": "/tmp", "windows": [self.record]}
        self.sent, self.launched = [], []
        self.surface = types.SimpleNamespace(record=self.record, pid=42, disposed=False, terminal=FixtureTerminal(),
                                             send=self.sent.append, launch=lambda: self.launched.append(True),
                                             mobile_color_profile=fixture_profile())
        self.window = types.SimpleNamespace(
            store=types.SimpleNamespace(workspaces=[self.workspace], data={"selectedWorkspaceId": "other"}),
            locked=False, surfaces={"window": self.surface}, focused_surface=None)
        self.commands = []
        self.screen = "\x1b[31mExistente\x1b[0m\n"
        self.now, self.delays = 100.0, []
        def wait(delay):
            self.delays.append(delay)
            self.now += delay
        def transport(*args, **kwargs):
            def run(script, **options):
                self.commands.append(script)
                return capture_output(script, self.screen)
            return types.SimpleNamespace(run=run)
        self.rpc = MobileRPC(self.window, None, lambda callback: callback(), transport_factory=transport,
                             clock=lambda: self.now, wait=wait)
        self.params = {"workspace_id": "workspace", "surface_id": "window"}

    def test_list_replay_and_input_preserve_identity_and_desktop_selection(self):
        before = json.dumps(self.record, sort_keys=True)
        boxes = self.rpc.dispatch("mobile.workspace.list", {}, "peer")
        self.assertFalse(boxes["workspaces"][0]["is_selected"])
        self.assertEqual(boxes["workspaces"][0]["terminals"][0]["tmux_binding"]["name"], "fixture")
        replay = self.rpc.dispatch("mobile.terminal.replay", self.params, "peer")
        grid = replay["render_grid"]
        self.assertEqual(grid["format"], "cmux.render-grid.v1")
        self.assertEqual(grid["surface_id"], self.record["id"])
        self.assertEqual(grid_text(replay), "Existente")  # The login banner is excluded.
        self.assertEqual(grid["styles"][1]["foreground"], self.surface.mobile_color_profile["palette"][1])
        self.assertEqual((grid["cursor"]["column"], grid["cursor"]["row"]), (2, 1))
        self.assertEqual(grid["revision"], replay["revision"])
        self.assertEqual(self.rpc.dispatch("mobile.terminal.replay", self.params, "peer")["seq"], replay["seq"])
        self.assertEqual(len(self.commands), 1)
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

    def test_replay_keeps_blank_history_and_viewport_rows_and_revises_history_only_changes(self):
        self.screen = "\x1b[31mAnterior A\n\nVisible\x1b[0m\n"
        def run(script, **options):
            self.commands.append(script)
            return capture_output(script, self.screen, metadata="80\t2\t2\t1\t1\t0")
        self.rpc.transport_factory = lambda *args, **kwargs: types.SimpleNamespace(run=run)
        first = self.rpc.replay(self.params)
        grid = first["render_grid"]
        self.assertEqual(grid["scrollback_rows"], 2)
        self.assertEqual([span["text"] for span in grid["scrollback_spans"]], ["Anterior A"])
        self.assertEqual([span["row"] for span in grid["scrollback_spans"]], [0])
        self.assertEqual([(span["row"], span["text"]) for span in grid["row_spans"]], [(0, "Visible")])
        self.assertEqual(grid["scrollback_spans"][0]["style_id"], grid["row_spans"][0]["style_id"])
        self.assertEqual((grid["rows"], grid["cursor"]["row"]), (2, 1))
        self.assertEqual(len(self.commands), 1)
        arguments = shlex.split(self.commands[0])
        self.assertEqual(arguments[arguments.index("-S") + 1], "-300")
        self.assertEqual(arguments.count("capture-pane"), 1)
        self.assertNotIn("attach-session", arguments)
        self.assertNotIn("new-session", arguments)
        self.screen = self.screen.replace("Anterior A", "Anterior B")
        self.rpc.invalidate_terminal("window")
        second = self.rpc.replay(self.params)
        self.assertEqual(second["revision"], first["revision"] + 1)
        self.assertEqual(second["render_grid"]["row_spans"], first["render_grid"]["row_spans"])
        self.rpc.invalidate_terminal("window")
        self.assertEqual(self.rpc.replay(self.params)["revision"], second["revision"])
        self.assertEqual(self.sent, [])
        self.assertEqual(self.launched, [])
        self.assertEqual(self.window.store.data["selectedWorkspaceId"], "other")
        self.assertIsNone(self.window.focused_surface)

    def test_replay_never_exposes_primary_history_as_alternate_screen_history(self):
        self.rpc.transport_factory = lambda *args, **kwargs: types.SimpleNamespace(
            run=lambda script, **options: capture_output(script, "Anterior\nVisible\n", metadata="80\t2\t2\t1\t1\t1"))
        grid = self.rpc.replay(self.params)["render_grid"]
        self.assertEqual(grid["active_screen"], "alternate")
        self.assertEqual(grid["scrollback_rows"], 0)
        self.assertEqual(grid["scrollback_spans"], [])
        self.assertEqual([(span["row"], span["text"]) for span in grid["row_spans"]], [(0, "Visible")])

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
                def run(script, **kwargs):
                    mutation()
                    return capture_output(script, "private")
                return types.SimpleNamespace(run=run)
            self.rpc.transport_factory = transport
            with self.assertRaises(RPCError):
                self.rpc.dispatch("mobile.terminal.replay", self.params, "peer")

    def test_dirty_bursts_wait_for_one_fresh_capture_instead_of_returning_stale_cache(self):
        first = self.rpc.replay(self.params)
        self.screen = "Actualizada"
        for _ in range(100):
            self.rpc.invalidate_terminal(self.record["id"])
        updated = self.rpc.replay(self.params)
        self.assertEqual(grid_text(updated), "Actualizada")
        self.assertEqual(updated["revision"], first["revision"] + 1)
        self.assertEqual(self.delays, [0.25])
        self.assertEqual(len(self.commands), 2)
        self.rpc.replay(self.params)
        self.assertEqual(len(self.commands), 2)
        self.now += 0.25
        self.assertEqual(self.rpc.replay(self.params)["revision"], updated["revision"])
        self.assertEqual(len(self.commands), 3)  # Bounded refresh if VTE misses a notification.

    def test_ssh_capture_cadence_is_bounded_and_profile_changes_invalidate_colors(self):
        self.workspace["kind"] = "ssh"
        self.window.connection = lambda workspace: "ssh fixture.invalid"
        original = self.rpc.replay(self.params)
        profile = self.surface.mobile_color_profile
        self.surface.mobile_color_profile = {**profile, "palette": (profile["palette"][0], "#123456") + profile["palette"][2:]}
        current = self.rpc.replay(self.params)
        self.assertEqual(self.delays, [0.75])
        self.assertEqual(current["render_grid"]["styles"][1]["foreground"], "#123456")
        self.assertEqual(current["revision"], original["revision"] + 1)

    def test_cached_frame_still_rechecks_permission_and_never_creates_missing_surface(self):
        self.rpc.replay(self.params)
        self.window.locked = True
        with self.assertRaises(RPCError):
            self.rpc.replay(self.params)
        self.window.locked = False
        with self.assertRaises(RPCError):
            self.rpc.replay(self.params, authorized=lambda: False)
        self.window.surfaces.clear()
        with self.assertRaises(RPCError) as issue:
            self.rpc.replay(self.params)
        self.assertEqual(issue.exception.code, "surface_unavailable")
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(self.launched, [])

    def test_unknown_capture_controls_fail_explicitly_and_pending_wrap_cursor_is_clamped(self):
        self.screen = "tab\tindeterminada"
        with self.assertRaises(RPCError) as issue:
            self.rpc.replay(self.params)
        self.assertEqual(issue.exception.code, "snapshot_unavailable")
        self.rpc.transport_factory = lambda *args, **kwargs: types.SimpleNamespace(
            run=lambda script, **options: capture_output(script, "borde", metadata="80\t24\t80\t-1\t1\t1"))
        frame = self.rpc.replay(self.params)["render_grid"]
        self.assertEqual((frame["cursor"]["column"], frame["cursor"]["row"]), (79, 0))
        self.assertEqual(frame["active_screen"], "alternate")

    def test_absent_unicode_dependency_never_advertises_a_working_renderer(self):
        from unittest.mock import patch
        self.rpc.access = types.SimpleNamespace(machine_id="fixture")
        self.rpc.host = types.SimpleNamespace(address="100.64.0.1", port=58465)
        with patch("uniconnect.mobile_rpc.capture_dependencies_ready", return_value=False):
            status = self.rpc.dispatch("mobile.host.status", {}, "peer")
            self.assertEqual(status["terminal_fidelity"], "unavailable")
            self.assertNotIn("terminal.render_grid.v1", status["capabilities"])
            with self.assertRaises(RPCError):
                self.rpc.replay(self.params)
        self.assertEqual(self.commands, [])
        status = self.rpc.dispatch("mobile.host.status", {}, "peer")
        self.assertEqual(status["terminal_fidelity"], "render_grid")
        self.assertIn("terminal.render_grid.v1", status["capabilities"])

    def test_concurrent_captures_cannot_publish_an_old_screen_with_a_newer_revision(self):
        entered, release = threading.Event(), threading.Event()
        requests, results, failures = [], {}, []
        def run(script, **kwargs):
            requests.append(script)
            if len(requests) == 1:
                screen = self.screen
                entered.set()
                if not release.wait(2):
                    raise TimeoutError("Fixture release deadline")
                return capture_output(script, screen)
            return capture_output(script, self.screen)
        self.rpc.transport_factory = lambda *args, **kwargs: types.SimpleNamespace(run=run)
        def replay(key):
            try:
                results[key] = self.rpc.replay(self.params)
            except Exception as error:
                failures.append(error)
        first = threading.Thread(target=replay, args=("first",), daemon=True)
        second = threading.Thread(target=replay, args=("second",), daemon=True)
        try:
            first.start()
            self.assertTrue(entered.wait(2))
            second.start()
            self.screen = "Más reciente"
            self.rpc.invalidate_terminal(self.record["id"])
        finally:
            release.set()
            first.join(3)
            if second.ident is not None:
                second.join(3)
        self.assertFalse(first.is_alive() or second.is_alive())
        self.assertEqual(failures, [])
        self.assertEqual(grid_text(results["first"]), "Existente")
        self.assertEqual(grid_text(results["second"]), "Más reciente")
        self.assertLess(results["first"]["revision"], results["second"]["revision"])

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
    def test_full_replay_carries_last_300_styled_history_rows_without_moving_the_pane(self):
        socket_name = "uc-scrollback-ci-" + uuid.uuid4().hex[:12]
        with tempfile.TemporaryDirectory(prefix="uc-mobile-history-") as folder:
            args = ["tmux", "-f", "/dev/null", "-L", socket_name]
            program = "import sys,time; [print('\\x1b[31mHISTORIA-%03d\\x1b[0m' % i) for i in range(400)]; print('UC_SCROLL_READY', flush=True); time.sleep(30)"
            try:
                subprocess.run(args + ["new-session", "-d", "-s", "fixture", "-x", "80", "-y", "12",
                                       shlex.join([sys.executable, "-c", program])], check=True, timeout=5)
                pid = subprocess.check_output(args + ["display-message", "-p", "-t", "=fixture:", "#{pane_pid}"], text=True).strip()
                record = {"id": "window", "name": "Validación", "tmux": "fixture", "tmuxSocket": socket_name, "cwd": folder}
                workspace = {"id": "workspace", "name": "Fixture", "kind": "local", "windows": [record]}
                surface = types.SimpleNamespace(disposed=False, mobile_color_profile=fixture_profile())
                window = types.SimpleNamespace(locked=False,
                    store=types.SimpleNamespace(workspaces=[workspace], data={"selectedWorkspaceId": "other"}),
                    surfaces={"window": surface}, focused_surface=None)
                rpc = MobileRPC(window, None, lambda callback: callback())
                deadline = time.monotonic() + 5
                while True:
                    result = rpc.replay({"workspace_id": "workspace", "surface_id": "window"})
                    if "UC_SCROLL_READY" in grid_text(result):
                        break
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.04)
                grid = result["render_grid"]
                self.assertTrue(grid["full"])
                self.assertEqual(grid["scrollback_rows"], 300)
                lines = [""] * grid["scrollback_rows"]
                for span in grid["scrollback_spans"]:
                    self.assertGreaterEqual(span["row"], 0)
                    self.assertLess(span["row"], 300)
                    lines[span["row"]] += span["text"]
                    style = next(item for item in grid["styles"] if item["id"] == span["style_id"])
                    self.assertEqual(style["foreground"], fixture_profile()["palette"][1])
                expected = subprocess.check_output(args + ["capture-pane", "-p", "-N", "-S", "-300", "-E", "-1", "-t", "=fixture:"], text=True).splitlines()
                self.assertEqual(lines, expected)
                self.assertNotIn("HISTORIA-000", lines)
                self.assertEqual(pid, subprocess.check_output(args + ["display-message", "-p", "-t", "=fixture:", "#{pane_pid}"], text=True).strip())
                self.assertEqual(window.store.data["selectedWorkspaceId"], "other")
                self.assertIsNone(window.focused_surface)
            finally:
                subprocess.run(args + ["kill-server"], capture_output=True, timeout=5)

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
                surface = types.SimpleNamespace(disposed=False, mobile_color_profile=fixture_profile())
                window = types.SimpleNamespace(locked=False, store=types.SimpleNamespace(workspaces=[workspace]),
                                               surfaces={"window": surface})
                rpc = MobileRPC(window, None, lambda callback: callback())
                deadline = time.monotonic() + 5
                while True:
                    result = rpc.dispatch("mobile.terminal.replay", {"workspace_id": "workspace", "surface_id": "window"}, "peer")
                    if "UC_EXISTING" in grid_text(result):
                        break
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.04)
                self.assertEqual(pid, subprocess.check_output(args + ["display-message", "-p", "-t", "=fixture:", "#{pane_pid}"], text=True).strip())
                self.assertEqual(subprocess.check_output(args + ["list-sessions", "-F", "#{session_name}"], text=True).splitlines(), ["fixture"])
            finally:
                subprocess.run(args + ["kill-server"], capture_output=True, timeout=5)


if __name__ == "__main__":
    unittest.main()
