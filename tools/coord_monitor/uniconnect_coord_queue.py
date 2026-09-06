"""Coalesce only authenticated CODEX VPS coordination notices; never start a turn."""

import hashlib
import json
import os
from pathlib import Path
import re
import select
import stat
import subprocess
import time
from uuid import UUID, NAMESPACE_URL, uuid5

PREFIX = "CODEX VPS: cambio en el canal local de coordinación /tmp/coord5Sep.md,"
EVENT_ROOT = Path("/root/.local/state/uniconnect-branch-monitor/coord5Sep/events")
METHODS = {"initialize", *("thread/queue/" + name for name in ("list", "add", "update", "delete"))}


class QueueError(RuntimeError):
    """A non-secret transport or validation failure."""


class QueueClient:
    """A transient stdio control client with one deadline, no session startup RPC."""

    def __init__(self):
        self.deadline = time.monotonic() + 14
        self.process = None
        self.buffer = b""
        self.identifier = 0

    def __enter__(self):
        try:
            self.process = subprocess.Popen(
                ["/usr/bin/codex", "app-server", "--stdio"], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0,
            )
            os.set_blocking(self.process.stdin.fileno(), False)
            os.set_blocking(self.process.stdout.fileno(), False)
            self.call("initialize", {"clientInfo": {"name": "uniconnect_coord", "version": "1"},
                                     "capabilities": {"experimentalApi": True}})
            self.send({"method": "initialized"})
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *_):
        if self.process is None:
            return
        self.process.stdin.close()
        try:
            self.process.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            self.process.terminate()  # Only our transient control process.
            try:
                self.process.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=0.2)
        finally:
            self.process.stdout.close()

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise QueueError("queue-timeout")
        return remaining

    def send(self, value):
        data = (json.dumps(value, ensure_ascii=True, separators=(",", ":")) + "\n").encode()
        if len(data) > 65536:
            raise QueueError("queue-request-too-large")
        while data:
            if not select.select([], [self.process.stdin], [], self.remaining())[1]:
                raise QueueError("queue-timeout")
            try:
                written = os.write(self.process.stdin.fileno(), data)
            except BlockingIOError:
                continue
            if not written:
                raise QueueError("queue-closed")
            data = data[written:]

    def receive(self):
        while b"\n" not in self.buffer:
            if not select.select([self.process.stdout], [], [], self.remaining())[0]:
                raise QueueError("queue-timeout")
            try:
                chunk = os.read(self.process.stdout.fileno(), 65536)
            except BlockingIOError:
                continue
            if not chunk:
                raise QueueError("queue-closed")
            self.buffer += chunk
            if len(self.buffer) > 2 * 1024 * 1024:
                raise QueueError("queue-response-too-large")
        line, self.buffer = self.buffer.split(b"\n", 1)
        value = json.loads(line)
        if not isinstance(value, dict):
            raise QueueError("queue-invalid-response")
        return value

    def call(self, method, params):
        if method not in METHODS:
            raise QueueError("queue-method-forbidden")
        self.identifier += 1
        identifier = self.identifier
        self.send({"id": identifier, "method": method, "params": params})
        for _ in range(256):
            value = self.receive()
            if "method" in value:
                if "id" in value:
                    self.send({"id": value["id"], "error": {"code": -32601, "message": "Unsupported request"}})
                continue
            if value.get("id") != identifier or "error" in value or not isinstance(value.get("result"), dict):
                raise QueueError("queue-rpc-failed")
            return value["result"]
        raise QueueError("queue-response-overflow")


def event_id(message, event_root):
    """An exact own prefix AND immutable private event proof define ownership."""
    if not isinstance(message, str) or not message.startswith(PREFIX):
        raise QueueError("not-coordination-notice")
    match = re.search(r"Evento ([0-9a-f]{64}); metadatos: "
                      + re.escape(str(event_root)) + r"/([0-9a-f]{64})\.json\.", message)
    if not match or match[1] != match[2] or event_root.resolve() != event_root:
        raise QueueError("invalid-coordination-proof")
    path = event_root / (match[1] + ".json")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        metadata = os.fstat(source.fileno())
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                or metadata.st_mode & 0o077 or metadata.st_size > 65536):
            raise QueueError("unsafe-coordination-proof")
        raw = source.read(65537)
    if len(raw) > 65536:
        raise QueueError("invalid-coordination-proof")
    event = json.loads(raw)
    if not isinstance(event, dict):
        raise QueueError("invalid-coordination-proof")
    identifier = event.pop("eventId", None)
    encoded = (json.dumps(event, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()
    if (identifier != match[1] or hashlib.sha256(encoded).hexdigest() != identifier
            or event.get("source") != "/tmp/coord5Sep.md" or event.get("identity") != "CODEX VPS"
            or event.get("version") != 1):
        raise QueueError("invalid-coordination-proof")
    return identifier


def own_item(item, event_root):
    try:
        content = item["input"]
        if len(content) != 1 or content[0].get("type") != "text":
            return False
        event_id(content[0]["text"], event_root)
        return True
    except (QueueError, OSError, ValueError, KeyError, TypeError, AttributeError):
        return False


def list_items(client, thread):
    items, cursors, cursor = [], set(), None
    for _ in range(10):
        result = client.call("thread/queue/list", {"threadId": thread, "limit": 100, "cursor": cursor})
        page = result.get("data")
        if not isinstance(page, list) or not all(isinstance(item, dict) and isinstance(item.get("id"), str) for item in page):
            raise QueueError("invalid-queue-list")
        items.extend(page)
        if len({item["id"] for item in items}) != len(items):
            raise QueueError("invalid-queue-list")
        cursor = result.get("nextCursor")
        if cursor is None:
            return items
        if not isinstance(cursor, str) or cursor in cursors:
            break
        cursors.add(cursor)
    raise QueueError("queue-pagination-limit")


def notify_command(argv, *, client_factory=QueueClient, event_root=EVENT_ROOT):
    """Return zero for queued/coalesced, never a claim that a model received it."""
    try:
        if len(argv) != 6 or argv[:3] != ["/usr/bin/codex", "queue", "--thread"] or argv[4] != "--message":
            raise QueueError("invalid-queue-command")
        thread, message = str(UUID(argv[3])), argv[5]
        identifier = event_id(message, event_root)
        content = [{"type": "text", "text": message, "text_elements": []}]
        with client_factory() as client:
            own = [item for item in list_items(client, thread) if own_item(item, event_root)]
            if own:
                # Queue API has no compare-and-swap: revalidate immediately before edits.
                first = next((item for item in list_items(client, thread) if item["id"] == own[0]["id"]), None)
                if first is None or not own_item(first, event_root):
                    raise QueueError("queue-changed")
                result = client.call("thread/queue/update", {"threadId": thread,
                    "queuedSubmissionId": first["id"], "input": content})
                expected_id = first["id"]
            else:
                result = client.call("thread/queue/add", {"threadId": thread, "input": content,
                    "clientUserMessageId": str(uuid5(NAMESPACE_URL, thread + ":coord:" + identifier))})
                expected_id = None
            accepted = result.get("queuedSubmission", {})
            if (not isinstance(accepted, dict) or not isinstance(accepted.get("id"), str)
                    or (expected_id is not None and accepted["id"] != expected_id)
                    or accepted.get("input") != content):
                raise QueueError("queue-not-confirmed")
            for duplicate in own[1:]:
                current = next((item for item in list_items(client, thread) if item["id"] == duplicate["id"]), None)
                if current is not None and own_item(current, event_root):
                    result = client.call("thread/queue/delete", {"threadId": thread, "queuedSubmissionId": current["id"]})
                    if type(result.get("deleted")) is not bool:
                        raise QueueError("queue-delete-unconfirmed")
        return 0
    except (QueueError, OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
        return 1
