"""Provisional launch must never fall back to a direct provider process."""

from types import SimpleNamespace
from unittest import TestCase, mock

from uniconnect.staged_terminal import StagedTerminal
from uniconnect.transport import TerminalLaunch, TransportError


class StagedLaunchPolicyTests(TestCase):
    def test_missing_tmux_never_prepares_or_runs_an_imported_command(self):
        owner = SimpleNamespace(readiness_token="a" * 32)
        for kind in ("local", "ssh"):
            with self.subTest(kind=kind), mock.patch("uniconnect.staged_terminal.TerminalSurface._build_launch") as prepare:
                with self.assertRaises(TransportError):
                    StagedTerminal._prepare(owner, {"kind": kind},
                                            {"agent": "custom", "commandArgv": ["fixture-must-not-execute"]},
                                            "ssh fixture@example.test" if kind == "ssh" else None, False)
                prepare.assert_not_called()

    def test_missing_ssh_connection_never_falls_back_to_local_preparation(self):
        owner = SimpleNamespace(readiness_token="b" * 32)
        with mock.patch("uniconnect.staged_terminal.TerminalSurface._build_launch") as prepare:
            with self.assertRaises(TransportError):
                StagedTerminal._prepare(owner, {"kind": "ssh"}, {"tmux": "fixture"}, None, False)
            prepare.assert_not_called()

    def test_provisional_ssh_cannot_wait_for_an_invisible_password_prompt(self):
        owner = SimpleNamespace(readiness_token="c" * 32)
        fixture = TerminalLaunch(["ssh", "fixture", "exec fixture-attach"], "/tmp", {})
        with mock.patch("uniconnect.staged_terminal.TerminalSurface._build_launch", return_value=(fixture, [])):
            launch, _ = StagedTerminal._prepare(owner, {"kind": "ssh"}, {"tmux": "fixture"},
                                               "ssh fixture@example.test", False)
        self.assertIn("BatchMode=yes", launch.argv)
        self.assertNotIn("BatchMode=no", launch.argv)
        self.assertTrue(launch.argv[-1].startswith("env UNICONNECT_ATTACH_TOKEN=" + owner.readiness_token + " "))
