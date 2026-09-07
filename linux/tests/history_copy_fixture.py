"""Pointer and history fixtures, used only on isolated CI displays."""

import ctypes
import ctypes.util
import faulthandler
import os
import shlex
import time
import unittest

import test_mainwindow_copy as window_fixture
from gi.repository import Gdk, GLib, Gtk, Vte


class PointerHistoryFixture(window_fixture.MainWindowCopyTests):
    def wait_for(self, predicate):
        deadline = time.monotonic() + 8
        loop = GLib.MainLoop()
        errors = []
        def observe():
            try:
                ready = predicate()
            except Exception as error:
                errors.append(error)
                ready = True
            if ready or time.monotonic() >= deadline:
                loop.quit()
                return False
            return True
        GLib.timeout_add(15, observe)
        loop.run()
        if errors:
            raise errors[0]
        drag = getattr(self.surface, "selection_drag", None)
        state = {key: getattr(drag, key, None) for key in
                 ("point", "pane", "busy", "pressed", "active", "pending_move", "timer")}
        self.assertTrue(predicate(), f"GTK deadline: {state}; status={self.surface.status_label.get_text()}; errors={self.errors}")

    def setUp(self):
        faulthandler.dump_traceback_later(40, exit=True)
        self.addCleanup(faulthandler.cancel_dump_traceback_later)
        super().setUp()
        self.window.resize(1000, 600)
        self.window.move(30, 180)
        self.window.present()
        self.wait_for(lambda: self.tmux("display-message", "-p", "-t", "=subject:",
                                       "#{window_width}:#{window_height}")
                      == f"{self.surface.terminal.get_column_count()}:{self.surface.terminal.get_row_count() - 1}")
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
        if os.environ.get('RUNNER_TEMP'):
            root = Gdk.get_default_root_window()
            pixbuf = Gdk.pixbuf_get_from_window(root, 0, 0, root.get_width(), root.get_height())
            pixbuf.savev(os.path.join(os.environ['RUNNER_TEMP'], self._testMethodName + '.png'), 'png', [], [])
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
        terminal = self.surface.terminal
        def visible_text():
            return (terminal.get_text_format(Vte.Format.TEXT) if hasattr(terminal, "get_text_format")
                    else terminal.get_text(None, None)[0]) or ""
        self.wait_for(lambda: "ROW0119" in visible_text())
