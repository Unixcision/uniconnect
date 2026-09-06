"""A real held Shift+mouse drag must select beyond VTE's alternate screen."""

import ctypes
import ctypes.util
import shlex

import test_mainwindow_copy as window_fixture
from gi.repository import Gtk


class ShiftHistoryTests(window_fixture.MainWindowCopyTests):
    def setUp(self):
        super().setUp()
        self.window.resize(1000, 600)
        self.window.move(30, 180)
        self.window.present()
        self.x11 = ctypes.CDLL(ctypes.util.find_library("X11"))
        self.xtst = ctypes.CDLL(ctypes.util.find_library("Xtst"))
        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.x11.XKeysymToKeycode.restype = ctypes.c_uint
        self.xtst.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                                 ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
        for method in ("XTestFakeButtonEvent", "XTestFakeKeyEvent"):
            getattr(self.xtst, method).argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                                  ctypes.c_int, ctypes.c_ulong]
        self.display = self.x11.XOpenDisplay(None)
        self.assertTrue(self.display)
        self.shift = self.x11.XKeysymToKeycode(self.display, 0xffe1)

    def tearDown(self):
        if getattr(self, "display", None):
            self.release_pointer()
            self.x11.XCloseDisplay(self.display)
        super().tearDown()

    def release_pointer(self):
        self.xtst.XTestFakeButtonEvent(self.display, 1, False, 0)
        self.xtst.XTestFakeKeyEvent(self.display, self.shift, False, 0)
        self.x11.XSync(self.display, False)

    def seed_history(self):
        socket = shlex.quote(self.socket)
        command = ("i=0; while [ $i -lt 120 ]; do printf 'ROW%04d copia_ñ\\n' $i; i=$((i+1)); done; "
                   f"tmux -L {socket} wait-for -S history-ready; IFS= read -r uc_input; "
                   "printf 'ENTRADA:%s\\n' \"$uc_input\"; "
                   f"tmux -L {socket} wait-for -S typed; exec sleep 90")
        self.tmux("respawn-pane", "-k", "-t", "=subject:", command)
        self.tmux("wait-for", "history-ready")
        self.before = self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_id}:#{pane_pid}")
        self.wait_for(lambda: "ROW0119" in self.surface.terminal.get_text(None, None)[0])

    def start_drag(self):
        terminal = self.surface.terminal
        rows = self.tmux("capture-pane", "-p", "-t", "=subject:").splitlines()
        row = next(index for index, text in enumerate(rows) if "ROW0119" in text)
        origin_x, origin_y = terminal.get_window().get_origin()[-2:]
        padding = terminal.get_style_context().get_padding(Gtk.StateFlags.NORMAL)
        self.left = origin_x + padding.left + terminal.get_char_width() // 2
        self.top = origin_y + padding.top
        self.xtst.XTestFakeMotionEvent(self.display, -1,
                                      self.left + 16 * terminal.get_char_width(),
                                      self.top + row * terminal.get_char_height()
                                      + terminal.get_char_height() // 2, 0)
        self.xtst.XTestFakeKeyEvent(self.display, self.shift, True, 0)
        self.xtst.XTestFakeButtonEvent(self.display, 1, True, 0)
        self.x11.XSync(self.display, False)
        self.wait_for(lambda: self.tmux("display-message", "-p", "-t", "=subject:",
                                       "#{selection_present}") == "1")

    def test_held_shift_drag_autoscrolls_history_and_copies_then_accepts_input(self):
        self.seed_history()
        self.tmux("new-session", "-d", "-s", "other", "sleep 90")
        self.tmux("copy-mode", "-t", "=other:")
        self.tmux("send-keys", "-t", "=other:", "-X", "begin-selection")
        self.start_drag()
        self.xtst.XTestFakeMotionEvent(self.display, -1, self.left, self.top - 55, 0)
        self.x11.XSync(self.display, False)
        height = self.surface.terminal.get_row_count()
        self.wait_for(lambda: int(self.tmux("display-message", "-p", "-t", "=subject:",
                                           "#{scroll_position}") or "0") > height + 5)
        self.release_pointer()
        # Exercise Copy immediately after mouse release: its async export must
        # follow the final queued drag, not race it or an outstanding SSH call.
        self.window.run_action("copy")
        self.wait_for(lambda: "ROW0119" in (self.clipboard.wait_for_text() or ""))
        copied = self.clipboard.wait_for_text()
        lines = [line.strip() for line in copied.splitlines() if line.strip()]
        self.assertGreater(len(lines), height)
        numbers = [int(line[3:7]) for line in lines]
        self.assertEqual(numbers, list(range(numbers[0], 120)))
        self.assertTrue(all("copia_ñ" in line for line in lines))
        self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_in_mode}"), "0")
        self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_id}:#{pane_pid}"), self.before)
        self.assertEqual(self.tmux("display-message", "-p", "-t", "=other:", "#{pane_in_mode}:#{selection_present}"), "1:1")
        self.surface.send("UC_HISTORY_TECLADO_OK\n")
        self.tmux("wait-for", "typed")
        self.assertIn("ENTRADA:UC_HISTORY_TECLADO_OK", self.tmux("capture-pane", "-p", "-t", "=subject:"))
        self.assertEqual(self.errors, [])
