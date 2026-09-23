"""Bandeja de entrada del móvil (contrato inbox.v1): lo que hay en `~/UniConnect/Entrada`.

El móvil necesita tres cosas de esa carpeta: ver qué hay (con tamaño, fecha y tipo, para
enseñar una vista previa y volver a pegar la ruta), leer un archivo por trozos (para la
vista previa y para reproducir audio y vídeo), y borrar con criterio (todo, lo anterior a
unos días o lo que pasa de un tamaño) sabiendo antes cuánto se va a liberar.

Nada de esto puede salir de la carpeta: cada ruta se resuelve y se comprueba que cuelga de
ella, los enlaces simbólicos no se siguen, y los `.part` de subidas en marcha ni se listan
ni se borran. Ni el contenido ni los nombres se registran en ningún log.
"""

from __future__ import annotations

import base64
import os
import stat
import time
from pathlib import Path
from typing import Callable

from .mobile_protocol import RPCError

READ_CHUNK_BYTES = 1024 * 1024
MAX_LIST = 500

_KINDS = {
    "image": {"jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg"},
    "video": {"mp4", "mov", "m4v", "webm", "mkv", "avi", "3gp"},
    "audio": {"mp3", "m4a", "aac", "wav", "ogg", "oga", "opus", "flac", "amr"},
    "document": {"pdf", "txt", "md", "csv", "json", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "zip"},
}


def kind_of(name: str) -> str:
    """Tipo para la vista previa, por extensión: image, video, audio, document u other."""
    extension = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    for kind, extensions in _KINDS.items():
        if extension in extensions:
            return kind
    return "other"


class Inbox:
    """Una carpeta de entrada. `root` se inyecta para que los tests usen una temporal."""

    def __init__(self, root: str | Path, *, clock: Callable[[], float] = time.time):
        self.root = Path(root)
        self.clock = clock

    # ----- recorrido seguro -----

    def _real_root(self) -> str:
        return os.path.realpath(self.root)

    def _files(self):
        """Archivos normales de la bandeja; sin ocultos, sin `.part`, sin seguir enlaces."""
        if not self.root.is_dir():
            return
        for directory, subdirs, names in os.walk(self.root, followlinks=False):
            subdirs[:] = [d for d in subdirs if not d.startswith(".")]
            for name in names:
                if name.startswith(".") or name.endswith(".part"):
                    continue
                path = Path(directory) / name
                try:
                    info = path.lstat()
                except OSError:
                    continue
                if stat.S_ISREG(info.st_mode):
                    yield path, info

    def resolve(self, relative) -> Path:
        """Ruta relativa a la bandeja → ruta real, solo si es un archivo normal dentro de ella."""
        if not isinstance(relative, str) or not relative or len(relative) > 1024 or "\0" in relative:
            raise RPCError("invalid_params", "Ruta no válida")
        if os.path.isabs(relative) or ".." in Path(relative).parts:
            raise RPCError("invalid_params", "Ruta fuera de la bandeja")
        path = self.root / relative
        real = os.path.realpath(path)
        if not real.startswith(self._real_root() + os.sep):
            raise RPCError("invalid_params", "Ruta fuera de la bandeja")
        try:
            info = path.lstat()
        except FileNotFoundError:
            raise RPCError("not_found", "El archivo ya no está en la bandeja")
        if not stat.S_ISREG(info.st_mode) or path.name.endswith(".part"):
            raise RPCError("invalid_params", "No es un archivo de la bandeja")
        return path

    def _entry(self, path: Path, info) -> dict:
        return {"path": str(path.relative_to(self.root)), "absolute": str(path), "name": path.name,
                "size": info.st_size, "modified": int(info.st_mtime), "kind": kind_of(path.name)}

    # ----- inbox.list -----

    def list(self, limit: int = 200, offset: int = 0) -> dict:
        """Lo más nuevo primero, con el total de la carpeta entera (no solo de la página)."""
        files = sorted(self._files(), key=lambda item: item[1].st_mtime, reverse=True)
        total = sum(info.st_size for _, info in files)
        page = files[offset:offset + max(0, min(limit, MAX_LIST))]
        return {"root": str(self.root), "count": len(files), "total_bytes": total,
                "oldest": int(files[-1][1].st_mtime) if files else None,
                "newest": int(files[0][1].st_mtime) if files else None,
                "entries": [self._entry(path, info) for path, info in page]}

    # ----- inbox.delete -----

    def delete(self, *, everything: bool = False, older_than_days: float | None = None,
               larger_than_bytes: int | None = None, paths=None, dry_run: bool = False) -> dict:
        """Borra lo que cumple TODOS los criterios dados (o `everything`, o `paths` concretas).

        Sin ningún criterio no borra nada: un filtro vacío que lo borrase todo es justo el
        accidente que no se puede deshacer. `dry_run` devuelve lo mismo sin tocar disco, para
        enseñar antes cuánto se va a liberar.
        """
        if paths is not None:
            if not isinstance(paths, list) or len(paths) > MAX_LIST:
                raise RPCError("invalid_params", "Lista de rutas no válida")
            chosen = []
            for relative in paths:
                path = self.resolve(relative)
                chosen.append((path, path.lstat()))
        else:
            if not everything and older_than_days is None and larger_than_bytes is None:
                raise RPCError("invalid_params", "Falta un criterio de borrado")
            limit_time = self.clock() - older_than_days * 86400 if older_than_days is not None else None
            chosen = [(path, info) for path, info in self._files()
                      if everything or ((limit_time is None or info.st_mtime < limit_time)
                                        and (larger_than_bytes is None or info.st_size > larger_than_bytes))]
        freed, deleted = 0, 0
        if not dry_run:
            for path, info in chosen:
                try:
                    path.unlink()
                except FileNotFoundError:
                    continue
                freed += info.st_size
                deleted += 1
            self._remove_empty_directories()
        else:
            freed, deleted = sum(info.st_size for _, info in chosen), len(chosen)
        remaining = list(self._files())
        return {"dry_run": dry_run, "deleted": deleted, "freed_bytes": freed,
                "remaining_count": len(remaining) if not dry_run else len(remaining) - deleted,
                "remaining_bytes": sum(info.st_size for _, info in remaining) - (freed if dry_run else 0)}

    def _remove_empty_directories(self):
        """Quita las carpetas de día que se han quedado vacías; nunca la raíz."""
        if not self.root.is_dir():
            return
        for directory, _, _ in sorted(os.walk(self.root, followlinks=False), key=lambda item: -len(item[0])):
            path = Path(directory)
            if path == self.root or path.is_symlink():
                continue
            try:
                path.rmdir()  # Solo si está vacía.
            except OSError:
                pass

    # ----- inbox.read -----

    def read(self, relative, offset: int = 0, length: int = READ_CHUNK_BYTES) -> dict:
        """Un trozo del archivo en base64, para la vista previa o para reproducirlo en el móvil."""
        if type(offset) is not int or offset < 0 or type(length) is not int or length <= 0:
            raise RPCError("invalid_params", "Desplazamiento o longitud no válidos")
        path = self.resolve(relative)
        size = path.lstat().st_size
        length = min(length, READ_CHUNK_BYTES)
        with open(path, "rb") as handle:
            handle.seek(offset)
            data = handle.read(length)
        return {"path": relative, "size": size, "offset": offset,
                "data": base64.b64encode(data).decode("ascii"), "eof": offset + len(data) >= size}
