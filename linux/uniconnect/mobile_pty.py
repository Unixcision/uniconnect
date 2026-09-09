"""Connection-owned mobile PTY streams; desktop terminals are never input targets."""

import base64
from collections import deque
from dataclasses import dataclass, field
import select
import threading
import uuid

from .mobile_protocol import RPCError


@dataclass
class _Attachment:
    identifier: str
    connection: str
    target: dict
    columns: int
    rows: int
    authorized: object
    process: object = None
    seq: int = 0
    pending: deque = field(default_factory=deque)
    pending_bytes: int = 0
    lock: object = field(default_factory=threading.RLock)
    stopped: object = field(default_factory=threading.Event)
    ready: object = field(default_factory=threading.Event)
    reader_started: bool = False
    cleanup_started: bool = False
    failure: object = None
    geometry: object = None


class MobilePTYAttachments:
    """Own only spawned clients, bounded input queues and their connection IDs.

    Target lookup/authorization and event delivery are injected by the desktop
    composition. No credential, terminal content or attach handle is persisted.
    """

    MAX_INPUT = 65536
    MAX_PENDING = 256 * 1024
    MAX_PER_CONNECTION = 4
    TOPIC = "terminal.pty"

    def __init__(self, *, prepare, validate, has_topic, emit, process_factory, disconnect=lambda connection: None,
                 on_input=lambda surface_id, kind: None):
        self.prepare, self.validate = prepare, validate
        self.has_topic, self.emit = has_topic, emit
        # Teclado/tamaño del móvil ya validados (permiso, dueño, parámetros), fuera de todo cerrojo.
        self.on_input = on_input
        self.process_factory = process_factory
        self.disconnect = disconnect
        self.lock = threading.RLock()
        self.attachments = {}

    @staticmethod
    def dimensions(params):
        columns, rows = params.get("columns"), params.get("rows")
        if type(columns) is not int or type(rows) is not int or not 1 <= columns <= 1000 or not 1 <= rows <= 1000:
            raise RPCError("invalid_params", "El tamaño de la terminal no es válido")
        return columns, rows

    def dispatch(self, operation, params, connection, authorized):
        if not authorized():
            raise RPCError("approval_required", "El permiso de este dispositivo ha sido revocado")
        if operation == "terminal.attach":
            return self.attach(params, connection, authorized)
        attachment = self.lookup(params.get("attach_id"), connection)
        self.validate(attachment.target, authorized)
        if operation == "terminal.detach":
            self.cancel(attachment)
            return {"ok": True}
        if operation == "terminal.pty_resize":
            columns, rows = self.dimensions(params)
            with attachment.lock:
                self.require_live(attachment)
                attachment.process.resize(columns, rows)
                attachment.columns, attachment.rows = columns, rows
            self.on_input(attachment.target["surface_id"], "resize")
            return {"attach_id": attachment.identifier, "columns": columns, "rows": rows}
        if operation == "terminal.pty_input":
            encoded = params.get("data")
            if not isinstance(encoded, str) or len(encoded) > 4 * ((self.MAX_INPUT + 2) // 3):
                raise RPCError("invalid_params", "Los bytes de entrada no son válidos")
            try:
                data = base64.b64decode(encoded, validate=True)
            except (ValueError, TypeError):
                raise RPCError("invalid_params", "Los bytes de entrada no son válidos") from None
            if not data or len(data) > self.MAX_INPUT:
                raise RPCError("invalid_params", "Los bytes de entrada no son válidos")
            with attachment.lock:
                self.require_live(attachment)
                if attachment.pending_bytes + len(data) > self.MAX_PENDING or len(attachment.pending) >= 128:
                    raise RPCError("busy", "La terminal todavía está procesando la entrada anterior")
                attachment.pending.append(data)
                attachment.pending_bytes += len(data)
            self.on_input(attachment.target["surface_id"], "input")
            return {"attach_id": attachment.identifier, "queued": True}
        raise RPCError("method_not_found", "Esta operación no está disponible")

    def attach(self, params, connection, authorized):
        columns, rows = self.dimensions(params)
        client_id = params.get("client_id")
        if not isinstance(client_id, str) or not client_id or len(client_id) > 128:
            raise RPCError("invalid_params", "El identificador del cliente no es válido")
        if not self.has_topic(connection, self.TOPIC):
            raise RPCError("subscription_required", "Suscríbete a la salida de la terminal antes de conectar")
        launch, target = self.prepare(params, authorized)
        # Never hold this registry lock across GTK, credentials or host locks.
        with self.lock:
            owned = [value for value in self.attachments.values() if value.connection == connection]
            attachment = next((value for value in owned if value.target["surface_id"] == target["surface_id"]), None)
            if attachment is None:
                if len(owned) >= self.MAX_PER_CONNECTION:
                    raise RPCError("too_many_attachments", "Hay demasiadas terminales móviles abiertas")
                attachment = _Attachment(str(uuid.uuid4()), connection, target, columns, rows, authorized)
                self.attachments[attachment.identifier] = attachment
                created = True
            else:
                created = False
        if not created:
            if not attachment.ready.wait(6):
                raise RPCError("busy", "La terminal todavía está conectando")
            self.validate(attachment.target, authorized)
            with attachment.lock:
                self.require_live(attachment)
            return self.reply(attachment)
        try:
            if attachment.stopped.is_set():
                raise RPCError("approval_required", "La conexión móvil se ha cerrado")
            process = self.process_factory(launch, columns, rows)
            with attachment.lock:
                attachment.process = process
            process.wait_ready(timeout=5, cancelled=lambda: attachment.stopped.is_set() or not authorized())
            self.validate(target, authorized)
            with attachment.lock:
                self.require_live(attachment)
            return self.reply(attachment)
        except Exception as error:
            attachment.failure = error
            self.cancel(attachment)
            if isinstance(error, RPCError):
                raise
            raise RPCError("attach_failed", "No se pudo adjuntar a la sesión tmux existente") from None
        finally:
            attachment.ready.set()

    @staticmethod
    def reply(attachment):
        return {"workspace_id": attachment.target["workspace_id"], "surface_id": attachment.target["surface_id"],
                "attach_id": attachment.identifier, "columns": attachment.columns, "rows": attachment.rows,
                **(getattr(attachment.process, "source_geometry", None) or {})}

    @staticmethod
    def require_live(attachment):
        if attachment.stopped.is_set() or attachment.failure or attachment.process is None or attachment.process.poll() is not None:
            raise RPCError("process_exited", "El cliente de la terminal se ha desconectado")

    def lookup(self, identifier, connection):
        if not isinstance(identifier, str) or not identifier or len(identifier) > 128:
            raise RPCError("invalid_params", "El identificador de la terminal no es válido")
        with self.lock:
            value = self.attachments.get(identifier)
            if value is None or value.connection != connection:
                raise RPCError("not_found", "No se encontró la terminal de esta conexión")
            return value

    def activate(self, identifier, connection):
        """Called only after the attach ACK was accepted into the same FIFO."""
        try:
            attachment = self.lookup(identifier, connection)
        except RPCError:
            return
        with attachment.lock:
            if attachment.reader_started or attachment.stopped.is_set() or attachment.failure:
                return
            attachment.reader_started = True
        threading.Thread(target=self.read_loop, args=(attachment,), name="uc-mobile-pty", daemon=True).start()

    def permitted(self, attachment):
        if attachment.stopped.is_set() or not attachment.authorized():
            return False
        try:
            self.validate(attachment.target, attachment.authorized)
            return not attachment.stopped.is_set()
        except Exception:
            return False

    def send_event(self, attachment, **payload):
        if not self.permitted(attachment):
            return False
        message = {"attach_id": attachment.identifier, "surface_id": attachment.target["surface_id"],
                   "seq": attachment.seq, **payload}
        if not self.emit(attachment.connection, self.TOPIC, message):
            return False
        attachment.seq += 1
        return True

    def read_loop(self, attachment):
        exited = False
        try:
            while self.permitted(attachment):
                process = attachment.process
                # Drain startup bytes retained by wait_ready before waiting for
                # fd readability. Otherwise an idle freshly attached shell can
                # leave its initial screen buffered forever.
                try:
                    data = process.read(self.MAX_INPUT)
                except BlockingIOError:
                    data = None
                if data == b"":
                    exited = True
                    break
                geometry = getattr(process, "source_geometry", None)
                payload = {}
                if geometry and geometry != attachment.geometry:
                    payload.update(geometry)
                if data:
                    payload["data"] = base64.b64encode(data).decode("ascii")
                if payload:
                    if not self.send_event(attachment, **payload):
                        break
                    attachment.geometry = dict(geometry) if geometry else None
                with attachment.lock:
                    pending = bool(attachment.pending)
                _, writable, _ = select.select([process.fileno()], [process.fileno()] if pending else [], [], 0.1)
                if writable and self.permitted(attachment):
                    with attachment.lock:
                        if not attachment.stopped.is_set() and attachment.pending:
                            chunk = attachment.pending[0]
                            written = process.write(chunk)
                            if written:
                                attachment.pending_bytes -= written
                                if written == len(chunk):
                                    attachment.pending.popleft()
                                else:
                                    attachment.pending[0] = chunk[written:]
                # Child exit is not stream EOF: wait_ready may still retain
                # multiple output chunks, even when the fd is no longer ready.
                # Only read() returning b"" proves every retained byte drained.
        except (OSError, ValueError):
            exited = True
        finally:
            if exited:
                if not self.send_event(attachment, exit=True) and not attachment.stopped.is_set():
                    self.disconnect(attachment.connection)
            elif not attachment.stopped.is_set():
                # Invalidated identity/approval or a broken stream must also
                # wake the mobile consumer and discard queued private frames.
                self.disconnect(attachment.connection)
            self.cancel(attachment)

    def cancel(self, attachment):
        attachment.stopped.set()
        with self.lock:
            if self.attachments.get(attachment.identifier) is attachment:
                del self.attachments[attachment.identifier]
        # Closing may wait for a child to exit. Never block the host's lock or
        # GTK callback; the private process adapter serializes repeated closes.
        with attachment.lock:
            process = attachment.process
            attachment.pending.clear()
            attachment.pending_bytes = 0
            if attachment.cleanup_started:
                return
            if process is not None:
                attachment.cleanup_started = True
        if process is not None:
            threading.Thread(target=process.close, name="uc-mobile-pty-close", daemon=True).start()

    def disconnected(self, connection):
        with self.lock:
            owned = [value for value in self.attachments.values() if value.connection == connection]
        for attachment in owned:
            self.cancel(attachment)

    def close(self):
        with self.lock:
            values = list(self.attachments.values())
        for attachment in values:
            self.cancel(attachment)
