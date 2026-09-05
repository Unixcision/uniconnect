"""Exercise real VTE child lifecycle and reconnects on an isolated tmux socket."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    import gi
    gi.require_version("Gtk", "3.0")
    gi.require_version("Vte", "2.91")
    from gi.repository import GLib, Gtk
    from uniconnect.terminal import TerminalSurface
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


@unittest.skipUnless(GTK_AVAILABLE and shutil.which("tmux"), "GTK/VTE display and tmux required")
class TerminalLifecycleTests(unittest.TestCase):
    def test_reconnect_burst_preserves_tmux_and_uses_latest_child(self):
        socket = "uc-vte-test-" + uuid.uuid4().hex[:12]
        errors = []
        phase = [0]
        original_pane = []
        timed_out = []
        loop = GLib.MainLoop()
        with tempfile.TemporaryDirectory(prefix="uc-vte-") as directory:
            workspace = {"id": "workspace", "kind": "local", "cwd": directory}
            record = {"id": "window", "name": "VTE lifecycle", "cwd": directory,
                      "tmux": "lifecycle", "tmuxSocket": socket, "agent": "custom",
                      "commandArgv": ["/usr/bin/sleep", "90"]}
            owner = SimpleNamespace(store=SimpleNamespace(data={"settings": {}}), font_scale=1.0,
                                    _=lambda value: value, refresh_sidebar=lambda: None,
                                    notify_window=lambda *args: None)

            def pane_pid():
                return subprocess.check_output(["tmux", "-L", socket, "display-message", "-p",
                                                "-t", "=lifecycle:", "#{pane_pid}"], text=True).strip()

            def reconnect():
                surface.launch()
                surface.launch()
                surface.launch()
                return False

            def persisted():
                if surface.status != "Running":
                    return
                try:
                    self.assertGreater(surface.pid, 0)
                    if phase[0] == 0:
                        original_pane.append(pane_pid())
                        self.assertTrue(original_pane[0].isdigit())
                        phase[0] = 1
                        GLib.idle_add(reconnect)
                    elif phase[0] == 1:
                        self.assertEqual(pane_pid(), original_pane[0])
                        phase[0] = 2
                        GLib.idle_add(surface.dispose)
                except BaseException as error:
                    errors.append(error)
                    loop.quit()

            def exited(*args):
                if phase[0] != 2:
                    return
                try:
                    self.assertEqual(pane_pid(), original_pane[0])
                    self.assertFalse(owner._terminal_owners)
                    phase[0] = 3
                except BaseException as error:
                    errors.append(error)
                loop.quit()

            def deadline():
                timed_out.append((phase[0], surface.status, surface.status_label.get_text()))
                loop.quit()
                return False

            owner.persist = persisted
            window = Gtk.Window()
            surface = TerminalSurface(owner, workspace, record, create=True)
            surface.terminal.connect("child-exited", exited)
            window.add(surface)
            window.show_all()
            timeout = GLib.timeout_add_seconds(12, deadline)
            try:
                loop.run()
            finally:
                if not timed_out:
                    GLib.source_remove(timeout)
                surface.dispose()
                window.destroy()
                subprocess.run(["tmux", "-L", socket, "kill-server"], capture_output=True)
                lock = Path.home() / ".local/state/uniconnect" / ("tmux-create-" + socket + ".lock")
                lock.unlink(missing_ok=True)
            if errors:
                raise errors[0]
            self.assertFalse(timed_out, timed_out)
            self.assertEqual(phase[0], 3)


if __name__ == "__main__":
    unittest.main()
