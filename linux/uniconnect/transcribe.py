"""Transcripción de voz del móvil en el equipo (contrato transcribe.v1).

El móvil graba un audio corto y lo entrega por la conexión privada; el equipo lo
transcribe con whisper.cpp local (sin servicio externo, sin red) y devuelve solo
el texto. El audio vive en un temporal 0600 dentro de un directorio 0700 propio
de la llamada y se borra siempre —éxito, error, plazo agotado o cancelación—; ni
el audio ni el texto se registran en ningún log. Si el equipo no tiene motor o
modelo se responde `unsupported` y el móvil cae a su dictado local.
"""

from __future__ import annotations

import os
import re
import shutil
import struct
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .mobile_protocol import RPCError

MAX_AUDIO_BYTES = 6 * 1024 * 1024
MAX_AUDIO_SECONDS = 300
BUDGET_SECONDS = 90.0
CLEANUP_MARGIN = 3.0  # Reserva para matar el proceso y borrar el temporal antes del plazo.
MAX_THREADS = 8
WAV_PREFIX_BYTES = 65536

_LANGUAGE = re.compile(r"[a-z]{2}")
_MARKER = re.compile(r"\[[^\]]*\]")
_TIMESTAMP = re.compile(r"^\[[0-9:.,\s\->]+\]\s*")


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


def clean_transcript(output: str) -> str:
    """Deja una línea de dictado: sin marcas de tiempo, sin `[BLANK_AUDIO]` ni espacios de más."""
    lines = []
    for line in output.splitlines():
        line = _TIMESTAMP.sub("", line.strip())
        if not line or _MARKER.fullmatch(line):
            continue
        lines.append(line)
    return re.sub(r"\s+", " ", " ".join(lines)).strip()


class SubprocessRunner:
    """Ejecutor real: proceso hijo sin stdin, con salida capturada y plazo propio."""

    def __call__(self, argv: list[str], *, timeout: float) -> subprocess.CompletedProcess:
        return subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              errors="replace", timeout=timeout, check=False)


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
    un único presupuesto monotónico (`budget`, 90 s) con reloj inyectable, y todo
    corre en el hilo del que llama —nunca en el de GTK—, así que el móvil recibe la
    respuesta antes de su propio plazo.

    Para probarla sin ejecutar whisper se inyectan `runner` (ejecutor de procesos),
    `which`, `clock`, `temp_root` y las rutas de binario y modelo.
    """

    BINARIES = ("whisper-cli", "whisper-cpp", "main")
    EXTENSIONS = {"audio/mp4": ".m4a", "audio/m4a": ".m4a", "audio/x-m4a": ".m4a",
                  "audio/aac": ".m4a", "audio/ogg": ".ogg", "audio/opus": ".ogg",
                  "audio/wav": ".wav", "audio/x-wav": ".wav", "audio/wave": ".wav"}

    def __init__(self, *, model_directory: str | Path | None = None, binary: str | None = None,
                 model: str | None = None, threads: int | None = None,
                 runner: Callable[..., subprocess.CompletedProcess] | None = None,
                 which: Callable[[str], str | None] = shutil.which,
                 clock: Callable[[], float] = time.monotonic, temp_root: str | Path | None = None,
                 budget: float = BUDGET_SECONDS, max_bytes: int = MAX_AUDIO_BYTES,
                 max_seconds: float = MAX_AUDIO_SECONDS, environment=None):
        environment = os.environ if environment is None else environment
        self.model_directory = Path(model_directory) if model_directory is not None \
            else self.default_model_directory(environment)
        self.binary = binary if binary is not None else environment.get("UNICONNECT_WHISPER_BIN") or None
        self.model = model if model is not None else environment.get("UNICONNECT_WHISPER_MODEL") or None
        self.threads = threads if threads is not None else self.default_threads(environment)
        self.runner = runner if runner is not None else SubprocessRunner()
        self.which, self.clock = which, clock
        self.temp_root = Path(temp_root) if temp_root is not None else None
        self.budget, self.max_bytes, self.max_seconds = budget, max_bytes, max_seconds
        # Cerrojo corto: solo protege la caché de la detección, nunca la transcripción.
        self.lock = threading.Lock()
        self.engine: Engine | None = None

    @staticmethod
    def default_model_directory(environment) -> Path:
        base = environment.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
        return Path(base) / "uniconnect" / "whisper"

    @staticmethod
    def default_threads(environment) -> int:
        """Núcleos menos uno (el MINIPC tiene 4 y ninguna GPU), acotado y configurable."""
        configured = environment.get("UNICONNECT_WHISPER_THREADS")
        if configured and configured.strip().isdigit() and int(configured) > 0:
            return min(MAX_THREADS, int(configured))
        return max(1, min(MAX_THREADS, (os.cpu_count() or 2) - 1))

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

    # ----- transcripción -----

    def transcribe(self, audio: bytes, mime, language=None, *,
                   cancelled: Callable[[], bool] = lambda: False) -> dict:
        """Devuelve `{text, engine, seconds, took_ms}` para un audio ya decodificado.

        Valida formato y límites, escribe el audio en un temporal privado, lo convierte
        a WAV 16 kHz mono si hace falta y llama al motor. El directorio temporal se
        borra en cualquier salida.
        """
        started = self.clock()
        deadline = started + self.budget
        extension = self.extension_for(mime)
        language = self.language_for(language)
        if not isinstance(audio, (bytes, bytearray)) or not audio:
            raise RPCError("invalid_params", "No llegó ningún audio que transcribir")
        if len(audio) > self.max_bytes:
            raise RPCError("too_large", f"El audio supera el máximo de {self.max_bytes // (1024 * 1024)} MiB")
        engine = self.resolve()
        directory = Path(tempfile.mkdtemp(prefix="uniconnect-audio-", dir=self.temp_root))
        try:
            source = self.write_private(directory / ("entrada" + extension), audio)
            self.check(cancelled, deadline)
            seconds = self.probe_seconds(source, extension, deadline)
            if seconds is not None and seconds > self.max_seconds:
                raise RPCError("too_large", f"El audio supera los {int(self.max_seconds) // 60} minutos")
            wave, measured = self.prepare_wave(source, extension, directory, deadline, cancelled)
            seconds = measured if measured is not None else seconds
            if seconds is not None and seconds > self.max_seconds:
                raise RPCError("too_large", f"El audio supera los {int(self.max_seconds) // 60} minutos")
            self.check(cancelled, deadline)
            text = self.run_whisper(engine, wave, language, deadline)
        except RPCError:
            raise
        except OSError as error:
            raise RPCError("io_failed", "No se pudo preparar el audio en el equipo") from error
        finally:
            shutil.rmtree(directory, ignore_errors=True)
        return {"text": text, "engine": engine.name, "seconds": round(seconds or 0.0, 2),
                "took_ms": int((self.clock() - started) * 1000)}

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

    def probe_seconds(self, source: Path, extension: str, deadline: float) -> float | None:
        """Duración antes de convertir: cabecera WAV si la hay, si no `ffprobe`; `None` si no se sabe."""
        if extension == ".wav":
            fields = read_wav_format(source)
            if fields is not None:
                return fields.seconds
        probe = self.which("ffprobe")
        if not probe:
            return None
        remaining = deadline - self.clock() - CLEANUP_MARGIN
        if remaining <= 0:
            return None
        argv = [probe, "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(source)]
        try:
            result = self.runner(argv, timeout=min(10.0, remaining))
        except (subprocess.TimeoutExpired, OSError):
            return None
        try:
            return float((result.stdout or "").strip())
        except ValueError:
            return None

    def prepare_wave(self, source: Path, extension: str, directory: Path, deadline: float,
                     cancelled: Callable[[], bool]) -> tuple[Path, float | None]:
        """Devuelve el WAV 16 kHz mono que whisper.cpp acepta y su duración exacta."""
        if extension == ".wav":
            fields = read_wav_format(source)
            if fields is not None and fields.ready_for_whisper:
                return source, fields.seconds
        converter = self.which("ffmpeg")
        if not converter:
            raise RPCError("unsupported", "Falta ffmpeg en el equipo para convertir el audio del móvil")
        remaining = self.check(cancelled, deadline)
        target = directory / "audio16k.wav"
        argv = [converter, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
                "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "-f", "wav", str(target)]
        result = self.execute(argv, remaining, "No se pudo convertir el audio recibido")
        if result.returncode != 0 or not target.exists():
            raise RPCError("io_failed", "No se pudo convertir el audio recibido")
        try:
            os.chmod(target, 0o600)
        except OSError:
            pass
        fields = read_wav_format(target)
        return target, fields.seconds if fields is not None else None

    def run_whisper(self, engine: Engine, wave: Path, language: str, deadline: float) -> str:
        remaining = deadline - self.clock() - CLEANUP_MARGIN
        if remaining <= 0:
            raise RPCError("io_failed", "La transcripción tardó demasiado y se canceló")
        argv = [engine.binary, "--model", str(engine.model), "--file", str(wave),
                "--language", language, "--threads", str(engine.threads), "--no-timestamps"]
        result = self.execute(argv, remaining, "El motor de transcripción no respondió a tiempo")
        if result.returncode != 0:
            self.invalidate()  # Un motor averiado no se cachea: la próxima llamada vuelve a mirar.
            raise RPCError("io_failed", "El motor de transcripción falló en el equipo")
        return clean_transcript(result.stdout or "")

    def execute(self, argv: list[str], timeout: float, message: str) -> subprocess.CompletedProcess:
        try:
            return self.runner(argv, timeout=max(1.0, timeout))
        except subprocess.TimeoutExpired as error:
            self.invalidate()
            raise RPCError("io_failed", message) from error
        except OSError as error:
            self.invalidate()
            raise RPCError("io_failed", "No se pudo ejecutar el motor de transcripción en el equipo") from error
