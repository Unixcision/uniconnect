"""Real VTE fixture processes with deterministic, injected retry deadlines."""

import os
import shlex
import shutil
import signal
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
    from uniconnect.transport import TerminalLaunch
    GTK_AVAILABLE = Gtk.init_check()[0]
except (ImportError, ValueError):
    GTK_AVAILABLE = False


class ManualDeadlines:
    def __init__(self):
        self.now = 100.0
        self.sequence = 0
        self.pending = {}

    def schedule(self, delay, callback):
        self.sequence += 1
        self.pending[self.sequence] = (self.now + delay, delay, callback)
        return self.sequence

    def cancel(self, token):
        self.pending.pop(token, None)

    def advance(self, seconds):
        self.now += seconds
        ready = sorted((due, token, callback) for token, (due, _, callback) in self.pending.items() if due <= self.now)
        for _, token, callback in ready:
            if token in self.pending:
                del self.pending[token]
                callback()


@unittest.skipUnless(GTK_AVAILABLE, "GTK/VTE display required")
class AutomaticReconnectTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-retry-")
        self.timer = ManualDeadlines()
        self.calls = []
        self.watch = None
        self.surface = None
        self.window = Gtk.Window()
        self.owner = SimpleNamespace(store=SimpleNamespace(data={"settings": {}}), font_scale=1,
                                     _=lambda text: text, refresh_sidebar=self.notify, persist=self.notify,
                                     connection=lambda _: "ssh fixture.invalid", notify_window=lambda *args: None)

    def tearDown(self):
        self.watch = None
        if self.surface:
            self.surface.dispose()
        self.window.destroy()
        self.directory.cleanup()

    def notify(self):
        if self.watch:
            self.watch()

    def start(self, scripts, *, kind="ssh", create=False):
        def prepare(workspace, record, connect, create):
            self.calls.append(create)
            command = scripts[min(len(self.calls) - 1, len(scripts) - 1)]
            launch = TerminalLaunch(["/bin/sh", "-c", command], self.directory.name, dict(os.environ))
            return launch, [("tmux", ("fixture",), "fixture", "window")]
        self.surface = TerminalSurface(
            self.owner, {"id": "workspace", "kind": kind},
            {"id": "window", "tmux": "window", "name": "Retry fixture", "cwd": self.directory.name},
            create=create, clock=lambda: self.timer.now, schedule=self.timer.schedule,
            cancel_timer=self.timer.cancel, launch_preparer=prepare,
        )
        self.window.add(self.surface)
        self.window.show_all()

    def until(self, predicate):
        if predicate():
            return
        loop = GLib.MainLoop()
        timeout_fired = []

        def changed():
            if predicate():
                # Returning through the entire child callback preserves its state transaction.
                GLib.idle_add(loop.quit)

        def deadline():
            timeout_fired.append(True)
            loop.quit()
            return False

        self.watch = changed
        timer = GLib.timeout_add_seconds(5, deadline)
        loop.run()
        self.watch = None
        if not timeout_fired:
            GLib.source_remove(timer)
        self.assertFalse(timeout_fired, (self.surface.status, self.surface.status_label.get_text()))
        self.assertTrue(predicate())

    def test_exit_255_retries_six_times_attach_only_then_releases_ownership(self):
        self.start(["exit 255"], create=True)
        self.until(lambda: self.surface.status == "Reconnecting")
        for index, delay in enumerate((1, 2, 4, 8, 16, 16)):
            self.assertTrue(self.owner._terminal_owners)
            self.assertEqual([item[1] for item in self.timer.pending.values()], [delay])
            self.timer.advance(delay)
            wanted = "Disconnected" if index == 5 else "Reconnecting"
            self.until(lambda: len(self.calls) == index + 2 and self.surface.status == wanted)
        self.assertEqual(self.calls, [True, False, False, False, False, False, False])
        self.assertIn("Reconnect attempts exhausted", self.surface.status_label.get_text())
        self.assertFalse(self.owner._terminal_owners)
        self.assertFalse(self.timer.pending)

    def test_detach_missing_tmux_and_local_failures_do_not_retry(self):
        for kind, code in (("ssh", 0), ("ssh", 1), ("ssh", 72), ("local", 255)):
            with self.subTest(kind=kind, code=code):
                self.calls.clear()
                if self.surface:
                    self.surface.dispose()
                    self.window.remove(self.surface)
                self.start([f"exit {code}"], kind=kind)
                self.until(lambda: self.surface.status == "Disconnected")
                self.assertEqual(len(self.calls), 1)
                self.assertFalse(self.timer.pending)
                self.assertFalse(self.owner._terminal_owners)

    def test_server_crash_marker_retries_once_but_stale_scrollback_does_not(self):
        self.start(["printf '[server exited unexpectedly]\\n'; exit 1", "exit 1"])
        self.until(lambda: self.surface.status == "Reconnecting")
        self.timer.advance(1)
        self.until(lambda: len(self.calls) == 2 and self.surface.status == "Disconnected")
        self.assertEqual(self.calls, [False, False])
        self.assertFalse(self.timer.pending)

    @unittest.skipUnless(shutil.which("tmux"), "tmux unavailable")
    def test_real_isolated_tmux_server_crash_retries_attach_only(self):
        socket = "uc-crash-test-" + uuid.uuid4().hex[:12]
        command = ["tmux", "-L", socket]
        subprocess.run(command + ["-f", "/dev/null", "new-session", "-d", "-s", "fixture", "sleep 90"], check=True)
        self.addCleanup(lambda: subprocess.run(command + ["kill-server"], capture_output=True))
        server = int(subprocess.check_output(command + ["display-message", "-p", "#{pid}"], text=True))
        # This is the same attach-only command and missing-session exit used over
        # SSH; only the SSH hop is replaced with an isolated local tmux fixture.
        attach = shlex.join(command + ["has-session", "-t", "=fixture"]) + " 2>/dev/null || exit 72; exec "
        attach += shlex.join(command + ["attach-session", "-t", "=fixture"])
        self.start([attach])
        self.until(lambda: self.surface.status == "Running")
        attached = []

        def detect_client():
            result = subprocess.run(command + ["list-clients", "-F", "#{client_pid}"], text=True, capture_output=True)
            if result.stdout.strip():
                attached.append(True)
                self.notify()
                return False
            return True

        detector = GLib.timeout_add(10, detect_client)
        try:
            self.until(lambda: bool(attached))
        finally:
            if not attached:
                GLib.source_remove(detector)
        # Exact server PID was created above by this fixture; no user socket/PID
        # is queried or modified. SIGKILL simulates the clipboard core crash.
        os.kill(server, signal.SIGKILL)
        self.until(lambda: self.surface.status == "Reconnecting")
        self.timer.advance(1)
        self.until(lambda: len(self.calls) == 2 and self.surface.status == "Disconnected")
        self.assertEqual(self.calls, [False, False])
        self.assertIn("exit 72", self.surface.status_label.get_text())
        result = subprocess.run(command + ["has-session", "-t", "=fixture"], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.timer.pending)

    def test_manual_reconnect_cancels_backoff_and_stale_timer_cannot_respawn(self):
        self.start(["exit 255", "exit 0"])
        self.until(lambda: self.surface.status == "Reconnecting")
        stale = next(iter(self.timer.pending.values()))[2]
        self.surface.launch()
        self.until(lambda: len(self.calls) == 2 and self.surface.status == "Disconnected")
        stale()
        self.assertEqual(len(self.calls), 2)
        self.assertFalse(self.timer.pending)

    def test_late_backoff_timer_obeys_sixty_second_budget(self):
        self.start(["exit 255"])
        self.until(lambda: self.surface.status == "Reconnecting")
        self.timer.advance(61)
        self.assertEqual(self.surface.status, "Disconnected")
        self.assertEqual(len(self.calls), 1)
        self.assertFalse(self.owner._terminal_owners)

    def test_dispose_cancels_pending_network_reconnect(self):
        self.start(["exit 255"])
        self.until(lambda: self.surface.status == "Reconnecting")
        stale = next(iter(self.timer.pending.values()))[2]
        self.surface.dispose()
        stale()
        self.assertEqual(len(self.calls), 1)
        self.assertFalse(self.timer.pending)
        self.assertFalse(self.owner._terminal_owners)

    def test_full_stability_interval_resets_outage_budget(self):
        self.start(["exit 255", "read token; exit 255"])
        self.until(lambda: self.surface.status == "Reconnecting")
        self.timer.advance(1)
        self.until(lambda: len(self.calls) == 2 and self.surface.status == "Running")
        self.assertEqual(self.surface._retry_attempts, 1)
        self.timer.advance(60)
        self.assertEqual(self.surface._retry_attempts, 0)
        self.assertIsNone(self.surface._outage_started)
        self.assertTrue(self.owner._terminal_owners)
        self.surface.send("continue\n")
        self.until(lambda: self.surface.status == "Reconnecting")
        self.assertEqual([item[1] for item in self.timer.pending.values()], [1])


if __name__ == "__main__":
    unittest.main()
