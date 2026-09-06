"""Isolated behavioral coverage; no real Codex queue or coordination document."""

import json
import multiprocessing
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools" / "coord_monitor"))

from uniconnect_coord_monitor import CoordMonitor, MonitorError, external_text


def unsafe_probe(source, root, thread, sender):
    """An owned process bounds the test even if opening a FIFO regresses."""
    try:
        result = CoordMonitor(Path(source), Path(root), thread, notifier=lambda argv: 0).once()
        sender.send(("returned", result))
    except BaseException as error:
        sender.send((type(error).__name__, str(error)))
    finally:
        sender.close()


class CoordMonitorTests(unittest.TestCase):
    thread = "11111111-2222-4333-8444-555555555555"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uc-coord-monitor-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "coord.md"
        self.root = self.directory / "monitor"
        self.notices = []
        self.returncodes = []
        self.monitor = self.new_monitor()

    def new_monitor(self):
        return CoordMonitor(self.source, self.root, self.thread, notifier=self.notify)

    def notify(self, argv):
        self.notices.append({
            "argv": list(argv),
            "pending": self.read_json("pending.json"),
            "snapshot": self.read_json("snapshot.json"),
        })
        return self.returncodes.pop(0) if self.returncodes else 0

    def read_json(self, name):
        path = self.root / name
        return json.loads(path.read_text()) if path.exists() else None

    def write_source(self, text):
        self.source.write_text(text, encoding="utf-8")
        self.source.chmod(0o600)

    def baseline(self, text="A\n"):
        self.write_source(text)
        self.assertEqual("baseline", self.monitor.once())
        self.assertEqual([], self.notices)
        return self.read_json("snapshot.json")

    def test_baseline_and_unchanged_never_notify(self):
        before = self.baseline()
        self.assertIsNotNone(before)
        self.assertIn("sequence", before)
        self.assertIn("digest", before["observation"])
        self.assertEqual("unchanged", self.monitor.once())
        self.assertEqual("unchanged", self.new_monitor().once())
        self.assertEqual(before, self.read_json("snapshot.json"))
        self.assertEqual([], self.notices)
        self.assertFalse((self.root / "pending.json").exists())

    def test_external_change_delivers_once_and_survives_monitor_restart(self):
        before = self.baseline()
        self.write_source("B\n")
        self.assertEqual("queued", self.monitor.once())
        self.assertEqual(1, len(self.notices))
        after = self.read_json("snapshot.json")
        self.assertGreater(after["sequence"], before["sequence"])
        self.assertNotEqual(after["observation"]["digest"], before["observation"]["digest"])
        self.assertEqual(before, self.notices[0]["snapshot"])
        self.assertEqual(
            ["/usr/bin/codex", "queue", "--thread", self.thread, "--message"],
            self.notices[0]["argv"][:-1],
        )
        identifier = self.notices[0]["pending"]["eventId"]
        self.assertEqual(self.notices[0]["pending"], self.read_json(f"events/{identifier}.json"))
        self.assertEqual({"eventId": identifier, "thread": self.thread},
                         self.read_json(f"events/{identifier}.queued.json"))
        self.assertFalse((self.root / "pending.json").exists())
        self.assertEqual("unchanged", self.new_monitor().once())
        self.assertEqual(1, len(self.notices))

    def test_own_section_edits_do_not_change_external_baseline(self):
        template = "# Otro equipo\nA\n<!-- CODEX VPS:BEGIN -->\n{}\n<!-- CODEX VPS:END -->\nFin externo\n"
        before = self.baseline(template.format("Inicial"))
        self.write_source(template.format("Actualización propia\nMás líneas"))
        self.assertEqual("unchanged", self.monitor.once())
        self.assertEqual([], self.notices)
        self.assertEqual(before, self.read_json("snapshot.json"))
        self.write_source(template.format("Actualización propia").replace("Fin externo", "Cambio externo"))
        self.assertEqual("queued", self.monitor.once())
        self.assertEqual(1, len(self.notices))

    def test_external_text_ignores_only_exact_own_markers(self):
        own = "Antes\n<!-- CODEX VPS:BEGIN -->\n{}\n<!-- CODEX VPS:END -->\nDespués\n"
        self.assertEqual(external_text(own.format("uno")), external_text(own.format("dos")))
        self.assertIn("Antes", external_text(own.format("uno")))
        self.assertIn("Después", external_text(own.format("uno")))
        for begin, end in (
            ("<!-- CODEX MAC:BEGIN -->", "<!-- CODEX MAC:END -->"),
            ("<!-- codex vps:begin -->", "<!-- codex vps:end -->"),
            ("<!--CODEX VPS:BEGIN-->", "<!--CODEX VPS:END-->"),
        ):
            with self.subTest(begin=begin):
                first = f"{begin}\nuno\n{end}\n"
                second = f"{begin}\ndos\n{end}\n"
                self.assertNotEqual(external_text(first), external_text(second))

    def test_appending_second_own_block_does_not_notify(self):
        first = "A\n<!-- CODEX VPS:BEGIN -->\nPrimera nota\n<!-- CODEX VPS:END -->\n"
        before = self.baseline(first)
        self.write_source(first + "\n<!-- CODEX VPS:BEGIN -->\nSegunda nota\n<!-- CODEX VPS:END -->\n")
        self.assertEqual("unchanged", self.new_monitor().once())
        self.assertEqual(before, self.read_json("snapshot.json"))
        self.assertEqual([], self.notices)

    def test_group_writable_shared_source_keeps_permissions(self):
        self.write_source("A\n")
        self.source.chmod(0o664)
        self.assertEqual("baseline", self.monitor.once())
        self.assertEqual(0o664, stat.S_IMODE(self.source.stat().st_mode))
        self.assertEqual("unchanged", self.monitor.once())
        self.source.write_text("B\n", encoding="utf-8")
        self.assertEqual("queued", self.monitor.once())
        self.assertEqual(1, len(self.notices))
        self.assertEqual(0o664, stat.S_IMODE(self.source.stat().st_mode))

    def test_repeated_a_to_b_transitions_are_distinct_events(self):
        self.baseline()
        for text in ("B\n", "A\n", "B\n"):
            self.write_source(text)
            self.assertEqual("queued", self.new_monitor().once())
        self.assertEqual(3, len(self.notices))
        self.assertEqual(3, len({notice["argv"][-1] for notice in self.notices}))
        self.assertEqual("unchanged", self.new_monitor().once())
        self.assertEqual(3, len(self.notices))

    def test_failed_delivery_retries_durable_event_without_advancing_snapshot(self):
        before = self.baseline()
        self.write_source("B\n")
        self.returncodes = [17, 0]
        with self.assertRaisesRegex(MonitorError, "notification-failed"):
            self.monitor.once()
        pending = self.read_json("pending.json")
        self.assertIsNotNone(pending)
        self.assertEqual(before, self.read_json("snapshot.json"))
        self.assertEqual("queued", self.new_monitor().once())
        self.assertEqual(2, len(self.notices))
        self.assertEqual(self.notices[0]["argv"], self.notices[1]["argv"])
        self.assertEqual(pending, self.notices[1]["pending"])
        self.assertEqual(pending["eventId"], self.notices[1]["pending"]["eventId"])
        self.assertEqual(before, self.notices[1]["snapshot"])
        self.assertFalse((self.root / "pending.json").exists())
        self.assertNotEqual(before["observation"]["digest"],
                            self.read_json("snapshot.json")["observation"]["digest"])
        self.assertEqual("unchanged", self.new_monitor().once())
        self.assertEqual(2, len(self.notices))

    def test_missing_initial_file_then_creation(self):
        self.assertFalse(self.source.exists())
        self.assertEqual("baseline", self.monitor.once())
        self.assertEqual("unchanged", self.new_monitor().once())
        self.assertEqual([], self.notices)
        self.write_source("A\n")
        self.assertEqual("queued", self.new_monitor().once())
        self.assertEqual(1, len(self.notices))

    def test_delete_and_recreate_identical_content_each_deliver(self):
        self.baseline()
        self.source.unlink()
        self.assertEqual("queued", self.new_monitor().once())
        self.assertEqual("unchanged", self.new_monitor().once())
        self.write_source("A\n")
        self.assertEqual("queued", self.new_monitor().once())
        self.assertEqual(2, len(self.notices))
        self.assertNotEqual(self.notices[0]["argv"], self.notices[1]["argv"])

    def assert_unsafe_source_rejected_promptly(self):
        context = multiprocessing.get_context("fork")
        receiver, sender = context.Pipe(duplex=False)
        process = context.Process(target=unsafe_probe, args=(str(self.source), str(self.root), self.thread, sender))
        process.start()
        sender.close()
        try:
            self.assertTrue(receiver.poll(2), "unsafe source blocked instead of being rejected")
            self.assertEqual(("MonitorError", "unsafe-coordination-file"), receiver.recv())
        finally:
            receiver.close()
            process.join(0.2)
            if process.is_alive():
                process.terminate()  # Only this test-owned diagnostic process.
                process.join(1)
            process.close()
        self.assertEqual([], self.notices)
        self.assertFalse((self.root / "snapshot.json").exists())

    def test_symlink_source_is_rejected_without_reading_target(self):
        target = self.directory / "unrelated.md"
        target.write_text("No debe consumirse", encoding="utf-8")
        self.source.symlink_to(target)
        self.assert_unsafe_source_rejected_promptly()
        self.assertEqual("No debe consumirse", target.read_text(encoding="utf-8"))

    def test_fifo_source_is_rejected_without_waiting_for_a_writer(self):
        os.mkfifo(self.source, 0o600)
        self.assert_unsafe_source_rejected_promptly()


if __name__ == "__main__":
    unittest.main()
