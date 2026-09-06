"""Pruebas PTY con procesos y servidor tmux estrictamente privados."""

import dataclasses
import os
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect.mobile_pty_process import MobilePTYProcess
from uniconnect.transport import SSHCommand, TerminalLaunch, TransportError


class _PTYFixture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-mobile-pty-")
        self.root = Path(self.directory.name)
        self.env = {"HOME": str(self.root), "PATH": "/usr/bin:/bin", "TERM": "xterm-256color",
                    "LC_ALL": "C.UTF-8"}
        self.processes = []

    def tearDown(self):
        for process in reversed(self.processes):
            process.close()
        self.directory.cleanup()

    def process(self, launch, columns=100, rows=30):
        process = MobilePTYProcess(launch, columns, rows)
        self.processes.append(process)
        return process

    def python_launch(self, script, env=None):
        return TerminalLaunch([sys.executable, "-I", "-c", script], str(self.root), env or self.env)

    def read_until(self, process, needle, timeout=4):
        output = bytearray()
        deadline = time.monotonic() + timeout
        while needle not in output:
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, repr(output[-200:]))
            try:
                chunk = process.read()
            except BlockingIOError:
                select.select([process.fileno()], [], [], remaining)
                continue
            self.assertTrue(chunk, repr(output[-200:]))
            output.extend(chunk)
        return bytes(output)


class MobilePTYProcessTests(_PTYFixture):
    def test_controlling_tty_binary_roundtrip_size_and_owned_close(self):
        script = ("import os,tty,sys; tty.setraw(0); "
                  "assert os.tcgetpgrp(0)==os.getpgrp()==os.getpid(); "
                  "os.write(1,b'PTY_OK'); "
                  "data=os.read(0,65536);os.write(1,data);sys.stdin.read()")
        process = self.process(self.python_launch(script), 101, 31)
        self.read_until(process, b"PTY_OK")
        self.assertEqual(os.get_terminal_size(process.fileno()), (101, 31))
        payload = b"\x00\x01\x03\x1b[A\xffhola"
        self.assertEqual(process.write(payload), len(payload))
        self.assertEqual(self.read_until(process, payload), payload)
        process.resize(51, 19)
        self.assertEqual(os.get_terminal_size(process.fileno()), (51, 19))
        process.close()
        process.close()
        self.assertIsNotNone(process.poll())
        self.assertEqual(process.fileno(), -1)
        self.assertEqual(process.read(), b"")

    def test_backpressure_is_nonblocking_and_can_be_closed(self):
        process = self.process(self.python_launch("import os,tty,time;tty.setraw(0);os.write(1,b'WAIT');time.sleep(30)"))
        self.read_until(process, b"WAIT")
        written = 0
        for _ in range(64):
            count = process.write(b"x" * 65536)
            written += count
            if count == 0:
                break
        self.assertGreater(written, 0)
        self.assertEqual(count, 0)

    def test_ready_strips_only_banner_and_markers_not_vt(self):
        token = "a" * 32
        output = (b"SSH banner\r\n\x1eUCPTY_BEGIN_" + token.encode() + b"\x1f"
                  b"\x1b[?1049hANTES\x1eUCPTY_READY_" + token.encode() + b"\x1fDESPUES\x1b[0m")
        launch = self.python_launch("import os,time;os.write(1," + repr(output) + ");time.sleep(30)",
                                    {**self.env, MobilePTYProcess._TOKEN_ENV: token})
        process = self.process(launch)
        self.assertTrue(process.wait_ready())
        self.assertEqual(process.read(), b"\x1b[?1049hANTESDESPUES\x1b[0m")
        with self.assertRaises(BlockingIOError):
            process.read()

    def test_begin_or_wrong_nonce_is_not_ready_timeout_cancel_and_exit(self):
        token = "b" * 32
        for suffix, timeout, cancelled, expected in (
                ("import time;time.sleep(30)", .08, None, "mobile_pty_attach_timeout"),
                ("import time;time.sleep(30)", 2, lambda: True, "mobile_pty_cancelled"),
                ("", 2, None, "mobile_pty_attach_failed")):
            with self.subTest(expected=expected):
                data = b"\x1eUCPTY_BEGIN_" + token.encode() + b"\x1f\x1eUCPTY_READY_" + b"c" * 32 + b"\x1f"
                process = self.process(self.python_launch("import os;os.write(1," + repr(data) + ");" + suffix,
                                                          {**self.env, MobilePTYProcess._TOKEN_ENV: token}))
                with self.assertRaises(TransportError) as error:
                    process.wait_ready(timeout, cancelled)
                self.assertEqual(error.exception.code, expected)
                self.assertIsNotNone(process.poll())

    def test_launch_validation_and_ssh_endpoint_credentials(self):
        record = {"tmux": "fixture", "tmuxSocket": "private", "paneId": "%1", "cwd": "/does-not-exist"}
        command = SSHCommand.parse("ssh -p2222 -i '/tmp/fixture key' -oStrictHostKeyChecking=yes user@fixture.invalid")
        launch = MobilePTYProcess.build_launch({"kind": "ssh"}, record, command)
        self.assertEqual(launch.argv[:-1], command.argv(tty=True, batch=True))
        self.assertEqual(launch.cwd, "/")
        for field, value in (("tmux", "bad:window"), ("tmuxSocket", "/tmp/unsafe"),
                             ("paneId", "%1;echo"), ("paneId", None)):
            with self.subTest(field=field), self.assertRaises(TransportError):
                MobilePTYProcess.build_launch({"kind": "local"}, {**record, field: value})
        for size in ((0, 2), (2, 65536), (True, 2), (2.0, 2)):
            with self.subTest(size=size), self.assertRaises(TransportError):
                self.process(self.python_launch("pass"), *size)


@unittest.skipUnless(shutil.which("tmux"), "tmux no disponible")
class MobilePTYTmuxTests(_PTYFixture):
    def setUp(self):
        super().setUp()
        self.binary = [shutil.which("tmux"), "-N", "-S", str(self.root / "server.sock"), "-f", "/dev/null"]
        self.addCleanup(self.stop_server)
        creator = [item for item in self.binary if item != "-N"]
        subprocess.run(creator + ["new-session", "-d", "-x", "100", "-y", "30", "-s", "fixture",
                                  "/bin/bash", "--noprofile", "--norc"], env=self.env, check=True, timeout=3)
        self.first = self.tmux("display-message", "-p", "-t", "=fixture:", "#{pane_id}")
        self.second = self.tmux("split-window", "-d", "-h", "-t", "=fixture:", "-P", "-F", "#{pane_id}",
                                "/bin/bash", "--noprofile", "--norc")
        desktop = TerminalLaunch(self.binary + ["attach-session", "-E", "-t", "=fixture"], str(self.root), self.env)
        self.desktop = self.process(desktop)
        self.read_until(self.desktop, b"\x1b[")

    def stop_server(self):
        subprocess.run(self.binary + ["kill-server"], env=self.env, capture_output=True, timeout=3)

    def tearDown(self):
        for process in reversed(self.processes):
            process.close()
        self.stop_server()
        self.directory.cleanup()

    def tmux(self, *args):
        result = subprocess.run(self.binary + list(args), env=self.env, capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def mobile(self, pane=None, name="fixture", size=(60, 18)):
        record = {"tmux": name, "tmuxSocket": "fixture", "paneId": pane or self.second}
        with mock.patch.object(MobilePTYProcess, "_tmux_argv", return_value=self.binary):
            launch = MobilePTYProcess.build_launch({"kind": "local"}, record)
        launch = dataclasses.replace(launch, env={**self.env, MobilePTYProcess._TOKEN_ENV: launch.env[MobilePTYProcess._TOKEN_ENV]})
        return self.process(launch, *size)

    def identities(self):
        return self.tmux("list-panes", "-s", "-t", "=fixture", "-F", "#{session_name}:#{window_id}:#{pane_id}:#{pane_pid}:#{pane_width}:#{pane_height}:#{pane_active}:#{window_active}")

    def unique_panes(self):
        return set(self.tmux("list-panes", "-a", "-F", "#{window_id}:#{pane_id}:#{pane_pid}").splitlines())

    def sessions(self):
        return self.tmux("list-sessions", "-F", "#{session_name}").splitlines()

    def test_smaller_larger_resize_and_close_preserve_pc_and_existing_panes(self):
        before = self.identities()
        panes = self.unique_panes()
        options = [self.tmux("show-options", *args) for args in (("-g",), ("-s",), ("-w", "-t", "=fixture:"))]
        clients = self.tmux("list-clients", "-F", "#{client_pid}")
        for size in ((45, 12), (180, 60)):
            with self.subTest(size=size):
                mobile = self.mobile(size=size)
                self.assertTrue(mobile.wait_ready())
                flags = self.tmux("list-clients", "-F", "#{client_pid}:#{client_flags}")
                flags = next(line for line in flags.splitlines() if line.startswith(str(mobile.pid) + ":"))
                self.assertIn("ignore-size", flags)
                self.assertIn("active-pane", flags)
                self.assertEqual(before, self.identities())
                self.assertEqual(panes, self.unique_panes(), "La auxiliar sólo enlaza los panes existentes")
                auxiliary = [name for name in self.sessions() if name != "fixture"]
                self.assertEqual(len(auxiliary), 1)
                self.assertTrue(auxiliary[0].startswith("uc-mobile-"))
                self.assertEqual("on", self.tmux("show-options", "-v", "-t", auxiliary[0], "destroy-unattached"))
                mobile.resize(220, 70)
                self.assertEqual(before, self.identities())
                mobile.resize(20, 5)
                self.assertEqual(before, self.identities())
                mobile.close()
                self.assertIsNone(self.desktop.poll())
                self.assertEqual(before, self.identities())
                self.assertEqual(["fixture"], self.sessions())
        self.assertEqual(clients, self.tmux("list-clients", "-F", "#{client_pid}"))
        self.assertEqual(options, [self.tmux("show-options", *args) for args in (("-g",), ("-s",), ("-w", "-t", "=fixture:"))])

    def test_input_targets_only_mobile_pane_and_ready_never_enters_view_mode(self):
        before = self.identities()
        mobile = self.mobile(size=(100, 30))
        mobile.wait_ready()
        marker = b"UC_MOBILE_BYTES_OK"
        self.assertEqual(mobile.write(b"echo " + marker + b"\r"), len(marker) + 6)
        output = self.read_until(mobile, marker)
        self.assertNotIn(b"UCPTY_READY_", output)
        self.assertNotIn(b"UCPTY_BEGIN_", output)
        self.assertNotIn(marker.decode(), self.tmux("capture-pane", "-p", "-t", self.first))
        self.assertIn(marker.decode(), self.tmux("capture-pane", "-p", "-t", self.second))
        self.assertEqual(before, self.identities())

    def test_attachment_never_runs_configured_default_command(self):
        marker = self.root / "unexpected-default-command"
        self.tmux("set-option", "-g", "default-shell", "/bin/sh")
        self.tmux("set-option", "-g", "default-command",
                  "printf unexpected > " + shlex.quote(str(marker)) + "; exec /bin/sleep 60")
        for _ in range(12):
            mobile = self.mobile()
            mobile.wait_ready()
            mobile.close()
            self.assertFalse(marker.exists(), "El attach ejecutó el default-command del usuario")
        self.assertEqual(["fixture"], self.sessions())

    def test_layout_main_attaches_only_to_unambiguous_saved_session(self):
        pane = self.tmux("new-session", "-d", "-s", "single", "-P", "-F", "#{pane_id}",
                         "/bin/bash", "--noprofile", "--norc")
        before = self.identities()
        mobile = self.mobile(pane="main", name="single")
        mobile.wait_ready()
        marker = b"UC_LAYOUT_MAIN_TARGET"
        mobile.write(b"echo " + marker + b"\r")
        self.read_until(mobile, marker)
        self.assertIn(marker.decode(), self.tmux("capture-pane", "-p", "-t", pane))
        self.assertEqual(before, self.identities())
        mobile.close()
        self.tmux("new-window", "-d", "-t", "=single:", "/bin/bash", "--noprofile", "--norc")
        panes = self.unique_panes()
        for name in ("single", "fixture"):
            with self.subTest(ambiguous=name):
                mobile = self.mobile(pane="main", name=name)
                with self.assertRaises(TransportError):
                    mobile.wait_ready(timeout=1)
                self.assertEqual(panes, self.unique_panes())
                self.assertEqual(["fixture", "single"], self.sessions())

    def test_desktop_window_change_never_redirects_mobile_input(self):
        mobile = self.mobile(size=(100, 30))
        mobile.wait_ready()
        # Create the other window AFTER readiness: a single-window preflight
        # cannot establish that the saved pane remains this client's target.
        other = self.tmux("new-window", "-d", "-t", "=fixture:", "-P", "-F", "#{pane_id}",
                          "/bin/bash", "--noprofile", "--norc")
        other_window = self.tmux("display-message", "-p", "-t", other, "#{window_id}")
        self.tmux("select-window", "-t", "=fixture:" + other_window)
        marker = "UC_PRIVATE_MOBILE_TARGET_STABLE"
        try:
            mobile.write(("echo " + marker + "\r").encode("ascii"))
        except (OSError, TransportError):
            # A fail-closed implementation may already have cancelled its own
            # client, but it must actually close rather than silently lose input.
            pass
        deadline = time.monotonic() + 3
        delivered_to_original = cancelled = False
        while time.monotonic() < deadline:
            self.assertNotIn(marker, self.tmux("capture-pane", "-p", "-t", other),
                             "La entrada móvil llegó a la nueva ventana del escritorio")
            cancelled = mobile.poll() is not None or mobile.fileno() < 0
            delivered_to_original = marker in self.tmux("capture-pane", "-p", "-t", self.second)
            if cancelled or delivered_to_original:
                break
            time.sleep(0.02)
        self.assertTrue(cancelled or delivered_to_original,
                        "La entrada no llegó al pane guardado ni se canceló el cliente móvil")
        self.assertNotIn(marker, self.tmux("capture-pane", "-p", "-t", other))
        self.assertIsNone(self.desktop.poll(), "El cliente del escritorio debe seguir vivo")

    def test_two_mobile_clients_keep_pc_copy_mode_and_each_other_alive(self):
        self.tmux("copy-mode", "-t", self.first)
        before = self.identities()
        first = self.mobile(size=(40, 12))
        second = self.mobile(size=(180, 60))
        first.wait_ready()
        second.wait_ready()
        self.assertEqual("1", self.tmux("display-message", "-p", "-t", self.first, "#{pane_in_mode}"))
        self.assertEqual(before, self.identities())
        first.resize(240, 80)
        first.close()
        self.assertIsNone(second.poll())
        self.assertIsNone(self.desktop.poll())
        self.assertEqual(before, self.identities())
        self.assertEqual("1", self.tmux("display-message", "-p", "-t", self.first, "#{pane_in_mode}"))

    def test_missing_targets_fail_and_other_window_attaches_without_selecting_desktop(self):
        other = self.tmux("new-window", "-d", "-t", "=fixture:", "-P", "-F", "#{pane_id}",
                          "/bin/bash", "--noprofile", "--norc")
        before = self.identities()
        for name, pane in (("absent", self.second), ("fixture", "%99999")):
            with self.subTest(name=name, pane=pane):
                process = self.mobile(pane, name)
                with self.assertRaises(TransportError) as error:
                    process.wait_ready(timeout=1)
                self.assertEqual(error.exception.code, "mobile_pty_attach_failed")
                self.assertEqual(before, self.identities())
                self.assertIsNone(self.desktop.poll())
        with self.subTest(name="fixture", pane=other):
            panes = self.unique_panes()
            process = self.mobile(other)
            self.assertTrue(process.wait_ready())
            self.assertEqual(before, self.identities())
            self.assertEqual(panes, self.unique_panes())
            auxiliary = next(name for name in self.sessions() if name != "fixture")
            self.assertEqual(other, self.tmux("display-message", "-p", "-t", "=" + auxiliary + ":", "#{pane_id}"))
            process.close()
            self.assertEqual(["fixture"], self.sessions())
            self.assertEqual(before, self.identities())
            self.assertIsNone(self.desktop.poll())

    def test_cancel_during_start_removes_only_auxiliary_and_never_creates_a_pane(self):
        before = self.identities()
        panes = self.unique_panes()
        for stage in ("immediate", "attached", "immediate", "attached"):
            with self.subTest(stage=stage):
                mobile = self.mobile()
                cancelled = ((lambda: True) if stage == "immediate" else
                             (lambda: len(self.sessions()) > 1))
                with self.assertRaises(TransportError):
                    mobile.wait_ready(timeout=2, cancelled=cancelled)
                self.assertIsNotNone(mobile.poll())
                self.assertEqual(["fixture"], self.sessions())
                self.assertEqual(before, self.identities())
                self.assertEqual(panes, self.unique_panes())
                self.assertIsNone(self.desktop.poll())

    def test_session_disappearing_after_build_cannot_create_a_fallback_shell(self):
        # Another private session keeps the server running after the intended
        # session disappears; -N alone does not guard new-session -t here.
        self.tmux("new-session", "-d", "-s", "keeper", "/bin/bash", "--noprofile", "--norc")
        record = {"tmux": "fixture", "tmuxSocket": "fixture", "paneId": self.second}
        with mock.patch.object(MobilePTYProcess, "_tmux_argv", return_value=self.binary):
            launch = MobilePTYProcess.build_launch({"kind": "local"}, record)
        launch = dataclasses.replace(launch, env={**self.env, MobilePTYProcess._TOKEN_ENV: launch.env[MobilePTYProcess._TOKEN_ENV]})
        self.tmux("kill-session", "-t", "=fixture")
        panes = self.unique_panes()
        mobile = self.process(launch)
        with self.assertRaises(TransportError):
            mobile.wait_ready(timeout=1)
        self.assertEqual(["keeper"], self.sessions())
        self.assertEqual(panes, self.unique_panes())

    def test_no_server_does_not_load_config_or_start_one(self):
        binary = [self.binary[0], "-N", "-S", str(self.root / "absent.sock"), "-f", "/dev/null"]
        with mock.patch.object(MobilePTYProcess, "_tmux_argv", return_value=binary):
            launch = MobilePTYProcess.build_launch({"kind": "local"}, {"tmux": "missing", "paneId": "%0"})
        process = self.process(dataclasses.replace(launch, env={**self.env, MobilePTYProcess._TOKEN_ENV: launch.env[MobilePTYProcess._TOKEN_ENV]}))
        with self.assertRaises(TransportError):
            process.wait_ready(timeout=1)
        self.assertFalse((self.root / "absent.sock").exists())


if __name__ == "__main__":
    unittest.main()
