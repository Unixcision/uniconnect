"""Native lifecycle regressions: long rollouts and newly resumed processes."""

from datetime import datetime, timezone
import io
import json
from pathlib import Path
import tempfile
import unittest

from uniconnect.relaunch_worker import TargetWorker, Unavailable


class CodexLifecycleMetadataTests(unittest.TestCase):
    identifier = "10000000-0000-4000-8000-000000000001"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        descriptors = root / "proc" / "20" / "fd"
        descriptors.mkdir(parents=True)
        self.rollout = root / ("rollout-fixture-" + self.identifier + ".jsonl")
        (descriptors / "3").symlink_to(self.rollout)
        self.worker = TargetWorker({"session": "fixture", "socket": "fixture"}, proc=root / "proc")
        self.worker.process_birth_bounds = lambda process: None
        self.process = {"pid": 20, "start": "123", "cwd": "/work",
                        "argv": ["/bin/codex", "--yolo", "-m", "model", "-c", 'model_reasoning_effort="high"']}

    @staticmethod
    def row(kind, payload, stamp=1):
        return {"type": kind, "timestamp": datetime.fromtimestamp(stamp, timezone.utc).isoformat(), "payload": payload}

    def context(self, turn="turn", stamp=1):
        return self.row("turn_context", {"turn_id": turn, "model": "model", "effort": "high", "cwd": "/work",
                        "approval_policy": "never", "sandbox_policy": {"type": "danger-full-access"}}, stamp)

    def event(self, kind, turn="turn", stamp=2, **extra):
        return self.row("event_msg", {"type": kind, "turn_id": turn, **extra}, stamp)

    def settings(self, stamp=101):
        return self.row("event_msg", {"type": "thread_settings_applied", "thread_settings": {
            "model": "model", "reasoning_effort": "high", "cwd": "/work", "approval_policy": "never",
            "permission_profile": {"type": "disabled"}}}, stamp)

    def write(self, rows):
        with self.rollout.open("wb") as handle:
            header = {"type": "session_meta", "payload": {"id": self.identifier}}
            for row in [header, *rows]:
                handle.write(json.dumps(row).encode() + b"\n")

    def configuration(self, rows, *, allow_active=False):
        self.write(rows)
        return self.worker.quiescent_configuration("codex", self.process, self.identifier, None,
                                                    allow_active=allow_active)

    def assert_unavailable(self, rows, *, cause="dialogo_desconocido", allow_active=False):
        with self.assertRaises(Unavailable) as error:
            self.configuration(rows, allow_active=allow_active)
        self.assertEqual(error.exception.cause, cause)

    def test_completed_context_is_found_beyond_the_previous_four_mib_tail(self):
        filler = self.row("response_item", {"type": "function_call_output", "output": "private-output-" * 640}, 2)
        rows = [self.context(), *([filler] * 640), self.event("task_complete", stamp=3)]
        result = self.configuration(rows)
        self.assertGreater(self.rollout.stat().st_size, 4 * 1024 * 1024)
        self.assertEqual(result["model"], "model")
        self.assertEqual(result["effort"], "high")
        with self.rollout.open("rb") as handle:
            handle.readline()
            metadata = self.worker.codex_turn_metadata(handle, handle.tell(), self.rollout.stat().st_size)
        self.assertEqual([row["type"] for row in metadata], ["turn_context", "instance_activity", "event_msg"])
        self.assertNotIn("private-output", json.dumps(metadata))

    def test_large_completion_record_is_not_discarded(self):
        completion = self.event("task_complete", last_agent_message="private-completion-" * 8192)
        self.assertGreater(len(json.dumps(completion)), 65536)
        self.assertEqual(self.configuration([self.context(), completion])["cwd"], "/work")

    def test_active_context_is_also_found_beyond_four_mib_without_inventing_a_completion(self):
        filler = self.row("response_item", {"type": "function_call_output", "output": "active-output-" * 640}, 3)
        user = self.row("response_item", {"type": "message", "role": "user", "content": []}, 2)
        rows = [self.context(), user, *([filler] * 640)]
        self.assert_unavailable(rows)
        self.assertEqual(self.configuration(rows, allow_active=True)["model"], "model")
        self.assertGreater(self.rollout.stat().st_size, 4 * 1024 * 1024)

    def test_new_input_after_completion_invalidates_idle_even_with_active_consent(self):
        for user in (self.event("user_message", stamp=3),
                     self.row("response_item", {"type": "message", "role": "user", "content": []}, 3)):
            for allow_active in (False, True):
                with self.subTest(kind=user["type"], allow_active=allow_active):
                    self.assert_unavailable([self.context(), self.event("task_complete"), user],
                                            allow_active=allow_active)

    def test_accepted_user_of_the_current_turn_is_not_a_draft(self):
        # Observed native order: turn_context, accepted response/user, output.
        # This proves a known active turn only; the UI draft guard is separate.
        for user in (self.event("user_message", stamp=2),
                     self.row("response_item", {"type": "message", "role": "user", "content": []}, 2)):
            with self.subTest(kind=user["type"]):
                rows = [self.context(), user, self.row("response_item", {"type": "function_call_output"}, 3)]
                self.assert_unavailable(rows)
                self.assertEqual(self.configuration(rows, allow_active=True)["model"], "model")
                for finish in ("task_complete", "turn_aborted"):
                    self.assertEqual(self.configuration([*rows, self.event(finish, stamp=4)])["model"], "model")

    def test_later_start_cannot_reuse_an_older_completion_or_context(self):
        rows = [self.context(), self.event("task_complete"), self.event("task_started", turn="next", stamp=3)]
        self.assert_unavailable(rows)
        self.assert_unavailable(rows, allow_active=True)

    def test_latest_context_cannot_borrow_completion_from_an_older_turn(self):
        rows = [self.context("old"), self.event("task_complete", "old"), self.context("new", 3)]
        self.assert_unavailable(rows)
        self.assertEqual(self.configuration(rows, allow_active=True)["model"], "model")
        self.assert_unavailable([*rows, self.event("task_complete", "old", 4)])
        self.assertEqual(self.configuration([*rows, self.event("task_complete", "new", 4)])["model"], "model")

    def test_most_recent_settings_determine_effective_configuration(self):
        old_settings = self.settings(3)
        old_settings["payload"]["thread_settings"]["model"] = "old-model"
        rows = [self.context(), self.event("task_complete"), old_settings, self.settings(4)]
        self.assertEqual(self.configuration(rows)["model"], "model")
        rows[-1]["payload"]["thread_settings"]["model"] = "changed-model"
        configuration = self.configuration(rows)
        self.assertEqual(configuration["model"], "changed-model")
        self.assertTrue(configuration["settings_applied"])

    def test_rollout_growth_during_retrospective_read_is_rejected(self):
        original = self.worker.codex_turn_metadata

        def append_after_read(handle, start, end):
            result = original(handle, start, end)
            with self.rollout.open("ab") as writer:
                writer.write(json.dumps(self.event("user_message", stamp=3)).encode() + b"\n")
            return result

        self.worker.codex_turn_metadata = append_after_read
        self.assert_unavailable([self.context(), self.event("task_complete")])

    def test_incomplete_or_malformed_last_record_is_not_ignored(self):
        for suffix in (b'{"type":', b'[]\n'):
            with self.subTest(suffix=suffix):
                data = b"\n".join(json.dumps(row).encode() for row in [self.context(), self.event("task_complete")])
                handle = io.BytesIO(data + b"\n" + suffix)
                with self.assertRaises(Unavailable) as error:
                    self.worker.codex_turn_metadata(handle, 0, len(handle.getvalue()))
                self.assertEqual(error.exception.cause, "no_soportado")

    def test_fresh_resume_settings_prove_idle_despite_an_unfinished_historical_turn(self):
        self.worker.process_birth_bounds = lambda process: (100.0, 100.02)
        historical = [self.context(stamp=90), self.row("response_item", {"type": "function_call_output"}, 95)]
        self.assertEqual(self.configuration([*historical, self.settings()])["model"], "model")
        self.assertEqual(self.configuration([self.settings()])["model"], "model")

    def test_old_or_ambiguous_settings_do_not_prove_a_fresh_resume(self):
        self.worker.process_birth_bounds = lambda process: (100.0, 100.02)
        for stamp in (99, 100, 100.01):
            with self.subTest(stamp=stamp):
                self.assert_unavailable([self.context(stamp=90), self.settings(stamp)])

    def test_active_consent_cannot_reuse_an_unfinished_turn_from_an_older_process(self):
        self.worker.process_birth_bounds = lambda process: (100.0, 100.02)
        for stamp in (90, 100.01):
            with self.subTest(stamp=stamp):
                self.assert_unavailable([self.context(stamp=stamp)], allow_active=True)
        rows = [self.context(stamp=101), self.row("response_item", {"role": "user", "type": "message"}, 102)]
        self.assertEqual(self.configuration(rows, allow_active=True)["model"], "model")
        self.assert_unavailable(rows)

    def test_current_native_activity_blocks_fresh_resume_before_and_after_settings(self):
        self.worker.process_birth_bounds = lambda process: (100.0, 100.02)
        for stamp in (100.03, 102):
            activity = [self.event("user_message", stamp=stamp),
                        self.row("response_item", {"role": "user", "type": "message"}, stamp),
                        self.event("task_started", stamp=stamp), self.context(stamp=stamp),
                        self.row("response_item", {"type": "function_call_output"}, stamp),
                        self.event("item_completed", stamp=stamp)]
            for row in activity:
                with self.subTest(stamp=stamp, kind=row["type"], event=row["payload"].get("type")):
                    current = [row, self.settings()] if stamp < 101 else [self.settings(), row]
                    self.assert_unavailable([self.context(stamp=90), *current])

    def test_fresh_resume_requires_complete_safe_effective_settings(self):
        self.worker.process_birth_bounds = lambda process: (100.0, 100.02)
        for field in ("model", "reasoning_effort", "cwd", "approval_policy", "permission_profile"):
            with self.subTest(field=field):
                settings = self.settings()
                settings["payload"]["thread_settings"].pop(field)
                self.assert_unavailable([self.context(stamp=90), settings], cause="no_soportado")
        settings = self.settings()
        settings["payload"]["thread_settings"]["permission_profile"] = {"type": "custom"}
        self.assert_unavailable([self.context(stamp=90), settings], cause="no_soportado")

    def test_missing_or_out_of_order_timestamps_cannot_prove_fresh_resume(self):
        self.worker.process_birth_bounds = lambda process: (100.0, 100.02)
        context = self.context(stamp=90)
        context.pop("timestamp")
        self.assert_unavailable([context, self.settings()])
        self.assert_unavailable([self.context(stamp=90), self.settings(),
                                 self.row("response_item", {"type": "function_call_output"}, 95)])


if __name__ == "__main__":
    unittest.main()
