"""Ciclo real del diálogo GTK en la pantalla aislada de CI; nunca conecta con una app del usuario."""

import copy
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_window_details import fixture_catalog, inputs_from, response
from uniconnect.window_details import WindowDetails

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk
    from uniconnect.window import MainWindow
    from uniconnect.window_details_dialog import WindowDetailsDialog
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


if GTK_AVAILABLE:
    class DetailsDesktop(Gtk.Window):
        show_window_details = MainWindow.show_window_details
        action_lock = MainWindow.action_lock

        def __init__(self, expected):
            super().__init__()
            self._closed, self.pending = False, []
            self.locked, self._details_dialogs = False, set()
            self.sidebar_flyout = SimpleNamespace(hide=Mock())
            self.vault = SimpleNamespace(lock=Mock())
            self.overlay = SimpleNamespace(set_visible_child_name=Mock())
            self.catalog = fixture_catalog()
            self.workspace, self.record, _, _, self.clock = inputs_from(expected)
            self.surface = SimpleNamespace(workspace=self.workspace, record=self.record)

        def window_details(self, workspace, record):
            return WindowDetails.snapshot(workspace, record, None, self.catalog, self.clock)

        def details_inputs(self, workspace, record):
            return copy.deepcopy(workspace), copy.deepcopy(record), None, None

        def _details_catalog(self):
            return self.catalog

        def background(self, work, done):
            self.pending.append((work, done))

        def finish(self):
            work, done = self.pending.pop(0)
            done(work())


@unittest.skipUnless(GTK_AVAILABLE, "GTK display required for window details")
class WindowDetailsDialogTests(unittest.TestCase):
    def open_dialog(self, fixture="details-response-local.json"):
        expected = response(fixture)
        desktop = DetailsDesktop(expected)
        self.addCleanup(desktop.destroy)
        dialog = desktop.show_window_details(desktop.surface)
        self.addCleanup(dialog.destroy)
        return desktop, dialog, expected

    def test_loading_does_not_probe_or_copy_until_worker_finishes_then_copies_real_id(self):
        with patch("uniconnect.window_details_dialog.WindowDetails.gather") as gather, \
                patch("uniconnect.window_details_dialog.publish_text") as publish:
            desktop, dialog, expected = self.open_dialog()
            gather.assert_not_called()
            self.assertTrue(dialog.loading)
            self.assertEqual(dialog.status.get_text(), "Comprobando…")
            self.assertFalse(dialog.refresh_button.get_sensitive())
            self.assertFalse(dialog.copy_details_button.get_sensitive())
            dialog.copy("session_id")
            publish.assert_not_called()
            gather.return_value = expected
            desktop.finish()
            self.assertFalse(dialog.loading)
            dialog.copy_id_button.emit("clicked")
            publish.assert_called_once_with(expected["agent"]["session_id"])
            self.assertEqual(dialog.copy_status.get_text(), "ID copiado")
            dialog.copy_command_button.emit("clicked")
            self.assertEqual(publish.call_args.args, (expected["agent"]["resume"]["command"],))

    def test_failure_stays_in_dialog_without_exposing_exception_and_retry_recovers(self):
        with patch("uniconnect.window_details_dialog.WindowDetails.gather", side_effect=RuntimeError("private-password")) as gather:
            desktop, dialog, expected = self.open_dialog("details-response-vault-closed.json")
            desktop.finish()
            self.assertFalse(dialog.loading)
            self.assertEqual(dialog.status.get_text(), WindowDetailsDialog.FAILED)
            self.assertEqual(dialog.refresh_button.get_label(), "Reintentar")
            self.assertEqual(dialog.details["reason"], "host_inaccesible")
            self.assertNotIn("private-password", WindowDetails.copy_value(dialog.details, "details"))
            gather.side_effect = None
            gather.return_value = expected
            dialog.refresh_button.emit("clicked")
            self.assertTrue(dialog.loading)
            desktop.finish()
            self.assertEqual(dialog.status.get_text(), WindowDetails.warning(expected))
            self.assertTrue(dialog.copy_id_button.get_sensitive())

    def test_destroy_discards_pending_result_and_missing_id_hides_copy_actions(self):
        with patch("uniconnect.window_details_dialog.WindowDetails.gather") as gather:
            desktop, dialog, expected = self.open_dialog("details-response-sin-id.json")
            gather.return_value = expected
            desktop.finish()
            self.assertFalse(dialog.copy_id_button.get_visible())
            self.assertFalse(dialog.copy_command_button.get_visible())
            self.assertTrue(dialog.copy_details_button.get_sensitive())
            dialog.refresh()
            dialog.destroy()
            with patch.object(dialog, "render") as render:
                desktop.finish()
                render.assert_not_called()

    def test_lock_closes_details_and_discards_pending_result_and_copy(self):
        with patch("uniconnect.window_details_dialog.WindowDetails.gather") as gather, \
                patch("uniconnect.window_details_dialog.publish_text") as publish:
            desktop, dialog, expected = self.open_dialog()
            gather.return_value = expected
            desktop.action_lock()
            self.assertTrue(dialog.closed)
            self.assertIsNone(dialog.details)
            self.assertEqual(desktop._details_dialogs, set())
            desktop.vault.lock.assert_called_once_with()
            desktop.overlay.set_visible_child_name.assert_called_once_with("locked")
            with patch.object(dialog, "render") as render:
                desktop.finish()
                render.assert_not_called()
            dialog.copy("details")
            publish.assert_not_called()
            self.assertIsNone(desktop.show_window_details(desktop.surface))

    def test_callbacks_close_the_dialog_if_the_owner_has_become_locked(self):
        for action in ("refresh", "copy", "done"):
            with self.subTest(action=action), \
                    patch("uniconnect.window_details_dialog.WindowDetails.gather") as gather, \
                    patch("uniconnect.window_details_dialog.publish_text") as publish:
                desktop, dialog, expected = self.open_dialog()
                gather.return_value = expected
                if action != "done":
                    desktop.finish()
                desktop.locked = True
                if action == "done":
                    desktop.finish()
                elif action == "copy":
                    dialog.copy("session_id")
                else:
                    dialog.refresh()
                self.assertTrue(dialog.closed)
                self.assertIsNone(dialog.details)
                self.assertEqual(desktop._details_dialogs, set())
                self.assertEqual(desktop.pending, [])
                publish.assert_not_called()


if __name__ == "__main__":
    unittest.main()
