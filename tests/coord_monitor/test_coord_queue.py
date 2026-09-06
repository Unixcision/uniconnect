"""Queue tests use in-memory clients and private metadata fixtures, never Codex."""

import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools" / "coord_monitor"))
from uniconnect_coord_queue import PREFIX, QueueClient, QueueError, notify_command


class FakeClient:
    def __init__(self, queues, fail=None):
        self.queues, self.fail = queues, fail
        self.calls = []

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def call(self, method, params):
        self.calls.append((method, copy.deepcopy(params)))
        if method == self.fail:
            raise QueueError("injected-failure")
        queue = self.queues.setdefault(params["threadId"], [])
        if method == "thread/queue/list":
            return {"data": copy.deepcopy(queue), "nextCursor": None}
        if method == "thread/queue/add":
            UUID(params["clientUserMessageId"])
            item = {"id": "added", "clientUserMessageId": params["clientUserMessageId"], "input": params["input"]}
            queue.append(copy.deepcopy(item))
            return {"queuedSubmission": item}
        item = next(item for item in queue if item["id"] == params["queuedSubmissionId"])
        if method == "thread/queue/update":
            item["input"] = copy.deepcopy(params["input"])
            return {"queuedSubmission": copy.deepcopy(item)}
        if method == "thread/queue/delete":
            queue.remove(item)
            return {"deleted": True}
        raise AssertionError("forbidden RPC")


class CoordQueueTests(unittest.TestCase):
    thread = "11111111-2222-4333-8444-555555555555"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="uc-coord-queue-test-")
        self.addCleanup(self.temp.cleanup)
        self.events = Path(self.temp.name) / "events"
        self.events.mkdir(mode=0o700)

    def notice(self, sequence):
        event = {"version": 1, "identity": "CODEX VPS", "source": "/tmp/coord5Sep.md",
                 "sequence": sequence, "before": {}, "after": {"digest": str(sequence)}}
        raw = (json.dumps(event, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()
        identifier = hashlib.sha256(raw).hexdigest()
        path = self.events / (identifier + ".json")
        path.write_text(json.dumps({**event, "eventId": identifier}))
        path.chmod(0o600)
        return f"{PREFIX} vigilado por petición del usuario. Evento {identifier}; metadatos: {path}. Lee el documento."

    def item(self, identifier, text):
        return {"id": identifier, "input": [{"type": "text", "text": text, "text_elements": []}]}

    def notify(self, text, client):
        return notify_command(["/usr/bin/codex", "queue", "--thread", self.thread, "--message", text],
                              client_factory=lambda: client, event_root=self.events)

    def test_add_is_confirmed_without_starting_turn_and_retry_is_idempotent(self):
        message = self.notice(1)
        client = FakeClient({self.thread: []})
        self.assertEqual(0, self.notify(message, client))
        self.assertEqual(0, self.notify(message, client))
        self.assertEqual(1, len(client.queues[self.thread]))
        self.assertEqual(1, sum(method == "thread/queue/add" for method, _ in client.calls))
        self.assertTrue(all(method in {"thread/queue/list", "thread/queue/add", "thread/queue/update"}
                            for method, _ in client.calls))
        guard = QueueClient()
        for method in ("thread/queue/start", "thread/resume", "turn/start", "turn/steer"):
            with self.subTest(method=method), self.assertRaises(QueueError):
                guard.call(method, {})  # Rejected before any process or I/O.

    def test_coalesces_seven_own_notices_preserving_humans_other_threads_and_order(self):
        own = [self.item(f"own-{i}", self.notice(i)) for i in range(1, 8)]
        human_a, human_b = self.item("human-a", "Mensaje humano"), self.item("human-b", "Otro mensaje humano")
        branch = self.item("branch", "CODEX VPS. Monitor de ramas UniConnect, instalado por petición del usuario.")
        foreign = [self.item("foreign", self.notice(9))]
        queues = {self.thread: [human_a, own[0], human_b, *own[1:], branch], "other-thread": foreign}
        before_foreign = copy.deepcopy(foreign)
        client = FakeClient(queues)
        message = self.notice(10)
        self.assertEqual(0, self.notify(message, client))
        self.assertEqual(["human-a", "own-1", "human-b", "branch"], [item["id"] for item in queues[self.thread]])
        self.assertEqual(message, queues[self.thread][1]["input"][0]["text"])
        self.assertEqual(before_foreign, queues["other-thread"])
        self.assertEqual(human_a, queues[self.thread][0])
        self.assertEqual(human_b, queues[self.thread][2])
        self.assertTrue(all(params["threadId"] == self.thread for _, params in client.calls))

    def test_integrity_failures_preserve_unrelated_items_and_reject_invalid_incoming(self):
        valid = self.notice(1)
        corrupt = self.notice(2)
        path = Path(corrupt.split("metadatos: ")[1].split(". Lee")[0])
        payload = json.loads(path.read_text())
        payload["identity"] = "ANOTHER AGENT"
        path.write_text(json.dumps(payload))
        fake_prefix = self.item("forged", corrupt)
        client = FakeClient({self.thread: [copy.deepcopy(fake_prefix)]})
        self.assertEqual(1, self.notify(corrupt, client))
        self.assertEqual([], client.calls)
        self.assertEqual(0, self.notify(valid, client))
        self.assertEqual(fake_prefix, client.queues[self.thread][0])
        target = next(self.events.glob("*.json"))
        saved = target.read_bytes()
        target.unlink()
        target.symlink_to(self.events / "missing")
        client2 = FakeClient({self.thread: []})
        text = valid if target.name in valid else corrupt
        self.assertEqual(1, self.notify(text, client2))
        self.assertEqual([], client2.calls)

    def test_failed_update_never_deletes_and_failed_delete_keeps_latest_notice_retryable(self):
        one, two, latest = self.notice(1), self.notice(2), self.notice(3)
        original = [self.item("one", one), self.item("two", two), self.item("human", "Conservar")]
        for failure in ("thread/queue/list", "thread/queue/update", "thread/queue/delete"):
            with self.subTest(failure=failure):
                queues = {self.thread: copy.deepcopy(original)}
                client = FakeClient(queues, fail=failure)
                self.assertEqual(1, self.notify(latest, client))
                self.assertEqual(3, len(queues[self.thread]))
                if failure != "thread/queue/delete":
                    self.assertEqual(original, queues[self.thread])
                else:
                    self.assertEqual(latest, queues[self.thread][0]["input"][0]["text"])
                client.fail = None
                self.assertEqual(0, self.notify(latest, client))
                self.assertEqual(["one", "human"], [item["id"] for item in queues[self.thread]])


if __name__ == "__main__":
    unittest.main()
