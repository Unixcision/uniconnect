"""Runtime command parity and fail-closed resource tests; no provider is launched."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uniconnect.resume_catalog import AgentResumeCatalog
from uniconnect.transport import TmuxCommand, TransportError


class ResumeCatalogTests(unittest.TestCase):
    def test_existing_linux_launches_keep_cwd_model_and_do_not_add_permissions(self):
        cases = [
            ("codex", "chosen", ["codex", "resume", "SID", "-C", "/exact/root", "-m", "chosen"]),
            ("claude", "chosen", ["claude", "--resume", "SID", "--model", "chosen"]),
            ("grok", "chosen", ["grok", "-r", "SID", "--model", "chosen"]),
            ("agy", None, ["agy", "--conversation", "SID"]),
        ]
        for agent, model, expected in cases:
            with self.subTest(agent=agent):
                window = {"tmux": "fixture", "cwd": "/exact/root", "repo": "/metadata-only", "agent": agent,
                          "sessionId": "SID", "model": model}
                self.assertEqual(TmuxCommand.agent_argv(window), expected)
                window.pop("sessionId")
                self.assertEqual(TmuxCommand.agent_argv(window), [expected[0], *expected[3:]])
        with self.assertRaises(TransportError) as caught:
            TmuxCommand.agent_argv({"tmux": "fixture", "cwd": "/exact/root", "agent": "agy", "model": "unsupported"})
        self.assertEqual(caught.exception.code, "unsupported_agent_model")

    def test_argument_ordering_and_aliases_are_not_shell_interpolation(self):
        catalog = AgentResumeCatalog()
        arguments = ["--model", "name with spaces; $(must-not-run)"]
        self.assertEqual(catalog.resume_argv("amp", "SID", arguments), ["amp", "threads", "continue", *arguments, "SID"])
        self.assertEqual(catalog.resume_argv("hermes-agent", "SID", arguments), ["hermes", *arguments, "--resume", "SID"])
        self.assertEqual(catalog.resume_argv("agy", "SID"), catalog.resume_argv("antigravity", "SID"))

    def test_injected_catalogue_drives_transport_behavior(self):
        data = {"schemaVersion": 1, "providers": {"grok": {"executable": "fixture-grok",
                "resume": ["{executable}", "fixture-resume", "{arguments}", "{sessionId}"],
                "windowOptions": [{"field": "model", "option": "--fixture-model"}]}}}
        with tempfile.TemporaryDirectory(prefix="uc-resume-catalog-") as directory:
            resource = Path(directory) / "fixture.json"
            resource.write_text(json.dumps(data))
            catalog = AgentResumeCatalog(resource)
            with mock.patch("uniconnect.transport.AgentResumeCatalog", return_value=catalog):
                actual = TmuxCommand.agent_argv({"tmux": "fixture", "cwd": "/tmp", "agent": "grok", "sessionId": "SID", "model": "chosen"})
            self.assertEqual(actual, ["fixture-grok", "fixture-resume", "--fixture-model", "chosen", "SID"])

    def test_invalid_or_missing_catalogue_never_falls_back_to_duplicate_policy(self):
        for error in (FileNotFoundError("fixture"), ValueError("invalid_agent_catalog")):
            with mock.patch("uniconnect.transport.AgentResumeCatalog", side_effect=error):
                with self.assertRaises(TransportError) as caught:
                    TmuxCommand.agent_argv({"tmux": "fixture", "cwd": "/tmp", "agent": "codex", "sessionId": "SID"})
                self.assertEqual(caught.exception.code, "invalid_agent_catalog")
                self.assertEqual(TmuxCommand.agent_argv({"tmux": "fixture", "cwd": "/tmp", "agent": "terminal"}), [])

    def test_unknown_schema_rejected(self):
        with tempfile.TemporaryDirectory(prefix="uc-resume-catalog-") as directory:
            resource = Path(directory) / "fixture.json"
            resource.write_text(json.dumps({"schemaVersion": 99, "providers": {"future": {}}}))
            with self.assertRaises(ValueError):
                AgentResumeCatalog(resource)

    def test_checkout_resource_loads_through_symlink_from_unrelated_working_directory(self):
        with tempfile.TemporaryDirectory(prefix="uc-catalog-installed-") as directory:
            alias = Path(directory) / "checkout path with spaces"
            alias.symlink_to(Path(__file__).resolve().parents[1], target_is_directory=True)
            environment = dict(os.environ, PYTHONPATH=str(alias))
            script = ("import json; from uniconnect.transport import TmuxCommand; "
                      "print(json.dumps(TmuxCommand.agent_argv({'tmux':'fixture','cwd':'/exact/root',"
                      "'agent':'codex','sessionId':'SID'})))")
            process = subprocess.run([sys.executable, "-c", script], cwd=directory, env=environment,
                                     text=True, capture_output=True, timeout=10)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(json.loads(process.stdout), ["codex", "resume", "SID", "-C", "/exact/root"])


if __name__ == "__main__":
    unittest.main()
