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
                   "pending_input_count": 0, "tool_confirmation_pending": False, "task_count": 0,
                   "model": {"id": "gemini-fixture", "display_name": "Gemini fixture", "effort": "high"},
                   "sandbox": {"enabled": True},
                   "quota": {"weekly": {"remaining_fraction": 0}}}
        status = agy_status(payload, "statusline")
        self.assertEqual(status["state"], "idle")
        self.assertEqual(status["model"], "Gemini fixture")
        self.assertEqual(status["effort"], "high")
        self.assertEqual(status["pending_input_count"], 0)
        self.assertFalse(status["tool_confirmation_pending"])
        self.assertEqual(status["task_count"], 0)
        self.assertTrue(status["quota_paused"])

    def test_stop_hook_is_idle_only_when_fully_idle_without_error(self):
        self.assertEqual(agy_status({"fullyIdle": True, "error": ""}, "Stop")["state"], "idle")
        self.assertEqual(agy_status({"fullyIdle": False}, "Stop")["state"], "working")
        self.assertEqual(agy_status({"fullyIdle": True, "error": "provider error"}, "Stop")["state"], "error")

    def test_post_invocation_is_not_misclassified_as_idle(self):
        self.assertEqual(agy_status({}, "PostInvocation")["state"], "working")


if __name__ == "__main__":
    unittest.main()
