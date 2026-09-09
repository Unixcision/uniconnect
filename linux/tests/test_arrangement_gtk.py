"""Real notebooks, actions and RPC on an isolated GTK display and tmux socket."""

import copy
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Vte", "2.91")
from gi.repository import Gio, Gtk
from uniconnect.mobile_rpc import MobileRPC
from uniconnect.state import StateStore
from uniconnect.transport import Transport
from uniconnect.vault import Vault
from uniconnect.window import MainWindow
from test_window import MainWindowLifecycleTests


@unittest.skipUnless(Gtk.init_check()[0] and shutil.which("tmux"), "Isolated GTK display and tmux required")
class ArrangementGTKTests(unittest.TestCase):
    wait_for = MainWindowLifecycleTests.wait_for

    def test_rpc_actions_drag_rollback_and_restore_preserve_focus_panes_and_processes(self):
        socket_name = "uc-order-test-" + uuid.uuid4().hex[:12]
        app = Gtk.Application(application_id="com.unixcision.uniconnect.order" + uuid.uuid4().hex[:8],
                              flags=Gio.ApplicationFlags.NON_UNIQUE)
        app.register(None)
        window = None
        with tempfile.TemporaryDirectory(prefix="uc-order-ui-") as directory:
            root = Path(directory) / "state"
            vault = Vault(root)
            vault.initialize("isolated-favourite-test")
            store = StateStore(root, vault=vault)
            records = [{"id": name, "name": name.upper(), "cwd": directory, "tmux": "fixture-" + name,
                        "tmuxSocket": socket_name, "paneId": "right" if name == "b" else "left",
                        "agent": "custom", "commandArgv": ["/usr/bin/sleep", "120"]} for name in "abcd"]
            box = {"id": "box", "name": "Caja", "kind": "local", "cwd": directory,
                   "windows": records[:3], "selectedWindowId": "a", "splitPosition": 370, "splitAxis": "horizontal"}
            cold = {"id": "cold", "name": "Guardada", "kind": "local", "cwd": directory,
                    "windows": records[3:], "selectedWindowId": "d"}
            store.workspaces.extend([box, cold])
            store.data["selectedWorkspaceId"] = "box"
            store.save()
            def panes():
                return subprocess.check_output(["tmux", "-L", socket_name, "list-panes", "-a", "-F",
                                                "#{session_name}:#{pane_id}:#{pane_pid}"], text=True, timeout=3)
            try:
                transport = Transport(socket_name=socket_name)
                for record in records:
                    transport.ensure_session(record)
                before_panes = panes()
                window = MainWindow(app, store, vault)
                window.present()
                self.wait_for(lambda: len(window.surfaces) == 3 and all(s.pid for s in window.surfaces.values())
                              and not window._sidebar_refresh)
                window.select_surface(window.surfaces["a"])
                self.wait_for(lambda: not window._sidebar_refresh)
                focus, surface = window.get_focus(), window.focused_surface
                clients = {key: s.pid for key, s in window.surfaces.items()}
                notebooks = dict(window.notebooks)
                rpc = MobileRPC(window, None, lambda fn: fn())
                def update(method, **params):
                    return rpc.dispatch("mobile." + method, params, "isolated-peer")
                def order(notebook):
                    return [notebook.get_nth_page(i).record["id"] for i in range(notebook.get_n_pages())]
                left, right = notebooks[("box", "left")], notebooks[("box", "right")]
                with patch.object(window, "build_workspace", side_effect=AssertionError("metadata must not rebuild terminals")):
                    result = update("terminal.update", workspace_id="box", terminal_id="c", is_pinned=True, position=0)
                    self.assertIn("box_update", result["capabilities"])
                    self.assertEqual(order(left), ["c", "a"])
                    update("terminal.update", workspace_id="box", terminal_id="b", position=0)
                    self.assertEqual([r["id"] for r in box["windows"]], ["c", "b", "a"])
                    update("workspace.update", workspace_id="cold", is_pinned=True)
                    update("terminal.update", workspace_id="cold", terminal_id="d", is_pinned=True)
                    self.assertNotIn("d", window.surfaces)
                    window.run_action("window_first")
                    self.assertEqual([r["id"] for r in box["windows"]], ["c", "a", "b"])
                    window.run_action("pin_window")
                    self.assertTrue(surface.record["pinned"])
                    window.run_action("pin_window")
                    self.assertFalse(surface.record["pinned"])
                    # A real notebook drop cannot move a favourite behind others.
                    left.reorder_child(window.surfaces["c"], 1)
                    self.assertEqual(order(left), ["c", "a"])
                    update("terminal.update", workspace_id="box", terminal_id="c", is_pinned=False)
                    left.reorder_child(window.surfaces["c"], 1)
                    self.assertEqual(order(left), ["a", "c"])
                    self.assertEqual([r["id"] for r in box["windows"]], ["a", "c", "b"])
                    before = copy.deepcopy(store.data)
                    disk = store.path.read_bytes()
                    failures = []
                    with patch.object(store, "save", side_effect=OSError("fixture no space")), patch.object(window, "error", side_effect=failures.append):
                        left.reorder_child(window.surfaces["c"], 0)
                        self.assertEqual(order(left), ["a", "c"])
                        self.assertEqual(store.data, before)
                        self.assertEqual(store.path.read_bytes(), disk)
                    self.assertTrue(failures)
                self.wait_for(lambda: not window._sidebar_refresh)
                self.assertEqual(list(window.sidebar_flyout.snapshots), ["cold", "box"])
                self.assertTrue(window.sidebar_flyout.snapshots["cold"]["pinned"])
                self.assertIs(window.focused_surface, surface)
                self.assertIs(window.get_focus(), focus)
                self.assertEqual(box["selectedWindowId"], "a")
                self.assertEqual(store.data["selectedWorkspaceId"], "box")
                self.assertEqual(window.notebooks, notebooks)
                self.assertEqual({key: s.pid for key, s in window.surfaces.items()}, clients)
                self.assertEqual(panes(), before_panes)
                restored = json.loads(store.path.read_text())
                saved_box = next(b for b in restored["workspaces"] if b["id"] == "box")
                self.assertEqual(saved_box["paneOrder"], ["left", "right"])
                self.assertEqual(saved_box["selectedWindowId"], "a")
                self.assertEqual(saved_box["splitAxis"], "horizontal")
                # Building from the saved ordering still creates left then right,
                # even if a right-pane record was moved to the front remotely.
                update("terminal.update", workspace_id="box", terminal_id="b", position=0)
                window.build_workspace(box)
                self.assertEqual([p for w, p in window.notebooks if w == "box"], ["left", "right"])
                self.assertEqual({key: s.pid for key, s in window.surfaces.items()}, clients)
                self.assertEqual(panes(), before_panes)
            finally:
                if window:
                    window.on_delete()
                    window.destroy()
                subprocess.run(["tmux", "-L", socket_name, "kill-server"], capture_output=True, timeout=3)
                (Path.home() / ".local/state/uniconnect" / ("tmux-create-" + socket_name + ".lock")).unlink(missing_ok=True)
