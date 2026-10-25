"""Opt-in Antigravity hooks preserve user configuration and can be removed safely."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

from uniconnect.antigravity_integration import AntigravityIntegration, IntegrationError, MARKER, HOOK_KEY


class AntigravityIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uc-agy-integration-")
        self.home = Path(self.temporary.name)
        self.helper = self.home / "fixture-agent-hook.py"
        self.helper.write_text(Path(__file__).parents[1].joinpath("uniconnect/agent_identity_hook.py").read_text())
        self.integration = AntigravityIntegration(home=self.home, helper_source=self.helper)

    def tearDown(self):
        self.temporary.cleanup()

    def write_json(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    def test_enable_is_idempotent_and_preserves_other_settings_and_hooks(self):
        self.write_json(self.integration.hooks_path, {"user-hook": {"Stop": []}})
        self.write_json(self.integration.settings_path, {"model": "keep", "toolPermission": "ask"})
        self.integration.enable()
        first_hooks = json.loads(self.integration.hooks_path.read_text())
        first_settings = json.loads(self.integration.settings_path.read_text())
        self.integration.enable()
        self.assertEqual(json.loads(self.integration.hooks_path.read_text()), first_hooks)
        self.assertEqual(json.loads(self.integration.settings_path.read_text()), first_settings)
        self.assertEqual(first_hooks["user-hook"], {"Stop": []})
        self.assertEqual(first_settings["model"], "keep")
        self.assertEqual(first_settings["toolPermission"], "ask")
        self.assertEqual(set(first_hooks[HOOK_KEY]), {"SessionStart", "PreInvocation", "PostInvocation", "Stop"})
        self.assertTrue(all(MARKER in row["hooks"][0]["command"]
                            for rows in first_hooks[HOOK_KEY].values() for row in rows))
        self.assertIn(MARKER, first_settings["statusLine"]["command"])
        self.assertTrue(self.integration.status()["enabled"])

    def test_disable_removes_only_managed_entries_and_keeps_user_changes(self):
        self.integration.enable()
        hooks = json.loads(self.integration.hooks_path.read_text())
        hooks["user-added"] = {"PostToolUse": []}
        self.integration.hooks_path.write_text(json.dumps(hooks))
        settings = json.loads(self.integration.settings_path.read_text())
        settings["colorScheme"] = "keep"
        self.integration.settings_path.write_text(json.dumps(settings))
        result = self.integration.disable()
        self.assertFalse(result["enabled"])
        self.assertEqual(json.loads(self.integration.hooks_path.read_text()), {"user-added": {"PostToolUse": []}})
        self.assertEqual(json.loads(self.integration.settings_path.read_text()), {"colorScheme": "keep"})

    def test_user_statusline_conflict_fails_before_any_file_is_changed(self):
        self.write_json(self.integration.hooks_path, {"other": {"Stop": []}})
        self.write_json(self.integration.settings_path, {"statusLine": {"type": "command", "command": "my-line"}})
        original_hooks = self.integration.hooks_path.read_bytes()
        original_settings = self.integration.settings_path.read_bytes()
        with self.assertRaises(IntegrationError) as error:
            self.integration.enable()
        self.assertEqual(error.exception.args[0], "statusline_conflict")
        self.assertEqual(self.integration.hooks_path.read_bytes(), original_hooks)
        self.assertEqual(self.integration.settings_path.read_bytes(), original_settings)

    def test_hook_namespace_conflict_is_preserved_and_reported(self):
        self.write_json(self.integration.hooks_path, {HOOK_KEY: {"Stop": []}})
        with self.assertRaises(IntegrationError) as error:
            self.integration.enable()
        self.assertEqual(error.exception.args[0], "hook_name_conflict")
        self.assertEqual(json.loads(self.integration.hooks_path.read_text()), {HOOK_KEY: {"Stop": []}})

    def test_disable_preserves_a_statusline_changed_by_the_user(self):
        self.integration.enable()
        settings = json.loads(self.integration.settings_path.read_text())
        settings["statusLine"]["command"] = "custom-after-enable"
        self.integration.settings_path.write_text(json.dumps(settings))
        self.integration.disable()
        self.assertEqual(json.loads(self.integration.settings_path.read_text())["statusLine"]["command"],
                         "custom-after-enable")
        self.assertFalse(self.integration.status()["enabled"])

    def test_symlink_config_is_rejected(self):
        self.integration.hooks_path.parent.mkdir(parents=True, exist_ok=True)
        outside = self.home / "outside.json"
        outside.write_text("{}")
        self.integration.hooks_path.symlink_to(outside)
        with self.assertRaises(IntegrationError) as error:
            self.integration.enable()
        self.assertEqual(error.exception.args[0], "symlink_config_path")
        self.assertEqual(outside.read_text(), "{}")

    def test_second_file_race_rolls_back_only_our_first_write(self):
        self.write_json(self.integration.settings_path, {"model": "before"})
        write = self.integration._write

        def race(path, value, mode):
            if path == self.integration.settings_path:
                self.integration.settings_path.write_text('{"model":"concurrent"}')
                raise OSError("simulated concurrent writer")
            return write(path, value, mode)

        self.integration._write = race
        with self.assertRaises(OSError):
            self.integration.enable()
        self.assertFalse(self.integration.hooks_path.exists())
        self.assertEqual(self.integration.settings_path.read_text(), '{"model":"concurrent"}')

    def test_generated_statusline_command_runs_as_a_stdin_json_filter(self):
        command = self.integration._command("statusline")
        completed = subprocess.run(shlex.split(command), input=json.dumps({
            "conversation_id": "4a1ec7f2-126f-4e63-a347-92ab4576fdda",
            "agent_state": "idle", "model": {"display_name": "Gemini fixture", "effort": "high"},
            "pending_input_count": 0, "task_count": 0, "tool_confirmation_pending": False,
        }), text=True, capture_output=True, env={"PATH": os.environ["PATH"]}, timeout=5)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "idle · Gemini fixture · high · 4a1ec7f2")

    def test_uniconnect_cli_exposes_enable_status_disable_without_desktop_socket(self):
        env = dict(os.environ, HOME=str(self.home), PYTHONPATH=str(Path(__file__).parents[1]))
        for action, expected in (("enable", '"enabled": true'), ("status", '"hooks": true'),
                                 ("disable", '"enabled": false')):
            completed = subprocess.run([sys.executable, "-m", "uniconnect.cli", "antigravity-integration", action],
                                        env=env, text=True, capture_output=True, timeout=5)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn(expected, completed.stdout)


if __name__ == "__main__":
    unittest.main()
