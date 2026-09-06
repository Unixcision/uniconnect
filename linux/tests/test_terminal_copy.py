"""Real GTK clipboard + tmux selection regression, run on isolated CI displays."""

import os
import shlex
import shutil
import subprocess
import sys
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk
from uniconnect.terminal import TerminalSurface


@unittest.skipUnless(Gtk.init_check()[0] and shutil.which("tmux"), "GTK and tmux required")
class TerminalCopyTests(unittest.TestCase):
    def setUp(self):
        self.socket = "uc-copy-test-" + uuid.uuid4().hex[:12]
        self.errors = []
        self.owner = SimpleNamespace(store=SimpleNamespace(data={"settings": {}}), font_scale=1,
                                     _=lambda x: x, refresh_sidebar=lambda: None,
                                     error=self.errors.append)
        self.record = {"id": "copy-test", "tmux": "subject", "tmuxSocket": self.socket,
                       "cwd": "/tmp", "agent": "terminal"}
        self.surface = TerminalSurface(self.owner, {"kind": "local"}, self.record, auto_launch=False)
        self.window = Gtk.Window()
        self.window.add(self.surface)
        self.window.show_all()
        self.clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        self.clipboard.set_text("anterior", -1)
        self.tmux("new-session", "-d", "-s", "subject", "-x", "80", "-y", "24",
                  "printf 'COPIA_ñ\\nsegunda línea\\n'; tmux -L " + shlex.quote(self.socket)
                  + " wait-for -S rendered; exec sleep 90")
        self.tmux("wait-for", "rendered")
        self.before = self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_id}:#{pane_pid}")

    def tearDown(self):
        self.surface.dispose()
        self.surface.destroy()
        self.window.destroy()
        self.clipboard.clear()
        self.tmux("kill-server")

    def tmux(self, *args):
        env = dict(os.environ, LC_ALL="C.UTF-8")
        env.pop("TMUX", None)
        return subprocess.check_output(["tmux", "-L", self.socket, *args], env=env,
                                       text=True, timeout=5).strip()

    def select(self):
        self.tmux("copy-mode", "-t", "=subject:")
        for command in ("history-top", "start-of-line", "begin-selection", "end-of-line"):
            self.tmux("send-keys", "-t", "=subject:", "-X", command)
        self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:",
                                   "#{selection_present}"), "1")
        self.assertFalse(self.surface.terminal.get_has_selection())

    def copy_and_wait(self, expected):
        loop = GLib.MainLoop()
        def changed(*_):
            self.clipboard.request_text(lambda _, text, *__: loop.quit() if text == expected else None)
        signal = self.clipboard.connect("owner-change", changed)
        deadline = GLib.timeout_add_seconds(8, lambda: (loop.quit(), False)[1])
        self.surface.copy()
        loop.run()
        self.clipboard.disconnect(signal)
        # Removing an elapsed deadline only emits a warning, not a test failure.
        if GLib.MainContext.default().find_source_by_id(deadline):
            GLib.source_remove(deadline)
        self.assertEqual(self.clipboard.wait_for_text(), expected)
        self.assertEqual(self.errors, [])

    def test_tmux_selection_reaches_desktop_clipboard_and_releases_keyboard(self):
        self.select()
        self.copy_and_wait("COPIA_ñ")
        self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_in_mode}"), "0")
        self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_id}:#{pane_pid}"), self.before)

    def test_native_vte_selection_still_copies(self):
        loop = GLib.MainLoop()
        signal = self.surface.terminal.connect("contents-changed", lambda *_: loop.quit())
        self.surface.terminal.feed(b"NATIVO")
        deadline = GLib.timeout_add_seconds(3, lambda: (loop.quit(), False)[1])
        loop.run()
        if GLib.MainContext.default().find_source_by_id(deadline):
            GLib.source_remove(deadline)
        self.surface.terminal.disconnect(signal)
        self.surface.terminal.select_all()
        self.assertTrue(self.surface.terminal.get_has_selection())
        self.copy_and_wait("NATIVO\n")

    def test_no_selection_never_uses_another_panes_buffer(self):
        from uniconnect.terminal_copy import TerminalCopy
        from uniconnect.transport import Transport, TransportError
        self.tmux("set-buffer", "TEXTO DE OTRA VENTANA")
        with self.assertRaises(TransportError):
            TerminalCopy(Transport(socket_name=self.socket)).read_selection(self.record)
        self.assertEqual(self.clipboard.wait_for_text(), "anterior")
        self.assertEqual(self.tmux("show-buffer"), "TEXTO DE OTRA VENTANA")

    def test_cancel_for_explicit_reconnect_releases_only_copy_mode(self):
        from uniconnect.terminal_copy import TerminalCopy
        from uniconnect.transport import Transport
        self.select()
        bridge = TerminalCopy(Transport(socket_name=self.socket))
        bridge.cancel_selection(self.record)
        bridge.cancel_selection(self.record)
        self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_in_mode}"), "0")
        self.assertEqual(self.tmux("display-message", "-p", "-t", "=subject:", "#{pane_id}:#{pane_pid}"), self.before)
