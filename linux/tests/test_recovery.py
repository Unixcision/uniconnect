"""Regression checks for preserving an agent thread owned by another process."""

import os
import fcntl
from pathlib import Path
import pty
import select
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from unittest.mock import patch

import importlib.util

_SPEC = importlib.util.spec_from_file_location(
    "uniconnect_recovery", Path(__file__).resolve().parents[1] / "scripts/recovery.py"
)
recovery = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(recovery)


class LiveOwnershipTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("tmux"), "tmux required")
    def test_recovery_clipboard_policy_preserves_copy_buffer_and_running_pane(self):
        with tempfile.TemporaryDirectory(prefix="uc-copy-regression-") as directory:
            sock = str(Path(directory) / "socket")
            base = ["tmux", "-S", sock, "-f", "/dev/null"]
            def run(*args, **kwargs):
                return subprocess.run(base + list(args), text=True, capture_output=True, timeout=10, **kwargs)
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 119, 0, 0))
            client = None
            try:
                command = shlex.join([sys.executable, "-c", "import sys; print('UC_COPY_FIXTURE',flush=True); sys.stdin.readline()"])
                run("new-session", "-d", "-s", "fixture", "-x", "119", "-y", "35", command, check=True)
                run("set-option", "-t", "=fixture:", "@uniconnect_session_id", "fixture-id", check=True)
                before = run("display-message", "-p", "-t", "=fixture:", "#{pid}|#{pane_pid}", check=True).stdout
                data = {"tmuxSocket": "test-only", "windows": [{"tmux": "fixture", "sessionId": "fixture-id"}]}
                # Route the production recovery policy exclusively to this owned fixture socket.
                with patch.object(recovery, "tmux", side_effect=lambda data, *args, **kw: run(*args, **kw)):
                    recovery.ensure_windows(data, Path(directory) / "unused-manifest.json")
                self.assertEqual(run("show-options", "-s", "-v", "set-clipboard", check=True).stdout.strip(), "off")
                client = subprocess.Popen(base + ["attach-session", "-t", "=fixture"], stdin=slave, stdout=slave, stderr=slave,
                                          env={**os.environ, "TERM": "xterm-256color"}, close_fds=True)
                os.close(slave)
                slave = None
                deadline, output = time.monotonic() + 10, b""
                while b"UC_COPY_FIXTURE" not in output and time.monotonic() < deadline:
                    readable, _, _ = select.select([master], [], [], max(0, deadline - time.monotonic()))
                    if readable:
                        output += os.read(master, 65536)
                self.assertIn(b"UC_COPY_FIXTURE", output)
                run("copy-mode", "-t", "=fixture:", check=True)
                for action in ("history-top", "start-of-line", "begin-selection", "end-of-line", "copy-pipe-and-cancel"):
                    run("send-keys", "-t", "=fixture:", "-X", action, check=True)
                self.assertEqual(run("show-buffer", check=True).stdout.strip(), "UC_COPY_FIXTURE")
                self.assertEqual(run("display-message", "-p", "-t", "=fixture:", "#{pid}|#{pane_pid}", check=True).stdout, before)
            finally:
                run("kill-server", check=False)  # Only the uniquely created fixture socket.
                if client:
                    client.wait(timeout=10)
                if slave is not None:
                    os.close(slave)
                os.close(master)

    def test_kernel_lock_blocks_recovery_until_actual_owner_exits(self):
        with tempfile.TemporaryFile() as handle:
            path = Path("/proc") / str(os.getpid()) / "fd" / str(handle.fileno())
            child = subprocess.Popen(
                [sys.executable, "-c",
                 "import fcntl,sys; h=open(sys.argv[1]); fcntl.flock(h,fcntl.LOCK_EX); "
                 "print('ready',flush=True); sys.stdin.readline()", str(path)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, text=True,
            )
            try:
                self.assertEqual(child.stdout.readline().strip(), "ready")
                self.assertIn(child.pid, recovery.lock_owners(path))
                with patch.object(recovery, "native_lock_path", return_value=path):
                    self.assertFalse(recovery.native_session_available({}))
                # The owner exits normally; the recovery check never signals it.
                child.stdin.write("\n")
                child.stdin.flush()
                child.wait(timeout=5)
                self.assertEqual(recovery.lock_owners(path), [])
                with patch.object(recovery, "native_lock_path", return_value=path):
                    self.assertTrue(recovery.native_session_available({}))
            finally:
                child.stdin.close()
                child.stdout.close()
                child.wait(timeout=5)

    def test_existing_unowned_tmux_target_is_never_replaced(self):
        data = {"tmuxSocket": "uniconnect", "windows": [{
            "tmux": "uc-test-01a070d7", "sessionId": "01a070d7-5f44-7f33-aee1-867c845860ef",
        }]}
        calls = []

        def fake_tmux(data, *args, **kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args, 0, stdout="another-owner\n", stderr="")

        with patch.object(recovery, "tmux", side_effect=fake_tmux):
            with self.assertRaisesRegex(RuntimeError, "different ownership"):
                recovery.ensure_windows(data, Path("/tmp/unused-manifest.json"))
        self.assertEqual([call[0] for call in calls], ["has-session", "show-option"])


if __name__ == "__main__":
    unittest.main()
