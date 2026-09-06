"""Connection-owned PTY manager coverage using private nonblocking socket pairs."""

import base64
from pathlib import Path
import queue
import socket
import sys
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect.mobile_protocol import RPCError
from uniconnect.mobile_pty import MobilePTYAttachments


class SocketProcess:
    def __init__(self, *, blocked_ready=False, max_read=65536, max_write=65536, source_geometry=None):
        self.socket, self.peer = socket.socketpair()
        self.socket.setblocking(False)
        self.peer.settimeout(2)
        self.max_read, self.max_write = max_read, max_write
        self.started, self.reading = threading.Event(), threading.Event()
        self.ready, self.closed = threading.Event(), threading.Event()
        self.lock = threading.Lock()
        self.resizes, self.writes = [], []
        self.buffered_output = bytearray()
        self.close_count = 0
        self.returncode = None
        self.source_geometry = source_geometry
        if not blocked_ready:
            self.ready.set()

    def wait_ready(self, *, timeout, cancelled):
        self.started.set()
        if not self.ready.wait(timeout):
            raise TimeoutError("Tiempo de espera de la prueba agotado")
        if cancelled() or self.closed.is_set():
            raise OSError("Proceso privado cancelado")

    def read(self, maximum):
        self.reading.set()
        if self.buffered_output:
            count = min(maximum, self.max_read)
            result = bytes(self.buffered_output[:count])
            del self.buffered_output[:count]
            return result
        if self.returncode is not None:
            return b""
        return self.socket.recv(min(maximum, self.max_read))

    def write(self, data):
        written = self.socket.send(data[:self.max_write])
        self.writes.append(data[:written])
        return written

    def resize(self, columns, rows):
        self.resizes.append((columns, rows))

    def poll(self):
        return self.returncode

    def fileno(self):
        return self.socket.fileno()

    def close(self):
        with self.lock:
            if self.closed.is_set():
                return
            self.close_count += 1
            self.returncode = 0
            try:
                self.socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.socket.close()
            self.ready.set()
            self.closed.set()


class MobilePTYAttachmentTests(unittest.TestCase):
    def setUp(self):
        self.processes, self.launches, self.prepared, self.validations = [], [], [], []
        self.events = queue.Queue()
        self.emit_attempted = threading.Event()
        self.approved = {"owner": True, "other": True}
        self.subscribed = {"owner": True, "other": True}
        self.identity, self.locked, self.accept_events = 1, False, True
        self.disconnections = []
        self.process_options = {}
        self.manager = MobilePTYAttachments(
            prepare=self.prepare, validate=self.validate, has_topic=self.has_topic,
            emit=self.emit, process_factory=self.factory, disconnect=self.disconnections.append,
        )

    def tearDown(self):
        self.manager.close()
        for process in self.processes:
            self.assertTrue(process.closed.wait(2), "El cliente privado no se cerró")
            process.peer.close()

    def authorized(self, connection):
        return lambda: self.approved.get(connection, False)

    def prepare(self, params, authorized):
        target = {"workspace_id": params.get("workspace_id", "workspace"),
                  "surface_id": params.get("surface_id", "surface"), "identity": self.identity}
        self.validate(target, authorized)
        self.prepared.append(target)
        return {"target": target}, target

    def validate(self, target, authorized):
        self.validations.append(target)
        if not authorized():
            raise RPCError("approval_required", "Permiso revocado")
        if self.locked:
            raise RPCError("locked", "Equipo bloqueado")
        if target["identity"] != self.identity:
            raise RPCError("stale_target", "La identidad del destino ha cambiado")

    def has_topic(self, connection, topic):
        self.assertEqual(topic, "terminal.pty")
        return self.subscribed.get(connection, False)

    def emit(self, connection, topic, payload):
        self.emit_attempted.set()
        if not self.accept_events:
            return False
        self.events.put((connection, topic, payload))
        return True

    def factory(self, launch, columns, rows):
        self.launches.append((launch, columns, rows))
        process = SocketProcess(**self.process_options)
        self.processes.append(process)
        return process

    def dispatch(self, operation, params, connection="owner"):
        return self.manager.dispatch(operation, params, connection, self.authorized(connection))

    def attach(self, surface="surface", connection="owner", **changes):
        params = {"workspace_id": "workspace", "surface_id": surface,
                  "columns": 80, "rows": 24, "client_id": "untrusted-client-label"}
        params.update(changes)
        return self.dispatch("terminal.attach", params, connection)

    def input(self, attached, data, connection="owner"):
        return self.dispatch("terminal.pty_input", {"attach_id": attached["attach_id"],
                             "data": base64.b64encode(data).decode("ascii")}, connection)

    def assert_error(self, code, callback):
        with self.assertRaises(RPCError) as caught:
            callback()
        self.assertEqual(caught.exception.code, code)

    def next_event(self):
        owner, topic, payload = self.events.get(timeout=2)
        self.assertEqual(owner, "owner")
        self.assertEqual(topic, "terminal.pty")
        return payload

    def test_four_per_connection_and_idempotence_are_independent_of_client_label(self):
        attached = [self.attach(f"surface-{number}") for number in range(4)]
        same = self.attach("surface-0", client_id="otra-etiqueta", columns=40, rows=12)
        self.assertEqual(same, attached[0])
        self.assertEqual(len(self.processes), 4)
        self.assertEqual(len({value["attach_id"] for value in attached}), 4)
        self.assert_error("too_many_attachments", lambda: self.attach("surface-4"))
        self.assertEqual(len(self.processes), 4)
        other = self.attach("surface-0", "other")
        self.assertNotEqual(other["attach_id"], attached[0]["attach_id"])

    def test_geometry_is_optional_and_does_not_redefine_requested_pty_size(self):
        geometry = {"source_columns": 80, "source_rows": 23,
                    "presentation_columns": 80, "presentation_rows": 24}
        self.process_options = {"source_geometry": geometry}
        attached = self.attach(columns=120, rows=50)
        self.assertEqual((attached["columns"], attached["rows"]), (120, 50))
        self.assertEqual({key: attached[key] for key in geometry}, geometry)
        self.manager.activate(attached["attach_id"], "owner")
        first = self.next_event()
        self.assertEqual(first["seq"], 0)
        self.assertNotIn("data", first)
        self.assertEqual({key: first[key] for key in geometry}, geometry)
        changed = {**geometry, "source_rows": 30, "presentation_rows": 33}
        self.processes[0].source_geometry = changed
        self.processes[0].peer.sendall(b"\x1b[2JCONTENIDO")
        event = self.next_event()
        self.assertEqual(event["seq"], 1)
        self.assertEqual({key: event[key] for key in geometry}, changed)
        self.assertEqual(base64.b64decode(event["data"]), b"\x1b[2JCONTENIDO")
        self.assertEqual(len(self.processes), 5)

    def test_foreign_owner_cannot_input_resize_detach_or_activate_with_claimed_client_id(self):
        attached = self.attach()
        for operation in ("terminal.pty_input", "terminal.pty_resize", "terminal.detach"):
            with self.subTest(operation=operation):
                params = {"attach_id": attached["attach_id"], "client_id": "owner",
                          "columns": 1, "rows": 1, "data": "eA=="}
                self.assert_error("not_found", lambda: self.dispatch(operation, params, "other"))
        self.manager.activate(attached["attach_id"], "other")
        self.assertFalse(self.processes[0].reading.is_set())
        self.assertEqual(self.processes[0].writes, [])
        self.assertEqual(self.processes[0].resizes, [])
        self.assertFalse(self.processes[0].closed.is_set())

    def test_attach_rejects_missing_subscription_permission_and_invalid_dimensions_before_spawn(self):
        self.subscribed["owner"] = False
        self.assert_error("subscription_required", self.attach)
        self.subscribed["owner"] = True
        for changes in ({"columns": 0}, {"rows": 1001}, {"columns": True}, {"rows": "24"},
                        {"client_id": ""}, {"client_id": "x" * 129}, {"client_id": None}):
            with self.subTest(changes=changes):
                self.assert_error("invalid_params", lambda: self.attach(**changes))
        self.approved["owner"] = False
        self.assert_error("approval_required", self.attach)
        self.assertEqual(self.launches, [])
        self.assertEqual(self.prepared, [])

    def test_raw_input_accepts_exactly_64k_and_bounds_total_queued_bytes(self):
        attached = self.attach()
        raw = bytes(range(256)) * 256
        for _ in range(4):
            self.assertEqual(self.input(attached, raw), {"attach_id": attached["attach_id"], "queued": True})
        self.assert_error("busy", lambda: self.input(attached, b"x"))
        self.assertEqual(self.processes[0].writes, [])
        self.manager.activate(attached["attach_id"], "owner")
        received = bytearray()
        while len(received) < 4 * len(raw):
            chunk = self.processes[0].peer.recv(4 * len(raw) - len(received))
            self.assertTrue(chunk, "La entrada quedó incompleta antes del cierre")
            received.extend(chunk)
        self.assertEqual(bytes(received), raw * 4)
        self.dispatch("terminal.detach", {"attach_id": attached["attach_id"]})
        self.assertTrue(self.processes[0].closed.wait(2))

    def test_input_queue_also_bounds_chunk_count(self):
        attached = self.attach()
        for _ in range(128):
            self.input(attached, b"x")
        self.assert_error("busy", lambda: self.input(attached, b"x"))
        self.assertEqual(self.processes[0].writes, [])

    def test_input_rejects_oversize_malformed_non_ascii_and_empty_without_writing(self):
        attached = self.attach()
        for data in (None, 1, "", "%%%", "eA=", "é", "eA==\n",
                     base64.b64encode(b"x" * 65537).decode("ascii"), "A" * 87388):
            with self.subTest(length=len(data) if isinstance(data, str) else data):
                self.assert_error("invalid_params", lambda: self.dispatch("terminal.pty_input", {
                    "attach_id": attached["attach_id"], "data": data,
                }))
        self.assertEqual(self.processes[0].writes, [])

    def test_activate_after_ack_preserves_raw_bytes_and_monotonic_sequence(self):
        self.process_options["max_read"] = 3
        attached = self.attach()
        process = self.processes[0]
        raw = b"\x1b[31m\x00\xff\r\n"
        process.peer.sendall(raw)
        self.assertTrue(self.events.empty())
        self.assertFalse(process.reading.is_set())
        self.manager.activate(attached["attach_id"], "owner")
        chunks = [self.next_event() for _ in range((len(raw) + 2) // 3)]
        self.assertEqual([item["seq"] for item in chunks], list(range(len(chunks))))
        self.assertTrue(all(item["attach_id"] == attached["attach_id"] and item["surface_id"] == "surface"
                            for item in chunks))
        self.assertEqual(b"".join(base64.b64decode(item["data"]) for item in chunks), raw)

    def test_input_partial_writes_preserve_bytes_and_order(self):
        self.process_options["max_write"] = 3
        attached = self.attach()
        raw = b"\x1b[200~uno\x00\xff\x1b[201~\r"
        self.input(attached, raw[:7])
        self.input(attached, raw[7:])
        self.manager.activate(attached["attach_id"], "owner")
        received = bytearray()
        while len(received) < len(raw):
            chunk = self.processes[0].peer.recv(len(raw) - len(received))
            self.assertTrue(chunk, "La entrada quedó incompleta antes del cierre")
            received.extend(chunk)
        self.assertEqual(bytes(received), raw)
        self.assertTrue(all(len(value) <= 3 for value in self.processes[0].writes))

    def test_resize_only_targets_owned_live_process_and_validates_bounds(self):
        attached = self.attach()
        for columns, rows in ((1, 1), (1000, 1000), (40, 12)):
            result = self.dispatch("terminal.pty_resize", {"attach_id": attached["attach_id"],
                                   "columns": columns, "rows": rows})
            self.assertEqual(result, {"attach_id": attached["attach_id"], "columns": columns, "rows": rows})
        self.assert_error("invalid_params", lambda: self.dispatch("terminal.pty_resize", {
            "attach_id": attached["attach_id"], "columns": False, "rows": 12,
        }))
        self.assertEqual(self.processes[0].resizes, [(1, 1), (1000, 1000), (40, 12)])
        self.assertEqual(self.attach()["columns"], 40)
        self.assertEqual(len(self.processes), 1)

    def test_eof_publishes_final_sequence_then_closes_owned_process(self):
        attached = self.attach()
        process = self.processes[0]
        process.peer.sendall(b"fin")
        self.manager.activate(attached["attach_id"], "owner")
        self.assertEqual(self.next_event()["seq"], 0)
        process.peer.shutdown(socket.SHUT_WR)
        ending = self.next_event()
        self.assertEqual(ending, {"attach_id": attached["attach_id"], "surface_id": "surface", "seq": 1, "exit": True})
        self.assertTrue(process.closed.wait(2))
        self.assertEqual([], self.disconnections)
        self.assert_error("not_found", lambda: self.input(attached, b"x"))

    def test_emit_rejection_closes_client_instead_of_skipping_output(self):
        attached = self.attach()
        self.accept_events = False
        self.processes[0].peer.sendall(b"salida")
        self.manager.activate(attached["attach_id"], "owner")
        self.assertTrue(self.emit_attempted.wait(2))
        self.assertTrue(self.processes[0].closed.wait(2))
        self.assertEqual(["owner"], self.disconnections)
        self.assertTrue(self.events.empty())
        self.assert_error("not_found", lambda: self.input(attached, b"x"))

    def test_exited_process_drains_readiness_buffer_before_final_event(self):
        attached = self.attach()
        process = self.processes[0]
        raw = bytes(range(256)) * 273 + b"salida-final"
        # wait_ready can retain more than one read-sized chunk. The process may
        # exit after the attach ACK but before the stream starts consuming it.
        process.buffered_output.extend(raw)
        process.returncode = 0
        self.manager.activate(attached["attach_id"], "owner")
        self.assertTrue(process.closed.wait(2))
        events = []
        while not self.events.empty():
            events.append(self.next_event())
        output = b"".join(base64.b64decode(event["data"]) for event in events if "data" in event)
        self.assertEqual(output, raw)
        self.assertEqual([event["seq"] for event in events], list(range(len(events))))
        self.assertTrue(events[-1]["exit"])
        self.assertEqual([], self.disconnections)

    def test_idle_revocation_lock_and_identity_change_cancel_without_new_input(self):
        for change in ("revocation", "lock", "identity"):
            with self.subTest(change=change):
                self.approved["owner"], self.locked = True, False
                self.disconnections.clear()
                attached = self.attach(change)
                process = self.processes[-1]
                self.manager.activate(attached["attach_id"], "owner")
                self.assertTrue(process.reading.wait(2))
                if change == "revocation":
                    self.approved["owner"] = False
                elif change == "lock":
                    self.locked = True
                else:
                    self.identity += 1
                self.assertTrue(process.closed.wait(2))
                self.assertEqual(["owner"], self.disconnections)
                self.assertEqual(process.writes, [])
                self.assertTrue(self.events.empty())

    def test_disconnect_while_wait_ready_cancels_startup_and_never_activates_reader(self):
        self.process_options["blocked_ready"] = True
        result, created = queue.Queue(), threading.Event()
        original_factory = self.manager.process_factory
        def factory(*args):
            process = original_factory(*args)
            created.set()
            return process
        self.manager.process_factory = factory
        def connect():
            try:
                result.put(self.attach())
            except Exception as error:
                result.put(error)
        worker = threading.Thread(target=connect, daemon=True)
        worker.start()
        try:
            self.assertTrue(created.wait(2))
            process = self.processes[0]
            self.assertTrue(process.started.wait(2))
            self.manager.disconnected("owner")
            self.assertTrue(process.closed.wait(2))
            failure = result.get(timeout=2)
            self.assertIsInstance(failure, RPCError)
            self.assertIn(failure.code, ("attach_failed", "approval_required", "process_exited"))
            self.assertFalse(process.reading.is_set())
            self.assertTrue(self.events.empty())
        finally:
            self.manager.close()
            worker.join(timeout=2)
            self.assertFalse(worker.is_alive())

    def test_disconnect_only_cancels_that_connections_clients(self):
        own = self.attach()
        other = self.attach(connection="other")
        self.manager.disconnected("owner")
        self.assertTrue(self.processes[0].closed.wait(2))
        self.assertFalse(self.processes[1].closed.is_set())
        self.assert_error("not_found", lambda: self.input(own, b"x"))
        self.assertTrue(self.input(other, b"x", "other")["queued"])


if __name__ == "__main__":
    unittest.main()
