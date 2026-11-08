"""Historial de UniConnect en Linux (contrato log.v1, compartido con el Mac).

Una línea JSON por evento en `~/.uniconnect/logs/uniconnect.jsonl`, con rotación en cascada a
5 MiB × 5. `info`, `warn` y `error` siempre; `debug` solo con el modo depuración, que se
enciende desde la app (casilla de Ajustes o `log.debug` por el socket de control), se guarda en
`settings.log_debug` de `state.json` y se apaga solo a las 24 h.

Registrar nunca rompe nada: un fallo al escribir o rotar se traga, y la rotación fallida deja su
propia línea `log.rotate_failed`. Qué nunca entra: texto de pantalla o terminal, argv o entorno
completos, tokens, contraseñas ni prompts. Un texto de `detail` que no es corto y limpio no se
escribe: va su longitud.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time

LEVELS = ("debug", "info", "warn", "error")
AREAS = ("relaunch", "reconnect", "mobile", "activity", "tree", "ui", "retention", "update", "log")
MAX_BYTES = 5 * 1024 * 1024
KEEP = 5  # uniconnect.jsonl + .1 … .4
DEBUG_SECONDS = 24 * 3600
SAFE_TEXT = re.compile(r"[A-Za-z0-9 _.:/@%+=,()#~-]{0,120}")  # Ids, códigos, rutas, nombres de opciones.


def app_version(source=Path(__file__).resolve().parents[1]):
    """`0.1.0+<commit>` del checkout que corre, como en el contrato; `+unknown` si no se sabe."""
    try:
        commit = subprocess.run(["git", "-C", str(source), "rev-parse", "--short=10", "HEAD"],
                                capture_output=True, text=True, timeout=3).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        commit = ""
    return "0.1.0+" + (commit if re.fullmatch(r"[0-9a-f]{7,40}", commit) else "unknown")


class EventLog:
    def __init__(self, path=None, *, version=None, settings=lambda: {}, save=lambda: None,
                 clock=time.time, max_bytes=MAX_BYTES, keep=KEEP):
        self.path = Path(path) if path is not None else Path.home() / ".uniconnect/logs/uniconnect.jsonl"
        self.version = version or app_version()
        self.settings, self.save, self.clock = settings, save, clock
        self.max_bytes, self.keep = max_bytes, keep
        self.lock = threading.Lock()

    # ----- modo depuración -----

    def debug_until(self):
        """Fin del modo depuración (época) o None si está apagado; lo apaga si ya pasó su hora."""
        settings = self.settings()
        until = settings.get("log_debug_until") if settings.get("log_debug") is True else None
        if not isinstance(until, (int, float)):
            return None
        if self.clock() >= until:
            settings["log_debug"], settings["log_debug_until"] = False, None
            self.write("info", "log", "log.debug_off", detail={"reason": "timeout"})
            self.persist()
            return None
        return until

    def set_debug(self, enabled):
        """Enciende (24 h) o apaga el modo; devuelve lo que responde `log.debug` por el socket."""
        settings = self.settings()
        was = self.debug_until() is not None
        settings["log_debug"] = bool(enabled)
        settings["log_debug_until"] = self.clock() + DEBUG_SECONDS if enabled else None
        if bool(enabled) != was:
            self.write("info", "log", "log.debug_on" if enabled else "log.debug_off",
                       detail=None if enabled else {"reason": "user"})
        self.persist()
        until = settings["log_debug_until"]
        return {"enabled": bool(enabled), "until": self.iso(until) if until else None}

    def persist(self):
        try:
            self.save()
        except Exception:
            pass  # El ajuste vuelve a guardarse con el siguiente guardado de la app.

    # ----- escritura -----

    @staticmethod
    def iso(value):
        moment = datetime.fromtimestamp(value, timezone.utc)
        return moment.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (moment.microsecond // 1000)

    @staticmethod
    def clean_detail(detail):
        """Plano y corto: un texto que no es limpio ni corto se cambia por su longitud."""
        if not isinstance(detail, dict):
            return None
        result = {}
        for key, value in list(detail.items())[:16]:
            if not isinstance(key, str) or not re.fullmatch(r"[a-z_]{1,32}", key):
                continue
            if value is None or isinstance(value, (bool, int, float)):
                result[key] = value
            elif isinstance(value, str):
                result[key] = value if SAFE_TEXT.fullmatch(value) else {"length": len(value)}
            elif isinstance(value, (list, tuple)) and all(isinstance(item, str) and SAFE_TEXT.fullmatch(item)
                                                         for item in value) and len(value) <= 16:
                result[key] = list(value)
            else:
                result[key] = {"length": len(str(value))}
        return result

    def write(self, level, area, event, *, workspace=None, window=None, op=None, detail=None):
        """Una línea de log.v1. Nunca lanza: registrar no puede romper la app."""
        try:
            if level not in LEVELS or area not in AREAS or not re.fullmatch(r"[a-z_]+(\.[a-z_]+)+", event):
                return False
            if level == "debug" and event != "log.debug_off" and self.debug_until() is None:
                return False
            line = {"ts": self.iso(self.clock()), "level": level, "area": area, "event": event,
                    "platform": "linux", "version": self.version}
            for key, value in (("workspace", workspace), ("window", window), ("op", op)):
                if isinstance(value, str) and value:
                    line[key] = value[:64]
            cleaned = self.clean_detail(detail)
            if cleaned:
                line["detail"] = cleaned
            data = (json.dumps(line, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
            with self.lock:
                self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                os.chmod(self.path.parent, 0o700)
                rotate_error = self.rotate(len(data))
                descriptor = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
                try:
                    if rotate_error:
                        failed = {"ts": line["ts"], "level": "warn", "area": "log", "event": "log.rotate_failed",
                                  "platform": "linux", "version": self.version, "detail": {"error": rotate_error}}
                        os.write(descriptor, (json.dumps(failed, separators=(",", ":")) + "\n").encode())
                    os.write(descriptor, data)
                finally:
                    os.close(descriptor)
            return True
        except Exception:
            return False

    def rotate(self, incoming):
        """Cascada `.jsonl` → `.1` → … → `.4` al pasar de max_bytes; devuelve el error o None."""
        try:
            if not self.path.exists() or self.path.stat().st_size + incoming <= self.max_bytes:
                return None
            oldest = self.path.with_name(self.path.name + ".%d" % (self.keep - 1))
            if oldest.exists():
                oldest.unlink()
            for index in range(self.keep - 2, 0, -1):
                source = self.path.with_name(self.path.name + ".%d" % index)
                if source.exists():
                    os.replace(source, self.path.with_name(self.path.name + ".%d" % (index + 1)))
            os.replace(self.path, self.path.with_name(self.path.name + ".1"))
            return None
        except OSError as error:
            return type(error).__name__  # Se sigue escribiendo en el actual (log.v1).

    # Atajos por nivel.
    def info(self, area, event, **fields):
        return self.write("info", area, event, **fields)

    def warn(self, area, event, **fields):
        return self.write("warn", area, event, **fields)

    def error(self, area, event, **fields):
        return self.write("error", area, event, **fields)

    def debug(self, area, event, **fields):
        return self.write("debug", area, event, **fields)


class NullLog:
    """Para tests y superficies sin ventana: acepta todo y no escribe nada."""

    def __getattr__(self, name):
        return lambda *args, **kwargs: False
