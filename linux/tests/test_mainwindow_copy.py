"""Exercise the user's real MainWindow action gate, not just Surface.copy()."""

import tempfile
import time
import unittest
import uuid
from pathlib import Path

import test_terminal_copy as terminal_fixture
from gi.repository import Gdk, Gio, GLib, Gtk
from uniconnect.state import StateStore
from uniconnect.vault import Vault
from uniconnect.window import MainWindow


class MainWindowCopyTests(unittest.TestCase):
    tmux = terminal_fixture.TerminalCopyTests.tmux
    select = terminal_fixture.TerminalCopyTests.select
    copy_and_wait = terminal_fixture.TerminalCopyTests.copy_and_wait

    @classmethod
    def setUpClass(cls):
        cls.app = Gtk.Application(application_id="com.unixcision.uniconnect.copytest" + uuid.uuid4().hex,
                                  flags=Gio.ApplicationFlags.NON_UNIQUE)
        cls.app.register(None)

    def wait_for(self, predicate):
        deadline = time.monotonic() + 8
        loop = GLib.MainLoop()
        def observe():
            if predicate() or time.monotonic() >= deadline:
                loop.quit()
                return False
            return True
        GLib.timeout_add(15, observe)
        loop.run()
        self.assertTrue(predicate(), "GTK state deadline expired")

    def setUp(self):
        terminal_fixture.TerminalCopyTests.setUp(self)
        self.surface.dispose()
        self.window.destroy()
        self.directory = tempfile.TemporaryDirectory(prefix="uc-copy-ui-")
        root = Path(self.directory.name)
        vault = Vault(root)
        vault.initialize("isolated-test-only")
        store = StateStore(root, vault=vault)
        self.record.update(name="QA copiar", paneId="main")
        store.workspaces.append({"id": "qa-copy", "name": "QA copiar", "kind": "local",
                                 "cwd": "/tmp", "windows": [self.record],
                                 "selectedWindowId": self.record["id"]})
        store.data['selectedWorkspaceId'] = "qa-copy"
        store.save()
        self.window = MainWindow(self.app, store, vault)
        self.owner = self.window
        self.window.error = self.errors.append
        self.surface = self.window.focused_surface
        self.wait_for(lambda: self.surface.status == "Running" and not self.window._sidebar_refresh)
        # Spawn completion is not the first tmux resize. That resize clears a
        # selection, so select only after the real VTE geometry reaches tmux.
        self.wait_for(lambda: self.tmux("display-message", "-p", "-t", "=subject:",
                                       "#{session_attached}:#{window_width}:#{window_height}")
                      == f"1:{self.surface.terminal.get_column_count()}:{self.surface.terminal.get_row_count() - 1}")

    def tearDown(self):
        self.window.on_delete()
        terminal_fixture.TerminalCopyTests.tearDown(self)
        self.directory.cleanup()

    def test_copy_through_real_menu_action_and_palette_dispatch(self):
        for entry in ("menu", "shortcut", "palette"):
            with self.subTest(entry=entry):
                self.select()
                self.clipboard.set_text("anterior", -1)
                self.window.refresh_actions()
                menu = dict(self.window.menu_items)["copy"]
                self.assertTrue(menu.get_sensitive(), "Copiar is disabled despite tmux selection")
                self.assertTrue(self.window.command_menu_item("copy").get_sensitive())
                self.assertTrue(self.window.lookup_action("copy").get_enabled())
                if entry == "menu":
                    action = menu.activate
                elif entry == "shortcut":
                    def action():
                        event = Gdk.Event.new(Gdk.EventType.KEY_PRESS)
                        event.keyval = Gdk.KEY_c
                        event.state = Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK
                        event.window = self.surface.terminal.get_window()
                        keymap = Gdk.Keymap.get_for_display(self.window.get_display())
                        success, keys = keymap.get_entries_for_keyval(Gdk.KEY_c)
                        self.assertTrue(success)
                        event.hardware_keycode = keys[0].keycode
                        event.group = keys[0].group
                        self.assertTrue(self.window.activate_key(event.key))
                else:
                    action = lambda: self.window.run_action("copy")
                self.copy_and_wait("COPIA_ñ", action)
                self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_in_mode}"), "0")

    def test_cancel_selection_without_copy_is_accessible_and_preserves_clipboard(self):
        self.select()
        self.window.refresh_actions()
        self.assertIn("cancel_selection", self.window.action_map)
        self.assertTrue(self.window.lookup_action("cancel_selection").get_enabled())
        self.window.run_action("cancel_selection")
        self.wait_for(lambda: self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_in_mode}") == "0")
        self.assertEqual(self.clipboard.wait_for_text(), "anterior")
        self.assertEqual(self.errors, [])

    def test_explicit_local_reconnect_cancels_copy_mode_without_restarting_pane(self):
        self.select()
        self.assertTrue(self.window.action_enabled("reconnect"))
        generation = self.surface.generation
        self.window.run_action("reconnect")
        self.wait_for(lambda: self.surface.generation > generation and self.surface.status == "Running")
        self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_in_mode}"), "0")
        self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_id}:#{pane_pid}"), self.before)
