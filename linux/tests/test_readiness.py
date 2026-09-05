"""Exact tmux-client readiness on private real PTYs; no user's sessions involved."""

import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import threading
import time
import unittest
from unittest.mock import patch
import uuid

from uniconnect.readiness import ReadinessError, TmuxAttachmentProbe
from uniconnect.transport import SSHCommand, Transport


@unittest.skipUnless(shutil.which("tmux") and Path("/proc/self/environ").exists(), "Linux tmux and /proc required")
class AttachmentReadinessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uc-readiness-")
        self.addCleanup(self.temporary.cleanup)
        self.socket = "uc-ready-" + uuid.uuid4().hex[:16]
        self.record = {"tmux": "candidate", "tmuxSocket": self.socket}
        self.transport = Transport(socket_name=self.socket)
        self.clients = []
        self.token = uuid.uuid4().hex
        base = ["tmux", "-L", self.socket, "-f", "/dev/null"]
        self.base = base
        # This daemon has no candidate nonce. Only each attached client gets one.
        environment = dict(os.environ)
        environment.pop("UNICONNECT_ATTACH_TOKEN", None)
        subprocess.run(base + ["new-session", "-d", "-s", "candidate", "-x", "119", "-y", "35",
                               "/usr/bin/sleep 90"], env=environment, check=True, capture_output=True)
        self.addCleanup(self.cleanup_fixture)
        self.before = self.identity()

    def cleanup_fixture(self):
        subprocess.run(self.base + ["kill-server"], capture_output=True, timeout=5)
        for client, master in self.clients:
            client.wait(timeout=5)
            os.close(master)

    def identity(self):
        return subprocess.check_output(self.base + ["display-message", "-p", "-t", "=candidate:",
                                                    "#{pid}|#{pane_pid}"], text=True).strip()

    def attach(self, token=None, name="candidate"):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 35, 119, 0, 0))
        env = dict(os.environ)
        env.pop("TMUX", None)
        env.pop("UNICONNECT_ATTACH_TOKEN", None)
        env["TERM"] = "xterm-256color"
        if token is not None:
            env["UNICONNECT_ATTACH_TOKEN"] = token
        client = subprocess.Popen(self.base + ["attach-session", "-t", "=" + name], stdin=slave, stdout=slave,
                                  stderr=slave, env=env, close_fds=True)
        os.close(slave)
        self.clients.append((client, master))
        # A PTY render is an event-driven indication the fixture really attached.
        readable, _, _ = select.select([master], [], [], 5)
        self.assertTrue(readable)
        self.assertTrue(os.read(master, 65536))
        self.assertIsNone(client.poll())
        return client

    def assert_code(self, expected, operation):
        with self.assertRaises(ReadinessError) as caught:
            operation()
        self.assertEqual(caught.exception.code, expected)
        self.assertEqual(str(caught.exception), expected)

    def test_exact_live_client_proof_and_single_diagnostic_launch(self):
        unrelated = self.attach(uuid.uuid4().hex)
        expected = self.attach(self.token)
        probe = TmuxAttachmentProbe(self.transport, self.record, self.token, threading.Event())
        with patch.object(probe, "_launch", wraps=probe._launch) as launch:
            proof = probe.wait(timeout=3)
        self.assertEqual(launch.call_count, 1)
        self.assertEqual(proof, {"kind": "tmux-client-attached", "token": self.token,
                                 "tmux": "candidate", "clientPid": expected.pid})
        self.assertNotEqual(proof["clientPid"], unrelated.pid)
        self.assertEqual(self.identity(), self.before)
        self.assertIsNone(expected.poll())
        self.assertIsNone(unrelated.poll())

    def test_existing_session_without_matching_nonce_is_not_ready(self):
        for token in (None, uuid.uuid4().hex):
            self.attach(token)
            probe = TmuxAttachmentProbe(self.transport, self.record, self.token, threading.Event())
            started = time.monotonic()
            self.assert_code("readiness_timeout", lambda: probe.wait(timeout=0.3))
            self.assertLess(time.monotonic() - started, 1.5)
            self.assertEqual(self.identity(), self.before)

    def test_right_nonce_on_different_session_does_not_prove_target(self):
        subprocess.run(self.base + ["new-session", "-d", "-s", "candidate-other", "/usr/bin/sleep 90"],
                       check=True, capture_output=True)
        self.attach(self.token, "candidate-other")
        probe = TmuxAttachmentProbe(self.transport, self.record, self.token, threading.Event())
        self.assert_code("readiness_timeout", lambda: probe.wait(timeout=0.3))
        self.assertEqual(self.identity(), self.before)

    def test_cancel_terminates_only_diagnostic_and_keeps_attachment_alive(self):
        candidate = self.attach(uuid.uuid4().hex)
        cancel = threading.Event()
        launched = threading.Event()
        probe = TmuxAttachmentProbe(self.transport, self.record, self.token, cancel)
        native_launch = probe._launch
        processes, failures = [], []
        def launch(timeout):
            process = native_launch(timeout)
            processes.append(process)
            launched.set()
            return process
        def wait():
            try:
                probe.wait(timeout=10)
            except ReadinessError as error:
                failures.append(error.code)
        with patch.object(probe, "_launch", side_effect=launch):
            worker = threading.Thread(target=wait)
            worker.start()
            self.assertTrue(launched.wait(3))
            cancel.set()
            worker.join(timeout=2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(failures, ["readiness_cancelled"])
        self.assertIsNotNone(processes[0].poll())
        self.assertIsNone(candidate.poll())
        self.assertEqual(self.identity(), self.before)

    def test_pre_cancelled_probe_does_not_launch_process(self):
        cancel = threading.Event()
        cancel.set()
        probe = TmuxAttachmentProbe(self.transport, self.record, self.token, cancel)
        with patch.object(probe, "_launch", side_effect=AssertionError("must not launch")):
            self.assert_code("readiness_cancelled", probe.wait)

    def test_disconnected_nonce_client_is_not_ready(self):
        client = self.attach(self.token)
        listed = subprocess.check_output(self.base + ["list-clients", "-F", "#{client_pid}\t#{client_name}"], text=True)
        name = next(line.split("\t")[1] for line in listed.splitlines() if line.split("\t")[0] == str(client.pid))
        subprocess.run(self.base + ["detach-client", "-t", name], check=True, capture_output=True)
        client.wait(timeout=3)
        probe = TmuxAttachmentProbe(self.transport, self.record, self.token, threading.Event())
        self.assert_code("readiness_timeout", lambda: probe.wait(timeout=0.3))
        self.assertEqual(self.identity(), self.before)


class ReadinessBoundaryTests(unittest.TestCase):
    def probe(self, token="a" * 32, record=None):
        return TmuxAttachmentProbe(Transport(socket_name="uc-fixture"), record or {"tmux": "fixture"},
                                   token, threading.Event())

    def test_rejects_invalid_tokens_targets_and_timeouts_without_launch(self):
        for token in ("", "abc", "g" * 32, "a" * 129, "a" * 32 + ";id", None):
            with self.subTest(token=token), self.assertRaises(ReadinessError) as caught:
                self.probe(token=token)
            self.assertEqual(caught.exception.code, "readiness_invalid_token")
        for record in ({"tmux": "bad:name"}, {"tmux": "fixture", "tmuxSocket": "../../default"}, {}):
            with self.subTest(record=record), self.assertRaises(ReadinessError):
                TmuxAttachmentProbe(Transport(), record, "a" * 32, threading.Event())
        probe = self.probe()
        for timeout in (0, -1, 121, float("nan"), float("inf"), True, "20"):
            with self.subTest(timeout=timeout), patch.object(probe, "_launch", side_effect=AssertionError("must not launch")):
                with self.assertRaises(ReadinessError) as caught:
                    probe.wait(timeout=timeout)
                self.assertEqual(caught.exception.code, "readiness_invalid_timeout")

    def test_remote_command_uses_one_existing_transport_ssh_and_redacted_environment(self):
        command = SSHCommand("fixture.invalid", options=("-p", "2222"))
        transport = Transport(command, socket_name="uc-fixture")
        probe = TmuxAttachmentProbe(transport, {"tmux": "fixture"}, "b" * 32, threading.Event())
        with patch("uniconnect.readiness.subprocess.Popen") as spawn:
            probe._launch(20)
        args, kwargs = spawn.call_args
        argv = args[0]
        self.assertEqual(argv[0], "/usr/bin/ssh")
        self.assertIn("BatchMode=yes", argv)
        self.assertIn("fixture.invalid", argv)
        self.assertIn("-T", argv)
        self.assertNotIn("-tt", argv)
        self.assertTrue(kwargs["start_new_session"])
        self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)

    def test_invalid_diagnostic_output_never_leaks_to_error(self):
        marker = "PRIVATE_DIAGNOSTIC_OUTPUT"
        probe = self.probe()
        def launch(timeout):
            return subprocess.Popen(["/usr/bin/python3", "-c", "print(" + repr(marker) + ")"],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    start_new_session=True)
        with patch.object(probe, "_launch", side_effect=launch), self.assertRaises(ReadinessError) as caught:
            probe.wait(timeout=3)
        self.assertEqual(caught.exception.code, "readiness_invalid_proof")
        self.assertNotIn(marker, str(caught.exception))

    def test_malformed_or_unbounded_proof_is_rejected_with_a_stable_code(self):
        probe = self.probe()
        valid = {"kind": "tmux-client-attached", "token": "a" * 32, "tmux": "fixture", "clientPid": 99}
        malformed = [json.dumps({**valid, "clientPid": True}), json.dumps({**valid, "token": "b" * 32}),
                     json.dumps({**valid, "tmux": "another"}), json.dumps({"error": []}),
                     '{"error":"readiness_timeout","error":"readiness_timeout"}', "x" * 5000,
                     "[" * 1500 + "0" + "]" * 1500]
        for raw in malformed:
            def launch(timeout):
                return subprocess.Popen(["/usr/bin/python3", "-c", "print(" + repr(raw) + ")"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        start_new_session=True)
            with self.subTest(size=len(raw)), patch.object(probe, "_launch", side_effect=launch):
                with self.assertRaises(ReadinessError) as caught:
                    probe.wait(timeout=3)
                self.assertEqual(caught.exception.code, "readiness_invalid_proof")


if __name__ == "__main__":
    unittest.main()
