"""Bounded TCP adapter for the desktop's existing mobile RPC domain."""

import json
import select
import shutil
import socket
import subprocess
import threading
import time
import uuid
from collections import deque

from .mobile_access import tailnet_address
from .mobile_protocol import FrameDecoder, RPCError, encode_frame


def verified_tailscale_address(*, run=subprocess.run):
    """Require both running tailscaled identity and the kernel tunnel address."""
    executable = shutil.which("tailscale")
    if not executable:
        raise RuntimeError("Tailscale no está instalado")
    status = json.loads(run([executable, "status", "--json"], capture_output=True, text=True,
                            check=True, timeout=3).stdout)
    addresses = json.loads(run(["ip", "-j", "address", "show", "dev", "tailscale0"],
                               capture_output=True, text=True, check=True, timeout=3).stdout)
    kernel = {entry["local"] for interface in addresses for entry in interface.get("addr_info", [])}
    if status.get("BackendState") == "Running":
        for value in status.get("Self", {}).get("TailscaleIPs", []):
            address = tailnet_address(value)
            if address and ":" not in address and address in kernel:
                return address
    raise RuntimeError("No se ha podido verificar la dirección de Tailscale")


class MobileHost:
    def __init__(self, access, rpc, *, port=58465, resolve=verified_tailscale_address, translate=lambda value: value):
        self.access, self.rpc, self.port, self.resolve = access, rpc, port, resolve
        self.translate = translate
        self.lock = threading.RLock()
        self.clients = set()
        self.listener = None
        self.address = None
        self.generation = 0
        self.error = None
        self.on_change = lambda: None
        access.on_revoke = self.revoke

    def start(self):
        self.stop()
        with self.lock:
            generation = self.generation
        threading.Thread(target=self._listen, args=(generation,), name="uc-mobile-listener", daemon=True).start()

    def _listen(self, generation):
        listener = None
        try:
            address = self.resolve()
            if not tailnet_address(address) or ":" in address:
                raise RuntimeError("Dirección de Tailscale no válida")
            listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind((address, self.port))
            listener.listen(8)
            listener.settimeout(0.5)
            with self.lock:
                if generation != self.generation:
                    return
                self.listener, self.address, self.error = listener, address, None
            self.on_change()
            next_verify = time.monotonic() + 15
            while generation == self.generation:
                if time.monotonic() >= next_verify:
                    if self.resolve() != address:
                        raise RuntimeError("La dirección de Tailscale ha cambiado; vuelve a activar el acceso")
                    next_verify = time.monotonic() + 15
                try:
                    connection, remote = listener.accept()
                except socket.timeout:
                    continue
                peer = tailnet_address(remote[0])
                with self.lock:
                    if not peer or len(self.clients) >= 8 or generation != self.generation:
                        connection.close()
                        continue
                    client = _Client(self, connection, peer)
                    self.clients.add(client)
                threading.Thread(target=client.run, name="uc-mobile-peer", daemon=True).start()
        except Exception:
            clients = []
            with self.lock:
                if generation == self.generation:
                    self.error = "No se pudo abrir el acceso móvil. Comprueba Tailscale y el puerto 58465."
                    self.listener, self.address = None, None
                    clients = list(self.clients)
            for client in clients:
                client.close()
            self.on_change()
        finally:
            if listener:
                listener.close()

    def stop(self):
        with self.lock:
            self.generation += 1
            if self.listener:
                self.listener.close()
            self.listener, self.address = None, None
            clients = list(self.clients)
        for client in clients:
            client.close()

    def revoke(self, address):
        with self.lock:
            clients = [client for client in self.clients if client.peer == address]
        for client in clients:
            client.close()

    def disconnect_clients(self):
        """Discard queued output and disconnect peers, preserving listener/approvals."""
        with self.lock:
            clients = list(self.clients)
        for client in clients:
            client.close()  # Cleanup callbacks must run outside the host lock.

    def disconnect_client(self, connection_id):
        """Close only the live connection owner; never revoke its peer's approval."""
        client = self._client(connection_id)
        if client is not None:
            client.close()

    def emit(self, topic, payload=None):
        if topic == "terminal.pty":
            return  # Raw terminal output is never a broadcast topic.
        event = {"kind": "event", "topic": topic, "payload": payload or {}}
        with self.lock:
            clients = list(self.clients)
        for client in clients:
            if topic in client.topics and self.access.authorize(client.peer):
                client.enqueue(event, coalesce=topic in ("terminal.updated", "workspace.updated"))

    def _client(self, connection_id):
        with self.lock:
            return next((client for client in self.clients if client.identifier == connection_id), None)

    def has_topic(self, connection_id, topic):
        """Check a live owner's subscription without requesting new approval."""
        client = self._client(connection_id)
        if client is None:
            return False
        # Approval revocation takes this same lock before closing the client.
        with self.access.lock:
            if not self.access.is_approved(client.peer):
                return False
            with client.lock:
                return not client.closed and topic in client.topics

    def emit_private(self, connection_id, topic, payload):
        """Queue an event only for its approved, subscribed connection owner."""
        client = self._client(connection_id)
        if client is None:
            return False
        return client.enqueue({"kind": "event", "topic": topic, "payload": payload},
                              required_topic=topic)


class _Client:
    def __init__(self, host, connection, peer):
        self.host, self.socket, self.peer = host, connection, peer
        self.socket.settimeout(0.2)
        self.decoder = FrameDecoder()
        self.streams, self.topics = {}, set()
        self.queue, self.queue_bytes = deque(), 0
        self.lock = threading.RLock()
        self.closed = False
        self.identifier = str(uuid.uuid4())

    def enqueue(self, message, *, coalesce=False, required_topic=None):
        try:
            data = encode_frame(message)
        except (TypeError, ValueError, OverflowError):
            self.close()
            return False
        key = message.get("topic") if coalesce else None
        if required_topic is None:
            accepted = self._enqueue_frame(data, key)
        else:
            with self.host.access.lock:
                if not self.host.access.is_approved(self.peer):
                    return False
                accepted = self._enqueue_frame(data, key, required_topic)
        if accepted is None:
            self._finish_close()
        return accepted is True

    def _enqueue_frame(self, data, key, required_topic=None):
        with self.lock:
            if self.closed or required_topic is not None and required_topic not in self.topics:
                return False
            if key:
                retained = deque((old_key, old_data) for old_key, old_data in self.queue if old_key != key)
                self.queue, self.queue_bytes = retained, sum(len(item[1]) for item in retained)
            if self.queue_bytes + len(data) > 2 * 1024 * 1024 or len(self.queue) >= 128:
                self._close_locked()  # Claim cleanup before another producer can enqueue.
                return None
            self.queue.append((key, data))
            self.queue_bytes += len(data)
            return True

    def close(self):
        with self.lock:
            changed = self._close_locked()
        if changed:
            self._finish_close()

    def _close_locked(self):
        if self.closed:
            return False
        self.closed = True
        self.queue.clear()
        self.queue_bytes = 0
        self.streams.clear()
        self.topics.clear()
        try:
            self.socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.socket.close()
        return True

    def _finish_close(self):
        # Neither host nor client locks may cover domain cleanup callbacks.
        with self.host.lock:
            self.host.clients.discard(self)
        callback = getattr(self.host.rpc, "disconnected", None)
        if callable(callback):
            try:
                callback(self.identifier)
            except Exception:
                pass  # A failed cleanup must not leave other clients connected.

    def run(self):
        activity, first = time.monotonic(), True
        try:
            while not self.closed:
                with self.lock:
                    outbound = self.queue.popleft() if self.queue else None
                    if outbound:
                        self.queue_bytes -= len(outbound[1])
                if outbound:
                    self.socket.sendall(outbound[1])
                readable, _, _ = select.select([self.socket], [], [], 0.05)
                if readable:
                    data = self.socket.recv(65536)
                    if not data:
                        break
                    activity = time.monotonic()
                    requests = self.decoder.feed(data)
                    if len(requests) > 64:
                        raise ValueError("Demasiadas peticiones en una lectura")
                    for request in requests:
                        if self.closed:
                            break
                        first = False
                        self.handle(request)
                if time.monotonic() - activity > (15 if first else 30) and not self.streams:
                    break
        except (OSError, ValueError, TypeError):
            pass
        finally:
            self.close()

    def handle(self, request):
        if self.closed:
            return
        identifier = request.get("id")
        try:
            method, params = request.get("method"), request.get("params", {})
            if not isinstance(identifier, str) or len(identifier) > 128 or not isinstance(method, str) or not isinstance(params, dict):
                raise RPCError("invalid_params", "Petición no válida")
            if not self.host.access.authorize(self.peer, params.get("device_name", "")):
                raise RPCError("approval_required", "Autoriza este dispositivo en UniConnect en el equipo al que quieres acceder.")
            if method == "mobile.events.subscribe":
                stream, topics = params.get("stream_id"), params.get("topics")
                allowed = {"workspace.updated", "terminal.updated", "terminal.pty", "notification.created"}
                if not isinstance(stream, str) or len(stream) > 128 or not isinstance(topics, list) or len(topics) > 16:
                    raise RPCError("invalid_params", "Suscripción no válida")
                if not all(isinstance(topic, str) for topic in topics):
                    raise RPCError("invalid_params", "Suscripción no válida")
                with self.lock:
                    if self.closed:
                        return
                    if len(self.streams) >= 8 and stream not in self.streams:
                        raise RPCError("invalid_params", "Suscripción no válida")
                    self.streams[stream] = set(topics) & allowed
                    self.topics = set().union(*self.streams.values())
                    result = {"stream_id": stream, "topics": sorted(self.streams[stream])}
            elif method == "mobile.events.unsubscribe":
                stream = params.get("stream_id")
                if not isinstance(stream, str):
                    raise RPCError("invalid_params", "Suscripción no válida")
                with self.lock:
                    removed = self.streams.pop(stream, None) is not None
                    self.topics = set().union(*self.streams.values()) if self.streams else set()
                result = {"stream_id": stream, "removed": removed}
            else:
                result = self.host.rpc.dispatch(
                    method, params, self.identifier,
                    authorized=lambda: not self.closed and self.host.access.is_approved(self.peer))
            if self.enqueue({"id": identifier, "ok": True, "result": result}):
                callback = getattr(self.host.rpc, "response_enqueued", None)
                if callable(callback):
                    try:
                        callback(method, result, self.identifier)
                    except Exception:
                        self.close()  # The ACK already exists; never send a second response.
        except RPCError as error:
            self.enqueue(error.response(identifier, self.host.translate))
        except Exception:
            self.enqueue(RPCError("internal_error", "No se pudo completar la operación remota").response(identifier, self.host.translate))
