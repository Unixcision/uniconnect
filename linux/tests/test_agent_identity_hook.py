"""Antigravity hook/statusline projections contain identity and state, never transcript text."""

import unittest

from uniconnect.agent_identity_hook import agy_status, native_id


class AntigravityMetadataTests(unittest.TestCase):
    identifier = "4a1ec7f2-126f-4e63-a347-92ab4576fdda"

    def test_hooks_provide_one_validated_conversation_id(self):
        for event in ("SessionStart", "PreInvocation", "PostInvocation", "Stop"):
            with self.subTest(event=event):
                self.assertEqual(native_id("agy", {"conversationId": self.identifier}, event), self.identifier)
        self.assertEqual(native_id("agy", {"conversationId": "bad id"}, "SessionStart"), None)
        self.assertEqual(native_id("agy", {"conversationId": self.identifier}, "unknown"), None)

    def test_statusline_snapshot_requires_explicit_idle_and_empty_queues(self):
        payload = {"conversation_id": self.identifier, "agent_state": "idle",
                   "version": "1.4.4",
                   "pending_input_count": 0, "tool_confirmation_pending": False, "task_count": 0,
                   "model": {"id": "gemini-fixture", "display_name": "Gemini fixture", "effort": "high"},
                   "cycle_mode": "plan",
                   "sandbox": {"enabled": True},
                   "quota": {"weekly": {"remaining_fraction": 0}}}
        status = agy_status(payload, "statusline")
        self.assertEqual(status["state"], "idle")
        self.assertEqual(status["model"], "Gemini fixture")
        self.assertEqual(status["model_id"], "gemini-fixture")
        self.assertEqual(status["effort"], "high")
        self.assertEqual(status["pending_input_count"], 0)
        self.assertFalse(status["tool_confirmation_pending"])
        self.assertEqual(status["task_count"], 0)
        self.assertTrue(status["sandbox_enabled"])
        self.assertEqual(status["cycle_mode"], "plan")
        self.assertEqual(status["version"], "1.4.4")
        self.assertTrue(status["quota_paused"])

    def test_missing_zero_counters_are_safe_but_mixed_quota_buckets_are_not_paused(self):
        payload = {"conversation_id": self.identifier, "agent_state": "idle", "version": "1.4.4",
                   "model": {"id": "gemini-fixture"}, "sandbox": {"enabled": False},
                   "quota": {"weekly": {"remaining_fraction": 0},
                             "fast": {"remaining_fraction": 0.5}}}
        status = agy_status(payload, "statusline")
        self.assertEqual(status["pending_input_count"], 0)
        self.assertEqual(status["task_count"], 0)
        self.assertIs(status["tool_confirmation_pending"], False)
        self.assertIs(status["quota_paused"], False)
        payload["quota"] = {"weekly": {"remaining_fraction": 0}, "fast": {"disabled": True}}
        self.assertIs(agy_status(payload, "statusline")["quota_paused"], True)

    def test_documented_human_readable_model_id_is_preserved_but_controls_are_rejected(self):
        payload = {"model": {"id": "Claude Sonnet 4.6 (Thinking)",
                             "display_name": "Claude Sonnet 4.6 (Thinking)"}}
        self.assertEqual(agy_status(payload, "statusline")["model_id"], "Claude Sonnet 4.6 (Thinking)")
        payload["model"]["id"] = "Gemini 4 Argon (Medium)\n--dangerous"
        self.assertIsNone(agy_status(payload, "statusline")["model_id"])

    def test_stop_hook_is_idle_only_when_fully_idle_without_error(self):
        self.assertEqual(agy_status({"fullyIdle": True, "error": ""}, "Stop")["state"], "idle")
        self.assertEqual(agy_status({"fullyIdle": False}, "Stop")["state"], "working")
        self.assertEqual(agy_status({"fullyIdle": True, "error": "provider error"}, "Stop")["state"], "error")

    def test_post_invocation_is_not_misclassified_as_idle(self):
        self.assertEqual(agy_status({}, "PostInvocation")["state"], "working")


if __name__ == "__main__":
    unittest.main()
