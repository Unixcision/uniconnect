"""Regression coverage for the real recovery-launcher and Codex idle UI."""

import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from uniconnect.relaunch_worker import TargetWorker, Unavailable


class RecoveryRelaunchTests(unittest.TestCase):
    def worker(self):
        return TargetWorker({"session": "fixture", "socket": "fixture", "provider": "codex"})

    def test_dim_placeholder_at_empty_cursor_is_not_a_draft(self):
        worker = self.worker()
        plain = "› Ask Codex to do anything"
        styled = "\x1b[1m›\x1b[0m \x1b[2mAsk Codex to do anything\x1b[0m"
        def tmux(*args):
            if args[0] == "display-message":
                return "2" if args[-1] == "#{cursor_x}" else "0"
            return styled if "-e" in args else plain
        worker.tmux = tmux
        worker.require_empty_composer({"pane": {"pane": "%1"}})
        for line, cursor in ((plain, 2), (styled, 6), (styled + " extra", 2)):
            with self.subTest(line=line, cursor=cursor):
                worker.tmux = lambda *a: (str(cursor) if a[-1] == "#{cursor_x}" else "0") if a[0] == "display-message" else (line if "-e" in a else plain)
                with self.assertRaises(Unavailable):
                    worker.require_empty_composer({"pane": {"pane": "%1"}})

    def test_resume_settings_supersede_old_turn_configuration_but_not_activity(self):
        process = {"cwd": "/work", "argv": ["codex", "resume", "id", "--yolo", "-m", "current", "-c", 'model_reasoning_effort="max"']}
        context = {"type": "turn_context", "payload": {"turn_id": "turn", "model": "old", "effort": "high", "cwd": "/work",
                   "approval_policy": "on-request", "sandbox_policy": {"type": "workspace-write"}}}
        complete = {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "turn"}}
        settings = {"type": "event_msg", "payload": {"type": "thread_settings_applied", "thread_settings": {
            "model": "current", "reasoning_effort": "max", "cwd": "/work", "approval_policy": "never",
            "permission_profile": {"type": "disabled"}}}}
        TargetWorker.validate_quiescence([context, complete, settings], process)
        TargetWorker.validate_quiescence([context, complete, settings], {**process, "argv": ["codex", "resume", "id", "--yolo"]})
        for rows in ([context, settings], [context, complete, settings, {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "next"}}]):
            with self.assertRaises(Unavailable):
                TargetWorker.validate_quiescence(rows, process)
        with self.assertRaises(Unavailable):
            TargetWorker.validate_quiescence([context, complete, settings], {**process, "argv": ["codex", "--yolo", "-m", "wrong"]})

    def test_only_pinned_recovery_with_same_conversation_and_arguments_is_admitted(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            script = home / "recovery.py"
            script.write_text("# reviewed recovery fixture\n")
            manifest = home / "manifest.json"
            entry = {"tmux": "fixture", "agent": "codex", "sessionId": "native", "cwd": directory,
                     "model": "m", "reasoningEffort": "max"}
            manifest.write_text(json.dumps({"tmuxSocket": "fixture", "windows": [entry]}))
            worker = self.worker()
            worker.request["recovery_sha256"] = hashlib.sha256(script.read_bytes()).hexdigest()
            root = {"argv": ["/usr/bin/python3", str(script), "--manifest", str(manifest), "launch", "fixture"]}
            process = {"cwd": directory, "argv": ["/bin/codex", "resume", "-C", directory, "-m", "m", "-c", 'model_reasoning_effort="max"',
                       "--dangerously-bypass-approvals-and-sandbox", "native"]}
            proof = worker.recovery_launcher(root, process, "native")
            self.assertEqual(proof["session_id"], "native")
            for mutation in ("id", "script", "arguments"):
                with self.subTest(mutation=mutation):
                    changed = dict(process)
                    if mutation == "id":
                        entry["sessionId"] = "stale"
                        manifest.write_text(json.dumps({"tmuxSocket": "fixture", "windows": [entry]}))
                    elif mutation == "script":
                        script.write_text("# unreviewed supervisor\n")
                    else:
                        changed["argv"] = [*process["argv"], "--search"]
                    with self.assertRaises(Unavailable):
                        worker.recovery_launcher(root, changed, "native")
                    entry["sessionId"] = "native"
                    manifest.write_text(json.dumps({"tmuxSocket": "fixture", "windows": [entry]}))
                    script.write_text("# reviewed recovery fixture\n")


if __name__ == "__main__":
    unittest.main()
