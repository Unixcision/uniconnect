"""Real TCP admission and dead-stream recovery, on isolated CI loopback sockets."""

import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from uniconnect.mobile_access import MobileAccess
from uniconnect.mobile_host import MobileHost
from uniconnect.mobile_protocol import FrameDecoder, encode_frame

RealSocket = socket.socket


class LoopbackListener(RealSocket):
    """Only replace tailnet routing; keep production accept and TCP options."""
    accepted = 0

    def bind(self, address):
        super().bind(("127.0.0.1", 0))

    def accept(self):
        connection, address = super().accept()
        self.accepted += 1
        return connection, ("100.64.0.2" if self.accepted % 2 else "100.64.0.3", address[1])


@unittest.skipUnless(sys.platform == "linux", "Linux TCP transport")
class MobileConnectionsTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="uc-mobile-connections-")
        self.addCleanup(folder.cleanup)
        self.access = MobileAccess(Path(folder.name))
        for peer in ("100.64.0.2", "100.64.0.3"):
            self.access.authorize(peer)
            self.access.approve(peer)
        self.closed = queue.Queue()
        rpc = types.SimpleNamespace(disconnected=self.closed.put)
        self.now = 0
        self.host = MobileHost(self.access, rpc, resolve=lambda: "100.64.0.1", clock=lambda: self.now)
        ready = threading.Event()
        self.host.on_change = ready.set
        self.factory = patch("uniconnect.mobile_host.socket.socket", LoopbackListener)
        self.factory.start()
        self.addCleanup(self.factory.stop)
        self.thread = threading.Thread(target=self.host._listen, args=(self.host.generation,), daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)
        self.assertTrue(ready.wait(3), "Listener did not start")
        self.assertIsNone(self.host.error)
        self.port = self.host.listener.getsockname()[1]

    def stop(self):
        self.host.stop()
        self.thread.join(3)
        self.assertFalse(self.thread.is_alive())

    def connect(self):
        connection = RealSocket(socket.AF_INET, socket.SOCK_STREAM)
        self.addCleanup(connection.close)
        connection.settimeout(3)
        connection.connect(("127.0.0.1", self.port))
        return connection

    def subscribe(self, connection):
        connection.sendall(encode_frame({"id": "subscribe", "method": "mobile.events.subscribe",
            "params": {"stream_id": "terminal", "topics": ["terminal.pty"]}}))
        decoder = FrameDecoder()
        while True:
            data = connection.recv(65536)
            self.assertTrue(data, "Host refused a live phone's connection")
            frames = decoder.feed(data)
            if frames:
                self.assertTrue(frames[0]["ok"], frames[0])
                return

    def test_two_phones_fit_and_seventeenth_does_not_evict_active_streams(self):
        connections = [self.connect() for _ in range(16)]
        for connection in connections:
            self.subscribe(connection)
        with self.host.lock:
            self.assertEqual(len(self.host.clients), 16)
            self.assertEqual({peer: sum(c.peer == peer for c in self.host.clients)
                for peer in ("100.64.0.2", "100.64.0.3")}, {"100.64.0.2": 8, "100.64.0.3": 8})
        excess = self.connect()
        try:
            self.assertEqual(excess.recv(1), b"")
        except ConnectionResetError:
            pass
        for connection in connections:
            self.subscribe(connection)
        connections[0].close()
        self.closed.get(timeout=3)
        self.subscribe(self.connect())
        self.assertEqual(len(self.host.clients), 16)

    def test_accepted_socket_has_bounded_kernel_liveness_checks(self):
        self.subscribe(self.connect())
        with self.host.lock:
            connection = next(iter(self.host.clients)).socket
        self.assertEqual(connection.getsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE), 1)
        for option, expected in ((socket.TCP_KEEPIDLE, 30), (socket.TCP_KEEPINTVL, 10),
                                 (socket.TCP_KEEPCNT, 3), (socket.TCP_USER_TIMEOUT, 90000)):
            self.assertEqual(connection.getsockopt(socket.IPPROTO_TCP, option), expected)

    def test_live_silent_stream_survives_application_idle_deadline(self):
        connection = self.connect()
        self.subscribe(connection)
        self.now = 3600
        self.subscribe(connection)
        self.assertEqual(len(self.host.clients), 1)
        self.assertTrue(self.closed.empty())

    @unittest.skipUnless(os.environ.get("UC_TEST_TCP_BLACKHOLE") == "1", "Isolated CI firewall only")
    def test_unreachable_subscriber_releases_its_slot_without_closing_other_phone(self):
        dead, live = self.connect(), self.connect()
        self.subscribe(dead)
        self.subscribe(live)
        with self.host.lock:
            victim = next(c for c in self.host.clients if c.socket.getpeername()[1] == dead.getsockname()[1])
        # Shorten only the test socket's deadlines, not the production defaults.
        for option, value in ((socket.TCP_KEEPIDLE, 1), (socket.TCP_KEEPINTVL, 1),
                              (socket.TCP_KEEPCNT, 2), (socket.TCP_USER_TIMEOUT, 3000)):
            victim.socket.setsockopt(socket.IPPROTO_TCP, option, value)
        rule = ["OUTPUT", "-o", "lo", "-p", "tcp", "--sport", str(dead.getsockname()[1]),
                "--dport", str(self.port), "-j", "DROP"]
        subprocess.run(["iptables", "-I", *rule], check=True)
        try:
            self.assertEqual(self.closed.get(timeout=10), victim.identifier)
            self.assertNotIn(victim, self.host.clients)
            self.subscribe(live)
            self.subscribe(self.connect())
            self.assertEqual(len(self.host.clients), 2)
            self.assertTrue(self.access.is_approved(victim.peer))
        finally:
            subprocess.run(["iptables", "-D", *rule], check=True)
