"""Creating a box asks for its first window instead of spawning a plain terminal."""

from pathlib import Path
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk
    from uniconnect.i18n import Translator
    from uniconnect.window import MainWindow
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


if GTK_AVAILABLE:
    class TwoStepDesktop:
        action_new_workspace = MainWindow.action_new_workspace
        action_new_window = MainWindow.action_new_window
        commit_new_workspace = MainWindow.commit_new_workspace
        commit_new_window = MainWindow.commit_new_window

        def __init__(self, folder, *, cancel_second=False):
            self._ = Translator()
            self.folder = folder
            self.cancel_second = cancel_second
            self.dialogs, self.built, self.selected = [], [], []
            self.focused_surface = None
            self.store = SimpleNamespace(workspaces=[], save=lambda: None)

        def current_workspace(self):
            return self.store.workspaces[-1] if self.store.workspaces else None

        def fields_dialog(self, title, fields, accept):
            self.dialogs.append((title, [key for key, _, _, _ in fields], accept))
            if len(self.dialogs) == 1:
                return {"name": "Proyecto", "kind": "local", "cwd": self.folder, "connect": "", "color": "#66b9ff"}
            if self.cancel_second:
                return None
            return {key: value for key, _, value, _ in fields}

        def refresh_sidebar(self):
            pass

        def select_workspace(self, workspace_id=None):
            self.selected.append(workspace_id)

        def build_workspace(self, workspace, create_ids=()):
            self.built.append((workspace["id"], tuple(create_ids)))


@unittest.skipUnless(GTK_AVAILABLE, "GTK 3 is required")
class FirstWindowTests(unittest.TestCase):
    def test_new_box_opens_the_first_window_dialog_and_creates_that_window(self):
        desktop = TwoStepDesktop(str(Path.home()))
        desktop.action_new_workspace()
        self.assertEqual([title for title, _, _ in desktop.dialogs], ["New workspace", "First window"])
        self.assertEqual(desktop.dialogs[1][2], "Create")
        self.assertIn("agent", desktop.dialogs[1][1])
        workspace = desktop.store.workspaces[0]
        self.assertEqual(workspace["name"], "Proyecto")
        self.assertEqual(len(workspace["windows"]), 1)
        window = workspace["windows"][0]
        self.assertEqual(window["cwd"], desktop.folder)
        self.assertEqual(window["agent"], "shell")
        self.assertEqual(window["tmuxSocket"], "uniconnect-local")
        self.assertEqual(desktop.built, [(workspace["id"], (window["id"],))])

    def test_cancelling_the_first_window_keeps_the_box_without_windows(self):
        desktop = TwoStepDesktop(str(Path.home()), cancel_second=True)
        desktop.action_new_workspace()
        self.assertEqual([title for title, _, _ in desktop.dialogs], ["New workspace", "First window"])
        self.assertEqual(desktop.store.workspaces[0]["windows"], [])
        self.assertEqual(desktop.built, [])

    def test_first_window_title_is_translated(self):
        self.assertEqual(Translator()("First window"), "Primera ventana")


if __name__ == "__main__":
    unittest.main()
