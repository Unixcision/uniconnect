"""Retención de las conversaciones de las IAs (contrato transcript-retention-v1).

Cada hora se revisan los `.jsonl` de Claude Code (`~/.claude/projects`) y de Codex
(`~/.codex/sessions`): con más de 30 días sin tocar se comprimen en el sitio a
`.jsonl.gz` con la misma fecha, y con más de 365 se borran, comprimidos o no. Nunca se
toca una conversación en uso: la de cualquier ventana de UniConnect (todo UUID del
almacén de estado) ni la de cualquier Claude vivo (`~/.claude/sessions/<pid>.json`).

El plan es una función pura sobre rutas lógicas (`claude/...`, `codex/...`) y edades;
el escaneo y la ejecución son las únicas piezas que tocan disco. Un fichero que falla
se cuenta y se sigue con el siguiente: una pasada nunca se interrumpe por uno solo.
"""

from __future__ import annotations

import contextlib
import fcntl
import gzip
import hashlib
import json
import os
import re
import stat
import sys
import threading
import time
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

DAY_SECONDS = 86400.0
CHUNK_BYTES = 1024 * 1024
COMPRESS_LEVEL = 6  # El de `gzip` por omisión: 9 cuesta mucho más para ganar muy poco.
MAX_FICHA_BYTES = 1024 * 1024
# Durante una pasada larga (la primera puede comprimir miles de ficheros) una IA puede
# arrancar sobre una conversación vieja; antes de confirmar cada fichero se vuelve a
# leer el conjunto protegido si la última lectura tiene más de estos segundos.
GUARD_REFRESH_SECONDS = 5.0
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
PID_FILE = re.compile(r"([1-9][0-9]{0,9})\.json")


class RetentionError(Exception):
    """Un fichero no se pudo tratar sin arriesgar su contenido; se queda como estaba."""


class ProtectedSetUnavailable(Exception):
    """No se pudo saber qué conversaciones están en uso: la pasada no toca nada."""


@dataclass(frozen=True)
class Policy:
    compress_after_days: float = 30
    delete_after_days: float = 365


@dataclass(frozen=True)
class Entry:
    """Un fichero visto por el escaneo: ruta lógica, edad y su identidad en disco."""

    path: str
    age_days: float
    size: int | None = None
    mtime_ns: int | None = None
    inode: int | None = None

    @property
    def identity(self):
        if self.size is None or self.mtime_ns is None or self.inode is None:
            return None
        return (self.inode, self.size, self.mtime_ns)


@dataclass(frozen=True)
class Plan:
    compress: tuple[str, ...] = ()
    delete: tuple[str, ...] = ()


@dataclass
class Summary:
    compressed: int = 0
    deleted: int = 0
    freed_bytes: int = 0
    failures: int = 0
    deferred: int = 0  # Cambiaron mientras se trataban: quedan para la hora siguiente.

    @property
    def eventful(self) -> bool:
        return bool(self.compressed or self.deleted or self.failures or self.deferred)

    def describe(self) -> str:
        return ("Conversaciones de las IAs: comprimidas %d, borradas %d, liberado %s, aplazadas %d, fallos %d"
                % (self.compressed, self.deleted, human_size(self.freed_bytes), self.deferred, self.failures))


def human_size(count: int) -> str:
    value, unit = float(count), "B"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(value) < 1024 or unit == "TB":
            break
        value /= 1024
    return ("%d %s" % (value, unit) if unit == "B" else ("%.1f %s" % (value, unit)).replace(".", ","))


def is_transcript(name: str) -> bool:
    return name.endswith(".jsonl") or name.endswith(".jsonl.gz")


def uuids_in(text: str) -> set[str]:
    return {match.group(0).lower() for match in UUID.finditer(text)}


def is_protected(path: str, protected) -> bool:
    """En uso si cualquier UUID de la ruta (sin mirar mayúsculas) está en el conjunto."""
    return not uuids_in(path).isdisjoint(protected)


def plan(entries: Iterable, protected: Iterable[str], policy: Policy = Policy()) -> Plan:
    """Qué comprimir y qué borrar; puro, sin disco. Los límites son estrictos (`>`)."""
    protected = {identifier.lower() for identifier in protected}
    compress, delete = [], []
    for entry in entries:
        name = entry.path.rsplit("/", 1)[-1]
        if not is_transcript(name) or is_protected(entry.path, protected):
            continue
        if entry.age_days > policy.delete_after_days:
            delete.append(entry.path)
        elif entry.age_days > policy.compress_after_days and name.endswith(".jsonl"):
            # También si ya existe su `.gz`: es una conversación archivada que se retomó.
            compress.append(entry.path)
    return Plan(tuple(compress), tuple(delete))


# ----- escaneo -----

def default_roots(home: str | Path | None = None) -> dict[str, Path]:
    home = Path(home) if home is not None else Path.home()
    return {"claude": home / ".claude" / "projects", "codex": home / ".codex" / "sessions"}


def scan(roots: dict, now: float) -> list[Entry]:
    """Ficheros normales `.jsonl`/`.jsonl.gz` bajo cada raíz, sin seguir enlaces."""
    entries = []
    for name, root in sorted(roots.items()):
        try:
            if not stat.S_ISDIR(os.lstat(root).st_mode):
                continue
        except OSError:
            continue
        pending = [(os.fspath(root), name)]
        while pending:
            folder, logical = pending.pop()
            try:
                with os.scandir(folder) as items:
                    children = list(items)
            except OSError:
                continue
            for item in children:
                try:
                    info = item.stat(follow_symlinks=False)
                except OSError:
                    continue
                path = logical + "/" + item.name
                if stat.S_ISDIR(info.st_mode):
                    pending.append((item.path, path))
                elif stat.S_ISREG(info.st_mode) and is_transcript(item.name):
                    age = (now - info.st_mtime_ns / 1e9) / DAY_SECONDS
                    entries.append(Entry(path, age, info.st_size, info.st_mtime_ns, info.st_ino))
    entries.sort(key=lambda entry: entry.path)
    return entries


# ----- conjunto protegido -----

def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # Existe, aunque sea de otro usuario.
    except (OverflowError, ValueError):
        return False
    return True


def live_claude_sessions(directory: str | Path, alive: Callable[[int], bool] = pid_alive) -> set[str]:
    """`sessionId` (y cualquier otro UUID) de cada ficha cuyo proceso sigue vivo."""
    found = set()
    try:
        with os.scandir(directory) as items:
            names = [item.name for item in items]
    except FileNotFoundError:
        return found
    except OSError as error:
        raise ProtectedSetUnavailable("no se pudo leer %s: %s" % (directory, error.strerror or error)) from None
    for name in names:
        match = PID_FILE.fullmatch(name)
        if not match or not alive(int(match.group(1))):
            continue
        try:
            with open(os.path.join(directory, name), "rb") as handle:
                raw = handle.read(MAX_FICHA_BYTES)
        except FileNotFoundError:
            continue  # La IA acaba de terminar.
        except OSError as error:
            raise ProtectedSetUnavailable("no se pudo leer la ficha %s: %s" % (name, error.strerror or error)) from None
        # Una ficha a medio escribir no es JSON válido, pero el UUID ya se ve en el texto.
        text = raw.decode("utf-8", "replace")
        found |= uuids_in(text)
        try:
            session = json.loads(text).get("sessionId")
        except (ValueError, AttributeError):
            session = None
        if isinstance(session, str):
            found.add(session.lower())
    return found


def protected_ids(*, state_paths: Iterable = (), state_texts: Iterable[str] = (), sessions_dir=None,
                  alive: Callable[[int], bool] = pid_alive) -> set[str]:
    """Todo UUID del estado de UniConnect (disco y memoria) más el de cada Claude vivo.

    Sobran UUIDs que no son conversaciones (ventanas, cajas), y no hacen daño. Un estado
    que existe pero no se puede leer detiene la pasada: proteger de menos no se arregla.
    """
    found = set()
    for text in state_texts:
        if text:
            found |= uuids_in(text)
    for path in state_paths:
        try:
            with open(path, "rb") as handle:
                raw = handle.read()
        except FileNotFoundError:
            continue
        except OSError as error:
            raise ProtectedSetUnavailable("no se pudo leer %s: %s" % (path, error.strerror or error)) from None
        found |= uuids_in(raw.decode("utf-8", "replace"))
    if sessions_dir is not None:
        found |= live_claude_sessions(sessions_dir, alive)
    return found


class ProtectionGuard:
    """Comprobación de última hora antes de confirmar cada fichero, con relectura acotada."""

    def __init__(self, read: Callable[[], set], initial: set, *, monotonic=time.monotonic,
                 refresh_seconds: float = GUARD_REFRESH_SECONDS):
        self.read, self.ids, self.monotonic = read, set(initial), monotonic
        self.refresh_seconds = refresh_seconds
        self.read_at = monotonic()

    def __call__(self, path: str) -> bool:
        if self.monotonic() - self.read_at >= self.refresh_seconds:
            try:
                self.ids = self.read()
            except ProtectedSetUnavailable:
                return True  # Sin saberlo, se trata como en uso; se reintenta con el siguiente.
            self.read_at = self.monotonic()
        return is_protected(path, self.ids)


# ----- ejecución -----

def _identity(info):
    return (info.st_ino, info.st_size, info.st_mtime_ns)


def _lstat(path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None


def _sync_dir(folder) -> None:
    descriptor = os.open(folder, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _copy(source, target) -> int:
    copied = 0
    for chunk in iter(lambda: source.read(CHUNK_BYTES), b""):
        target.write(chunk)
        copied += len(chunk)
    return copied


class RetentionExecutor:
    """Aplica un plan según «Cómo se aplica sin perder nada» del contrato.

    ``guard(path)`` dice si la conversación pasó a estar en uso desde el plan.
    ``failpoint(stage, path)`` es la costura de las pruebas: ``comprimido`` con el
    temporal escrito y comprobado, ``renombrado`` con el `.gz` ya en su sitio y el
    original todavía presente.
    """

    def __init__(self, roots: dict, *, guard: Callable[[str], bool] | None = None, failpoint=None):
        self.roots = {name: Path(root) for name, root in roots.items()}
        self.guard = guard or (lambda path: False)
        self.failpoint = failpoint or (lambda stage, path: None)

    def resolve(self, logical: str) -> tuple[Path, Path]:
        name, _, rest = logical.partition("/")
        if name not in self.roots or not rest or any(part in ("", ".", "..") for part in rest.split("/")):
            raise RetentionError("ruta fuera de las raíces: " + logical)
        root = self.roots[name]
        return root, root.joinpath(*rest.split("/"))

    def apply(self, chosen: Plan, entries: Iterable[Entry] = ()) -> Summary:
        summary = Summary()
        known = {entry.path: entry for entry in entries}
        emptied = {}
        # Primero los borrados: un `.gz` caducado junto a un `.jsonl` de 40 días se va
        # antes de comprimir, y el `.jsonl` no se añade a algo que se iba a borrar.
        for logical in chosen.delete:
            try:
                folder = self.delete(logical, known.get(logical), summary)
                if folder is not None:
                    emptied[folder] = self.resolve(logical)[0]
            except Exception:
                summary.failures += 1
        for logical in chosen.compress:
            try:
                self.compress(logical, known.get(logical), summary)
            except Exception:
                summary.failures += 1
        for folder in sorted(emptied, key=lambda item: len(item.parts), reverse=True):
            self.prune(folder, emptied[folder])
        return summary

    def delete(self, logical: str, entry: Entry | None, summary: Summary):
        _, path = self.resolve(logical)
        if self.guard(logical):
            return None
        info = _lstat(path)
        if info is None:
            return None
        if not stat.S_ISREG(info.st_mode):
            raise RetentionError("no es un fichero normal: " + logical)
        if entry is not None and entry.identity is not None and entry.identity != _identity(info):
            summary.deferred += 1
            return None
        os.unlink(path)
        summary.deleted += 1
        summary.freed_bytes += info.st_size
        return path.parent

    def compress(self, logical: str, entry: Entry | None, summary: Summary) -> None:
        _, source = self.resolve(logical)
        if not source.name.endswith(".jsonl"):
            raise RetentionError("solo se comprime un .jsonl: " + logical)
        target = source.with_name(source.name + ".gz")
        temporary = source.with_name(source.name + ".gz.tmp")
        with open(os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC), "rb") as original:
            before = os.fstat(original.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise RetentionError("no es un fichero normal: " + logical)
            if entry is not None and entry.identity is not None and entry.identity != _identity(before):
                summary.deferred += 1
                return
            previous = _lstat(target)
            if previous is not None and not stat.S_ISREG(previous.st_mode):
                raise RetentionError("el .gz no es un fichero normal: " + logical)
            if previous is not None and previous.st_mtime_ns == before.st_mtime_ns \
                    and self.packed_tail_matches(target, original, before.st_size):
                # Una pasada anterior se cortó entre el renombrado y el borrado del original.
                self.finish_interrupted(logical, source, before, summary)
                return
            self.write_and_commit(logical, original, before, source, target, temporary, previous, summary)

    def write_and_commit(self, logical, original, before, source, target, temporary, previous, summary):
        leftover = _lstat(temporary)
        if leftover is not None:
            # Con la raíz bajo cerrojo, un temporal solo puede ser de una pasada que se cortó.
            if stat.S_ISDIR(leftover.st_mode):
                raise RetentionError("el temporal es una carpeta: " + logical)
            os.unlink(temporary)
        mode = stat.S_IMODE(before.st_mode)
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        committed = False
        try:
            with open(descriptor, "wb") as out:
                os.fchmod(out.fileno(), mode)
                if os.geteuid() == 0 and (before.st_uid, before.st_gid) != (0, 0):
                    os.fchown(out.fileno(), before.st_uid, before.st_gid)
                offset = 0
                if previous is not None:
                    with open(os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC), "rb") as old:
                        if _identity(os.fstat(old.fileno())) != _identity(previous):
                            summary.deferred += 1
                            return
                        offset = _copy(old, out)
                digest, length = hashlib.sha256(), 0
                original.seek(0)
                # Otro miembro gzip al final: `gzip -dc` devuelve lo viejo y después lo nuevo.
                with gzip.GzipFile(filename=source.name, mode="wb", fileobj=out, compresslevel=COMPRESS_LEVEL,
                                   mtime=max(0, int(before.st_mtime))) as packed:
                    for chunk in iter(lambda: original.read(CHUNK_BYTES), b""):
                        digest.update(chunk)
                        length += len(chunk)
                        packed.write(chunk)
                out.flush()
                os.fsync(out.fileno())
                self.verify(temporary, offset, length, digest.digest())
                self.failpoint("comprimido", logical)
                current = _lstat(source)
                if length != before.st_size or current is None or _identity(current) != _identity(before):
                    summary.deferred += 1
                    return
                if self.guard(logical):
                    return
                now_target = _lstat(target)
                if (None if now_target is None else _identity(now_target)) != \
                        (None if previous is None else _identity(previous)):
                    summary.deferred += 1
                    return
                if os.utime in os.supports_fd:
                    os.utime(out.fileno(), ns=(before.st_atime_ns, before.st_mtime_ns))
                else:
                    os.utime(temporary, ns=(before.st_atime_ns, before.st_mtime_ns))
                os.fsync(out.fileno())
                packed_size = os.fstat(out.fileno()).st_size
            os.replace(temporary, target)
            committed = True
            _sync_dir(source.parent)
        finally:
            if not committed and _lstat(temporary) is not None:
                os.unlink(temporary)
        self.failpoint("renombrado", logical)
        final = _lstat(source)
        if final is None or _identity(final) != _identity(before):
            # La IA escribió justo ahora: se deshace el `.gz` y el original sigue mandando.
            if previous is None:
                os.unlink(target)
            else:
                os.truncate(target, previous.st_size)
                os.utime(target, ns=(previous.st_atime_ns, previous.st_mtime_ns))
            summary.deferred += 1
            return
        os.unlink(source)
        _sync_dir(source.parent)
        summary.compressed += 1
        summary.freed_bytes += before.st_size - (packed_size - (previous.st_size if previous is not None else 0))

    def finish_interrupted(self, logical, source, before, summary):
        if self.guard(logical):
            return
        current = _lstat(source)
        if current is None or _identity(current) != _identity(before):
            summary.deferred += 1
            return
        os.unlink(source)
        _sync_dir(source.parent)
        summary.compressed += 1
        summary.freed_bytes += before.st_size

    @staticmethod
    def verify(temporary, offset: int, length: int, digest: bytes) -> None:
        """Equivalente a `gzip -t` del temporal entero, y el miembro nuevo igual al original."""
        try:
            with open(temporary, "rb") as raw:
                if offset:
                    with gzip.GzipFile(fileobj=raw, mode="rb") as whole:
                        while whole.read(CHUNK_BYTES):
                            pass
                    raw.seek(offset)
                check, total = hashlib.sha256(), 0
                with gzip.GzipFile(fileobj=raw, mode="rb") as tail:
                    for chunk in iter(lambda: tail.read(CHUNK_BYTES), b""):
                        check.update(chunk)
                        total += len(chunk)
        except (OSError, EOFError, zlib.error) as error:
            raise RetentionError("el temporal no supera la comprobación") from error
        if total != length or check.digest() != digest:
            raise RetentionError("el temporal no devuelve el original")

    @staticmethod
    def packed_tail_matches(target, original, size: int) -> bool:
        """¿El `.gz` ya termina exactamente con el contenido del original?"""
        expected = hashlib.sha256()
        original.seek(0)
        for chunk in iter(lambda: original.read(CHUNK_BYTES), b""):
            expected.update(chunk)
        try:
            total = 0
            with gzip.open(target, "rb") as packed:
                for chunk in iter(lambda: packed.read(CHUNK_BYTES), b""):
                    total += len(chunk)
            if total < size:
                return False
            skip, check = total - size, hashlib.sha256()
            with gzip.open(target, "rb") as packed:
                while skip:
                    chunk = packed.read(min(CHUNK_BYTES, skip))
                    if not chunk:
                        return False
                    skip -= len(chunk)
                for chunk in iter(lambda: packed.read(CHUNK_BYTES), b""):
                    check.update(chunk)
        except (OSError, EOFError, zlib.error):
            return False
        finally:
            original.seek(0)
        return check.digest() == expected.digest()

    @staticmethod
    def prune(folder: Path, root: Path) -> None:
        """Quita las carpetas que se quedaron vacías hacia arriba; la raíz, nunca."""
        root, folder = os.path.abspath(root), os.path.abspath(folder)
        while folder != root and folder.startswith(root + os.sep):
            try:
                os.rmdir(folder)
            except OSError:
                return
            folder = os.path.dirname(folder)


# ----- una pasada -----

@contextlib.contextmanager
def locked_roots(roots: dict):
    """Cerrojo `flock` sobre cada raíz (carpeta real, sin enlaces); None si otra pasada la tiene."""
    with contextlib.ExitStack() as stack:
        held = {}
        for name, root in roots.items():
            try:
                descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            except OSError:
                continue  # No existe, o es un enlace o no es una carpeta: se ignora.
            stack.callback(os.close, descriptor)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                yield None
                return
            held[name] = Path(root)
        yield held


def log_to_stderr(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def run(*, roots: dict | None = None, state_paths: Iterable = (), state_texts: Iterable[str] = (),
        sessions_dir=None, clock=time.time, monotonic=time.monotonic, alive=pid_alive,
        policy: Policy = Policy(), failpoint=None, log: Callable[[str], None] = log_to_stderr) -> Summary:
    """Una pasada completa: conjunto protegido, escaneo, plan y ejecución; deja una línea en el registro."""
    roots = default_roots() if roots is None else roots
    sessions_dir = Path.home() / ".claude" / "sessions" if sessions_dir is None else sessions_dir
    state_paths, state_texts = tuple(state_paths), tuple(state_texts)

    def read_protected():
        return protected_ids(state_paths=state_paths, state_texts=state_texts, sessions_dir=sessions_dir,
                             alive=alive)

    try:
        protected = read_protected()
    except ProtectedSetUnavailable as error:
        log("Conversaciones de las IAs: no se toca nada esta hora, " + str(error))
        return Summary(failures=1)
    with locked_roots(roots) as held:
        if held is None:
            return Summary()  # Otra pasada de UniConnect está con estas mismas raíces.
        entries = scan(held, clock())
        chosen = plan(entries, protected, policy)
        guard = ProtectionGuard(read_protected, protected, monotonic=monotonic)
        summary = RetentionExecutor(held, guard=guard, failpoint=failpoint).apply(chosen, entries)
    if summary.eventful:
        log(summary.describe())
    return summary


# ----- en el escritorio -----

class RetentionSchedule:
    """Lanza una pasada poco después de arrancar y luego cada hora, en un hilo propio.

    El temporizador corre en el hilo GTK y solo copia el estado en memoria (más reciente
    que el `state.json` del disco, que se guarda cada 8 s); la pasada va en un hilo
    aparte y nunca hay dos a la vez. Solo programa la instancia dueña del estado
    por omisión del usuario: una con `--state-dir` (pruebas, ensayos) no conoce las
    ventanas de verdad y protegería de menos. GLib solo se importa al arrancar, para
    poder componer el programador con ventanas falsas.
    """

    FIRST_DELAY_SECONDS = 60
    INTERVAL_SECONDS = 3600

    def __init__(self, window, *, runner=run, timer=None, cancel=None, spawn=None,
                 first_delay: int = FIRST_DELAY_SECONDS, interval: int = INTERVAL_SECONDS,
                 user_state_root=None, log: Callable[[str], None] = log_to_stderr):
        self.window, self.runner, self.log = window, runner, log
        self.timer, self.cancel = timer, cancel
        self.spawn = spawn or self.background
        self.first_delay, self.interval = first_delay, interval
        self.user_state_root = user_state_root
        self.source = None
        self.running = False

    def owns_user_state(self) -> bool:
        try:
            root = self.user_state_root
            if root is None:
                from .vault import default_root
                root = default_root()
            return os.path.realpath(self.window.store.root) == os.path.realpath(root)
        except Exception:
            return False

    def start(self) -> None:
        if self.source is not None or not self.owns_user_state():
            return
        if self.timer is None:
            from gi.repository import GLib
            self.timer, self.cancel = GLib.timeout_add_seconds, GLib.source_remove
        self.source = self.timer(self.first_delay, self.first)

    def stop(self) -> None:
        if self.source is not None and self.cancel is not None:
            self.cancel(self.source)
        self.source = None

    def first(self) -> bool:
        self.source = None
        if self.window._closed:
            return False
        self.launch()
        self.source = self.timer(self.interval, self.hourly)
        return False

    def hourly(self) -> bool:
        if self.window._closed:
            self.source = None
            return False
        self.launch()
        return True

    def launch(self) -> bool:
        if self.running:
            return False
        store = self.window.store
        try:
            snapshot = json.dumps(store.data, ensure_ascii=False, default=str)
        except Exception:
            snapshot = ""  # Queda el `state.json` del disco, que se lee en el hilo.
        state_path = store.path
        self.running = True

        def work():
            try:
                summary = self.runner(state_paths=(state_path,), state_texts=(snapshot,))
                log = getattr(self.window, "event_log", None)
                if log is not None and summary is not None:
                    log.info("retention", "retention.pass", detail={
                        key: getattr(summary, key, None) for key in ("compressed", "deleted", "failures", "deferred")})
            except Exception as error:
                self.log("Conversaciones de las IAs: la pasada falló (%s)" % type(error).__name__)
            finally:
                self.running = False

        try:
            self.spawn(work)
        except Exception:
            self.running = False
            return False
        return True

    @staticmethod
    def background(work) -> None:
        # Sin bajar la prioridad del hilo: con el GIL, un hilo a nice 19 desplanificado
        # haría esperar al de GTK. zlib, hashlib y la E/S ya sueltan el GIL al trabajar.
        threading.Thread(target=work, name="uniconnect-retencion", daemon=True).start()
