"""A loopback-only RFB clipboard peer on the disposable CI X display."""

import os
import re
import socket
import struct
import subprocess
import tempfile
import threading
import time
import ctypes


class VNCClipboardPeer:
    def __init__(self, direction="send"):
        if direction not in ("send", "recv"):
            raise ValueError("VNC test direction must be send or recv")
        self.direction = direction

    def __enter__(self):
        self.directory = tempfile.TemporaryDirectory(prefix='uc-vnc-copy-')
        with socket.socket() as port:
            port.bind(('127.0.0.1', 0))
            self.port = port.getsockname()[1]
        server_env = os.environ.copy()
        # In a headless Xvfb there is no window manager to disappear. Without
        # this x11vnc delays creating its selection-owner window for 45s, so a
        # clipboard message sent as soon as RFB is ready races initialization.
        server_env['X11VNC_AVOID_WINDOWS'] = 'never'
        self.server = subprocess.Popen(['x11vnc', '-display', os.environ['DISPLAY'], '-localhost',
            '-rfbport', str(self.port), '-nopw', '-shared', '-forever', '-noxdamage', '-debug_sel',
            '-seldir', self.direction,
            '-o', self.directory.name + '/log'], env=server_env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Wait for the bound socket, not a version-specific stdout line.
        deadline = time.monotonic() + 5
        while self.server.poll() is None and time.monotonic() < deadline:
            try:
                with socket.create_connection(('127.0.0.1', self.port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.05)
        else:
            log = self.server_log()
            self.__exit__(None, None, None)
            raise RuntimeError('CI VNC server failed to start: ' + log)
        self.socket = socket.create_connection(('127.0.0.1', self.port), timeout=8)
        self._read(12)
        self.socket.sendall(b'RFB 003.008\n')
        count = self._read(1)[0]
        if 1 not in self._read(count):
            raise RuntimeError('Unexpected CI VNC authentication')
        self.socket.sendall(b'\x01')
        if self._read(4) != b'\0\0\0\0':
            raise RuntimeError('CI VNC handshake failed')
        self.socket.sendall(b'\x01')  # Shared: never evict another connection.
        header = self._read(24)
        self.pixel_bytes = header[4] // 8
        self._read(struct.unpack('!I', header[20:24])[0])
        self.socket.sendall(b'\x02\0\0\x01' + struct.pack('!i', 0))
        self.socket.sendall(b'\x03\0' + struct.pack('!HHHH', 0, 0, 1, 1))
        self._wait_for_selection_owner()
        # The handshake uses a deadline; the long-lived RFB reader must not
        # time out and silently stop before the desktop changes its clipboard.
        self.socket.settimeout(None)
        self.received, self.error = [], None
        self.ready = False
        self.reader = threading.Thread(target=self._receive, daemon=True)
        self.reader.start()
        return self

    def _wait_for_selection_owner(self):
        self.x11 = ctypes.CDLL('libX11.so.6')
        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        self.x11.XInternAtom.restype = ctypes.c_ulong
        self.x11.XGetSelectionOwner.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.x11.XGetSelectionOwner.restype = ctypes.c_ulong
        self.x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.x11.XCloseDisplay.restype = ctypes.c_int
        self.display = self.x11.XOpenDisplay(None)
        if not self.display:
            raise RuntimeError('Cannot open CI X display to inspect VNC clipboard owner')
        atom = self.x11.XInternAtom(self.display, b'CLIPBOARD', 0)
        deadline = time.monotonic() + 5
        self.selection_window = None
        while self.server.poll() is None and time.monotonic() < deadline:
            match = re.search(r'created selwin:\s+0x([0-9a-fA-F]+)', self.server_log())
            if match:
                self.selection_window = int(match.group(1), 16)
                owner = self.x11.XGetSelectionOwner(self.display, atom)
                if owner == self.selection_window:
                    return
            time.sleep(0.05)
        log = self.server_log()
        self.__exit__(None, None, None)
        raise RuntimeError('CI VNC selection owner did not become ready: '
                           f'window={self.selection_window!r}; log={log!r}')

    def server_log(self):
        try:
            with open(self.directory.name + '/log', encoding='utf-8', errors='replace') as log:
                return log.read()[-4000:]
        except OSError:
            return "unavailable"

    def _read(self, length):
        data = b''
        while len(data) < length:
            part = self.socket.recv(length - len(data))
            if not part:
                raise EOFError()
            data += part
        return data

    def _receive(self):
        try:
            while True:
                kind = self._read(1)[0]
                if kind == 0:
                    header = self._read(3)
                    for _ in range(struct.unpack('!H', header[1:])[0]):
                        x, y, width, height, encoding = struct.unpack('!HHHHi', self._read(12))
                        if encoding != 0:
                            raise RuntimeError('Unexpected CI RFB encoding')
                        self._read(width * height * self.pixel_bytes)
                    self.ready = True
                    continue
                if kind == 2:  # Bell; no framebuffer updates are requested.
                    continue
                if kind != 3:
                    raise RuntimeError('Unexpected RFB clipboard message')
                header = self._read(7)
                self.received.append(self._read(struct.unpack('!I', header[3:])[0]).decode('latin-1'))
        except Exception as error:
            self.error = type(error).__name__

    def send(self, text):
        data = text.encode('latin-1')
        self.socket.sendall(b'\x06\0\0\0' + struct.pack('!I', len(data)) + data)

    def __exit__(self, *_):
        if getattr(self, 'socket', None):
            self.socket.close()
        if getattr(self, 'display', None):
            self.x11.XCloseDisplay(self.display)
            self.display = None
        if getattr(self, 'server', None):
            if self.server.poll() is None:
                self.server.terminate()
                try:
                    self.server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.server.kill()
                    self.server.wait(timeout=5)
        self.directory.cleanup()
