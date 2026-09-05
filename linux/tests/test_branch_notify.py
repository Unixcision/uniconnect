"""Notification adapter tests; no real Codex messages or network access."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))
from uniconnect_branch_monitor import BranchMonitor, MonitorError, atomic_json, read_json
from uniconnect_branch_notify import queue_event
sys.path.pop(0)


class BranchNotificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "pending.json"
        self.archive = self.root / "events"
        self.thread = "00000000-0000-4000-8000-000000000001"
        snapshot = {"version": 1, "repository": "Unixcision/uniconnect",
                    "branches": {"desarrollo/multiplataforma": "a" * 40}, "ci": {}}
        self.event = BranchMonitor.event(None, snapshot)
        atomic_json(self.source, self.event)
        self.calls = []

    def runner(self, argv, **kwargs):
        self.calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, "Queued message", "")

    def send(self, runner=None):
        return queue_event(self.source, self.archive, self.thread, runner=runner or self.runner)

    def test_archived_event_survives_watcher_cleanup(self):
        self.assertEqual(self.send(), "queued")
        self.source.unlink()
        saved = self.archive / f"{self.event['eventId']}.json"
        self.assertEqual(read_json(saved), self.event)
        self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.archive.stat().st_mode & 0o777, 0o700)
        self.assertIn(str(saved), self.calls[0][-1])
        self.assertEqual(self.calls[0][:4], ["/usr/bin/codex", "queue", "--thread", self.thread])

    def test_delivered_event_is_not_queued_twice(self):
        self.send()
        self.assertEqual(self.send(), "already-queued")
        self.assertEqual(len(self.calls), 1)

    def test_failed_delivery_is_retryable(self):
        def unavailable(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 1)
        with self.assertRaisesRegex(MonitorError, "codex-queue-failed"):
            self.send(unavailable)
        self.assertFalse(list(self.archive.glob("*.queued.json")))
        self.assertEqual(self.send(), "queued")

    def test_timeout_is_retryable(self):
        def timeout(argv, **kwargs):
            raise subprocess.TimeoutExpired(argv, 45)
        with self.assertRaisesRegex(MonitorError, "codex-queue-unavailable"):
            self.send(timeout)
        self.assertEqual(self.send(), "queued")

    def test_tampered_event_does_not_invoke_codex(self):
        self.event["repository"] = "untrusted/other"
        atomic_json(self.source, self.event)
        with self.assertRaisesRegex(MonitorError, "invalid-notification-event"):
            self.send()
        self.assertFalse(self.calls)

    def test_invalid_thread_and_symlink_archive_are_rejected(self):
        with self.assertRaisesRegex(MonitorError, "invalid-notification-thread"):
            queue_event(self.source, self.archive, "not-a-uuid", runner=self.runner)
        self.archive.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(MonitorError, "unsafe-notification-directory"):
            self.send()
        self.assertFalse(self.calls)

    def test_archive_cannot_escape_private_event_directory(self):
        for archive in (self.root, self.root / "..", Path("/tmp/..")):
            with self.subTest(archive=archive), self.assertRaisesRegex(MonitorError, "unsafe-notification-directory"):
                queue_event(self.source, archive, self.thread, runner=self.runner)
        self.assertFalse(self.calls)


if __name__ == "__main__":
    unittest.main()
