"""Exercise the actual GTK new-terminal form instead of mocking its modal dialog."""

from pathlib import Path
import sys
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import GLib, Gtk
    from uniconnect.i18n import Translator
    from uniconnect.window import MainWindow
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


if GTK_AVAILABLE:
    class DialogHarness(Gtk.Window):
        fields_dialog = MainWindow.fields_dialog

        def __init__(self):
            super().__init__()
            self._ = Translator()


@unittest.skipUnless(GTK_AVAILABLE, "GTK display required; run under xvfb-run")
class NewWindowDialogTests(unittest.TestCase):
    def setUp(self):
        self.parent = DialogHarness()
        self.parent.show()
        self.addCleanup(self.parent.destroy)

    def respond_to_real_dialog(self, response, *, value=None):
        observed = []
        issues = []
        deadline = time.monotonic() + 4
        source_active = [True]

        def respond():
            dialogs = [item for item in Gtk.Window.list_toplevels()
                       if isinstance(item, Gtk.Dialog) and item.get_visible()]
            if not dialogs:
                if time.monotonic() < deadline:
                    return True
                source_active[0] = False
                issues.append("the real modal form was never shown to GTK")
                return False
            dialog = dialogs[-1]
            observed.append(dialog)
            try:
                if not dialog.get_modal():
                    issues.append("dialog is not modal")
                if dialog.get_transient_for() is not self.parent:
                    issues.append("dialog is not transient for the main window")
                if value is not None:
                    grids = [child for child in dialog.get_content_area().get_children()
                             if isinstance(child, Gtk.Grid)]
                    entry = next(child for child in grids[0].get_children()
                                 if isinstance(child, Gtk.Entry))
                    entry.set_text(value)
            except Exception as error:
                issues.append(f"could not inspect dialog widgets: {error}")
            finally:
                dialog.response(response)
                source_active[0] = False
            return False

        source = GLib.timeout_add(20, respond)
        try:
            result = self.parent.fields_dialog(
                "New window", [("name", "Name", "", "text")], "Create")
        finally:
            if source_active[0]:
                GLib.source_remove(source)
        self.assertTrue(observed or issues, "dialog timeout callback did not run")
        self.assertEqual(issues, [])
        return result

    def test_cancel_button_response_returns_without_creating_values(self):
        self.assertIsNone(self.respond_to_real_dialog(Gtk.ResponseType.CANCEL))

    def test_window_manager_close_response_returns_without_creating_values(self):
        self.assertIsNone(self.respond_to_real_dialog(Gtk.ResponseType.DELETE_EVENT))

    def test_create_response_returns_the_entered_value(self):
        self.assertEqual(self.respond_to_real_dialog(Gtk.ResponseType.OK, value="terminal-prueba"),
                         {"name": "terminal-prueba"})


if __name__ == "__main__":
    unittest.main()
