"""tmux scrollback drag selection, clipboard export, and SSH history UI."""

import os
import shutil
import unittest
from unittest.mock import patch

from history_copy_fixture import PointerHistoryFixture
from gi.repository import Gdk, GLib, Gtk
from ssh_copy_fixture import SSHCopyFixture
from vnc_copy_fixture import VNCClipboardPeer


class HistoryCopyTests(PointerHistoryFixture):
    @unittest.skipUnless(shutil.which("x11vnc"), "x11vnc required for VNC clipboard integration")
    def test_explicit_copy_crosses_vnc_and_viewer_text_can_be_pasted(self):
        from uniconnect.clipboard_text import publish_text
        self.seed_history()
        with VNCClipboardPeer() as peer:
            self.wait_for(lambda: peer.ready)
            publish_text('UC_VNC_COPIA_123')
            self.wait_for(lambda: 'UC_VNC_COPIA_123' in peer.received,
                          detail=lambda: f"VNC received={peer.received!r}; peer_error={peer.error!r}; "
                          f"server_log={peer.server_log()!r}")
            peer.send('UC_VNC_PEGADO_456')
            self.wait_for(lambda: self.clipboard.wait_for_text() == 'UC_VNC_PEGADO_456')
            self.window.run_action('paste')
            self.wait_for(lambda: 'UC_VNC_PEGADO_456' in self.tmux('capture-pane', '-p', '-t', '=subject:'))
            self.surface.send('\n')
            self.tmux('wait-for', 'typed')
            self.assertIn('ENTRADA:UC_VNC_PEGADO_456', self.tmux('capture-pane', '-p', '-t', '=subject:'))

    def test_shift_drag_selects_tmux_scrollback_and_preserves_agent_input(self):
        self.seed_history()
        terminal = self.surface.terminal
        rows = self.tmux("capture-pane", "-p", "-t", "=subject:").splitlines()
        row = next(i for i, text in enumerate(rows) if "ROW0119" in text)
        top = terminal.get_toplevel()
        top_x, top_y = top.get_window().get_origin()[-2:]
        offset_x, offset_y = terminal.translate_coordinates(top, 0, 0)[-2:]
        x, y = top_x + offset_x + 8 * terminal.get_char_width(), top_y + offset_y
        y += row * terminal.get_char_height() + terminal.get_char_height() // 2
        pointer_events = []
        terminal.connect('event', lambda widget, event: (pointer_events.append(
            (event.type, event.state, event.x, event.y)) or False)
            if event.type in (Gdk.EventType.BUTTON_PRESS, Gdk.EventType.MOTION_NOTIFY) else False)
        self.xtst.XTestFakeMotionEvent(self.display, -1, x, y, 0)
        self.xtst.XTestFakeKeyEvent(self.display, self.shift, True, 30)
        self.xtst.XTestFakeButtonEvent(self.display, 1, True, 50)
        self.x11.XSync(self.display, False)
        self.wait_for(lambda: any(event[0] == Gdk.EventType.BUTTON_PRESS for event in pointer_events))
        self.wait_for(lambda: self.tmux("display-message", "-p", "-t", "=subject:",
                                        "#{pane_in_mode}:#{selection_present}") == "1:1")
        # copy-mode starts in a tmux worker; wait until GTK has received the exact
        # pane identity before sending synthetic pointer motion. Otherwise this
        # test races the initial metadata roundtrip, unlike a human drag.
        self.wait_for(lambda: self.surface.selection_drag.pane is not None
                      and not self.surface.selection_drag.busy)
        # Hold the pointer above the viewport: the edge-scroll timer must walk
        # the real tmux history instead of stopping at VTE's visible rows.
        self.xtst.XTestFakeMotionEvent(self.display, -1,
                                       x + 16 * terminal.get_char_width(),
                                       top_y + offset_y - 12 * terminal.get_char_height() - 2, 0)
        self.x11.XSync(self.display, False)
        self.wait_for(lambda: any(event[0] == Gdk.EventType.MOTION_NOTIFY
                                  and event[1] & Gdk.ModifierType.BUTTON1_MASK for event in pointer_events),
                      detail=lambda: f"pointer_events={pointer_events[-8:]!r}")
        loop = GLib.MainLoop()
        GLib.timeout_add(1500, lambda: (loop.quit(), False)[1])
        loop.run()
        self.xtst.XTestFakeButtonEvent(self.display, 1, False, 30)
        self.xtst.XTestFakeKeyEvent(self.display, self.shift, False, 30)
        self.x11.XSync(self.display, False)
        self.wait_for(lambda: not self.surface.selection_drag.busy
                      and self.surface.selection_drag.pending_move is None)
        self.release_pointer()
        self.window.run_action("copy")
        self.wait_for(lambda: "ROW0119" in (self.clipboard.wait_for_text() or "")
                      and "ROW0000" in (self.clipboard.wait_for_text() or ""),
                      detail=lambda: f"pointer_events={pointer_events[-8:]!r}; "
                      f"tmux={self.tmux('display-message', '-p', '-t', '=subject:', '#{pane_mode}:#{selection_present}:#{copy_cursor_y}')!r}")
        self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_in_mode}"), "1")
        self.assertIn("ROW0119", Gtk.Clipboard.get(Gdk.SELECTION_PRIMARY).wait_for_text())
        self.assertIn("ROW0000", Gtk.Clipboard.get(Gdk.SELECTION_PRIMARY).wait_for_text())
        self.window.run_action("cancel_selection")
        self.wait_for(lambda: self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_in_mode}") == "0")
        self.surface.send("UC_BLUE_OK\n")
        self.tmux("wait-for", "typed")
        self.assertIn("ENTRADA:UC_BLUE_OK", self.tmux("capture-pane", "-p", "-t", "=subject:"))

    @unittest.skipIf(os.geteuid() == 0, "isolated sshd fixture cannot authenticate the locked root account")
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
