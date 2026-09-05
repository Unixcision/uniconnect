"""MainWindow dogfood on a private display, state directory and tmux socket."""

import copy
import json
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Vte", "2.91")
    from gi.repository import Gio, GLib, Gtk
    from uniconnect.state import StateStore
    from uniconnect.transport import Transport
    from uniconnect.vault import Vault
    from uniconnect.window import MainWindow
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


@unittest.skipUnless(GTK_AVAILABLE and shutil.which("tmux"), "GTK/VTE display and tmux required")
class MainWindowLifecycleTests(unittest.TestCase):
    def wait_for(self, predicate, timeout=8):
        if predicate():
            return
        loop = GLib.MainLoop()
        deadline = time.monotonic() + timeout
        error = []

        def observe():
            try:
                if predicate():
                    loop.quit()
                    return False
                if time.monotonic() >= deadline:
                    error.append("GTK state deadline expired")
                    loop.quit()
                    return False
                return True
            except BaseException as exc:
                error.append(exc)
                loop.quit()
                return False

        GLib.timeout_add(15, observe)
        loop.run()
        if error:
            self.fail(str(error[0]))

    def fields_response(self, values):
        def respond():
            dialogs = [widget for widget in Gtk.Window.list_toplevels()
                       if isinstance(widget, Gtk.Dialog) and widget.get_visible()]
            self.assertTrue(dialogs)
            dialog = dialogs[-1]
            pending = list(dialog.get_content_area().get_children())
            grid = None
            while pending:
                candidate = pending.pop()
                if isinstance(candidate, Gtk.Grid):
                    grid = candidate
                    break
                if isinstance(candidate, Gtk.Container):
                    pending.extend(candidate.get_children())
            self.assertIsNotNone(grid)
            for child in grid.get_children():
                row = grid.child_get_property(child, "top-attach")
                if row not in values:
                    continue
                if isinstance(child, Gtk.Entry):
                    child.set_text(values[row])
                elif isinstance(child, Gtk.ComboBoxText):
                    child.set_active_id(values[row])
            dialog.response(Gtk.ResponseType.OK)
            return False
        GLib.idle_add(respond)

    def test_six_workspaces_switch_rebuild_close_reopen_and_persist_preferences(self):
        socket = "uc-ui-test-" + uuid.uuid4().hex[:12]
        app = Gtk.Application(application_id="com.unixcision.uniconnect.test" + uuid.uuid4().hex[:8],
                              flags=Gio.ApplicationFlags.NON_UNIQUE)
        app.register(None)
        window = None
        with tempfile.TemporaryDirectory(prefix="uc-mainwindow-") as directory:
            root = Path(directory) / "state"
            vault = Vault(root)
            vault.initialize("only-this-isolated-test-vault")
            store = StateStore(root, vault=vault)
            transport = Transport(socket_name=socket)
            for index in range(6):
                record = {"id": f"window-{index}", "name": f"Terminal {index}", "cwd": directory,
                          "tmux": f"window-{index}", "tmuxSocket": socket, "agent": "custom",
                          "commandArgv": ["/usr/bin/sleep", "120"], "paneId": "main"}
                transport.ensure_session(record)
                store.workspaces.append({"id": f"workspace-{index}", "name": f"Workspace {index}",
                                         "kind": "local", "cwd": directory, "windows": [record],
                                         "selectedWindowId": record["id"]})
            extra = {"id": "extra-pane", "name": "Extra pane", "cwd": directory, "tmux": "extra-pane",
                     "tmuxSocket": socket, "agent": "custom", "commandArgv": ["/usr/bin/sleep", "120"], "paneId": "main"}
            transport.ensure_session(extra)
            store.workspace("workspace-0")["windows"].append(extra)
            store.data["selectedWorkspaceId"] = "workspace-0"
            store.save()
            try:
                window = MainWindow(app, store, vault)
                window.present()
                for round in range(4):
                    for workspace in list(store.workspaces):
                        window.select_workspace(workspace["id"])
                        self.wait_for(lambda: window._sidebar_refresh == 0)
                        self.assertEqual(window.workspace_stack.get_visible_child_name(), workspace["id"])
                        self.assertEqual(window.focused_surface.record["id"], workspace["selectedWindowId"])
                self.wait_for(lambda: len(window.surfaces) == 7 and all(s.status == "Running" for s in window.surfaces.values()))
                pane_before = subprocess.check_output(["tmux", "-L", socket, "list-panes", "-a", "-F",
                                                       "#{session_name}:#{pane_pid}"], text=True)
                window.select_workspace("workspace-0")
                surface = window.focused_surface
                client_pid = surface.pid
                self.fields_response({0: "Renamed workspace", 1: "#aabbcc"})
                window.action_rename_workspace()
                self.assertIs(window.focused_surface, surface)
                self.assertEqual(surface.pid, client_pid)
                self.fields_response({0: "Renamed terminal"})
                window.action_rename_window()
                self.assertIs(window.focused_surface, surface)
                self.assertEqual(surface.pid, client_pid)
                self.assertEqual(store.workspace("workspace-0")["name"], "Renamed workspace")
                self.assertEqual(surface.record["name"], "Renamed terminal")
                self.assertFalse(window.action_enabled("edit_ssh"))
                self.assertFalse(window.action_enabled("reconnect"))
                window.run_action("workspace_9")
                self.assertEqual(window.current_workspace()["id"], "workspace-5")
                window.run_action("workspace_1")
                window.run_action("window_next")
                self.assertEqual(window.focused_surface.record["id"], "extra-pane")
                window.run_action("window_previous")
                self.assertIs(window.focused_surface, surface)
                window.run_action("pin_window")
                self.assertTrue(surface.record["pinned"])
                window.run_action("pin_window")
                window.run_action("workspace_down")
                self.assertEqual(store.workspaces[1]["id"], "workspace-0")
                window.run_action("workspace_up")
                self.assertEqual(store.workspaces[0]["id"], "workspace-0")
                self.assertEqual(surface.pid, client_pid)

                extra["paneId"] = "right"
                window.build_workspace(store.workspace("workspace-0"))
                window.select_workspace("workspace-0")
                self.assertEqual(len([key for key in window.notebooks if key[0] == "workspace-0"]), 2)
                self.assertIs(window.surfaces[surface.record["id"]], surface)
                window.run_action("maximize_pane")
                self.assertEqual(store.workspace("workspace-0")["maximizedPaneId"], "main")
                self.assertFalse(window.notebooks[("workspace-0", "right")].get_visible())
                window.run_action("maximize_pane")
                self.assertTrue(window.notebooks[("workspace-0", "right")].get_visible())
                window.run_action("focus_right")
                self.assertEqual(window.focused_surface.record["id"], "extra-pane")
                window.run_action("focus_left")
                self.assertIs(window.focused_surface, surface)

                window.close_surface(surface)
                closed_tmux = store.closed[0]["window"]["tmux"]
                self.wait_for(lambda: surface.pid == 0)
                # Activate the actual Reopen dialog button, not a replacement action.
                def reopen_button():
                    dialog = next(widget for widget in Gtk.Window.list_toplevels()
                                  if isinstance(widget, Gtk.Dialog) and widget.get_visible())
                    button = next(child for child in dialog.get_content_area().get_children() if isinstance(child, Gtk.Button))
                    button.clicked()
                    return False
                GLib.idle_add(reopen_button)
                window.action_reopen()
                restored = store.window("workspace-0", "window-0")
                self.assertEqual(restored["tmux"], closed_tmux)
                self.wait_for(lambda: window.surfaces["window-0"].status == "Running")
                self.assertEqual(subprocess.check_output(["tmux", "-L", socket, "list-panes", "-a", "-F",
                                                         "#{session_name}:#{pane_pid}"], text=True), pane_before)

                window.action_sidebar()
                self.wait_for(lambda: window._sidebar_refresh == 0)
                self.assertTrue(store.data["settings"]["compactSidebar"])
                self.assertFalse(window.sidebar_search.get_visible())
                self.assertEqual(len(window.workspace_list.get_children()), 6)
                self.fields_response({0: "light", 1: "en", 2: "Monospace 13", 3: "0"})
                window.action_settings()
                loaded = StateStore(root, vault=vault)
                self.assertEqual(loaded.data["settings"]["font"], "Monospace 13")
                self.assertEqual(loaded.data["settings"]["theme"], "light")
                self.assertTrue(loaded.data["settings"]["compactSidebar"])
                self.assertEqual(len(loaded.workspaces), 6)
                self.assertEqual(loaded.window("workspace-0", "window-0")["tmux"], closed_tmux)
            finally:
                if window:
                    window.on_delete()
                    window.destroy()
                subprocess.run(["tmux", "-L", socket, "kill-server"], capture_output=True)
                lock = Path.home() / ".local/state/uniconnect" / ("tmux-create-" + socket + ".lock")
                lock.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
