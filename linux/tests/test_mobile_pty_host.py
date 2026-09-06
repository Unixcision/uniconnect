"""Private PTY event routing and lifecycle through isolated local sockets."""

import base64
from pathlib import Path
import socket
import sys
import tempfile
import threading
import types
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect.mobile_access import MobileAccess
from uniconnect.mobile_host import MobileHost, _Client
from uniconnect.mobile_protocol import FrameDecoder, RPCError, encode_frame


class MobilePTYHostTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix="uc-pty-host-")
        self.access = MobileAccess(Path(self.folder.name))
        self.disconnections = []
        self.responses = []
        self.dispatches = []
        self.rpc = types.SimpleNamespace(
            dispatch=self.dispatch,
            disconnected=self.disconnections.append,
            response_enqueued=self.response_enqueued,
        )
        self.host = MobileHost(self.access, self.rpc)
        self.sockets = []
        self.threads = []
        self.on_response = lambda *args: None

    def tearDown(self):
        self.host.stop()
        for connection in self.sockets:
            connection.close()
        for thread in self.threads:
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive(), "El hilo privado no terminó")
        self.folder.cleanup()

    def dispatch(self, method, params, connection_id, **kwargs):
        self.dispatches.append((method, connection_id))
        return {"attach_id": "fixture-attach"}

    def response_enqueued(self, method, result, connection_id):
        self.responses.append((method, result, connection_id))
        self.on_response(method, result, connection_id)

    def client(self, address="100.64.0.2", *, approved=True):
        left, right = socket.socketpair()
        self.sockets.extend((left, right))
        right.settimeout(2)
        client = _Client(self.host, left, address)
        with self.host.lock:
            self.host.clients.add(client)
        if approved and not self.access.is_approved(address):
            self.access.authorize(address)
            self.assertTrue(self.access.approve(address))
        return client, right

    def start(self, client):
        thread = threading.Thread(target=client.run, daemon=True)
        self.threads.append(thread)
        thread.start()
        return thread

    @staticmethod
    def queued(client):
        with client.lock:
            wire = b"".join(frame for _, frame in client.queue)
            client.queue.clear()
            client.queue_bytes = 0
        return FrameDecoder().feed(wire)

    def subscribe(self, client, stream="pty", topics=None):
        client.handle({"id": "subscribe", "method": "mobile.events.subscribe", "params": {
            "stream_id": stream, "topics": topics if topics is not None else ["terminal.pty"],
        }})
        return self.queued(client)[0]

    @staticmethod
    def payload(seq=0):
        return {"attach_id": "fixture-attach", "surface_id": "fixture-surface", "seq": seq,
                "data": base64.b64encode(b"\x1b[31mSalida\x00\xff\r\n").decode("ascii")}

    def test_topic_negotiation_preserves_existing_topics_and_filters_unknown(self):
        client, _ = self.client()
        result = self.subscribe(client, topics=["terminal.pty", "terminal.updated", "desconocido"])
        self.assertEqual(result["result"]["topics"], ["terminal.pty", "terminal.updated"])
        self.assertTrue(self.host.has_topic(client.identifier, "terminal.pty"))
        self.assertFalse(self.host.has_topic(client.identifier, "desconocido"))
        self.assertFalse(self.host.has_topic("conexión-inexistente", "terminal.pty"))

    def test_private_output_reaches_only_owner_even_when_peers_share_approval(self):
        owner, _ = self.client()
        other, _ = self.client()
        for client in (owner, other):
            self.subscribe(client)
        self.assertNotEqual(owner.identifier, other.identifier)
        for seq in range(3):
            self.assertTrue(self.host.emit_private(owner.identifier, "terminal.pty", self.payload(seq)))
        events = self.queued(owner)
        self.assertEqual([event["payload"]["seq"] for event in events], [0, 1, 2])
        self.assertEqual(base64.b64decode(events[0]["payload"]["data"]), b"\x1b[31mSalida\x00\xff\r\n")
        self.assertEqual(self.queued(other), [])
        self.host.emit("terminal.pty", self.payload(4))
        self.assertEqual(self.queued(owner), [])
        self.assertEqual(self.queued(other), [])

    def test_unknown_unsubscribed_rejected_and_revoked_have_no_private_output(self):
        client, _ = self.client()
        self.assertFalse(self.host.emit_private("no-existe", "terminal.pty", self.payload()))
        self.assertFalse(self.host.emit_private(client.identifier, "terminal.pty", self.payload()))
        self.subscribe(client)
        self.access.revoke(client.peer)
        self.assertFalse(self.host.has_topic(client.identifier, "terminal.pty"))
        self.assertFalse(self.host.emit_private(client.identifier, "terminal.pty", self.payload()))
        self.assertEqual(self.queued(client), [])
        rejected, _ = self.client("100.64.0.3", approved=False)
        self.access.reject(rejected.peer)
        self.assertEqual(self.subscribe(rejected)["error"]["code"], "approval_required")
        self.assertFalse(self.host.has_topic(rejected.identifier, "terminal.pty"))
        self.assertFalse(self.host.emit_private(rejected.identifier, "terminal.pty", self.payload()))
        self.assertEqual(self.queued(rejected), [])
        self.assertEqual(self.access.snapshot()[1], [])

    def test_unsubscribe_union_does_not_duplicate_and_last_unsubscribe_blocks_output(self):
        client, _ = self.client()
        self.subscribe(client, "first")
        self.subscribe(client, "second")
        for stream in ("first", "second"):
            client.handle({"id": stream, "method": "mobile.events.unsubscribe",
                           "params": {"stream_id": stream}})
            self.queued(client)
            expected = stream == "first"
            self.assertEqual(self.host.has_topic(client.identifier, "terminal.pty"), expected)
            self.assertEqual(self.host.emit_private(client.identifier, "terminal.pty", self.payload()), expected)
            self.assertEqual(len(self.queued(client)), int(expected))

    def test_socket_ack_precedes_first_pty_byte(self):
        client, peer = self.client()
        def begin_output(method, result, owner):
            if method == "mobile.terminal.attach":
                self.host.emit_private(owner, "terminal.pty", self.payload())
        self.on_response = begin_output
        self.start(client)
        requests = [
            {"id": "subscribe", "method": "mobile.events.subscribe",
             "params": {"stream_id": "pty", "topics": ["terminal.pty"]}},
            {"id": "attach", "method": "mobile.terminal.attach", "params": {}},
        ]
        peer.sendall(b"".join(encode_frame(request) for request in requests))
        decoder, messages = FrameDecoder(), []
        while len(messages) < 3:
            received = peer.recv(65536)
            self.assertTrue(received, "Conexión terminada antes de recibir la salida")
            messages.extend(decoder.feed(received))
        self.assertEqual([message.get("id") for message in messages], ["subscribe", "attach", None])
        self.assertEqual(messages[1]["result"]["attach_id"], "fixture-attach")
        self.assertEqual(messages[2], {"kind": "event", "topic": "terminal.pty", "payload": self.payload()})

    def test_ack_queue_failure_cleans_up_without_starting_reader(self):
        client, _ = self.client()
        self.subscribe(client)
        self.responses.clear()
        for number in range(128):
            self.assertTrue(client.enqueue({"id": str(number), "ok": True}))
        client.handle({"id": "attach", "method": "mobile.terminal.attach", "params": {}})
        self.assertTrue(client.closed)
        self.assertEqual(self.responses, [])
        self.assertEqual(self.disconnections, [client.identifier])
        self.assertEqual(self.queued(client), [])

    def test_failed_rpc_never_invokes_success_callback(self):
        client, _ = self.client()
        def fail(*args, **kwargs):
            raise RPCError("attach_failed", "No se pudo adjuntar el terminal")
        self.rpc.dispatch = fail
        client.handle({"id": "attach", "method": "mobile.terminal.attach", "params": {}})
        self.assertEqual(self.queued(client)[0]["error"]["code"], "attach_failed")
        self.assertEqual(self.responses, [])

    def test_private_byte_budget_overflow_closes_and_notifies_exactly_once(self):
        client, _ = self.client()
        self.subscribe(client)
        self.assertTrue(self.host.emit_private(client.identifier, "terminal.pty", {"data": "a" * 1048576}))
        self.assertFalse(self.host.emit_private(client.identifier, "terminal.pty", {"data": "b" * 1048576}))
        self.assertTrue(client.closed)
        self.assertEqual(self.disconnections, [client.identifier])
        self.assertEqual(client.queue_bytes, 0)
        self.assertFalse(client.enqueue({"id": "late"}))
        client.close()
        client.run()
        self.assertEqual(self.disconnections, [client.identifier])

    def test_stop_and_revoke_release_attachments_without_waiting_for_client_read(self):
        first, _ = self.client()
        second, _ = self.client("100.64.0.3")
        self.access.revoke(first.peer)
        self.assertEqual(self.disconnections, [first.identifier])
        self.assertFalse(second.closed)
        self.host.stop()
        self.assertEqual(self.disconnections, [first.identifier, second.identifier])
        self.host.stop()
        first.run()
        second.run()
        self.assertEqual(self.disconnections, [first.identifier, second.identifier])

    def test_disconnect_all_drops_queued_pty_gives_eof_and_preserves_listener_approval(self):
        clients = [self.client(), self.client("100.64.0.3")]
        for client, _ in clients:
            self.subscribe(client)
            self.assertTrue(self.host.emit_private(client.identifier, "terminal.pty", self.payload()))
        permissions = self.access.path.read_bytes()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(2)
        self.host.listener, self.host.address = listener, "100.64.0.1"
        generation = self.host.generation
        callback_unlocked = []

        def disconnected(owner):
            acquired = threading.Event()
            def probe():
                with self.host.lock:
                    for client, _ in clients:
                        with client.lock:
                            pass
                    acquired.set()
            worker = threading.Thread(target=probe, daemon=True)
            self.threads.append(worker)
            worker.start()
            callback_unlocked.append(acquired.wait(1))
            self.disconnections.append(owner)
        self.rpc.disconnected = disconnected

        self.host.disconnect_clients()
        self.host.disconnect_clients()
        for client, peer in clients:
            self.assertTrue(client.closed)
            self.assertEqual(client.queue_bytes, 0)
            self.assertEqual(self.queued(client), [])
            self.assertEqual(peer.recv(1), b"")
            self.assertFalse(self.host.emit_private(client.identifier, "terminal.pty", self.payload()))
            client.run()
        self.assertCountEqual(self.disconnections, [client.identifier for client, _ in clients])
        self.assertEqual(callback_unlocked, [True, True])
        self.assertEqual(self.host.clients, set())
        self.assertIs(self.host.listener, listener)
        self.assertEqual((self.host.address, self.host.generation), ("100.64.0.1", generation))
        self.assertEqual(self.access.path.read_bytes(), permissions)
        # The exact same private listener still accepts a new connection.
        with socket.create_connection(listener.getsockname(), timeout=2):
            accepted, _ = listener.accept()
            accepted.close()

    def test_disconnect_one_owner_does_not_close_same_peer_sibling_or_revoke(self):
        first, peer = self.client()
        second, _ = self.client()
        for client in (first, second):
            self.subscribe(client)
            self.host.emit_private(client.identifier, "terminal.pty", self.payload())
        permissions = self.access.path.read_bytes()
        self.host.disconnect_client("unknown-owner")
        self.host.disconnect_client(first.identifier)
        self.host.disconnect_client(first.identifier)
        self.assertEqual(peer.recv(1), b"")
        self.assertEqual(first.queue_bytes, 0)
        self.assertEqual(self.queued(first), [])
        self.assertFalse(second.closed)
        self.assertEqual(len(self.queued(second)), 1)
        self.assertEqual(self.disconnections, [first.identifier])
        self.assertEqual(self.host.clients, {second})
        self.assertEqual(self.access.path.read_bytes(), permissions)

    def test_cleanup_callback_holds_neither_host_nor_client_lock(self):
        client, _ = self.client()
        acquired = threading.Event()
        callback_results = []
        def disconnected(owner):
            def probe():
                with self.host.lock, client.lock:
                    acquired.set()
            probe_thread = threading.Thread(target=probe, daemon=True)
            self.threads.append(probe_thread)
            probe_thread.start()
            callback_results.append(acquired.wait(1))
            self.disconnections.append(owner)
        self.rpc.disconnected = disconnected
        self.host.stop()
        self.assertEqual(callback_results, [True])
        self.assertEqual(self.disconnections, [client.identifier])

    def test_parallel_close_and_reader_eof_still_notify_once(self):
        client, peer = self.client()
        reader = self.start(client)
        ready = threading.Barrier(5)
        def close():
            ready.wait(timeout=2)
            client.close()
        workers = [threading.Thread(target=close, daemon=True) for _ in range(4)]
        self.threads.extend(workers)
        for worker in workers:
            worker.start()
        ready.wait(timeout=2)
        peer.close()
        for worker in workers + [reader]:
            worker.join(timeout=2)
            self.assertFalse(worker.is_alive())
        self.assertEqual(self.disconnections, [client.identifier])

    def test_private_send_waiting_on_approval_cannot_outlive_revocation(self):
        client, _ = self.client()
        self.subscribe(client)
        started, results = threading.Event(), []
        def emit():
            started.set()
            results.append(self.host.emit_private(client.identifier, "terminal.pty", self.payload()))
        with self.access.lock:
            worker = threading.Thread(target=emit, daemon=True)
            self.threads.append(worker)
            worker.start()
            self.assertTrue(started.wait(1))
            self.access.revoke(client.peer)
        worker.join(timeout=2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(results, [False])
        self.assertEqual(self.queued(client), [])
        self.assertEqual(self.disconnections, [client.identifier])

    def test_legacy_rpc_without_response_hook_remains_compatible(self):
        client, _ = self.client()
        del self.rpc.response_enqueued
        client.handle({"id": "status", "method": "mobile.host.status", "params": {}})
        self.assertTrue(self.queued(client)[0]["ok"])
        self.assertFalse(client.closed)


if __name__ == "__main__":
    unittest.main()
