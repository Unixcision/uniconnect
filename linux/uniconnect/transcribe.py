"""Transcripción de voz del móvil en el equipo (contrato transcribe.v1).

El móvil graba un audio corto y lo entrega por la conexión privada; el equipo lo
transcribe con whisper.cpp local (sin servicio externo, sin red) y devuelve solo
el texto. El audio vive en un temporal 0600 dentro de un directorio 0700 propio
de la llamada, bajo `~/.cache/uniconnect/transcribe/`, y se borra siempre —éxito,
error, plazo agotado o cancelación—; el borrado se comprueba, y lo que quede en
disco (por una caída o por un fallo de borrado) lo barre el arranque siguiente.
Ni el audio ni el texto se registran en ningún log. Si el equipo no tiene motor o
modelo se responde `unsupported` y el móvil cae a su dictado local.
"""

from __future__ import annotations

import fcntl
import os
import re
import shutil
import signal
import struct
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .mobile_protocol import RPCError

# 3 MiB binarios son 4 MiB en base64: el marco del protocolo admite 8 MiB, así que
# queda sitio de sobra para el JSON que envuelve al audio. Con 6 MiB la petición
# reventaría en el decodificador antes de que nadie pudiera responder `too_large`.
MAX_AUDIO_BYTES = 3 * 1024 * 1024
MAX_AUDIO_SECONDS = 300
CONVERSION_MARGIN = 5.0  # Lo que se deja convertir de más para poder ver que el audio se pasa.
# El presupuesto se cuenta desde que la petición entra en el RPC, no desde que llega
# al motor: decodificar el base64 y saltar al hilo del modelo también gasta. El móvil
# arranca sus 90 s antes incluso, al enviar, así que el equipo se queda en 75.
BUDGET_SECONDS = 75.0
CLEANUP_MARGIN = 5.0  # Reservado dentro del presupuesto para matar al hijo y limpiar.
TURN_SECONDS = 5.0
MAX_JOBS = 2
MAX_JOBS_PER_OWNER = 1
GRACE_SECONDS = 30.0
# El cerrojo es HERMANO del directorio de trabajo, no vive dentro: se crea y se toma
# antes de que el directorio exista, así que nadie llega a ver un trabajo sin dueño.
LOCK_PREFIX = ".uc-trabajo-"
MAX_THREADS = 8
WAV_PREFIX_BYTES = 65536
WAV_BYTES_PER_SECOND = 16000 * 2  # PCM 16 bits mono a 16 kHz, que es lo que whisper.cpp lee.

_LANGUAGE = re.compile(r"[a-z]{2}")
# Lo que este módulo crea y por tanto puede barrer: `<pid>-<azar>`. Lo que no encaje
# aquí no es nuestro y se conserva, aunque lleve meses en la carpeta.
_OURS = re.compile(r"\d+-.+")
_TIMESTAMP = re.compile(r"^\[[0-9:.,\s\->]+\]\s*")
_BRACKETS = re.compile(r"^\[(.*)\]$")
_TOKEN = re.compile(r"_[a-z]{2,4}_[0-9]*")
# Lo que whisper.cpp escribe cuando no hay voz. Cualquier otra cosa entre corchetes
# es dictado del usuario y se conserva: "[pendiente]" es texto, no un marcador.
_MARKERS = frozenset({"blank_audio", "music", "applause", "laughter", "silence", "inaudible",
                      "noise", "sound", "no_speech", "speaking_foreign_language", "*"})


class CancelledTranscription(Exception):
    """El móvil se fue o perdió el permiso mientras el motor trabajaba."""


@dataclass(frozen=True)
class WavFormat:
    """Geometría de un WAV: lo que whisper.cpp exige (PCM 16 bits, mono, 16 kHz) y su duración."""

    audio_format: int
    channels: int
    sample_rate: int
    byte_rate: int
    bits: int
    data_bytes: int

    @property
    def seconds(self) -> float:
        return self.data_bytes / self.byte_rate if self.byte_rate > 0 else 0.0

    @property
    def ready_for_whisper(self) -> bool:
        """PCM 16 bits mono a 16 kHz: el único formato que whisper.cpp lee sin convertir."""
        return (self.audio_format == 1 and self.channels == 1
                and self.sample_rate == 16000 and self.bits == 16)


def read_wav_format(path: Path) -> WavFormat | None:
    """Lee la cabecera RIFF/WAVE de `path` sin cargar el audio; `None` si no es un WAV legible."""
    try:
        total = path.stat().st_size
        with open(path, "rb") as handle:
            head = handle.read(WAV_PREFIX_BYTES)
    except OSError:
        return None
    if len(head) < 12 or head[:4] != b"RIFF" or head[8:12] != b"WAVE":
        return None
    offset, fields = 12, None
    while offset + 8 <= len(head):
        chunk, size = head[offset:offset + 4], int.from_bytes(head[offset + 4:offset + 8], "little")
        body = offset + 8
        if chunk == b"fmt " and size >= 16 and body + 16 <= len(head):
            audio_format, channels, sample_rate = struct.unpack_from("<HHI", head, body)
            byte_rate, _, bits = struct.unpack_from("<IHH", head, body + 8)
            fields = (audio_format, channels, sample_rate, byte_rate, bits)
        elif chunk == b"data" and fields is not None:
            # Un `size` de 0 o mentiroso (grabación cortada) se sustituye por lo que hay en disco.
            data = size if 0 < size <= total - body else max(0, total - body)
            return WavFormat(*fields, data_bytes=data)
        offset = body + size + (size & 1)
    return WavFormat(*fields, data_bytes=max(0, total - offset)) if fields is not None else None


def is_marker(line: str) -> bool:
    """`True` solo para los marcadores que escribe whisper.cpp, no para todo lo entrecorchetado."""
    match = _BRACKETS.fullmatch(line)
    if match is None:
        return False
    inner = "_".join(match.group(1).strip().lower().split())
    return inner in _MARKERS or _TOKEN.fullmatch(inner) is not None


def clean_transcript(output: str) -> str:
    """Deja una línea de dictado: sin marcas de tiempo, sin marcadores y sin espacios de más."""
    lines = []
    for line in output.splitlines():
        line = _TIMESTAMP.sub("", line.strip())
        if not line or is_marker(line):
            continue
        lines.append(line)
    return re.sub(r"\s+", " ", " ".join(lines)).strip()


class SubprocessRunner:
    """Ejecutor real: proceso hijo sin stdin, vigilado, y muerto en cuanto sobra.

    No basta con mirar entre etapas: whisper puede pasarse minutos comiéndose la
    máquina después de que el móvil se haya ido. El hijo se lanza sin bloquear y se
    espera a trocitos, comprobando en cada vuelta el plazo y la cancelación; cuando
    toca parar, la señal va al grupo de procesos entero (`start_new_session`), porque
    matar solo al padre deja vivos a sus nietos y con ellos las tuberías abiertas que
    nos tendrían esperando.
    """

    GRACE_SECONDS = 1.0
    POLL_SECONDS = 0.05

    def __call__(self, argv: list[str], *, timeout: float,
                 cancelled: Callable[[], bool] = lambda: False) -> subprocess.CompletedProcess:
        deadline = time.monotonic() + timeout
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, errors="replace",
                                   start_new_session=True)
        while True:
            try:
                # Reintentar communicate tras un TimeoutExpired no pierde salida (doc de Python).
                stdout, stderr = process.communicate(timeout=self.POLL_SECONDS)
                return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
            except subprocess.TimeoutExpired:
                pass
            if cancelled():
                self.stop(process)
                raise CancelledTranscription()
            if time.monotonic() >= deadline:
                self.stop(process)
                raise subprocess.TimeoutExpired(argv, timeout)

    def stop(self, process: subprocess.Popen) -> None:
        """Cierra el hijo cueste lo que cueste: primero por las buenas, luego a la fuerza."""
        self.signal(process, signal.SIGTERM)
        try:
            process.communicate(timeout=self.GRACE_SECONDS)
            return
        except subprocess.TimeoutExpired:
            pass
        self.signal(process, signal.SIGKILL)
        try:
            process.communicate(timeout=self.GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            pass  # Ya está muerto: una tubería que dejara abierta no puede retenernos.

    @staticmethod
    def signal(process: subprocess.Popen, number: int) -> None:
        """Señal al grupo entero; si no se puede, al menos al hijo directo."""
        try:
            os.killpg(os.getpgid(process.pid), number)
            return
        except OSError:
            pass
        try:
            process.kill() if number == signal.SIGKILL else process.terminate()
        except OSError:
            pass


@dataclass(frozen=True)
class Engine:
    """Binario y modelo elegidos para transcribir, con los hilos que puede gastar."""

    binary: str
    model: Path
    threads: int

    @property
    def name(self) -> str:
        """Lo que viaja al móvil en `engine`: motor y modelo, sin rutas del equipo."""
        return "whisper.cpp/" + self.model.name


class TranscriptionEngine:
    """whisper.cpp local detrás del RPC `mobile.audio.transcribe`, sin GTK ni estado compartido.

    No hace nada en el constructor: el binario y el modelo se buscan en la primera
    transcripción y se cachean, y una avería del motor invalida la caché para que la
    siguiente llamada vuelva a mirar. Conversión, transcripción y limpieza comparten
    un único presupuesto monotónico (`budget`, 90 s) con reloj inyectable, del que se
    reservan los últimos `CLEANUP_MARGIN` segundos, así que la respuesta sale antes
    del plazo de 90 s del móvil. Todo corre en el hilo del que llama, nunca en el de
    GTK. Como whisper se come la máquina, solo hay `max_jobs` transcripciones a la
    vez y `max_jobs_per_owner` por dispositivo: quien llega de más espera un turno
    corto (`turn_seconds`) y, si no se libera, recibe `busy`.

    Para probarla sin ejecutar whisper se inyectan `runner` (ejecutor de procesos),
    `which`, `clock`, `work_directory`, `remove` y las rutas del motor.
    """

    BINARIES = ("whisper-cli", "whisper-cpp", "main")
    EXTENSIONS = {"audio/mp4": ".m4a", "audio/m4a": ".m4a", "audio/x-m4a": ".m4a",
                  "audio/aac": ".m4a", "audio/ogg": ".ogg", "audio/opus": ".ogg",
                  "audio/wav": ".wav", "audio/x-wav": ".wav", "audio/wave": ".wav"}

    def __init__(self, *, model_directory: str | Path | None = None, binary: str | None = None,
                 model: str | None = None, threads: int | None = None,
                 runner: Callable[..., subprocess.CompletedProcess] | None = None,
                 which: Callable[[str], str | None] = shutil.which,
                 clock: Callable[[], float] = time.monotonic,
                 work_directory: str | Path | None = None,
                 remove: Callable[[Path], None] = shutil.rmtree,
                 budget: float = BUDGET_SECONDS, max_bytes: int = MAX_AUDIO_BYTES,
                 max_seconds: float = MAX_AUDIO_SECONDS, max_jobs: int = MAX_JOBS,
                 max_jobs_per_owner: int = MAX_JOBS_PER_OWNER, turn_seconds: float = TURN_SECONDS,
                 grace_seconds: float = GRACE_SECONDS, environment=None):
        environment = os.environ if environment is None else environment
        self.model_directory = Path(model_directory) if model_directory is not None \
            else self.default_model_directory(environment)
        self.work_directory = Path(work_directory) if work_directory is not None \
            else self.default_work_directory(environment)
        self.binary = binary if binary is not None else environment.get("UNICONNECT_WHISPER_BIN") or None
        self.model = model if model is not None else environment.get("UNICONNECT_WHISPER_MODEL") or None
        self.threads = threads if threads is not None else self.default_threads(environment)
        self.runner = runner if runner is not None else SubprocessRunner()
        self.which, self.clock, self.remove = which, clock, remove
        self.budget, self.max_bytes, self.max_seconds = budget, max_bytes, max_seconds
        self.max_jobs, self.max_jobs_per_owner = max_jobs, max_jobs_per_owner
        self.turn_seconds, self.grace_seconds = turn_seconds, grace_seconds
        # Un solo cerrojo, con su condición para los turnos: protege la caché del
        # motor, la cuenta de trabajos y la lista de directorios vivos. Lo lento
        # (conversión y transcripción) ocurre siempre fuera de él.
        self.lock = threading.Lock()
        self.turn = threading.Condition(self.lock)
        self.engine: Engine | None = None
        self.running: list[str] = []
        self.active: set[Path] = set()
        self.locks: dict[Path, int] = {}
        self.undeleted: list[Path] = []

    @staticmethod
    def default_model_directory(environment) -> Path:
        base = environment.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
        return Path(base) / "uniconnect" / "whisper"

    @staticmethod
    def default_work_directory(environment) -> Path:
        base = environment.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
        return Path(base) / "uniconnect" / "transcribe"

    @staticmethod
    def default_threads(environment) -> int:
        """Núcleos menos uno (el MINIPC tiene 4 y ninguna GPU), acotado y configurable."""
        configured = environment.get("UNICONNECT_WHISPER_THREADS")
        if configured and configured.strip().isdigit() and int(configured) > 0:
            return min(MAX_THREADS, int(configured))
        return max(1, min(MAX_THREADS, (os.cpu_count() or 2) - 1))

    # ----- temporales: borrado comprobado y restos de una caída -----

    def discard(self, directory: Path) -> bool:
        """Borra el directorio de una llamada y comprueba que de verdad ya no está.

        `rmtree(ignore_errors=True)` puede volver como si nada dejando el audio en
        disco, así que aquí se mira. Si el primer intento falla se reabren los
        permisos y se repite; lo que sobreviva a eso queda anotado para que el
        barrido lo reintente, nunca se da por borrado.
        """
        for attempt in range(2):
            try:
                self.remove(directory)
            except OSError:
                pass
            if not directory.exists():
                # El cerrojo se suelta cuando el trabajo ya no está, nunca antes.
                self.unlock(directory)
                self.unlink(self.lock_of(directory))
                with self.lock:
                    self.active.discard(directory)
                    if directory in self.undeleted:
                        self.undeleted.remove(directory)
                return True
            if attempt == 0:
                self.reopen(directory)
        # No se pudo borrar: el trabajo ha terminado igual, así que se suelta el
        # cerrojo para que el barrido siguiente pueda reclamar el resto. Su fichero
        # se conserva, que es lo que permite acreditarlo entonces.
        self.unlock(directory)
        with self.lock:
            self.active.discard(directory)
            if directory not in self.undeleted:
                self.undeleted.append(directory)
        return False

    def unlock(self, directory: Path) -> None:
        """Suelta el cerrojo del trabajo: cerrar el descriptor es lo que lo libera."""
        with self.lock:
            descriptor = self.locks.pop(directory, None)
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass

    @staticmethod
    def reopen(directory: Path) -> None:
        """Devuelve permisos de escritura por si un fallo previo los dejó cerrados."""
        try:
            directory.chmod(0o700)
            for item in directory.iterdir():
                try:
                    item.chmod(0o600)
                except OSError:
                    pass
        except OSError:
            pass

    def lock_of(self, directory: Path) -> Path:
        """El cerrojo hermano de un directorio `<pid>-<azar>`."""
        return directory.parent / (LOCK_PREFIX + directory.name.split("-", 1)[-1])

    def acquire(self, directory: Path) -> int | None:
        """Toma el cerrojo de un trabajo ajeno; devuelve su descriptor o `None` si tiene dueño.

        La antigüedad no prueba abandono: una suspensión del equipo, un salto del
        reloj o un trabajo atascado dejan un directorio viejo con su dueño vivo. Lo
        que sí lo prueba es que el `flock` se pueda tomar, porque el núcleo lo suelta
        cuando el proceso dueño muere, se cuelgue o no. El descriptor se devuelve
        para que quien vaya a borrar mantenga la exclusión hasta el final: soltarla
        antes abriría justo la carrera que el cerrojo existe para cerrar.
        """
        try:
            descriptor = os.open(self.lock_of(directory), os.O_RDWR)
        except OSError:
            return None  # Sin cerrojo legible no se acredita nada: no se toca.
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return descriptor
        except OSError:
            os.close(descriptor)
            return None

    def claimed(self, directory: Path) -> bool:
        """`True` si alguien está trabajando ahí ahora mismo. Solo para consultar."""
        if not directory.is_dir() or not self.lock_of(directory).exists():
            return False
        descriptor = self.acquire(directory)
        if descriptor is None:
            return True
        os.close(descriptor)
        return False

    def sweep_orphans(self) -> int:
        """Borra al arrancar los trabajos que dejó un proceso muerto, y solo esos.

        El `finally` de cada transcripción no cubre que el proceso desaparezca a
        media faena, así que el arranque limpia lo que quedó. Un directorio con
        cerrojo se borra si y solo si el cerrojo se puede tomar, y el borrado ocurre
        con la exclusión en la mano de principio a fin. Uno sin cerrojo no está
        acreditado como nuestro: solo se borra si lleva nuestro patrón de nombre (un
        temporal de una versión anterior) y ya ha pasado `grace_seconds`. Cualquier
        otra cosa que haya en la carpeta se conserva, que borrar lo ajeno no es tarea
        nuestra.
        """
        removed, now = 0, time.time()
        with self.lock:
            active, pending = set(self.active), list(self.undeleted)
        for directory in pending:
            if directory not in active and self.sweep(directory, now):
                removed += 1
        try:
            entries = list(self.work_directory.iterdir())
        except OSError:
            return removed
        for entry in entries:
            if not entry.name.startswith(LOCK_PREFIX) and entry not in active and entry not in pending:
                if self.sweep(entry, now):
                    removed += 1
        for entry in entries:
            if entry.name.startswith(LOCK_PREFIX) and self.sweep_lock(entry):
                removed += 1
        return removed

    def sweep(self, entry: Path, now: float) -> bool:
        """Borra una entrada suelta de la carpeta si de verdad es un huérfano nuestro."""
        if entry.is_dir() and self.lock_of(entry).exists():
            descriptor = self.acquire(entry)
            if descriptor is None:
                return False  # Tiene dueño, o no se puede comprobar.
            try:
                return self.discard(entry)  # Con el cerrojo puesto: nadie entra en medio.
            finally:
                os.close(descriptor)
        if not _OURS.fullmatch(entry.name):
            return False  # Ni cerrojo ni nuestro nombre: no se acredita, no se borra.
        try:
            if now - entry.stat().st_mtime < self.grace_seconds:
                return False  # Puede estar naciendo en otra instancia.
        except OSError:
            return False
        if entry.is_dir():
            return self.discard(entry)
        self.unlink(entry)
        return not entry.exists()

    def sweep_lock(self, lock: Path) -> bool:
        """Borra un cerrojo que ya no guarda a nadie: sin dueño y sin trabajo que proteger."""
        token = lock.name[len(LOCK_PREFIX):]
        # Ojo: el glob de pathlib también devuelve los ocultos, y el propio cerrojo
        # termina en el mismo token, así que solo cuenta un directorio de trabajo.
        if any(item.is_dir() for item in self.work_directory.glob(f"*-{token}")):
            return False  # Su trabajo sigue ahí: el cerrojo hace falta.
        try:
            descriptor = os.open(lock, os.O_RDWR)
        except OSError:
            return False
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False  # Alguien lo tiene tomado: está a punto de crear su trabajo.
        else:
            self.unlink(lock)
            return not lock.exists()
        finally:
            os.close(descriptor)

    @staticmethod
    def unlink(path: Path) -> None:
        try:
            path.unlink()
        except OSError:
            pass

    # ----- detección del motor -----

    def resolve(self) -> Engine:
        """Binario y modelo cacheados; `unsupported` con el motivo si falta cualquiera."""
        with self.lock:
            if self.engine is not None:
                return self.engine
        engine = Engine(binary=self.find_binary(), model=self.find_model(), threads=self.threads)
        with self.lock:
            self.engine = engine
        return engine

    def invalidate(self) -> None:
        """El motor falló: la próxima transcripción vuelve a buscar binario y modelo."""
        with self.lock:
            self.engine = None

    def find_binary(self) -> str:
        if self.binary:
            if os.path.isfile(self.binary) and os.access(self.binary, os.X_OK):
                return self.binary
            raise RPCError("unsupported", "El binario de whisper configurado no existe o no se puede ejecutar")
        for name in self.BINARIES:
            found = self.which(name)
            if found:
                return found
        raise RPCError("unsupported", "Este equipo no tiene whisper.cpp instalado; "
                                      "instala whisper-cli para dictar desde el móvil")

    def find_model(self) -> Path:
        if self.model:
            path = Path(self.model)
            if not path.is_absolute():
                path = self.model_directory / path
            if path.is_file():
                return path
            raise RPCError("unsupported", "El modelo de whisper configurado no está en el equipo")
        try:
            models = [item for item in self.model_directory.glob("*.bin") if item.is_file() and item.stat().st_size > 0]
        except OSError:
            models = []
        if not models:
            raise RPCError("unsupported", f"No hay ningún modelo de whisper en {self.model_directory}; "
                                          "descarga uno (por ejemplo ggml-base.bin) para dictar desde el móvil")
        # El más pequeño por defecto: en un equipo sin GPU es el único que responde a tiempo.
        return min(models, key=lambda item: (item.stat().st_size, item.name))

    # ----- trabajos en curso -----

    def claim(self, owner: str, deadline: float, cancelled: Callable[[], bool]) -> None:
        """Reserva turno esperando un poco; `busy` si el equipo sigue ocupado.

        El mismo dispositivo no espera: si ya está dictando, su segunda petición es
        un doble toque y se rechaza en el acto. Quien choca con el tope del equipo
        aguarda `turn_seconds` como mucho, y siempre dentro del presupuesto, para no
        gastar en la cola el tiempo que hace falta para transcribir.
        """
        limit = min(self.clock() + self.turn_seconds, deadline - CLEANUP_MARGIN)
        with self.turn:
            while True:
                if self.running.count(owner) >= self.max_jobs_per_owner:
                    raise RPCError("busy", "Ya hay un dictado en curso desde este dispositivo; espera un momento")
                if len(self.running) < self.max_jobs:
                    self.running.append(owner)
                    return
                remaining = limit - self.clock()
                if remaining <= 0 or cancelled():
                    raise RPCError("busy", "El equipo está transcribiendo otro audio; espera un momento")
                self.turn.wait(min(remaining, 0.25))

    def release(self, owner: str) -> None:
        with self.turn:
            if owner in self.running:
                self.running.remove(owner)
            self.turn.notify_all()

    # ----- transcripción -----

    def deadline(self) -> float:
        """Vencimiento de una petición que entra ahora, en el reloj monotónico del motor.

        Lo llama quien recibe el RPC, antes de decodificar el audio y de saltar al
        hilo del modelo, para que ese tiempo salga del mismo presupuesto y no se
        sume por detrás.
        """
        return self.clock() + self.budget

    def transcribe(self, audio: bytes, mime, language=None, *, owner: str = "",
                   deadline: float | None = None,
                   cancelled: Callable[[], bool] = lambda: False) -> dict:
        """Devuelve `{text, engine, seconds, took_ms}` para un audio ya decodificado.

        Valida formato y límites, espera turno, escribe el audio en un temporal
        privado, mide su duración real (nunca la que sugiera el MIME), lo convierte a
        WAV 16 kHz mono si hace falta y llama al motor. El directorio temporal se
        borra en cualquier salida, el turno se libera pase lo que pase y una
        cancelación no devuelve texto aunque el motor ya lo hubiera escrito.

        - Parameter deadline: vencimiento ya fijado por quien recibió la petición
          (`deadline()`); si falta, se cuenta desde aquí. `took_ms` se mide desde ese
          origen, así que incluye lo que la petición tardó en llegar al motor.
        """
        deadline = self.deadline() if deadline is None else deadline
        started = deadline - self.budget  # Cuándo empezó a contar, no cuándo llegó aquí.
        extension = self.extension_for(mime)
        language = self.language_for(language)
        if not isinstance(audio, (bytes, bytearray)) or not audio:
            raise RPCError("invalid_params", "No llegó ningún audio que transcribir")
        if len(audio) > self.max_bytes:
            raise RPCError("too_large", f"El audio supera el máximo de {self.max_bytes // (1024 * 1024)} MiB")
        engine = self.resolve()
        self.claim(owner, deadline, cancelled)
        try:
            directory = self.workspace()
            try:
                source = self.write_private(directory / ("entrada" + extension), audio)
                self.check(cancelled, deadline)
                seconds = self.measure(source, deadline, cancelled)
                wave, converted = self.prepare_wave(source, directory, deadline, cancelled)
                seconds = converted if converted is not None else seconds
                self.refuse_long(seconds)
                self.check(cancelled, deadline)
                text = self.run_whisper(engine, wave, language, deadline, cancelled)
                self.check(cancelled, deadline)  # Un dictado abandonado no devuelve texto.
            except RPCError:
                raise
            except OSError as error:
                raise RPCError("io_failed", "No se pudo preparar el audio en el equipo") from error
            finally:
                self.discard(directory)
        finally:
            self.release(owner)
        return {"text": text, "engine": engine.name, "seconds": round(seconds or 0.0, 2),
                "took_ms": int((self.clock() - started) * 1000)}

    def workspace(self) -> Path:
        """Directorio 0700 propio de esta llamada, con su cerrojo tomado de antemano.

        El cerrojo se crea y se adquiere primero, y el directorio de trabajo nace
        después con el nombre que lo emparienta. Así no existe el instante en que un
        trabajo es visible sin dueño: cuando el directorio aparece, su cerrojo lleva
        ya un rato en la mano de este proceso.
        """
        try:
            self.work_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor, lock = tempfile.mkstemp(prefix=LOCK_PREFIX, dir=self.work_directory)
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            directory = self.work_directory / f"{os.getpid()}-{Path(lock).name[len(LOCK_PREFIX):]}"
            os.mkdir(directory, 0o700)
        except OSError as error:
            raise RPCError("io_failed", "No se pudo preparar la carpeta de trabajo del equipo") from error
        with self.lock:
            self.active.add(directory)
            self.locks[directory] = descriptor
        return directory

    def extension_for(self, mime) -> str:
        if not isinstance(mime, str):
            raise RPCError("invalid_params", "Tipo de audio no válido")
        extension = self.EXTENSIONS.get(mime.split(";", 1)[0].strip().lower())
        if extension is None:
            raise RPCError("invalid_params", "Formato de audio no admitido; usa audio/mp4, audio/ogg o audio/wav")
        return extension

    @staticmethod
    def language_for(language) -> str:
        """`None` significa detección automática; cualquier otra cosa, un código ISO de dos letras."""
        if language is None:
            return "auto"
        if not isinstance(language, str) or not _LANGUAGE.fullmatch(language.strip().lower()):
            raise RPCError("invalid_params", "Idioma no válido")
        return language.strip().lower()

    def refuse_long(self, seconds: float | None) -> None:
        if seconds is not None and seconds > self.max_seconds:
            raise RPCError("too_large", f"El audio supera los {int(self.max_seconds) // 60} minutos")

    @staticmethod
    def write_private(path: Path, audio: bytes) -> Path:
        """Escribe el audio con permisos 0600 y sin seguir enlaces existentes."""
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            view = memoryview(audio)
            while view:
                view = view[os.write(descriptor, view):]
        finally:
            os.close(descriptor)
        return path

    def check(self, cancelled: Callable[[], bool], deadline: float) -> float:
        """Tiempo que queda del presupuesto; `io_failed` si se canceló o se agotó."""
        if cancelled():
            raise RPCError("io_failed", "La transcripción se canceló")
        remaining = deadline - self.clock() - CLEANUP_MARGIN
        if remaining <= 0:
            raise RPCError("io_failed", "La transcripción tardó demasiado y se canceló")
        return remaining

    def measure(self, source: Path, deadline: float, cancelled: Callable[[], bool]) -> float | None:
        """Duración del audio que llegó de verdad, no la que insinúe el MIME.

        Manda el contenido: la cabecera del archivo si resulta ser un WAV y, si no,
        `ffprobe`. Un audio que se anuncia como WAV y no lo es cae en la rama de
        `ffprobe` como cualquier otro. Si no hay forma de saberlo aquí (sin
        `ffprobe`), la conversión va acotada y la duración real se comprueba sobre su
        resultado antes de gastar un segundo de motor.
        """
        fields = read_wav_format(source)
        if fields is not None:
            self.refuse_long(fields.seconds)
            return fields.seconds
        probe = self.which("ffprobe")
        if not probe:
            return None
        remaining = deadline - self.clock() - CLEANUP_MARGIN
        if remaining <= 0:
            return None
        argv = [probe, "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(source)]
        try:
            result = self.runner(argv, timeout=min(10.0, remaining), cancelled=cancelled)
        except CancelledTranscription as error:
            raise RPCError("io_failed", "La transcripción se canceló") from error
        except (subprocess.TimeoutExpired, OSError):
            return None
        try:
            seconds = float((result.stdout or "").strip())
        except ValueError:
            return None
        self.refuse_long(seconds)
        return seconds

    @property
    def conversion_seconds(self) -> float:
        """Lo que se deja convertir: el máximo más un margen, para poder ver que se pasa."""
        return self.max_seconds + CONVERSION_MARGIN

    @property
    def conversion_bytes(self) -> int:
        """Tope de bytes de salida acorde con esa duración, cabecera incluida."""
        return int(self.conversion_seconds * WAV_BYTES_PER_SECOND) + WAV_PREFIX_BYTES

    def prepare_wave(self, source: Path, directory: Path, deadline: float,
                     cancelled: Callable[[], bool]) -> tuple[Path, float | None]:
        """Devuelve el WAV 16 kHz mono que whisper.cpp acepta y su duración exacta.

        La conversión va acotada en duración (`-t`) y en bytes de salida (`-fs`), así
        que un audio de una hora no se expande entero en el disco del equipo. Llegar
        a cualquiera de los dos topes es `too_large`, nunca un audio recortado que se
        transcribe en silencio; y un resultado que no se puede verificar es
        `io_failed`.
        """
        fields = read_wav_format(source)
        if fields is not None and fields.ready_for_whisper:
            return source, fields.seconds
        converter = self.which("ffmpeg")
        if not converter:
            raise RPCError("unsupported", "Falta ffmpeg en el equipo para convertir el audio del móvil")
        remaining = self.check(cancelled, deadline)
        target = directory / "audio16k.wav"
        argv = [converter, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
                "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "-f", "wav",
                "-t", f"{self.conversion_seconds:.3f}", "-fs", str(self.conversion_bytes), str(target)]
        result = self.execute(argv, remaining, "No se pudo convertir el audio recibido", cancelled)
        if result.returncode != 0 or not target.exists():
            raise RPCError("io_failed", "No se pudo convertir el audio recibido")
        try:
            os.chmod(target, 0o600)
            size = target.stat().st_size
        except OSError as error:
            raise RPCError("io_failed", "No se pudo leer el audio convertido") from error
        if size >= self.conversion_bytes:
            raise RPCError("too_large", f"El audio supera los {int(self.max_seconds) // 60} minutos")
        converted = read_wav_format(target)
        if converted is None or not converted.ready_for_whisper:
            raise RPCError("io_failed", "El audio convertido no se pudo verificar en el equipo")
        return target, converted.seconds

    def run_whisper(self, engine: Engine, wave: Path, language: str, deadline: float,
                    cancelled: Callable[[], bool]) -> str:
        remaining = deadline - self.clock() - CLEANUP_MARGIN
        if remaining <= 0:
            raise RPCError("io_failed", "La transcripción tardó demasiado y se canceló")
        argv = [engine.binary, "--model", str(engine.model), "--file", str(wave),
                "--language", language, "--threads", str(engine.threads), "--no-timestamps"]
        result = self.execute(argv, remaining, "El motor de transcripción no respondió a tiempo", cancelled)
        if result.returncode != 0:
            self.invalidate()  # Un motor averiado no se cachea: la próxima llamada vuelve a mirar.
            raise RPCError("io_failed", "El motor de transcripción falló en el equipo")
        return clean_transcript(result.stdout or "")

    def execute(self, argv: list[str], timeout: float, message: str,
                cancelled: Callable[[], bool]) -> subprocess.CompletedProcess:
        try:
            return self.runner(argv, timeout=max(1.0, timeout), cancelled=cancelled)
        except CancelledTranscription as error:
            raise RPCError("io_failed", "La transcripción se canceló") from error
        except subprocess.TimeoutExpired as error:
            self.invalidate()
            raise RPCError("io_failed", message) from error
        except OSError as error:
            self.invalidate()
            raise RPCError("io_failed", "No se pudo ejecutar el motor de transcripción en el equipo") from error
