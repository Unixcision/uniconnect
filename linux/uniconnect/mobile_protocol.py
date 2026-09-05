"""The shared CMUXMobileCore length-prefixed JSON wire format, not JSONL."""

import json
import struct


MAX_FRAME = 8 * 1024 * 1024


class FrameDecoder:
    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data):
        self.buffer.extend(data)
        if len(self.buffer) > MAX_FRAME + 65540:
            raise ValueError("Trama demasiado grande")
        frames = []
        while len(self.buffer) >= 4:
            length = struct.unpack("!I", self.buffer[:4])[0]
            if not 0 < length <= MAX_FRAME:
                raise ValueError("Longitud de trama no válida")
            if len(self.buffer) < length + 4:
                break
            message = json.loads(bytes(self.buffer[4:4 + length]))
            if not isinstance(message, dict):
                raise ValueError("La petición debe ser un objeto")
            frames.append(message)
            del self.buffer[:4 + length]
        return frames


def encode_frame(message):
    data = json.dumps(message, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()
    if not data or len(data) > MAX_FRAME:
        raise ValueError("Trama demasiado grande")
    return struct.pack("!I", len(data)) + data


class RPCError(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message
        super().__init__(message)

    def response(self, identifier, translate=lambda value: value):
        return {"id": identifier, "ok": False, "error": {"code": self.code, "message": translate(self.message)}}
