"""Real mobile RPC → private PTY → private tmux, without a desktop application."""

import base64
import dataclasses
import os
from pathlib import Path
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect.mobile_host import MobileHost, _Client
from uniconnect.mobile_protocol import FrameDecoder, encode_frame
from uniconnect.mobile_pty_process import MobilePTYProcess
from uniconnect.mobile_rpc import MobileRPC
from uniconnect.transport import TerminalLaunch


class WirePeer:
    def __init__(self, connection):
        self.connection, self.decoder = connection, FrameDecoder()
        self.messages, self.next_id = [], 0

    def receive_until(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while not predicate(self.messages):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.connection], [], [], max(0, remaining))[0]:
                raise AssertionError("Tiempo agotado esperando una respuesta de la fixture")
            data = self.connection.recv(65536)
            if not data:
                raise AssertionError("El socket privado se cerró antes de la respuesta")
            self.messages.extend(self.decoder.feed(data))

    def request(self, method, params):
        self.next_id += 1
        identifier = str(self.next_id)
        self.connection.sendall(encode_frame({"id": identifier, "method": method, "params": params}))
        self.receive_until(lambda messages: any(value.get("id") == identifier for value in messages))
        return next(value for value in self.messages if value.get("id") == identifier)

    @staticmethod
    def output(messages):
        return b"".join(base64.b64decode(value["payload"]["data"]) for value in messages
                        if value.get("topic") == "terminal.pty" and "data" in value["payload"])


@unittest.skipUnless(shutil.which("tmux"), "tmux no disponible")
class MobilePTYEndToEndTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-pty-e2e-")
        self.root = Path(self.directory.name)
        self.binary = [shutil.which("tmux"), "-N", "-S", str(self.root / "fixture.sock"), "-f", "/dev/null"]
        self.env = {"HOME": str(self.root), "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LC_ALL": "C.UTF-8"}
        self.processes, self.sockets, self.threads = [], [], []
        self.host = None
        self.addCleanup(self.cleanup)
        subprocess.run([item for item in self.binary if item != "-N"] + [
            "new-session", "-d", "-s", "fixture", "-x", "100", "-y", "30",
            "/bin/bash", "--noprofile", "--norc",
        ], env=self.env, check=True, timeout=3, capture_output=True)
        self.first = self.tmux("display-message", "-p", "-t", "=fixture:", "#{pane_id}")
        self.second = self.tmux("split-window", "-d", "-h", "-t", "=fixture:", "-P", "-F", "#{pane_id}",
                                "/bin/bash", "--noprofile", "--norc")
        self.desktop = self.process(TerminalLaunch(
            self.binary + ["attach-session", "-E", "-t", "=fixture"], str(self.root), self.env), 100, 30)
        deadline, startup = time.monotonic() + 3, bytearray()
        while b"\x1b[" not in startup:
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, "El cliente PC privado no arrancó")
            self.assertTrue(select.select([self.desktop.fileno()], [], [], remaining)[0])
            startup.extend(self.desktop.read())
        record = {"id": "surface", "name": "Terminal", "tmux": "fixture", "tmuxSocket": "private",
                  "paneId": self.second, "cwd": str(self.root)}
        workspace = {"id": "workspace", "kind": "local", "cwd": str(self.root), "windows": [record]}
        window = types.SimpleNamespace(locked=False, surfaces={}, store=types.SimpleNamespace(workspaces=[workspace]))
        access = types.SimpleNamespace(lock=threading.RLock(), machine_id="fixture",
                                       authorize=lambda *args: True, is_approved=lambda *args: True)
        self.rpc = MobileRPC(window, access, lambda callback: callback(), pty_factory=self.process)
        self.host = MobileHost(access, self.rpc)
        self.rpc.host = self.host

    def cleanup(self):
        if self.host:
            self.host.stop()
        for process in reversed(self.processes):
            process.close()
        for connection in self.sockets:
            connection.close()
        for thread in self.threads:
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive(), "El socket privado no terminó")
        subprocess.run(self.binary + ["kill-server"], env=self.env, capture_output=True, timeout=3)
        self.directory.cleanup()

    def process(self, launch, columns, rows):
        env = dict(self.env)
        if MobilePTYProcess._TOKEN_ENV in launch.env:
            env[MobilePTYProcess._TOKEN_ENV] = launch.env[MobilePTYProcess._TOKEN_ENV]
        process = MobilePTYProcess(dataclasses.replace(launch, env=env), columns, rows)
        self.processes.append(process)
        return process

    def tmux(self, *args):
        result = subprocess.run(self.binary + list(args), env=self.env, capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def identities(self):
        return self.tmux("list-panes", "-s", "-t", "=fixture", "-F",
                         "#{session_name}:#{window_id}:#{pane_id}:#{pane_pid}:#{pane_width}:#{pane_height}:#{pane_active}:#{window_active}")

    def native_panes(self):
        # Grouped sessions link existing panes; duplicate links are not newly
        # spawned shells. Verify the actual pane/PID pairs across the server.
        return set(self.tmux("list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}").splitlines())

    def peer(self, address):
        left, right = socket.socketpair()
        self.sockets.extend((left, right))
        right.settimeout(5)
        client = _Client(self.host, left, address)
        with self.host.lock:
            self.host.clients.add(client)
        thread = threading.Thread(target=client.run, daemon=True)
        self.threads.append(thread)
        thread.start()
        return WirePeer(right)

    def test_private_rpc_attach_input_resize_detach_preserves_desktop(self):
        before = self.identities()
        native_before = self.native_panes()
        desktop_pid = self.desktop.pid
        owner, other = self.peer("100.64.0.2"), self.peer("100.64.0.3")
        params = {"workspace_id": "workspace", "surface_id": "surface", "client_id": "etiqueta",
                  "columns": 100, "rows": 30}
        rejected = owner.request("mobile.terminal.attach", params)
        self.assertEqual(rejected["error"]["code"], "subscription_required")
        self.assertEqual(len(self.processes), 1)
        for peer in (owner, other):
            subscribed = peer.request("mobile.events.subscribe", {"stream_id": "pty", "topics": ["terminal.pty"]})
            self.assertEqual(subscribed["result"]["topics"], ["terminal.pty"])
        with patch.object(MobilePTYProcess, "_tmux_argv", return_value=self.binary):
            attached = owner.request("mobile.terminal.attach", params)
        self.assertTrue(attached["ok"], attached)
        attach_id = attached["result"]["attach_id"]
        mobile = self.processes[-1]
        owner.receive_until(lambda messages: any(value.get("topic") == "terminal.pty" for value in messages))
        first_event = next(index for index, value in enumerate(owner.messages) if value.get("topic") == "terminal.pty")
        self.assertLess(owner.messages.index(attached), first_event)
        self.assertEqual(self.identities(), before)
        self.assertEqual(self.native_panes(), native_before)
        sessions = self.tmux("list-sessions", "-F", "#{session_name}").splitlines()
        auxiliary = [name for name in sessions if name != "fixture"]
        self.assertEqual(len(auxiliary), 1)
        self.assertRegex(auxiliary[0], r"^uc-mobile-[0-9a-f]{32}$")
        self.assertEqual(self.tmux("show-options", "-v", "-t", auxiliary[0], "destroy-unattached"), "on")
        # The literal output marker does not occur in the command: observing it
        # proves execution, not merely the terminal echo of pasted input.
        command = b"printf '\\125\\103\\137\\105\\062\\105\\137\\117\\113\\n'\r"
        queued = owner.request("mobile.terminal.pty_input", {"attach_id": attach_id,
                              "data": base64.b64encode(command).decode("ascii")})
        self.assertTrue(queued["result"]["queued"])
        try:
            owner.receive_until(lambda messages: b"UC_E2E_OK" in WirePeer.output(messages))
        except AssertionError:
            self.fail(repr(WirePeer.output(owner.messages)[-1600:]) + "\n" +
                      self.tmux("capture-pane", "-p", "-t", self.second))
        self.assertNotIn("UC_E2E_OK", self.tmux("capture-pane", "-p", "-t", self.first))
        self.assertIn("UC_E2E_OK", self.tmux("capture-pane", "-p", "-t", self.second))
        for columns, rows in ((220, 70), (20, 5)):
            resized = owner.request("mobile.terminal.pty_resize", {"attach_id": attach_id,
                                    "columns": columns, "rows": rows})
            self.assertTrue(resized["ok"], resized)
            self.assertEqual(os.get_terminal_size(mobile.fileno()), (columns, rows))
            self.assertEqual(self.identities(), before)
            self.assertEqual(self.native_panes(), native_before)
        other.request("mobile.events.subscribe", {"stream_id": "pty", "topics": ["terminal.pty"]})
        self.assertFalse(any(value.get("topic") == "terminal.pty" for value in other.messages))
        events = [value["payload"] for value in owner.messages if value.get("topic") == "terminal.pty"]
        self.assertEqual([value["seq"] for value in events], list(range(len(events))))
        self.assertTrue(all(value["attach_id"] == attach_id and value["surface_id"] == "surface" for value in events))
        detached = owner.request("mobile.terminal.detach", {"attach_id": attach_id})
        self.assertEqual(detached["result"], {"ok": True})
        mobile._process.wait(timeout=3)
        self.assertIsNone(self.desktop.poll())
        self.assertEqual(self.desktop.pid, desktop_pid)
        self.assertEqual(self.identities(), before)
        self.assertEqual(self.native_panes(), native_before)
        self.assertEqual(self.tmux("list-sessions", "-F", "#{session_name}"), "fixture")


if __name__ == "__main__":
    unittest.main()
