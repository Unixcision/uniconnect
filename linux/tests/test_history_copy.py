"""Real local selection and history export through SSH, on an isolated CI display."""

import unittest
from unittest.mock import patch

from history_copy_fixture import PointerHistoryFixture
from gi.repository import Gdk, Gtk
from ssh_copy_fixture import SSHCopyFixture
from vnc_copy_fixture import VNCClipboardPeer


class HistoryCopyTests(PointerHistoryFixture):
    def test_explicit_copy_crosses_vnc_and_viewer_text_can_be_pasted(self):
        from uniconnect.clipboard_text import publish_text
        self.seed_history()
        with VNCClipboardPeer() as peer:
            publish_text('UC_VNC_COPIA_123')
            self.wait_for(lambda: 'UC_VNC_COPIA_123' in peer.received)
            peer.send('UC_VNC_PEGADO_456')
            self.wait_for(lambda: self.clipboard.wait_for_text() == 'UC_VNC_PEGADO_456')
            self.window.run_action('paste')
            self.wait_for(lambda: 'UC_VNC_PEGADO_456' in self.tmux('capture-pane', '-p', '-t', '=subject:'))
            self.surface.send('\n')
            self.tmux('wait-for', 'typed')
            self.assertIn('ENTRADA:UC_VNC_PEGADO_456', self.tmux('capture-pane', '-p', '-t', '=subject:'))

    def test_shift_drag_is_native_and_never_pauses_remote_input(self):
        self.seed_history()
        terminal = self.surface.terminal
        rows = self.tmux("capture-pane", "-p", "-t", "=subject:").splitlines()
        row = next(i for i, text in enumerate(rows) if "ROW0119" in text)
        top = terminal.get_toplevel()
        x, y = top.get_window().get_origin()[-2:]
        offset_x, offset_y = terminal.translate_coordinates(top, 0, 0)[-2:]
        x, y = x + offset_x, y + offset_y
        padding = terminal.get_style_context().get_padding(Gtk.StateFlags.NORMAL)
        x += padding.left + terminal.get_char_width() // 2
        y += padding.top + row * terminal.get_char_height() + terminal.get_char_height() // 2
        presses = []
        terminal.connect('event', lambda widget, event: (presses.append(True) or False)
                         if event.type == Gdk.EventType.BUTTON_PRESS else False)
        self.xtst.XTestFakeMotionEvent(self.display, -1, x, y, 0)
        self.xtst.XTestFakeKeyEvent(self.display, self.shift, True, 0)
        self.xtst.XTestFakeButtonEvent(self.display, 1, True, 0)
        self.x11.XSync(self.display, False)
        self.wait_for(lambda: bool(presses))
        self.xtst.XTestFakeMotionEvent(self.display, -1, x + 16 * terminal.get_char_width(), y, 0)
        self.x11.XSync(self.display, False)
        self.wait_for(terminal.get_has_selection)
        self.release_pointer()
        self.window.run_action("copy")
        self.wait_for(lambda: "ROW0119" in (self.clipboard.wait_for_text() or ""))
        self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_in_mode}"), "0")
        self.assertIn("ROW0119", Gtk.Clipboard.get(Gdk.SELECTION_PRIMARY).wait_for_text())
        self.surface.send("UC_BLUE_OK\n")
        self.tmux("wait-for", "typed")
        self.assertIn("ENTRADA:UC_BLUE_OK", self.tmux("capture-pane", "-p", "-t", "=subject:"))

    def test_ssh_history_native_drag_copies_both_clipboards_and_leaves_agent_running(self):
        self.seed_history()
        self.assertIn("show_history", self.window.action_map)
        with SSHCopyFixture() as ssh:
            self.surface.workspace["kind"] = "ssh"
            self.surface.workspace["credentialId"] = self.window.vault.put(ssh.command)
            # Exercise the actual app's SSH launch, not only a mock transport.
            self.surface.launch()
            self.wait_for(lambda: self.surface.status == "Running" and not self.surface._preparing)
            self.window.run_action("show_history")
            self.wait_for(lambda: self.surface.history_view is not None and self.surface.history_view.ready)
            view = self.surface.history_view
            self.addCleanup(view.destroy)
            self.assertIn("ROW0000", view.text.get_buffer().get_text(*view.text.get_buffer().get_bounds(), False))
            self.assertIn("ROW0119", view.text.get_buffer().get_text(*view.text.get_buffer().get_bounds(), False))
            self.tmux("new-session", "-d", "-s", "other", "sleep 90")
            other = self.tmux("display-message", "-p", "-t", "=other:", "#{pane_id}:#{pane_pid}")
            self.tmux("set-buffer", "OTRA_VENTANA")
            view.resize(800, 450)
            view.move(60, 220)
            view.present()
            buffer = view.text.get_buffer()
            end = buffer.get_end_iter()
            buffer.place_cursor(end)
            view.text.scroll_to_iter(end, 0, True, 0, 1)
            self.wait_for(lambda: view.text.get_vadjustment().get_value() > 0)
            visible = view.text.get_visible_rect()
            text_window = view.text.get_window(Gtk.TextWindowType.TEXT)
            x, y = text_window.get_origin()[-2:]
            # From the penultimate visible line to outside the top edge, held.
            presses = []
            view.text.connect('event', lambda widget, event: (presses.append(True) or False)
                              if event.type == Gdk.EventType.BUTTON_PRESS else False)
            self.xtst.XTestFakeMotionEvent(self.display, -1, x + 180, y + visible.height - 35, 0)
            self.xtst.XTestFakeButtonEvent(self.display, 1, True, 0)
            self.x11.XSync(self.display, False)
            self.wait_for(lambda: bool(presses))
            self.xtst.XTestFakeMotionEvent(self.display, -1, x + 5, y - 70, 0)
            self.x11.XSync(self.display, False)
            with patch("uniconnect.transport.Transport.run", side_effect=AssertionError("Dragging/copying must be local")):
                self.wait_for(lambda: buffer.get_has_selection() and
                              abs(buffer.get_iter_at_mark(buffer.get_insert()).get_line() -
                                  buffer.get_iter_at_mark(buffer.get_selection_bound()).get_line()) > 40)
                self.release_pointer()
                view.copy()
                copied = buffer.get_text(*buffer.get_selection_bounds(), False) if buffer.get_has_selection() else self.clipboard.wait_for_text()
                self.assertEqual(self.clipboard.wait_for_text(), copied)
                self.assertEqual(Gtk.Clipboard.get(Gdk.SELECTION_PRIMARY).wait_for_text(), copied)
                self.assertIn("copia_ñ", copied)
                self.assertGreater(len(copied.splitlines()), 40)
                view.destroy()
            self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_in_mode}"), "0")
            self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_id}:#{pane_pid}"), self.before)
            self.assertEqual(self.tmux("display-message", "-p", "-t", "=other:", "#{pane_id}:#{pane_pid}"), other)
            self.assertEqual(self.tmux("show-buffer"), "OTRA_VENTANA")
            self.clipboard.set_text("UC_PASTE_OK", -1)
            self.window.run_action("paste")
            self.wait_for(lambda: "UC_PASTE_OK" in self.tmux("capture-pane", "-p", "-t", "=subject:"))
            self.surface.send("\n")
            self.tmux("wait-for", "typed")
            self.assertIn("ENTRADA:UC_PASTE_OK", self.tmux("capture-pane", "-p", "-t", "=subject:"))
            self.assertEqual(self.errors, [])
            self.surface.stop_client()


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(HistoryCopyTests(name) for name in HistoryCopyTests.__dict__ if name.startswith("test_"))
