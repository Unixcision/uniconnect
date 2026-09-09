"""A loopback-only RFB clipboard peer on the disposable CI X display."""

import os
import socket
import struct
import subprocess
import tempfile
import threading


class VNCClipboardPeer:
    def __enter__(self):
        self.directory = tempfile.TemporaryDirectory(prefix='uc-vnc-copy-')
        with socket.socket() as port:
            port.bind(('127.0.0.1', 0))
            self.port = port.getsockname()[1]
        self.server = subprocess.Popen(['x11vnc', '-display', os.environ['DISPLAY'], '-localhost',
            '-rfbport', str(self.port), '-nopw', '-shared', '-forever', '-noxdamage', '-quiet',
            '-o', self.directory.name + '/log'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        # x11vnc emits PORT after binding; no arbitrary startup sleep.
        if not self.server.stdout.readline().startswith('PORT='):
            self.__exit__(None, None, None)
            raise RuntimeError('CI VNC server failed to start')
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
        self.received, self.error = [], None
        self.ready = False
        self.reader = threading.Thread(target=self._receive, daemon=True)
        self.reader.start()
        return self

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
        if getattr(self, 'server', None):
            self.server.terminate()
            self.server.wait(timeout=5)
            self.server.stdout.close()
        self.directory.cleanup()
