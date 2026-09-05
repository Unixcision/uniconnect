"""Behavioral transport checks using isolated tmux and OpenSSH SFTP servers."""

import os
import pty
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect.transport import SSHCommand, TmuxCommand, Transport, TransportError, terminal_launch
from uniconnect.transfers import SFTPTransfer


class SSHCommandTests(unittest.TestCase):
    def test_identity_with_spaces_remains_one_argument(self):
        command = SSHCommand.parse("ssh -i '/tmp/private key.pem' -p2222 ec2-user@host")
        args = command.argv("printf '%s' 'hello; world'", tty=True)
        self.assertEqual(args[args.index("-i") + 1], "/tmp/private key.pem")
        self.assertLess(args.index("-tt"), args.index("ec2-user@host"))
        self.assertEqual(args[-1], "printf '%s' 'hello; world'")
        self.assertEqual(command.endpoint_key(resolve=False), ("ec2-user", "host", "2222"))

    def test_rejects_shell_payloads_and_ssh_execution_hooks(self):
        for value in ("ssh host; touch /tmp/escaped", "ssh host | sh", "ssh host reboot",
                      "ssh -oProxyCommand='touch /tmp/escaped' host", "ssh -F /tmp/evil host",
                      "ssh -oPermitLocalCommand=yes host", "ssh $(id) host", "sh -c 'ssh host'",
                      "ssh -p0 host", "ssh -i x\n host"):
            with self.subTest(value=value), self.assertRaises(TransportError):
                SSHCommand.parse(value)

    def test_password_never_in_representation(self):
        command = SSHCommand.parse("sshpass -p 'secret pass' ssh -i k user@host")
        self.assertNotIn("secret pass", repr(command))
        self.assertEqual(command.environment()["SSHPASS"], "secret pass")
        if shutil.which("sshpass"):
            self.assertNotIn("secret pass", command.argv("true"))

    def test_resume_keeps_requested_cwd_model_and_approval_settings(self):
        window = {"tmux": "test", "cwd": "/home/ec2-user", "repo": "/var/www/project",
                  "agent": "codex", "sessionId": "01a070d7-5f44-7f33-aee1-867c845860ef",
                  "model": "gpt-6-astra"}
        self.assertEqual(TmuxCommand.agent_argv(window), ["codex", "resume", window["sessionId"],
                                                         "-C", "/home/ec2-user", "-m", "gpt-6-astra"])
        self.assertNotIn("yolo", TmuxCommand.pane_command(window))
        for name in ("", "bad.name", "bad:name", "a" * 41):
            with self.assertRaises(TransportError):
                TmuxCommand.validate_name(name)
        self.assertLessEqual(len(TmuxCommand.suggested_name("Long window" * 50)), 40)

    def test_clipboard_workaround_only_changes_dedicated_sockets(self):
        window = {"tmux": "window", "cwd": "/tmp", "agent": "terminal"}
        for socket in ("uniconnect", "uniconnect-local", "user-custom", None):
            for create in (True, False):
                with self.subTest(socket=socket, create=create):
                    command = TmuxCommand.attach(window, socket_name=socket, create=create)
                    self.assertEqual("set-option -s set-clipboard off" in command,
                                     socket in ("uniconnect", "uniconnect-local"))

    def test_missing_local_root_is_a_recoverable_shell_not_an_agent_launch(self):
        with tempfile.TemporaryDirectory(prefix="uc-missing-root-") as directory:
            missing = str(Path(directory) / "deleted-root")
            window = {"tmux": "never-created", "cwd": missing, "agent": "codex", "sessionId": "native-id"}
            with mock.patch.dict(os.environ, {"BASH_ENV": "/must-not-source", "PROMPT_COMMAND": "must-not-run"}):
                launch = terminal_launch({"kind": "local"}, window, create=True)
            self.assertEqual(launch.notice, missing)
            self.assertEqual(window["cwd"], missing)
            self.assertNotEqual(launch.cwd, missing)
            self.assertNotIn("BASH_ENV", launch.env)
            self.assertNotIn("PROMPT_COMMAND", launch.env)
            self.assertNotIn("tmux", shlex.join(launch.argv))
            self.assertNotIn("codex", shlex.join(launch.argv))
            process = subprocess.run(launch.argv, input="printf 'UC_RECOVERABLE\\n'; exit\n", text=True,
                                     capture_output=True, cwd=launch.cwd, env=launch.env, timeout=5)
            self.assertEqual(process.returncode, 0)
            self.assertIn("UC_RECOVERABLE", process.stdout)


@unittest.skipUnless(shutil.which("tmux"), "tmux unavailable")
class TmuxBehaviorTests(unittest.TestCase):
    def setUp(self):
        self.socket = "uc-test-" + uuid.uuid4().hex[:12]
        self.transport = Transport(socket_name=self.socket)
        self.directory = tempfile.TemporaryDirectory(prefix="uc-transport-")
        self.window = {"tmux": "window-one", "tmuxSocket": self.socket, "cwd": self.directory.name,
                       "agent": "custom", "commandArgv": ["/usr/bin/sleep", "90"]}

    def tearDown(self):
        subprocess.run(["tmux", "-L", self.socket, "kill-server"], capture_output=True)
        lock = Path.home() / ".local/state/uniconnect" / ("tmux-create-" + self.socket + ".lock")
        lock.unlink(missing_ok=True)
        self.directory.cleanup()

    def pane_identity(self):
        return subprocess.check_output(["tmux", "-L", self.socket, "display-message", "-p", "-t", "=window-one:",
                                        "#{pane_pid}:#{pane_start_command}:#{pane_current_path}"], text=True).strip()

    def test_repeated_create_does_not_change_existing_pane(self):
        self.assertTrue(self.transport.ensure_session(self.window)["created"])
        before = self.pane_identity()
        changed = dict(self.window, commandArgv=["/usr/bin/false"])
        self.assertFalse(self.transport.ensure_session(changed)["created"])
        self.assertEqual(before, self.pane_identity())
        self.assertTrue(self.transport.preflight(self.window)["sessionExists"])
        self.assertIn(self.directory.name, before)

    def test_missing_reconnect_does_not_create(self):
        command = TmuxCommand.attach(self.window, socket_name=self.socket)
        result = subprocess.run(["/bin/bash", "-lc", command], capture_output=True)
        self.assertEqual(result.returncode, 72)
        self.assertEqual(self.transport.list_sessions(), [])

    def test_same_native_session_is_not_started_in_two_tmux_names(self):
        first = dict(self.window, sessionId="test-native-session")
        self.transport.ensure_session(first)
        with self.assertRaises(TransportError) as caught:
            self.transport.ensure_session(dict(first, tmux="window-two"))
        self.assertEqual(caught.exception.code, "duplicate_agent_owner")
        self.assertEqual([s["name"] for s in self.transport.list_sessions()], ["window-one"])

    def test_closing_client_keeps_tmux_pane(self):
        self.transport.ensure_session(self.window)
        before = self.pane_identity()
        launch = terminal_launch({"kind": "local"}, self.window)
        master, slave = pty.openpty()
        process = subprocess.Popen(launch.argv, stdin=slave, stdout=slave, stderr=slave,
                                   env=launch.env, cwd=launch.cwd, start_new_session=True)
        os.close(slave)
        # A bounded read waits for actual attach output before terminating this client.
        import select
        self.assertTrue(select.select([master], [], [], 5)[0])
        os.read(master, 1024)
        process.terminate()
        process.wait(timeout=5)
        os.close(master)
        self.assertEqual(before, self.pane_identity())


@unittest.skipUnless(shutil.which("tmux"), "tmux unavailable")
class TmuxHistoryBehaviorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-history-policy-")
        self.root = Path(self.directory.name)
        self.sockets = set()
        self.environment = dict(os.environ, TERM="xterm-256color")
        for name in ("TMUX", "TMUX_PANE", "BASH_ENV", "ENV", "PROMPT_COMMAND"):
            self.environment.pop(name, None)
        # Logical dedicated names still select production policy, but every
        # executable call goes to an absolute private socket and ignores configs.
        self.binary_patch = mock.patch.object(TmuxCommand, "_binary", side_effect=self.binary)
        self.pane_patch = mock.patch.object(TmuxCommand, "pane_command", return_value="/bin/bash --noprofile --norc")
        self.binary_patch.start()
        self.pane_patch.start()

    def tearDown(self):
        self.pane_patch.stop()
        self.binary_patch.stop()
        for socket in self.sockets:
            subprocess.run(["tmux", "-S", str(socket), "kill-server"], capture_output=True, timeout=3)
        self.directory.cleanup()

    def binary(self, name):
        socket = self.root / ((name or "default") + ".sock")
        self.sockets.add(socket)
        return shlex.join(["tmux", "-S", str(socket), "-f", "/dev/null"])

    def run_shell(self, script, **_):
        # Isolate creation-lock storage and login-profile effects, not the tmux
        # commands or their ordering under test. No real app state is accessed.
        script = script.replace("$HOME/.local/state/uniconnect", str(self.root / "locks"))
        script = script.replace("/bin/bash -lc ", "/bin/bash --noprofile --norc -c ")
        return subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", script],
                              env=self.environment, capture_output=True, text=True, timeout=8)

    def tmux(self, socket, *args):
        result = subprocess.run([*shlex.split(self.binary(socket)), *args], env=self.environment,
                                capture_output=True, text=True, timeout=8)
        self.assertEqual(0, result.returncode, result.stderr)
        return result.stdout.strip()

    def create(self, socket, route, name="subject", create=True):
        window = {"tmux": name, "cwd": str(self.root), "agent": "terminal", "tmuxSocket": socket}
        if route == "ensure":
            transport = Transport(socket_name=socket)
            transport.run = self.run_shell
            return transport.ensure_session(window)
        command = TmuxCommand.attach(window, socket_name=socket, create=create)
        master, slave = pty.openpty()
        process = subprocess.Popen(["/bin/bash", "--noprofile", "--norc", "-c", command],
                                   stdin=slave, stdout=slave, stderr=slave, env=self.environment,
                                   start_new_session=True)
        os.close(slave)
        try:
            self.assertTrue(select.select([master], [], [], 5)[0], "tmux client produced no startup output")
            os.read(master, 65536)
            self.tmux(socket, "has-session", "-t", "=" + name)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=3)
            os.close(master)

    def identity(self, socket, name="subject"):
        return self.tmux(socket, "display-message", "-p", "-t", "=" + name + ":", "#{pane_pid}:#{history_limit}")

    def test_dedicated_first_panes_keep_5100_lines_in_both_creation_routes(self):
        for socket in ("uniconnect", "uniconnect-local"):
            for route in ("ensure", "attach"):
                with self.subTest(socket=socket, route=route):
                    self.create(socket, route)
                    self.assertEqual("50000", self.identity(socket).split(":")[1])
                    signal = self.binary(socket) + " wait-for -S complete"
                    script = 'for ((i=1;i<=5100;i++)); do printf "UC_LINE_%04d\\n" "$i"; done; ' + signal
                    self.tmux(socket, "send-keys", "-l", "-t", "=subject:", script)
                    self.tmux(socket, "send-keys", "-t", "=subject:", "Enter")
                    self.tmux(socket, "wait-for", "complete")
                    lines = self.tmux(socket, "capture-pane", "-p", "-S", "-", "-t", "=subject:").splitlines()
                    self.assertEqual([f"UC_LINE_{i:04d}" for i in range(1, 5101)],
                                     [line for line in lines if line.startswith("UC_LINE_")])
                    self.tmux(socket, "kill-server")

    def test_existing_dedicated_panes_and_limits_are_not_changed(self):
        socket = "uniconnect"
        self.tmux(socket, "set-option", "-g", "history-limit", "1234", ";", "new-session", "-d", "-s", "subject",
                  "/bin/bash --noprofile --norc")
        before = self.identity(socket)
        for route in ("ensure", "attach"):
            self.create(socket, route)
            self.assertEqual(before, self.identity(socket))
            self.assertEqual("1234", self.tmux(socket, "show-options", "-gv", "history-limit"))
        self.create(socket, "attach", create=False)
        self.assertEqual(before, self.identity(socket))
        self.assertEqual("", self.tmux(socket, "show-options", "-v", "-t", "=subject:", "history-limit"))

    def test_larger_dedicated_global_limit_is_preserved(self):
        socket = "uniconnect"
        self.tmux(socket, "set-option", "-g", "history-limit", "70000", ";", "new-session", "-d", "-s", "keeper",
                  "/bin/bash --noprofile --norc")
        before = self.identity(socket, "keeper")
        for route in ("ensure", "attach"):
            self.create(socket, route, name=route)
            self.assertEqual("70000", self.identity(socket, route).split(":")[1])
            self.assertEqual("70000", self.tmux(socket, "show-options", "-gv", "history-limit"))
            self.assertEqual(before, self.identity(socket, "keeper"))

    def test_custom_and_default_servers_keep_their_own_history_policy(self):
        for socket in ("custom", None):
            self.tmux(socket, "set-option", "-g", "history-limit", "9000", ";", "new-session", "-d", "-s", "keeper",
                      "/bin/bash --noprofile --norc")
            for route in ("ensure", "attach"):
                with self.subTest(socket=socket, route=route):
                    self.create(socket, route, name=route)
                    self.assertEqual("9000", self.identity(socket, route).split(":")[1])
                    self.assertEqual("9000", self.tmux(socket, "show-options", "-gv", "history-limit"))
                    # No per-session override is introduced on another server.
                    self.assertEqual("", self.tmux(socket, "show-options", "-v", "-t", "=" + route + ":", "history-limit"))


class LocalSFTPCommand:
    def argv(self, *args, **kwargs):
        return ["/usr/lib/openssh/sftp-server"]

    def environment(self):
        return dict(os.environ)


@unittest.skipUnless(Path("/usr/lib/openssh/sftp-server").exists(), "sftp-server unavailable")
class SFTPBehaviorTests(unittest.TestCase):
    def test_binary_upload_reports_confirmed_bytes_and_publishes_complete_file(self):
        with tempfile.TemporaryDirectory(prefix="uc-sftp-") as directory:
            source = Path(directory) / "image ' with spaces.png"
            data = bytes(range(256)) * 300
            source.write_bytes(data)
            destination = Path(directory) / "destination"
            destination.mkdir()
            events = []
            transfer = SFTPTransfer(LocalSFTPCommand())
            result = transfer.run(source, str(destination), lambda done, total: events.append((done, total)))
            self.assertEqual(Path(result).read_bytes(), data)
            self.assertEqual(events[0], (0, len(data)))
            self.assertEqual(events[-1], (len(data), len(data)))
            self.assertEqual(len(list(destination.iterdir())), 1)
            self.assertEqual(Path(result).stat().st_mode & 0o777, 0o600)

    def test_cancel_removes_only_its_partial_file(self):
        with tempfile.TemporaryDirectory(prefix="uc-sftp-") as directory:
            source = Path(directory) / "source"
            source.write_bytes(b"x" * 100000)
            destination = Path(directory) / "destination"
            destination.mkdir()
            sentinel = destination / "existing"
            sentinel.write_text("keep me")
            transfer = SFTPTransfer(LocalSFTPCommand())
            with self.assertRaises(TransportError) as caught:
                transfer.run(source, str(destination), lambda done, total: transfer.cancel() if done else None)
            self.assertEqual(caught.exception.code, "upload_cancelled")
            self.assertEqual(list(destination.iterdir()), [sentinel])
            self.assertEqual(sentinel.read_text(), "keep me")


if __name__ == "__main__":
    unittest.main()
