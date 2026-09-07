"""Behaviour of the recovery supervisor that does not need a live tmux or /proc."""
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

_SPEC = importlib.util.spec_from_file_location(
    "uniconnect_recovery", Path(__file__).resolve().parents[1] / "scripts/recovery.py"
)
recovery = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(recovery)


class NoPromptFlagsTest(unittest.TestCase):
    """Every recovered agent must come back without asking for permissions."""

    def test_claude_is_resumed_with_skip_permissions_and_its_id(self):
        with patch.object(recovery, "claude_executable", return_value="/usr/bin/claude"):
            argv = recovery.command_for({"agent": "claude", "sessionId": "abc", "cwd": "/tmp"})
        self.assertEqual(argv, ["/usr/bin/claude", "--dangerously-skip-permissions", "--resume", "abc"])

    def test_codex_is_resumed_bypassing_approvals_with_model_and_effort(self):
        with patch.object(recovery.shutil, "which", return_value="/usr/bin/codex"):
            argv = recovery.command_for({"agent": "codex", "sessionId": "t1", "cwd": "/w", "model": "m", "reasoningEffort": "max"})
        self.assertEqual(argv, ["/usr/bin/codex", "resume", "-C", "/w", "-m", "m", "-c", 'model_reasoning_effort="max"',
                                "--dangerously-bypass-approvals-and-sandbox", "t1"])

    def test_gemini_is_resumed_skipping_permissions(self):
        with patch.object(recovery.shutil, "which", return_value="/usr/bin/agy"):
            argv = recovery.command_for({"agent": "agy", "sessionId": "g1", "cwd": "/w"})
        self.assertEqual(argv, ["/usr/bin/agy", "--dangerously-skip-permissions", "--conversation", "g1"])

    def test_plain_commands_run_through_a_login_shell(self):
        self.assertEqual(recovery.command_for({"agent": "command", "command": "python bot.py", "cwd": "/w"}),
                         ["bash", "-lc", "python bot.py"])

    def test_claude_as_root_is_told_it_is_sandboxed(self):
        # Claude refuses its no-prompt flag as root unless IS_SANDBOX is set.
        with patch.object(recovery.os, "geteuid", return_value=0):
            self.assertEqual(recovery.environment_for({"agent": "claude"}).get("IS_SANDBOX"), "1")
        with patch.object(recovery.os, "geteuid", return_value=1000):
            env = recovery.environment_for({"agent": "claude"})
            self.assertEqual(env.get("IS_SANDBOX"), os.environ.get("IS_SANDBOX"))

    def test_claude_folder_is_trusted_ahead_of_the_launch(self):
        with tempfile.TemporaryDirectory() as home:
            config = Path(home) / ".claude.json"
            config.write_text(json.dumps({"projects": {}}))
            with patch.object(recovery.Path, "home", return_value=Path(home)):
                recovery.trust_folder_for_claude(home)
            self.assertTrue(json.loads(config.read_text())["projects"][os.path.realpath(home)]["hasTrustDialogAccepted"])


class ForgetOrRecreateTest(unittest.TestCase):
    """A window missing on purpose is forgotten; a crash or a reboot brings everything back."""

    def _data(self, boot, names=("a", "b")):
        return {"tmuxSocket": "s", "seen": {"bootId": boot, "sessions": list(names)},
                "windows": [{"tmux": n, "sessionId": n} for n in names]}

    def test_one_window_gone_on_the_same_boot_was_closed_by_hand(self):
        data = self._data("boot-1")
        with patch.object(recovery, "boot_id", return_value="boot-1"), \
             patch.object(recovery, "tmux", return_value=recovery.subprocess.CompletedProcess([], 0, "", "")):
            self.assertTrue(recovery.missing_is_deliberate(data, [data["windows"][0]]))

    def test_every_window_gone_means_the_server_died(self):
        data = self._data("boot-1")
        with patch.object(recovery, "boot_id", return_value="boot-1"), \
             patch.object(recovery, "tmux", return_value=recovery.subprocess.CompletedProcess([], 1, "", "")):
            self.assertFalse(recovery.missing_is_deliberate(data, data["windows"]))

    def test_a_new_boot_brings_everything_back(self):
        data = self._data("boot-1")
        with patch.object(recovery, "boot_id", return_value="boot-2"), \
             patch.object(recovery, "tmux", return_value=recovery.subprocess.CompletedProcess([], 0, "", "")):
            self.assertFalse(recovery.missing_is_deliberate(data, [data["windows"][0]]))


class SnapshotTest(unittest.TestCase):
    """The manifest learns the sessions that exist, so a window created later is protected too."""

    def test_learns_a_new_claude_session_from_its_process(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            data = {"tmuxSocket": "s", "windows": []}
            with patch.object(recovery, "live_sessions", return_value={"new": ("%1", 42, "/w", False)}), \
                 patch.object(recovery, "detect_agent", return_value=("claude", "id-1", {})), \
                 patch.object(recovery, "boot_id", return_value="boot-1"):
                recovery.snapshot(data, manifest)
            stored = json.loads(manifest.read_text())
            self.assertEqual([(w["tmux"], w["agent"], w["sessionId"], w["cwd"]) for w in stored["windows"]],
                             [("new", "claude", "id-1", "/w")])
            self.assertEqual(stored["seen"]["bootId"], "boot-1")


if __name__ == "__main__":
    unittest.main()
