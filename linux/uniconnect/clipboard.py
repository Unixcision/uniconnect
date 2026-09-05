"""Asynchronous GTK clipboard images with a private, bounded PNG cache.

The UI routes the returned file through the same upload action as a file drop.
An SSH caller releases it after upload; a local caller may retain it until the
agent has read it. Text stays text and never becomes a temporary file.
"""

from __future__ import annotations

import os
import re
import stat
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GLib, Gtk


class ClipboardError(RuntimeError):
    """Clipboard failure with a stable code suitable for localized UI handling."""

    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


class ClipboardImages:
    """Read clipboard data without blocking the main loop or altering its contents."""

    _NAME = re.compile(r"clipboard-[0-9a-f]{32}\.png\Z")
    _TEMP_NAME = re.compile(r"\.clipboard-[0-9a-f]{32}\.png\.tmp\Z")

    def __init__(self, cache_dir: str | Path | None = None, *, max_files: int = 32,
                 max_bytes: int = 256 * 1024 * 1024, max_age: float = 24 * 3600,
                 clock: Callable[[], float] = time.time):
        base = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
        self.cache_dir = Path(cache_dir) if cache_dir is not None else base / "uniconnect" / "clipboard"
        self.max_files, self.max_bytes, self.max_age = max_files, max_bytes, max_age
        self.clock = clock
        self._requests = {}
        self._cancellations = {}
        self._held: set[Path] = set()
        self._closed = False
        self._workers = ThreadPoolExecutor(max_workers=2, thread_name_prefix="uniconnect-clipboard")
        self._prepare_cache()
        self.prune()

    def _prepare_cache(self) -> None:
        self.cache_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.cache_dir.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
            raise ClipboardError("unsafe_clipboard_cache")
        os.chmod(self.cache_dir, 0o700)

    def request(self, on_image: Callable[[Path], None], on_text: Callable[[str], None],
                on_error: Callable[[Exception], None], *, clipboard=None) -> str:
        """Return a cancellable request ID; callbacks always run on the GTK thread."""
        if self._closed:
            raise ClipboardError("clipboard_reader_closed")
        identifier = uuid.uuid4().hex
        selection = clipboard if clipboard is not None else Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        self._requests[identifier] = (on_image, on_text, on_error)
        self.prune()
        selection.request_targets(self._targets, identifier)
        return identifier

    def cancel(self, request_id: str, on_done: Callable[[], None] | None = None) -> None:
        """Suppress delivery; any already-encoding PNG is removed when encoding ends."""
        self._requests.pop(request_id, None)
        if on_done:
            if self.cache_dir / ("clipboard-" + request_id + ".png") in self._held:
                self._cancellations[request_id] = on_done
            else:
                GLib.idle_add(on_done)

    def _targets(self, clipboard, targets, n_targets, request_id):
        if request_id not in self._requests:
            return
        if targets and Gtk.targets_include_image(targets, False):
            clipboard.request_image(self._image, request_id)
        else:
            clipboard.request_text(self._text, request_id)

    def _text(self, clipboard, text, request_id):
        callbacks = self._requests.pop(request_id, None)
        if callbacks is not None:
            callbacks[1](text or "")

    def _image(self, clipboard, pixbuf, request_id):
        if request_id not in self._requests:
            return
        if pixbuf is None:
            self._failed(request_id, ClipboardError("clipboard_image_unavailable"))
            return
        if pixbuf.get_width() * pixbuf.get_height() > 64 * 1024 * 1024:
            self._failed(request_id, ClipboardError("clipboard_image_too_large"))
            return
        path = self.cache_dir / ("clipboard-" + request_id + ".png")
        self._held.add(path)
        future = self._workers.submit(self._encode, pixbuf, path)

        def encoded(result):
            try:
                result.result()
                GLib.idle_add(self._deliver, request_id, path, None)
            except Exception as error:
                GLib.idle_add(self._deliver, request_id, path, error)

        future.add_done_callback(encoded)

    def _encode(self, pixbuf, path: Path) -> None:
        success, encoded = pixbuf.save_to_bufferv("png", [], [])
        if not success:
            raise ClipboardError("clipboard_encoding_failed")
        data = bytes(encoded)
        if len(data) > self.max_bytes:
            raise ClipboardError("clipboard_image_too_large")
        temporary = self.cache_dir / ("." + path.name + ".tmp")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            # The temporary name is excluded from pruning until its atomic commit.
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

    def _failed(self, request_id, error):
        callbacks = self._requests.pop(request_id, None)
        if callbacks is not None:
            callbacks[2](error)

    def _deliver(self, request_id, path, error):
        callbacks = self._requests.pop(request_id, None)
        if callbacks is None or self._closed:
            self.release(path)
            cancelled = self._cancellations.pop(request_id, None)
            if cancelled:
                cancelled()
            return False
        if error is not None:
            self.release(path)
            callbacks[2](error)
            return False
        try:
            self.prune()
            # Retained active transfers cannot be evicted to fit a new image.
            files = self._files()
            if len(files) > self.max_files or sum(info.st_size for _, info in files) > self.max_bytes:
                raise ClipboardError("clipboard_cache_full")
            callbacks[0](path)
        except Exception as failure:
            self.release(path)
            callbacks[2](failure)
        return False

    def _files(self):
        files = []
        for path in self.cache_dir.iterdir():
            if not self._NAME.fullmatch(path.name):
                continue
            try:
                info = path.lstat()
            except FileNotFoundError:
                continue
            if stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid():
                files.append((path, info))
        return files

    def retain_for_local(self, path: str | Path) -> None:
        """Release the transfer hold but keep a local attachment available until pruning."""
        self._held.discard(Path(path))

    def release(self, path: str | Path) -> None:
        """Remove only a cache file issued by this helper, never an arbitrary path."""
        path = Path(path)
        if path.parent != self.cache_dir or not self._NAME.fullmatch(path.name):
            raise ClipboardError("invalid_clipboard_cache_path")
        self._held.discard(path)
        try:
            info = path.lstat()
        except FileNotFoundError:
            return
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise ClipboardError("unsafe_clipboard_cache_file")
        path.unlink()

    def prune(self) -> None:
        """Evict expired and oldest unheld PNGs within this helper's namespace."""
        # Recover temporary PNGs left by a terminated encoder. The grace period
        # permits another app instance to finish an in-flight atomic write.
        temporary_cutoff = self.clock() - min(self.max_age, 3600)
        for path in self.cache_dir.iterdir():
            if not self._TEMP_NAME.fullmatch(path.name):
                continue
            try:
                info = path.lstat()
                if (stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
                        and info.st_mtime < temporary_cutoff):
                    path.unlink()
            except FileNotFoundError:
                pass
        files = sorted(self._files(), key=lambda item: item[1].st_mtime)
        count, size = len(files), sum(info.st_size for _, info in files)
        cutoff = self.clock() - self.max_age
        for path, info in files:
            if path in self._held:
                continue
            if info.st_mtime < cutoff or count > self.max_files or size > self.max_bytes:
                self.release(path)
                count -= 1
                size -= info.st_size

    def close(self) -> None:
        self._closed = True
        self._requests.clear()
        self._workers.shutdown(wait=False, cancel_futures=False)
