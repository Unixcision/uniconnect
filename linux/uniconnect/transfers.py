"""SFTP v3 uploads with acknowledged byte progress and cancellation.

OpenSSH carries the connection; this small protocol client avoids exposing a
password in scp arguments or approximating upload progress from a local copy.
"""

from __future__ import annotations

import os
import posixpath
import selectors
import struct
import subprocess
import threading
import time
import uuid
from pathlib import Path
from typing import Callable

from .transport import SSHCommand, TransportError


class SFTPTransfer:
    """One upload; call run in a worker thread and cancel from the UI thread."""

    def __init__(self, command: SSHCommand | str, *, timeout: float = 120):
        self.command = SSHCommand.parse(command) if isinstance(command, str) else command
        self.timeout = timeout
        self.cancelled = threading.Event()
        self._process: subprocess.Popen | None = None
        self._selector: selectors.BaseSelector | None = None
        self._write_selector: selectors.BaseSelector | None = None
        self._sequence = 0
        self._deadline = 0.0

    def cancel(self) -> None:
        self.cancelled.set()

    @staticmethod
    def _string(value: bytes | str) -> bytes:
        data = value.encode("utf-8") if isinstance(value, str) else value
        return struct.pack(">I", len(data)) + data

    def _receive(self, count: int, *, cleanup: bool = False) -> bytes:
        output = bytearray()
        while len(output) < count:
            if self.cancelled.is_set() and not cleanup:
                raise TransportError("upload_cancelled")
            if time.monotonic() >= self._deadline:
                raise TransportError("upload_timeout")
            if not self._selector.select(timeout=min(0.2, max(0.001, self._deadline - time.monotonic()))):
                continue
            chunk = os.read(self._process.stdout.fileno(), count - len(output))
            if not chunk:
                raise TransportError("sftp_connection_closed")
            output.extend(chunk)
        return bytes(output)

    def _packet(self, *, cleanup: bool = False) -> tuple[int, bytes]:
        size, = struct.unpack(">I", self._receive(4, cleanup=cleanup))
        if not 1 <= size <= 4 * 1024 * 1024:
            raise TransportError("invalid_sftp_response")
        packet = self._receive(size, cleanup=cleanup)
        return packet[0], packet[1:]

    def _send(self, kind: int, payload: bytes, *, cleanup: bool = False) -> None:
        data = bytes((kind,)) + payload
        data = memoryview(struct.pack(">I", len(data)) + data)
        try:
            while data:
                if self.cancelled.is_set() and not cleanup:
                    raise TransportError("upload_cancelled")
                if time.monotonic() >= self._deadline:
                    raise TransportError("upload_timeout")
                if not self._write_selector.select(timeout=0.2):
                    continue
                try:
                    sent = os.write(self._process.stdin.fileno(), data)
                    data = data[sent:]
                except BlockingIOError:
                    continue
        except (BrokenPipeError, OSError) as exc:
            raise TransportError("sftp_connection_closed") from exc

    def _request(self, kind: int, payload: bytes, *, expected: int = 101, cleanup: bool = False) -> bytes:
        self._sequence += 1
        self._send(kind, struct.pack(">I", self._sequence) + payload, cleanup=cleanup)
        response, data = self._packet(cleanup=cleanup)
        if len(data) < 4 or struct.unpack(">I", data[:4])[0] != self._sequence:
            raise TransportError("invalid_sftp_response")
        data = data[4:]
        if response == 101:
            if len(data) < 4:
                raise TransportError("invalid_sftp_response")
            status, = struct.unpack(">I", data[:4])
            if status:
                detail = str(status)
                if len(data) >= 8:
                    size, = struct.unpack(">I", data[4:8])
                    detail = data[8:8 + size].decode("utf-8", "replace")
                raise TransportError("sftp_operation_failed", detail)
        if response != expected:
            raise TransportError("unexpected_sftp_response", str(response))
        return data

    def _start(self) -> None:
        # Subsystem mode bypasses a remote shell entirely.
        self._process = subprocess.Popen(
            self.command.argv("sftp", batch=True, extra=("-s",)),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=self.command.environment(), bufsize=0, start_new_session=True,
        )
        self._selector = selectors.DefaultSelector()
        self._selector.register(self._process.stdout, selectors.EVENT_READ)
        os.set_blocking(self._process.stdin.fileno(), False)
        self._write_selector = selectors.DefaultSelector()
        self._write_selector.register(self._process.stdin, selectors.EVENT_WRITE)
        self._deadline = time.monotonic() + self.timeout
        self._send(1, struct.pack(">I", 3))
        kind, data = self._packet()
        if kind != 2 or len(data) < 4 or struct.unpack(">I", data[:4])[0] != 3:
            raise TransportError("unsupported_sftp_version")

    def _close(self) -> None:
        if self._selector:
            self._selector.close()
        if self._write_selector:
            self._write_selector.close()
        if self._process:
            if self._process.stdin:
                self._process.stdin.close()
            if self._process.stdout:
                self._process.stdout.close()
            try:
                self._process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._process.terminate()
                try:
                    self._process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self._process.kill()
                    self._process.wait()

    def run(self, local_path: str | Path, remote_directory: str,
            progress: Callable[[int, int], None] | None = None) -> str:
        """Upload to an existing absolute directory and return the final remote path.

        Each filename contains a random transfer ID, and partial data is renamed
        only after the server acknowledges all bytes and closes the file.
        """
        local_path = Path(local_path).expanduser().resolve(strict=True)
        if not local_path.is_file():
            raise TransportError("upload_not_regular_file")
        if not remote_directory.startswith("/") or "\0" in remote_directory:
            raise TransportError("invalid_upload_directory")
        total = local_path.stat().st_size
        identifier = uuid.uuid4().hex[:12]
        name = identifier + "-" + local_path.name
        final_path = posixpath.join(remote_directory, name)
        temporary_path = final_path + ".partial"
        temporary_created = False
        try:
            if self.cancelled.is_set():
                raise TransportError("upload_cancelled")
            self._start()
            # WRITE | CREAT | EXCL, permissions=0600. Never overwrite an existing file.
            data = self._request(3, self._string(temporary_path) + struct.pack(">III", 0x2 | 0x8 | 0x20, 0x4, 0o600), expected=102)
            if len(data) < 4:
                raise TransportError("invalid_sftp_response")
            size, = struct.unpack(">I", data[:4])
            handle = data[4:4 + size]
            if len(handle) != size:
                raise TransportError("invalid_sftp_response")
            temporary_created = True
            completed = 0
            if progress:
                progress(0, total)
            with local_path.open("rb") as stream:
                while chunk := stream.read(32768):
                    if self.cancelled.is_set():
                        raise TransportError("upload_cancelled")
                    self._request(6, self._string(handle) + struct.pack(">Q", completed) + self._string(chunk))
                    completed += len(chunk)
                    if progress:
                        progress(completed, total)
            self._request(4, self._string(handle))
            self._request(18, self._string(temporary_path) + self._string(final_path))
            temporary_created = False
            return final_path
        except BaseException as exc:
            if temporary_created and self._process and self._process.poll() is None:
                try:
                    self._deadline = time.monotonic() + 3
                    self._request(13, self._string(temporary_path), cleanup=True)
                except (TransportError, OSError):
                    # Exact path is surfaced so the caller can retry cleanup; never
                    # report success or insert a local path into the remote shell.
                    if isinstance(exc, TransportError):
                        exc.detail += " partial=" + temporary_path
            raise
        finally:
            self._close()
