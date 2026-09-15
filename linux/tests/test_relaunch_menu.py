"""Exercise the actual GTK menus/palette without app data, SSH or agent processes."""

from types import SimpleNamespace
import unittest

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Vte", "2.91")
    from gi.repository import GLib, Gtk
    from uniconnect.actions import ACTIONS
    from uniconnect.window import MainWindow
    from uniconnect.window_commands import WindowCommands
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


@unittest.skipUnless(GTK_AVAILABLE, "GTK/VTE private display required")
class RelaunchMenuTests(unittest.TestCase):
    def setUp(self):
        class Window(Gtk.Window, WindowCommands):
            build_menu = MainWindow.build_menu
            command_menu_item = MainWindow.command_menu_item
            run_action = MainWindow.run_action
            action_palette = MainWindow.action_palette

            def action_enabled(self, name):
                return WindowCommands.action_enabled(self, name) if name.startswith("relaunch_") else True

            def refresh_actions(self):
                pass

        self.window = Window()
        self.addCleanup(self.window.destroy)
        window = self.window
        window._ = lambda text: text
        window.locked = False
        window.action_map = {action.name: action for action in ACTIONS}
        window.store = SimpleNamespace(data={"settings": {"shortcuts": {"relaunch_global": "<Alt>g"}}})
        window.focused_surface = SimpleNamespace(record={"id": "window"})
        window.current_workspace = lambda: {"id": "box", "windows": [{"id": "window"}]}
        self.calls = []
        window.relaunch = SimpleNamespace(allowed=lambda: True, show=self.calls.append,
            show_history=lambda: self.calls.append("history"), show_machines=lambda: self.calls.append("machines"))
        window.error = lambda error: self.fail(str(error))

    def test_menu_exposes_and_dispatches_exactly_window_workspace_machine(self):
        menu = self.window.build_menu()
        self.addCleanup(menu.destroy)
        items = [(name, item) for name, item in self.window.menu_items if name.startswith("relaunch_")]
        self.assertEqual([name for name, _ in items],
                         ["relaunch_window", "relaunch_workspace", "relaunch_machine", "relaunch_history"])
        for _, item in items[:3]:
            item.activate()
        self.assertEqual(self.calls, ["window", "workspace", "machine"])

    def test_palette_and_old_shortcuts_cannot_dispatch_global(self):
        observed = []
        def inspect_dialog():
            dialog = next(w for w in Gtk.Window.list_toplevels() if isinstance(w, Gtk.Dialog))
            pending = list(dialog.get_content_area().get_children())
            while pending:
                widget = pending.pop()
                if isinstance(widget, Gtk.ListBoxRow):
                    observed.append(widget.action_name)
                if isinstance(widget, Gtk.Container):
                    pending.extend(widget.get_children())
            dialog.response(Gtk.ResponseType.CANCEL)
            return False
        GLib.idle_add(inspect_dialog)
        self.window.action_palette()
        self.assertNotIn("relaunch_global", observed)
        self.assertNotIn("relaunch_machines", observed)
        for name in ("relaunch_global", "relaunch_machines"):
            self.assertFalse(self.window.action_enabled(name))
            self.window.run_action(name)
        self.assertEqual(self.calls, [])
