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


sys.path.insert(0, str(Path(__file__).resolve().parent))
from contracts_dir import contract

SUPERSEDES = [{"flag": "-a", "takesValue": True}, {"flag": "--ask-for-approval", "takesValue": True},
              {"flag": "-s", "takesValue": True}, {"flag": "--sandbox", "takesValue": True},
              {"flag": "--full-auto", "takesValue": False}]
NO_PROMPT_FIXTURE = {"schemaVersion": 1, "providers": {
    "claude": {"displayName": "Claude Code", "executable": "claude", "resume": ["{executable}", "--resume", "{sessionId}", "{arguments}"],
               "windowOptions": [{"field": "model", "option": "--model"}],
               "noPrompt": {"suffix": ["--dangerously-skip-permissions"], "rootEnvironment": {"IS_SANDBOX": "1"}}},
    "codex": {"displayName": "Codex", "executable": "codex", "resume": ["{executable}", "resume", "{sessionId}", "{arguments}"],
              "windowOptions": [{"field": "cwd", "option": "-C"}, {"field": "model", "option": "-m"}],
              "noPrompt": {"prefix": ["--yolo"], "legacy": ["--dangerously-bypass-approvals-and-sandbox"],
                           "supersedes": SUPERSEDES}},
    "grok": {"executable": "grok", "resume": ["{executable}", "-r", "{sessionId}", "{arguments}"]},
    "antigravity": {"aliases": ["agy"], "executable": "agy", "resume": ["{executable}", "--conversation", "{sessionId}", "{arguments}"],
                    "noPrompt": {"prefix": ["--dangerously-skip-permissions"]}}}}


def catalog_from(data):
    directory = tempfile.TemporaryDirectory(prefix="uc-resume-catalog-")
    resource = Path(directory.name) / "fixture.json"
    resource.write_text(json.dumps(data))
    try:
        return AgentResumeCatalog(resource)
    finally:
        directory.cleanup()


class ResumeCatalogTests(unittest.TestCase):
    def test_existing_linux_launches_keep_cwd_model_and_run_without_questions(self):
        # Decisión de Dani (24-09): siempre modo sin preguntas, con la política del catálogo compartido.
        cases = [
            ("codex", "chosen", ["codex", "--yolo", "resume", "SID", "-C", "/exact/root", "-m", "chosen"],
             ["codex", "--yolo", "-C", "/exact/root", "-m", "chosen"]),
            ("claude", "chosen", ["claude", "--resume", "SID", "--model", "chosen", "--dangerously-skip-permissions"],
             ["claude", "--model", "chosen", "--dangerously-skip-permissions"]),
            ("grok", "chosen", ["grok", "-r", "SID", "--model", "chosen"], ["grok", "--model", "chosen"]),
            ("agy", None, ["agy", "--dangerously-skip-permissions", "--conversation", "SID"],
             ["agy", "--dangerously-skip-permissions"]),
        ]
        for agent, model, expected, fresh in cases:
            with self.subTest(agent=agent):
                window = {"tmux": "fixture", "cwd": "/exact/root", "repo": "/metadata-only", "agent": agent,
                          "sessionId": "SID", "model": model}
                self.assertEqual(TmuxCommand.agent_argv(window), expected)
                window.pop("sessionId")
                self.assertEqual(TmuxCommand.agent_argv(window), fresh)

    def test_no_prompt_policy_is_applied_once_and_replaces_legacy_flags(self):
        catalog = catalog_from(NO_PROMPT_FIXTURE)
        self.assertEqual(catalog.apply_no_prompt("codex", ["codex", "--dangerously-bypass-approvals-and-sandbox", "--yolo",
                                                           "resume", "SID", "--yolo"]),
                         ["codex", "--yolo", "resume", "SID"])
        self.assertEqual(catalog.apply_no_prompt("claude", ["claude", "--dangerously-skip-permissions", "--resume", "SID"]),
                         ["claude", "--resume", "SID", "--dangerously-skip-permissions"])
        self.assertEqual(catalog.no_prompt_resume("claude", "SID", True),
                         (["claude", "--resume", "SID", "--dangerously-skip-permissions"], {"IS_SANDBOX": "1"}))
        self.assertEqual(catalog.no_prompt_resume("claude", "SID", False)[1], {})
        self.assertEqual(catalog.no_prompt_resume("codex", "SID", True), (["codex", "--yolo", "resume", "SID"], {}))
        self.assertEqual(catalog.no_prompt_resume("agy", "SID", False)[0], ["agy", "--dangerously-skip-permissions", "--conversation", "SID"])
        # Sin política (grok) se lanza sin banderas: no es un error.
        self.assertIsNone(catalog.no_prompt("grok"))
        self.assertEqual(catalog.no_prompt_resume("grok", "SID", True), (["grok", "-r", "SID"], {}))
        self.assertEqual(catalog.window_argv({"agent": "codex", "sessionId": "SID", "cwd": "/w", "model": "m"}),
                         ["codex", "--yolo", "resume", "SID", "-C", "/w", "-m", "m"])

    def test_supersedes_drops_approval_and_sandbox_with_their_values_in_every_form(self):
        # D2: Codex rechaza --yolo junto a -a/--ask-for-approval, -s/--sandbox y --full-auto.
        catalog = catalog_from(NO_PROMPT_FIXTURE)
        argv = ["codex", "resume", "SID", "-C", "/w", "-a", "never", "--sandbox", "workspace-write", "--full-auto",
                "--ask-for-approval=on-request", "-s=danger-full-access", "--yolo", "-m", "m"]
        expected = ["codex", "--yolo", "resume", "SID", "-C", "/w", "-m", "m"]
        self.assertEqual(catalog.apply_no_prompt("codex", argv), expected)
        self.assertEqual(catalog.apply_no_prompt("codex", expected), expected)  # Dos veces = una.
        # La forma corta pegada no se reconoce (el catálogo nunca la produce) y Claude no tiene supersedes.
        self.assertEqual(catalog.apply_no_prompt("codex", ["codex", "-anever"]), ["codex", "--yolo", "-anever"])
        self.assertEqual(catalog.apply_no_prompt("claude", ["claude", "-a", "x"]),
                         ["claude", "-a", "x", "--dangerously-skip-permissions"])
        self.assertEqual(AgentResumeCatalog.apply_policy(None, ["grok", "-r", "x"]), ["grok", "-r", "x"])

    def test_display_name_comes_from_the_catalogue(self):
        catalog = catalog_from(NO_PROMPT_FIXTURE)
        self.assertEqual((catalog.display_name("claude"), catalog.display_name("codex")), ("Claude Code", "Codex"))
        # Sin displayName (o proveedor desconocido) se enseña su id tal cual.
        self.assertEqual((catalog.display_name("grok"), catalog.display_name("agy"), catalog.display_name("otro")),
                         ("grok", "agy", "otro"))
        for name in ("", "  ", 3):
            with self.subTest(name=name):
                data = json.loads(json.dumps(NO_PROMPT_FIXTURE))
                data["providers"]["grok"]["displayName"] = name
                with self.assertRaises(ValueError):
                    catalog_from(data)

    def test_invalid_no_prompt_policy_rejects_the_catalogue(self):
        for policy in ({"prefix": "--yolo"}, {"prefix": ["yolo"]}, {"suffix": ["--a b"]}, {"unknown": []}, {},
                       {"rootEnvironment": {"is_sandbox": "1"}}, {"rootEnvironment": {"IS_SANDBOX": "$(id)"}},
                       {"prefix": ["--yolo", "--yolo"]}, ["--yolo"],
                       {"prefix": ["--yolo"], "supersedes": "-a"},
                       {"prefix": ["--yolo"], "supersedes": [{"flag": "a", "takesValue": True}]},
                       {"prefix": ["--yolo"], "supersedes": [{"flag": "-a", "takesValue": "sí"}]},
                       {"prefix": ["--yolo"], "supersedes": [{"flag": "-a"}]},
                       {"prefix": ["--yolo"], "supersedes": [{"flag": "-a", "takesValue": True, "extra": 1}]},
                       {"prefix": ["--yolo"], "supersedes": [{"flag": "-a", "takesValue": True}, {"flag": "-a", "takesValue": False}]},
                       {"prefix": ["--yolo"], "supersedes": [{"flag": "--yolo", "takesValue": False}]}):
            with self.subTest(policy=policy):
                data = json.loads(json.dumps(NO_PROMPT_FIXTURE))
                data["providers"]["codex"]["noPrompt"] = policy
                with self.assertRaises(ValueError) as caught:
                    catalog_from(data)
                self.assertEqual(str(caught.exception), "invalid_agent_catalog")
                with mock.patch("uniconnect.transport.AgentResumeCatalog", side_effect=caught.exception):
                    with self.assertRaises(TransportError) as failed:
                        TmuxCommand.agent_argv({"tmux": "fixture", "cwd": "/tmp", "agent": "codex", "sessionId": "SID"})
                    self.assertEqual(failed.exception.code, "invalid_agent_catalog")

    def test_shell_command_quotes_folder_always_and_tokens_only_when_needed(self):
        command = AgentResumeCatalog.shell_command(["claude", "--resume", "SID", "--model", "two words"],
                                                   {"IS_SANDBOX": "1"}, "/root/it's here")
        self.assertEqual(command, "cd -- '/root/it'\\''s here' && IS_SANDBOX=1 claude --resume SID --model 'two words'")
        self.assertEqual(AgentResumeCatalog.shell_command(["codex", "--yolo", "resume", "a@b%c_d+e=f:g,h./-i"], {}, "/x"),
                         "cd -- '/x' && codex --yolo resume a@b%c_d+e=f:g,h./-i")
        with self.assertRaises(ValueError):
            AgentResumeCatalog.shell_command(["claude"], {"IS_SANDBOX": "1; rm"}, "/x")

    def test_parity_with_shared_resume_commands(self):
        # contracts/agent-tree-v1/reanudar-comandos.json con el catálogo real, pasando sus arguments.
        data = json.loads(contract("agent-tree-v1", "reanudar-comandos.json").read_text(encoding="utf-8"))
        self.assertTrue(data["casos"])
        catalog = AgentResumeCatalog()
        for case in data["casos"]:
            with self.subTest(caso=case["nombre"]):
                argv, environment = catalog.no_prompt_resume(case["provider"], case["session_id"], case["as_root"],
                                                             case.get("arguments", []))
                self.assertEqual(argv, case["argv"])
                self.assertEqual(environment, case["environment"])
                self.assertEqual(AgentResumeCatalog.shell_command(argv, environment, case["cwd"]), case["command"])
                self.assertEqual(catalog.no_prompt(case["provider"]) is not None, case["no_prompt_verified"])
                self.assertEqual(catalog.display_name(case["provider"]), case["display_name"])
                self.assertEqual(catalog.apply_no_prompt(case["provider"], argv), argv)
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
            self.assertEqual(json.loads(process.stdout), ["codex", "--yolo", "resume", "SID", "-C", "/exact/root"])


if __name__ == "__main__":
    unittest.main()
