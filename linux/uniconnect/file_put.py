"""Recepción de archivos del móvil (contrato file_put.v1) y su salto SSH.

El móvil entrega un archivo por trozos por la conexión privada; el host lo
guarda en `~/UniConnect/Entrada/<AAAAMMDD>/` sin sobrescribir nunca y, si la
caja es SSH, lo copia al servidor con la misma credencial que usa esa caja.
Ni el contenido ni los nombres se registran en ningún log.
"""

from __future__ import annotations

import datetime
import errno
import hashlib
import os
import posixpath
import re
import shutil
import threading
import time
import unicodedata
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterator

from .mobile_protocol import RPCError
from .transfers import SFTPTransfer
from .transport import SSHCommand, Transport, TransportError

CHUNK_BYTES = 1024 * 1024
MAX_SIZE = 200 * 1024 * 1024
MAX_NAME_CHARS = 120
MAX_NAME_BYTES = 200
EXPIRY_SECONDS = 600
SWEEP_SECONDS = 60
REMOTE_BUDGET_SECONDS = 100
MAX_SUFFIX = 1000

_EXTENSION = re.compile(r"\.([A-Za-z0-9]{1,15})$")
_SAFE_PUNCTUATION = frozenset(" ._-+,@=")


def sanitize_name(name) -> str:
    """Devuelve un nombre de archivo seguro: sin rutas, sin caracteres de control ni
    raros para el shell, acotado en longitud, con la extensión conservada y nunca vacío."""
    if not isinstance(name, str):
        raise RPCError("invalid_params", "Nombre de archivo no válido")
    name = unicodedata.normalize("NFC", name)
    for separator in ("/", "\\"):
        name = name.rsplit(separator, 1)[-1]
    cleaned = []
    for character in name:
        category = unicodedata.category(character)
        if category[0] == "C":
            continue  # Control, formato, sustitutos, uso privado y no asignados.
        if category[0] in "LNM" or character in _SAFE_PUNCTUATION:
            cleaned.append(character)
        else:
            cleaned.append("_")
    name = "".join(cleaned).strip(" .")
    match = _EXTENSION.search(name)
    extension = "." + match.group(1) if match else ""
    stem = name[:len(name) - len(extension)].rstrip(" .")
    stem = stem[:max(1, MAX_NAME_CHARS - len(extension))]
    while len((stem + extension).encode("utf-8")) > MAX_NAME_BYTES and stem:
        stem = stem[:-1]
    stem = stem.rstrip(" .") or "archivo"
    return stem + extension


def numbered_names(name: str) -> Iterator[str]:
    """`foto.jpg`, `foto-2.jpg`, `foto-3.jpg`… con la extensión conservada."""
    match = _EXTENSION.search(name)
    extension = "." + match.group(1) if match else ""
    stem = name[:len(name) - len(extension)]
    yield name
    for number in range(2, MAX_SUFFIX + 1):
        yield f"{stem}-{number}{extension}"


@dataclass
class _Transfer:
    identifier: str
    owner: str
    box: dict
    base: str
    name: str
    directory: Path
    part_path: Path
    size: int
    descriptor: int
    last_activity: float
    received: int = 0
    next_index: int = 0
    hasher: object = field(default_factory=hashlib.sha256)
    closed: bool = False


class FilePutStore:
    """Transferencias en curso: reserva de nombres, trozos, caducidad y verificación.

    No depende de GTK; `root`, `clock`, `today` y el temporizador se inyectan para
    poder probarla en un directorio temporal. Cada transferencia pertenece a un
    `owner` (el dispositivo móvil que la empezó) y guarda la `box` (identidad de la
    caja) que el que enruta comprueba antes de cada operación. Mientras haya
    transferencias vivas, un barrido cada `sweep_interval` segundos (hilo propio,
    nunca GTK) borra los .part caducados aunque el móvil ya no envíe nada; `close()`
    cancela el barrido y borra los .part vivos.
    """

    def __init__(self, root: str | Path, *, clock: Callable[[], float] = time.monotonic,
                 today: Callable[[], datetime.date] = datetime.date.today,
                 chunk_bytes: int = CHUNK_BYTES, max_size: int = MAX_SIZE, expiry: float = EXPIRY_SECONDS,
                 sweep_interval: float = SWEEP_SECONDS, timer: Callable | None = None,
                 max_transfers: int = 16, max_per_owner: int = 4, disk_usage=shutil.disk_usage):
        self.root = Path(root)
        self.clock, self.today = clock, today
        self.chunk_bytes, self.max_size, self.expiry = chunk_bytes, max_size, expiry
        self.sweep_interval = sweep_interval
        self.timer_factory = timer if timer is not None else self.daemon_timer
        self.max_transfers, self.max_per_owner = max_transfers, max_per_owner
        self.disk_usage = disk_usage
        # Un solo cerrojo reentrante: las escrituras de un trozo son cortas (≤ 1 MiB a
        # caché de páginas) y la copia larga al servidor ocurre fuera de él.
        self.lock = threading.RLock()
        self.transfers: dict[str, _Transfer] = {}
        self.timer = None
        self.closed = False

    @staticmethod
    def daemon_timer(interval: float, callback: Callable[[], None]):
        """Temporizador real: hilo daemon con `cancel()`, para no retener el cierre del proceso."""
        timer = threading.Timer(interval, callback)
        timer.daemon = True
        timer.start()
        return timer

    def _schedule_locked(self) -> None:
        if self.closed or self.timer is not None or not self.transfers:
            return
        self.timer = self.timer_factory(self.sweep_interval, self._sweep)

    def _sweep(self) -> None:
        with self.lock:
            self.timer = None
            if self.closed:
                return
            self._expire_locked()
            self._schedule_locked()

    def close(self) -> None:
        """Cierre definitivo: cancela el barrido y borra los .part de las transferencias vivas."""
        with self.lock:
            self.closed = True
            timer, self.timer = self.timer, None
            for transfer in list(self.transfers.values()):
                self._discard(transfer)
        if timer is not None:
            timer.cancel()

    # ----- ciclo de vida -----

    def begin(self, owner: str, box: dict, name, size) -> dict:
        """Reserva el nombre definitivo escribiendo `<nombre>.part` y devuelve el ticket."""
        if not isinstance(owner, str) or not owner:
            raise RPCError("invalid_params", "Sesión móvil no válida")
        if type(size) is not int or size < 0:
            raise RPCError("invalid_params", "Tamaño de archivo no válido")
        if size > self.max_size:
            raise RPCError("too_large", f"El archivo supera el máximo de {self.max_size // (1024 * 1024)} MiB")
        clean = sanitize_name(name)
        directory = self.root / self.today().strftime("%Y%m%d")
        with self.lock:
            if self.closed:
                raise RPCError("busy", "El acceso móvil se está cerrando")
            self._expire_locked()
            if len(self.transfers) >= self.max_transfers or \
                    sum(item.owner == owner for item in self.transfers.values()) >= self.max_per_owner:
                raise RPCError("busy", "Demasiadas transferencias en curso; espera a que terminen")
            try:
                directory.mkdir(parents=True, exist_ok=True, mode=0o700)
                free = self.disk_usage(directory).free
            except OSError as error:
                raise RPCError("io_failed", "No se pudo preparar la carpeta de entrada del equipo") from error
            if free < size + 64 * 1024 * 1024:
                raise RPCError("io_failed", "No hay espacio suficiente en el equipo")
            final_name, descriptor = self._reserve_locked(directory, clean)
            transfer = _Transfer(identifier=uuid.uuid4().hex, owner=owner, box=dict(box), base=clean, name=final_name,
                                 directory=directory, part_path=directory / (final_name + ".part"),
                                 size=size, descriptor=descriptor, last_activity=self.clock())
            self.transfers[transfer.identifier] = transfer
            self._schedule_locked()
        return {"transfer_id": transfer.identifier, "chunk_bytes": self.chunk_bytes}

    def _reserve_locked(self, directory: Path, name: str) -> tuple[str, int]:
        reserved = {item.name for item in self.transfers.values() if item.directory == directory}
        for candidate in numbered_names(name):
            if candidate in reserved or (directory / candidate).exists():
                continue
            try:
                # O_EXCL: dos procesos (o dos subidas concurrentes) nunca comparten un .part.
                descriptor = os.open(directory / (candidate + ".part"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                continue
            except OSError as error:
                raise RPCError("io_failed", "No se pudo crear el archivo en el equipo") from error
            return candidate, descriptor
        raise RPCError("io_failed", "Hay demasiados archivos con ese nombre hoy")

    def lookup(self, owner: str, transfer_id) -> dict:
        """Devuelve la caja capturada en begin o `not_found` si no es de esta sesión."""
        with self.lock:
            self._expire_locked()
            return dict(self._get_locked(owner, transfer_id).box)

    def _get_locked(self, owner: str, transfer_id) -> _Transfer:
        transfer = self.transfers.get(transfer_id) if isinstance(transfer_id, str) else None
        if transfer is None or transfer.owner != owner:
            raise RPCError("not_found", "No se encontró la transferencia")
        return transfer

    def chunk(self, owner: str, transfer_id, index, data: bytes) -> dict:
        if type(index) is not int or index < 0:
            raise RPCError("invalid_params", "Índice de trozo no válido")
        if not isinstance(data, (bytes, bytearray)) or not data:
            raise RPCError("invalid_params", "Trozo vacío")
        if len(data) > self.chunk_bytes:
            raise RPCError("invalid_params", "El trozo supera el tamaño acordado")
        with self.lock:
            self._expire_locked()
            transfer = self._get_locked(owner, transfer_id)
            if index != transfer.next_index:
                raise RPCError("invalid_params", f"Se esperaba el trozo {transfer.next_index}, no el {index}")
            if transfer.received + len(data) > transfer.size:
                self._discard(transfer)  # Mismo criterio que el host Mac: se descarta entera.
                raise RPCError("too_large", "Los trozos superan el tamaño anunciado")
            try:
                view = memoryview(data)
                while view:
                    written = os.write(transfer.descriptor, view)
                    view = view[written:]
            except OSError as error:
                self._discard(transfer)
                raise RPCError("io_failed", "No se pudo guardar el archivo en el equipo") from error
            transfer.hasher.update(data)
            transfer.received += len(data)
            transfer.next_index += 1
            transfer.last_activity = self.clock()
            return {"received_bytes": transfer.received}

    def commit(self, owner: str, transfer_id, sha256, *, remote_copy: Callable[[Path, str], str] | None = None) -> dict:
        """Verifica el SHA-256, publica el archivo sin sobrescribir y, si procede, lo copia al servidor.

        `remote_copy(host_path, name)` se ejecuta fuera de cualquier cerrojo y devuelve la
        ruta remota; si falla, la respuesta conserva la ruta del host con `remote_error`.
        """
        if not isinstance(sha256, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", sha256):
            raise RPCError("invalid_params", "SHA-256 no válido")
        with self.lock:
            self._expire_locked()
            transfer = self._get_locked(owner, transfer_id)
            if transfer.received != transfer.size:
                raise RPCError("invalid_params",
                               f"Faltan trozos: recibidos {transfer.received} de {transfer.size} bytes")
            if transfer.hasher.hexdigest() != sha256.lower():
                self._discard(transfer)
                raise RPCError("io_failed", "La verificación SHA-256 no coincide; el archivo se ha descartado")
            try:
                os.fsync(transfer.descriptor)
                os.close(transfer.descriptor)
                transfer.descriptor = -1
                final_path = self._publish(transfer)
            except OSError as error:
                self._discard(transfer)
                raise RPCError("io_failed", "No se pudo guardar el archivo en el equipo") from error
            transfer.closed = True
            self.transfers.pop(transfer.identifier, None)
        result = {"path": str(final_path), "location": "host"}
        if remote_copy is not None:
            try:
                result["remote_path"] = remote_copy(final_path, transfer.name)
                result["location"] = "remote"
            except Exception as error:
                result["remote_error"] = RemoteInbox.describe(error)
        return result

    def _publish(self, transfer: _Transfer) -> Path:
        """Enlaza el .part con el primer nombre libre y borra el .part; nunca sobrescribe."""
        reserved = {item.name for item in self.transfers.values()
                    if item.directory == transfer.directory and item is not transfer}
        for candidate in numbered_names(transfer.base):
            if candidate in reserved:
                continue
            final_path = transfer.directory / candidate
            try:
                os.link(transfer.part_path, final_path)
            except FileExistsError:
                continue
            transfer.name = candidate
            os.unlink(transfer.part_path)
            return final_path
        raise OSError(errno.EEXIST, "sin nombre libre")

    def abort(self, owner: str, transfer_id) -> dict:
        with self.lock:
            self._expire_locked()
            self._discard(self._get_locked(owner, transfer_id))
        return {}

    def discard(self, owner: str, transfer_id) -> None:
        """Descarta en silencio (la caja cambió); no falla si ya no existe."""
        with self.lock:
            transfer = self.transfers.get(transfer_id)
            if transfer is not None and transfer.owner == owner:
                self._discard(transfer)

    def disconnected(self, owner: str) -> None:
        """La sesión móvil se ha ido: sus transferencias no pueden continuar."""
        with self.lock:
            for transfer in [item for item in self.transfers.values() if item.owner == owner]:
                self._discard(transfer)

    def expire(self) -> int:
        """Descarta las transferencias sin trozos durante `expiry` segundos."""
        with self.lock:
            return self._expire_locked()

    def _expire_locked(self) -> int:
        now = self.clock()
        expired = [item for item in self.transfers.values() if now - item.last_activity >= self.expiry]
        for transfer in expired:
            self._discard(transfer)
        return len(expired)

    def _discard(self, transfer: _Transfer) -> None:
        self.transfers.pop(transfer.identifier, None)
        if transfer.closed:
            return
        transfer.closed = True
        if transfer.descriptor >= 0:
            try:
                os.close(transfer.descriptor)
            except OSError:
                pass
            transfer.descriptor = -1
        try:
            os.unlink(transfer.part_path)
        except OSError:
            pass


class RemoteInbox:
    """Copia un archivo ya guardado en el host a `~/uniconnect-entrada/` del servidor de la caja.

    Usa la misma conexión validada que la caja (sin credenciales en argv) y el
    cliente SFTP existente: nombre temporal oculto y renombrado sin sobrescribir.
    Preparar la carpeta, transferir y cerrar comparten un único presupuesto
    monotónico (`budget`, 100 s): el móvil abandona el commit a los 120 s y el
    host debe responder antes, con `location: "host"` si el plazo se agotó.
    """

    DIRECTORY = "uniconnect-entrada"
    CLOSE_MARGIN = 8.0  # Limpieza del temporal (3 s) y cierre del proceso sftp (≤ 4 s).

    def __init__(self, *, transport_factory=Transport, transfer_factory=SFTPTransfer,
                 budget: float = REMOTE_BUDGET_SECONDS, clock: Callable[[], float] = time.monotonic):
        self.transport_factory, self.transfer_factory = transport_factory, transfer_factory
        self.budget, self.clock = budget, clock

    def copy(self, command: SSHCommand, local_path: Path, name: str) -> str:
        deadline = self.clock() + self.budget
        script = ('umask 077; mkdir -p -- "$HOME/uniconnect-entrada" || exit 74; '
                  'printf \'UC_DIR\\t%s\\n\' "$HOME/uniconnect-entrada"')
        output = self.transport_factory(command).run(script, timeout=max(1.0, deadline - self.clock())).stdout
        directory = next((line.split("\t", 1)[1] for line in output.splitlines() if line.startswith("UC_DIR\t")), "")
        if not directory.startswith("/"):
            raise TransportError("remote_command_failed", "no se pudo resolver la carpeta de entrada")
        remaining = deadline - self.clock() - self.CLOSE_MARGIN
        if remaining <= 0:
            raise TransportError("upload_timeout")
        transfer = self.transfer_factory(command, timeout=remaining)
        return transfer.put(local_path, posixpath.normpath(directory), name)

    _MESSAGES = {
        "connection_timeout": "El servidor no respondió a tiempo",
        "upload_timeout": "La copia al servidor tardó demasiado y se canceló",
        "sftp_connection_closed": "La conexión con el servidor se cerró durante la copia",
        "unsupported_sftp_version": "El servidor no ofrece SFTP compatible",
        "sshpass_missing": "Falta sshpass en el equipo para la contraseña guardada",
        "process_unavailable": "No se pudo iniciar ssh en el equipo",
        "upload_name_conflict": "Hay demasiados archivos con ese nombre en el servidor",
        "remote_command_failed": "El servidor rechazó la orden",
        "sftp_operation_failed": "El servidor rechazó la escritura",
    }

    @classmethod
    def describe(cls, error: BaseException) -> str:
        """Texto legible en español, acotado, sin rutas locales ni contenido."""
        if isinstance(error, TransportError):
            text = cls._MESSAGES.get(error.code, "No se pudo copiar al servidor (" + error.code + ")")
            detail = " ".join(error.detail.split())
            if detail and error.code in ("remote_command_failed", "sftp_operation_failed"):
                text += ": " + detail
        else:
            text = "No se pudo copiar al servidor: " + (" ".join(str(error).split()) or error.__class__.__name__)
        return text[:500]
