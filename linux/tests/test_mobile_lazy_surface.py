"""A mobile request attaches only its saved terminal, without selecting its box."""

import copy
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Vte", "2.91")
    from gi.repository import Gio, GLib, Gtk
    from uniconnect.mobile_protocol import RPCError
    from uniconnect.mobile_rpc import MobileRPC
    from uniconnect.state import StateStore
    from uniconnect.transport import Transport
    from uniconnect.vault import Vault
    from uniconnect.window import MainWindow
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


@unittest.skipUnless(GTK_AVAILABLE and shutil.which("tmux"), "GTK/VTE display and tmux required")
class MobileLazySurfaceTests(unittest.TestCase):
    def wait_for(self, predicate, timeout=8):
        loop = GLib.MainLoop()
        deadline = time.monotonic() + timeout
        issues = []
        def observe():
            try:
                if predicate():
                    loop.quit()
                    return False
                if time.monotonic() >= deadline:
                    raise AssertionError("The isolated terminal did not become ready before the deadline")
            except BaseException as error:
                issues.append(error)
                loop.quit()
                return False
            return True
        GLib.timeout_add(25, observe)
        loop.run()
        if issues:
            raise issues[0]

    def test_replay_attaches_one_saved_pane_without_creating_selecting_or_replacing_it(self):
        socket = "uc-mobile-lazy-" + uuid.uuid4().hex[:10]
        app = Gtk.Application(application_id="com.unixcision.uniconnect.lazytest" + uuid.uuid4().hex[:8],
                              flags=Gio.ApplicationFlags.NON_UNIQUE)
        app.register(None)
        window = None
        with tempfile.TemporaryDirectory(prefix="uc-mobile-lazy-") as directory:
            root = Path(directory) / "state"
            vault = Vault(root)
            vault.initialize("isolated-fixture-only")
            store = StateStore(root, vault=vault)
            transport = Transport(socket_name=socket)
            records = [{"id": f"window-{index}", "name": f"Terminal {index}", "cwd": directory,
                        "tmux": f"fixture-{index}", "tmuxSocket": socket, "agent": "custom",
                        "commandArgv": ["/bin/sh", "-c", "printf 'UC_EXISTING\\n'; exec /bin/cat"],
                        "sessionId": str(uuid.uuid4()), "paneId": "main"} for index in range(4)]
            for index in range(2):
                members = records[index * 2:index * 2 + 2]
                store.workspaces.append({"id": f"box-{index}", "name": f"Caja {index}", "kind": "local",
                                         "cwd": directory, "windows": members, "selectedWindowId": members[0]["id"]})
            store.data["selectedWorkspaceId"] = "box-0"
            store.save()

            def tmux(*arguments):
                return subprocess.check_output(["tmux", "-L", socket, *arguments], text=True, timeout=3)

            try:
                # All four panes already exist. Only the visible box has VTE clients.
                for record in records:
                    transport.ensure_session(record)
                identities = tmux("list-panes", "-a", "-F", "#{session_name}:#{session_id}:#{pane_id}:#{pane_pid}")
                window = MainWindow(app, store, vault)
                window.present()
                self.wait_for(lambda: len(window.surfaces) == 2 and all(surface.pid for surface in window.surfaces.values())
                              and window._sidebar_refresh == 0)
                window.select_workspace("box-0")
                self.wait_for(lambda: window._sidebar_refresh == 0)
                focused = window.focused_surface
                focus_widget = window.get_focus()
                selected = (store.data["selectedWorkspaceId"], tuple(box["selectedWindowId"] for box in store.workspaces))
                untouched = copy.deepcopy(records[3])
                target = records[2]
                target_identity = {key: target[key] for key in ("id", "tmux", "tmuxSocket", "agent", "sessionId", "cwd")}
                rpc = MobileRPC(window, None, lambda callback: callback())
                params = {"workspace_id": "box-1", "surface_id": target["id"]}

                with patch.object(Transport, "ensure_session", side_effect=AssertionError("mobile must never create a session")):
                    boxes = rpc.dispatch("mobile.workspace.list", {}, "fixture-peer")["workspaces"]
                    self.assertEqual(sum(len(box["terminals"]) for box in boxes), 4)
                    self.assertEqual(len(window.surfaces), 2)
                    window.locked = True
                    with self.assertRaises(RPCError):
                        rpc.dispatch("mobile.terminal.replay", params, "fixture-peer")
                    window.locked = False
                    with self.assertRaises(RPCError):
                        rpc.dispatch("mobile.terminal.replay", params, "fixture-peer", authorized=lambda: False)
                    self.assertEqual(len(window.surfaces), 2)

                    # Regression: this currently raises surface_unavailable even
                    # though the saved tmux pane is alive and exactly identified.
                    replay = rpc.dispatch("mobile.terminal.replay", params, "fixture-peer")
                    self.assertEqual(replay["render_grid"]["surface_id"], target["id"])
                    self.assertEqual(set(window.surfaces), {records[0]["id"], records[1]["id"], target["id"]})
                    self.assertNotIn("box-1", window.pages)
                    surface = window.surfaces[target["id"]]
                    self.assertIs(surface.record, target)
                    self.assertIs(surface.workspace, store.workspaces[1])
                    self.wait_for(lambda: surface.pid and f"{surface.pid}:fixture-2" in tmux("list-clients", "-F", "#{client_pid}:#{session_name}"))
                    self.assertIs(window.focused_surface, focused)
                    self.assertIs(window.get_focus(), focus_widget)
                    self.assertEqual((store.data["selectedWorkspaceId"], tuple(box["selectedWindowId"] for box in store.workspaces)), selected)
                    self.assertEqual(records[3], untouched)
                    self.assertEqual({key: target[key] for key in target_identity}, target_identity)
                    self.assertEqual(tmux("list-panes", "-a", "-F", "#{session_name}:#{session_id}:#{pane_id}:#{pane_pid}"), identities)

                    result = rpc.dispatch("mobile.terminal.input", {**params, "text": "UC_MOBILE_INPUT\r"}, "fixture-peer")
                    self.assertTrue(result["queued"])
                    self.wait_for(lambda: "UC_MOBILE_INPUT" in tmux("capture-pane", "-p", "-t", "=fixture-2:"))
                    client_pid = surface.pid
                    window.select_workspace("box-1")  # Explicit desktop navigation now adopts the same VTE.
                    self.wait_for(lambda: window._sidebar_refresh == 0)
                    self.assertIs(window.surfaces[target["id"]], surface)
                    self.assertEqual(surface.pid, client_pid)
                    self.assertIs(surface.get_parent(), window.notebooks[("box-1", "main")])
                    self.assertEqual(tmux("list-panes", "-a", "-F", "#{session_name}:#{session_id}:#{pane_id}:#{pane_pid}"), identities)
            finally:
                if window:
                    window.on_delete()
                    window.destroy()
                subprocess.run(["tmux", "-L", socket, "kill-server"], capture_output=True, timeout=3)
                (Path.home() / ".local/state/uniconnect" / ("tmux-create-" + socket + ".lock")).unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
