"""Provider, fleet and isolated-process relaunch behavior; no real account used."""

import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

from uniconnect.relaunch_agents import RelaunchAgents, RelaunchUnavailable
from uniconnect.relaunch_fleet import RelaunchFleet
from uniconnect.relaunch_worker import TargetWorker, Unavailable, TmuxOutputEvents
from uniconnect.resume_catalog import AgentResumeCatalog
from uniconnect.transport import Transport, TransportError


class ArgumentsTests(unittest.TestCase):
    def setUp(self):
        self.catalog = AgentResumeCatalog().providers

    def test_replaces_effective_id_keeps_model_and_quoted_arguments_and_forces_no_prompt(self):
        # Decisión de Dani (24-09): se relanza siempre sin preguntas; --yolo sustituye a -s/-a.
        args = TargetWorker.resume_arguments("codex", ["/bin/codex", "resume", "-C", "/work with spaces",
            "-m", "model", "--sandbox", "workspace-write", "--ask-for-approval", "on-request", "old"], "current", self.catalog)
        self.assertEqual(args, ["/bin/codex", "--yolo", "resume", "current", "-C", "/work with spaces", "-m", "model",
                                "--no-alt-screen"])
        args = TargetWorker.resume_arguments("claude", ["/bin/claude", "--resume", "old", "--model", "model",
            "--permission-mode", "default", "--append-system-prompt", "x; $(not a shell command)"], "current", self.catalog)
        self.assertEqual(args, ["/bin/claude", "--resume", "current", "--model", "model", "--permission-mode", "default",
                                "--append-system-prompt", "x; $(not a shell command)", "--dangerously-skip-permissions"])

    def test_codex_resume_is_codex_yolo_resume_id_in_every_launch_form(self):
        for argv in (["codex", "resume", "old", "--yolo"], ["codex", "--yolo", "resume", "old"],
                     ["codex", "resume", "old", "--dangerously-bypass-approvals-and-sandbox"],
                     ["codex", "--full-auto"], ["codex", "-a", "never", "-s", "danger-full-access"]):
            with self.subTest(argv=argv):
                self.assertEqual(TargetWorker.resume_arguments("codex", argv, "current", self.catalog),
                                 ["codex", "--yolo", "resume", "current", "--no-alt-screen"])

    def test_codex_relaunch_keeps_inline_mode_once_across_repeated_relaunches(self):
        for options in ([], ["--no-alt-screen"], ["--no-alt-screen", "--search"]):
            with self.subTest(options=options):
                argv = ["codex", "--yolo", *options, "resume", "old", "-C", "/w", "-m", "model"]
                args = TargetWorker.resume_arguments("codex", argv, "current", self.catalog)
                self.assertEqual(args.count("--no-alt-screen"), 1)
                self.assertEqual(args.count("--yolo"), 1)
                self.assertEqual(TargetWorker.resume_arguments("codex", args, "current", self.catalog), args)
                self.assertEqual(args[args.index("-C") + 1], "/w")
                self.assertEqual(args[args.index("-m") + 1], "model")

    def test_codex_no_prompt_resume_does_not_widen_read_only_sandbox(self):
        restricted = {"sandbox_policy": {"type": "read-only"}, "approval_policy": "never"}
        with self.assertRaises(Unavailable) as error:
            TargetWorker.preserve_resume_permissions("codex", restricted, ["codex", "--yolo", "resume", "id"])
        self.assertEqual(error.exception.cause, "no_soportado")
        unrestricted = {"sandbox_policy": {"type": "danger-full-access"}, "approval_policy": "never"}
        TargetWorker.preserve_resume_permissions("codex", unrestricted, ["codex", "--yolo", "resume", "id"])

    def test_confirmed_active_target_can_finish_before_execution_but_cannot_change_identity(self):
        proof = {"key": "pane", "generation": 1, "effective_id": "native", "configuration": "same", "active": True}
        for changed in (False, True):
            with self.subTest(changed=changed):
                adapter = RelaunchAgents()
                current = {key: value for key, value in proof.items() if key != "active"}
                if changed:
                    current["effective_id"] = "different"
                adapter.probe = lambda *args: current
                calls = []
                adapter.request = lambda *args, **kwargs: calls.append((args, kwargs)) or {"state": "verificado", "effective_id": "native"}
                result = adapter.execute({}, "agent.relaunch", proof, "operation", lambda value: None, lambda: True)
                self.assertEqual(result["state"], "omitido" if changed else "verificado")
                self.assertEqual(len(calls), 0 if changed else 1)

    def test_worker_policy_matches_the_shared_catalogue_rule(self):
        catalog = AgentResumeCatalog()
        for provider, arguments in (("codex", ["-C", "/w", "-m", "m"]), ("claude", ["--model", "m"])):
            with self.subTest(provider=provider):
                expected = catalog.apply_no_prompt(provider, catalog.resume_argv(provider, "current", arguments))
                self.assertEqual(TargetWorker.no_prompt(provider, catalog.resume_argv(provider, "current", arguments),
                                                        catalog.providers), expected)
        # Sin noPrompt en el catálogo (petición antigua o proveedor sin política) no se añade nada.
        self.assertEqual(TargetWorker.no_prompt("codex", ["codex", "resume", "x"], {"codex": {}}), ["codex", "resume", "x"])

    def test_prompt_subcommand_and_unknown_option_are_not_replayed(self):
        for argv in (["codex", "exec", "fix"], ["codex", "resume", "old", "do anything"],
                     ["codex", "--unknown"], ["claude", "--print", "prompt"], ["claude", "--resume"]):
            with self.subTest(argv=argv), self.assertRaises(Unavailable):
                TargetWorker.resume_arguments(argv[0], argv, "current", self.catalog)

    def test_managed_notify_is_not_duplicated_and_user_configuration_is_retained(self):
        from uniconnect.agent_identity_hook import BOOTSTRAP
        hook = json.dumps(["/usr/bin/python3", "-c", BOOTSTRAP, "signal"])
        args = TargetWorker.resume_arguments("codex", ["codex", "resume", "old", "-c", "notify=" + hook,
            "-c", 'model_reasoning_effort="high"'], "current", self.catalog)
        self.assertEqual(args, ["codex", "--yolo", "resume", "current", "-c", 'model_reasoning_effort="high"',
                                "--no-alt-screen"])

    def test_antigravity_resume_preserves_validated_session_options_without_adding_permissions(self):
        identifier = "4a1ec7f2-126f-4e63-a347-92ab4576fdda"
        argv = ["/usr/bin/agy", "--conversation", identifier, "--model", "gemini-3-pro",
                "--effort", "high", "--mode", "accept-edits", "--sandbox", "--remote-control",
                "--project", "/work/project", "--agent", "reviewer", "--add-dir", "/work/shared"]
        self.assertEqual(TargetWorker.resume_arguments("agy", argv, identifier, self.catalog),
                         ["/usr/bin/agy", "--conversation", identifier, "--model", "gemini-3-pro",
                          "--effort", "high", "--mode", "accept-edits", "--sandbox", "--remote-control",
                          "--project", "/work/project", "--agent", "reviewer", "--add-dir", "/work/shared"])
        restricted = TargetWorker.resume_arguments("antigravity", argv, identifier, self.catalog)
        self.assertNotIn("--dangerously-skip-permissions", restricted)
        explicitly_permissive = TargetWorker.resume_arguments("agy", [*argv, "--dangerously-skip-permissions"],
                                                               identifier, self.catalog)
        self.assertEqual(explicitly_permissive[-1], "--dangerously-skip-permissions")
        self.assertEqual(TargetWorker.no_prompt("agy", ["agy", "--conversation", identifier], self.catalog),
                         ["agy", "--conversation", identifier])

    def test_antigravity_resume_rejects_ambiguous_identity_prompts_and_unknown_options(self):
        identifier = "4a1ec7f2-126f-4e63-a347-92ab4576fdda"
        for argv in (["agy", "--model", "m"],
                     ["agy", "--conversation", "other"],
                     ["agy", "--conversation", identifier, "--conversation", identifier],
                     ["agy", "--conversation", identifier, "--continue"],
                     ["agy", "--conversation", identifier, "--unknown", "x"],
                     ["agy", "--conversation", identifier, "do this task"],
                     ["agy", "--conversation", identifier, "--dangerously-skip-permissions",
                      "--dangerously-skip-permissions"]):
            with self.subTest(argv=argv), self.assertRaises(Unavailable):
                TargetWorker.resume_arguments("agy", argv, identifier, self.catalog)

    def test_unknown_provider_is_visible_but_does_not_issue_any_process_command(self):
        worker = TargetWorker({"session": "fixture", "socket": "fixture", "provider": "grok", "catalog": self.catalog})
        worker.pane = lambda: ({}, {}, "0", "")
        with self.assertRaises(Unavailable) as error:
            worker.inspect()
        self.assertEqual(error.exception.cause, "no_soportado")

    def test_window_without_agent_is_excluded_as_sin_ia_without_touching_the_host(self):
        calls = []
        adapter = RelaunchAgents(transport_factory=lambda *args, **kwargs: calls.append(args) or self.fail("sin SSH"))
        for provider in ("shell", "terminal", None):
            candidate = {"provider": provider, "connection": None, "record": {"id": "w", "tmux": "t"}}
            for verb in ("agent.relaunch", "agent.continue"):
                with self.subTest(provider=provider, verb=verb), self.assertRaises(RelaunchUnavailable) as error:
                    adapter.probe(candidate, verb)
                self.assertEqual(error.exception.cause, "sin_ia")
        self.assertEqual(calls, [])

    def test_footer_or_unknown_dialog_does_not_prove_an_empty_composer(self):
        worker = TargetWorker({"session": "fixture", "socket": "fixture"})
        for screen in ("some output\nbypass permissions", "❯ draft", "Do you trust this folder?\n❯ "):
            worker.tmux = lambda *args, screen=screen: (str(len(screen.splitlines()) - 1) if args[0] == "display-message" else screen)
            with self.assertRaises(Unavailable):
                worker.require_empty_composer({"pane": {"pane": "%1"}})

    def test_native_turn_activity_and_runtime_settings_are_required_before_exit(self):
        process = {"cwd": "/work", "argv": ["codex", "-m", "fixture-model", "-s", "read-only", "-a", "never"]}
        context = {"type": "turn_context", "payload": {"turn_id": "current-turn", "model": "fixture-model", "cwd": "/work",
                    "sandbox_policy": {"type": "read-only"}, "approval_policy": "never"}}
        complete = {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "current-turn"}}
        TargetWorker.validate_quiescence([context, complete], process)
        yolo_process = {**process, "argv": ["codex", "--yolo"]}
        yolo_context = {**context, "payload": {**context["payload"],
                                                "sandbox_policy": {"type": "danger-full-access"},
                                                "approval_policy": "never"}}
        TargetWorker.validate_quiescence([yolo_context, complete], yolo_process)
        for rows in ([context], [context, complete, {"type": "event_msg", "payload": {"type": "task_started"}}],
                     [context, {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "old-turn"}}],
                     [context, {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "new-turn"}}, complete],
                     [context, complete, {"type": "response_item", "payload": {"role": "user"}}],
                     [context, complete, {"type": "event_msg", "payload": {"type": "thread_settings_applied",
                         "thread_settings": {"model": "changed", "cwd": "/work", "approval_policy": "never"}}}]):
            with self.subTest(rows=rows), self.assertRaises(Unavailable):
                TargetWorker.validate_quiescence(rows, process)
        with self.assertRaises(Unavailable):
            TargetWorker.validate_quiescence([context, complete], {**process, "argv": ["codex"]})


class SharedPolicyTests(unittest.TestCase):
    """El trabajador usa la misma función que el escritorio y el catálogo que recibe (D2)."""

    def test_worker_has_no_policy_of_its_own(self):
        argv = ["codex", "resume", "x", "-a", "never", "--full-auto"]
        without = {"codex": {"noPrompt": {"prefix": ["--yolo"]}}}
        self.assertEqual(TargetWorker.no_prompt("codex", argv, without), ["codex", "--yolo", "resume", "x", "-a", "never", "--full-auto"])
        self.assertEqual(TargetWorker.no_prompt("codex", argv, AgentResumeCatalog().providers), ["codex", "--yolo", "resume", "x"])

    def test_self_contained_source_carries_the_catalogue_rule(self):
        # Lo que viaja por SSH: resume_catalog.py delante del trabajador, sin importar nada del paquete.
        source = RelaunchAgents.worker_source()
        payload = base64.b64encode(json.dumps({"action": "inspect", "session": "no valida", "socket": "x"}).encode()).decode()
        with tempfile.TemporaryDirectory(prefix="uc-worker-") as directory:
            result = subprocess.run([sys.executable, "-c", source, payload], cwd=directory, capture_output=True,
                                    text=True, timeout=30)
        self.assertEqual(result.stdout.strip(), 'UC_RELAUNCH_V1 {"error": "no_soportado"}', result.stderr)
        probe = source.replace('if __name__ == "__main__":', "if False:") + (
            "\nprint(json.dumps(TargetWorker.no_prompt('codex', ['codex', 'resume', 'x', '-s=read-only'], "
            "{'codex': {'noPrompt': {'prefix': ['--yolo'], 'supersedes': [{'flag': '-s', 'takesValue': True}]}}})))")
        result = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True, timeout=30)
        self.assertEqual(json.loads(result.stdout), ["codex", "--yolo", "resume", "x"], result.stderr)

    def test_announced_cells_are_exactly_the_linux_row_of_the_contract(self):
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from contracts_dir import contract
        from uniconnect.relaunch_agents import CAPABILITIES
        matrix = json.loads(contract("relaunch-v1", "proveedores.json").read_text(encoding="utf-8"))
        self.assertEqual(list(CAPABILITIES), matrix["capacidades"]["linux"])


class ClaudeDialectTests(unittest.TestCase):
    """D7 en Linux: identidad por la ficha de la raíz en idle, compositor vacío y /exit; nada vivo se toca."""

    SESSION = "473ed1de-4397-45ef-b00b-6b17fd7382b0"

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="uc-claude-dialect-")
        root = Path(self.directory.name)
        self.proc, self.config = root / "proc", root / "config"
        (self.config / "sessions").mkdir(parents=True)
        (self.proc / "4242").mkdir(parents=True)
        (self.proc / "4242" / "environ").write_bytes(b"HOME=/root\0CLAUDE_CONFIG_DIR=" + str(self.config).encode() + b"\0")
        self.worker = TargetWorker({"session": "fixture", "socket": "fixture", "provider": "claude",
                                    "catalog": AgentResumeCatalog().providers}, proc=self.proc)
        self.process = {"pid": 4242, "argv": ["claude", "--dangerously-skip-permissions"], "cwd": "/w"}

    def tearDown(self):
        self.directory.cleanup()

    def ficha(self, **values):
        data = {"pid": 4242, "sessionId": self.SESSION, "cwd": "/w", "status": "idle", **values}
        (self.config / "sessions" / "4242.json").write_text(json.dumps(data))

    def test_identity_only_from_its_own_ficha_and_only_when_idle(self):
        with self.assertRaises(Unavailable) as missing:
            self.worker.native_id("claude", self.process, "", {})
        self.assertEqual(missing.exception.cause, "identidad_ambigua")
        self.ficha()
        self.assertEqual(self.worker.native_id("claude", self.process, "", {}), self.SESSION)
        self.worker.quiescent_configuration("claude", self.process, self.SESSION, "")
        self.ficha(status="busy")
        with self.assertRaises(Unavailable) as busy:
            self.worker.quiescent_configuration("claude", self.process, self.SESSION, "")
        self.assertEqual(busy.exception.cause, "dialogo_desconocido")
        self.ficha(pid=999)  # Ficha copiada de otro proceso: no es la suya.
        with self.assertRaises(Unavailable) as foreign:
            self.worker.native_id("claude", self.process, "", {})
        self.assertEqual(foreign.exception.cause, "identidad_ambigua")

    def test_native_claude_is_recognised_by_name_or_versions_path(self):
        self.assertTrue(TargetWorker.is_provider("claude", ["claude"]))
        self.assertTrue(TargetWorker.is_provider("claude", ["/root/.local/share/claude/versions/2.1.280", "--resume", "x"]))
        self.assertFalse(TargetWorker.is_provider("claude", ["vim", "/root/.claude/CLAUDE.md"]))
        self.assertTrue(TargetWorker.is_provider("codex", ["/usr/bin/codex"]))

    def test_resume_keeps_window_options_and_forces_no_prompt_with_the_versions_executable(self):
        executable = "/root/.local/share/claude/versions/2.1.280"
        args = TargetWorker.resume_arguments("claude", [executable, "--resume", "old", "--model", "opus",
                                                        "--dangerously-skip-permissions"], self.SESSION, self.worker.request["catalog"])
        self.assertEqual(args, [executable, "--resume", self.SESSION, "--model", "opus", "--dangerously-skip-permissions"])

    def test_background_work_is_any_direct_child_but_an_mcp_server(self):
        # Dani: los monitores se guardan antes de cerrar, nunca se matan. Un Claude con una orden de
        # fondo o un monitor no se cierra; sus servidores MCP no cuentan como trabajo.
        self.assertTrue(TargetWorker.is_background_task(["/bin/bash", "-c", "tail -f /var/log/app.log"]))
        self.assertTrue(TargetWorker.is_background_task(["python3", "vigila.py"]))
        self.assertFalse(TargetWorker.is_background_task(["node", "/usr/lib/node_modules/@x/mcp-server-git/dist/index.js"]))
        self.assertFalse(TargetWorker.is_background_task(["python3", "-m", "chrome_mcp_server"]))

    def test_screen_reading_for_the_exit(self):
        screen = "Background work is running\n  1. Keep it running\n❯ 2. Exit and stop tasks\n"
        self.assertEqual(TargetWorker.claude_exit_option(screen), 2)
        self.assertIsNone(TargetWorker.claude_exit_option("Background work is running\n  Exit and stop tasks"))
        printed = "old " + "11111111-2222-4333-8444-555555555555\nResume this session with:\nclaude --resume " + self.SESSION
        self.assertEqual(TargetWorker.claude_printed_id(printed), self.SESSION)
        self.assertIsNone(TargetWorker.claude_printed_id("sin anuncio " + self.SESSION))

    def test_empty_claude_prompt_passes_and_folder_trust_is_left_to_a_person(self):
        for line in ("│ >                                          │", "> ", "❯ "):
            with self.subTest(line=line):
                self.worker.tmux = lambda *args, line=line: "1" if args[0] == "display-message" else "────\n" + line
                self.worker.require_empty_composer({"pane": {"pane": "%1"}})
        self.worker.tmux = lambda *args: ("1" if args[0] == "display-message"
                                          else "Do you trust the files in this folder?\n❯ 1. Yes, I trust this folder")
        with self.assertRaises(Unavailable) as trust:
            self.worker.require_empty_composer({"pane": {"pane": "%1"}})
        self.assertEqual(trust.exception.cause, "confianza_carpeta")


class AntigravityDialectTests(unittest.TestCase):
    SESSION = "4a1ec7f2-126f-4e63-a347-92ab4576fdda"

    def setUp(self):
        self.worker = TargetWorker({"session": "fixture", "socket": "fixture", "provider": "agy",
                                    "window_id": "window-1", "catalog": AgentResumeCatalog().providers})
        self.process = {"pid": 4242, "start": "555", "argv": ["agy", "--conversation", self.SESSION]}
        self.binding = {"version": 1, "window_id": "window-1", "agent": "agy", "generation": "a" * 32,
                        "tmux_pane": "%1", "pane_pid": 100, "tmux_session_id": "$1",
                        "agent_pid": 4242, "agent_start": "555", "session_id": self.SESSION,
                        "observed_at": time.time(), "runtime_status": {"state": "idle", "model": "Gemini",
                            "model_id": "gemini-fixture", "effort": "high", "pending_input_count": 0,
                            "tool_confirmation_pending": False, "task_count": 0, "sandbox_enabled": False,
                            "cycle_mode": "plan", "version": "1.2.17"}}
        self.hook = json.dumps(self.binding)

    def test_relaunch_requires_bound_idle_status_and_known_task_count_version(self):
        expected = {"model": "gemini-fixture", "effort": "high", "cycle_mode": "plan",
                    "sandbox_enabled": False, "version": "1.2.17"}
        with patch.object(TargetWorker, "process_birth_bounds", return_value=(0, 0)):
            self.assertEqual(self.worker.quiescent_configuration("agy", self.process, self.SESSION, self.hook), expected)
            for change, cause in (({"window_id": "other"}, "no_soportado"),
                                  ({"runtime_status": {**self.binding["runtime_status"], "version": "1.2.14"}}, "no_soportado"),
                                  ({"runtime_status": {**self.binding["runtime_status"], "state": "working"}}, "dialogo_desconocido"),
                                  ({"runtime_status": {**self.binding["runtime_status"], "task_count": 1}}, "dialogo_desconocido"),
                                  ({"runtime_status": {**self.binding["runtime_status"], "pending_input_count": 1}}, "dialogo_desconocido"),
                                  ({"runtime_status": {**self.binding["runtime_status"], "tool_confirmation_pending": True}}, "dialogo_desconocido")):
                value = {**self.binding, **change}
                with self.subTest(change=change), self.assertRaises(Unavailable) as error:
                    self.worker.quiescent_configuration("agy", self.process, self.SESSION, json.dumps(value))
                self.assertEqual(error.exception.cause, cause)
            stale = {**self.binding, "observed_at": time.time() - 30}
            with self.assertRaises(Unavailable) as error:
                self.worker.quiescent_configuration("agy", self.process, self.SESSION, json.dumps(stale))
            self.assertEqual(error.exception.cause, "no_soportado")

    def test_resume_reconstructs_native_model_effort_mode_and_sandbox_only(self):
        catalog = AgentResumeCatalog().providers
        argv = TargetWorker.resume_arguments("agy", ["/usr/bin/agy", "--conversation", self.SESSION,
            "--project", "/work"], self.SESSION, catalog)
        result = TargetWorker.preserve_antigravity_configuration(argv, {
            "model": "Gemini 4 Argon (Medium)", "effort": "high", "cycle_mode": "accept-edits",
            "sandbox_enabled": True})
        self.assertEqual(result, ["/usr/bin/agy", "--model", "Gemini 4 Argon (Medium)", "--effort", "high",
            "--mode", "accept-edits", "--sandbox", "--conversation", self.SESSION, "--project", "/work"])
        with self.assertRaises(Unavailable):
            TargetWorker.preserve_antigravity_configuration(["agy", "--sandbox", "--conversation", self.SESSION],
                {"model": "model", "effort": None, "cycle_mode": None, "sandbox_enabled": False})

    def test_binding_must_match_the_live_managed_pane_before_rewrapping(self):
        env = {"UNICONNECT_NATIVE_BINDING": json.dumps({key: self.binding[key] for key in
            ("version", "window_id", "agent", "generation", "tmux_pane", "pane_pid", "tmux_session_id", "agent_pid", "agent_start")})}
        pane = {"pane": "%1", "pane_pid": 100}
        self.assertTrue(self.worker.managed_antigravity(env, self.process, pane, self.hook))
        self.assertFalse(self.worker.managed_antigravity(env, self.process, {**pane, "pane": "%2"}, self.hook))


class FleetTests(unittest.TestCase):
    def test_global_freezes_local_and_remote_machine_plans_and_shows_partial_failures(self):
        calls = []
        def call(address, method, params):
            calls.append((address, method, params))
            if address == "100.64.0.3":
                raise ConnectionError()
            if method == "host.status":
                return {"machine_id": "remote", "capabilities": ["relaunch.v1"]}
            if method == "relaunch.plan":
                return {"operation_id": address, "token": "token", "targets": [
                    {"key": "shared-pane", "label": "IA", "provider": "codex", "generation": 1}], "excluded": []}
            return {"operation_state": "terminada", "results": [{"key": "shared-pane", "state": "verificado"}]}
        local = SimpleNamespace(machine_id="local", dispatch=lambda method, params: call("local", method, params))
        peers = [{"address": "100.64.0.2", "label": "Mac"}, {"address": "100.64.0.3", "label": "No disponible"}]
        fleet = RelaunchFleet(local, peers, call=call)
        plan = fleet.plan()
        peers.append({"address": "100.64.0.4", "label": "Nuevo"})
        self.assertEqual(len(plan["targets"]), 2)
        self.assertEqual(plan["excluded"], [{"label": "No disponible", "cause": "host_inaccesible"}])
        self.assertEqual([c[2]["scope"]["kind"] for c in calls if c[1] == "relaunch.plan"], ["machine", "machine"])
        result = fleet.operation("relaunch.apply")
        self.assertEqual(result["operation_state"], "terminada")
        self.assertFalse(any(c[0] == "100.64.0.4" for c in calls))

    def test_all_hosts_disconnected_is_unknown_not_a_finished_operation(self):
        local = SimpleNamespace(machine_id="local", dispatch=lambda *args: (_ for _ in ()).throw(ConnectionError()))
        fleet = RelaunchFleet.restore(local, [{"id": "local", "label": "Local", "plan": {
            "operation_id": "op", "targets": [{"key": "pane"}], "excluded": []}}])
        value = fleet.operation("relaunch.status")
        self.assertEqual(value["operation_state"], "en_curso")
        self.assertEqual(value["results"][0]["state"], "planificado")

    def test_configured_port_and_directory_endpoint_survive_receipt_recovery(self):
        calls = []
        local = SimpleNamespace(machine_id="local", dispatch=lambda method, params:
            {"operation_id": "local-op", "token": "token", "targets": [], "excluded": []})
        def call(address, method, params):
            calls.append((address, method, params))
            if method == "host.status":
                return {"machine_id": "remote", "capabilities": ["relaunch.v1"]}
            if method == "relaunch.plan":
                return {"operation_id": "remote-op", "token": "token", "targets": [], "excluded": []}
            return {"results": [], "operation_state": "terminada"}
        destination = {"host": "mac.tail123.ts.net", "port": 59001}
        fleet = RelaunchFleet(local, [{"id": "saved", "name": "Mac", **destination}], call=call)
        fleet.plan()
        self.assertEqual(calls[0][0], destination)
        host = fleet.hosts[1]
        restored = RelaunchFleet.restore(local, [{key: host[key] for key in ("id", "label", "endpoint", "plan")}], call=call)
        restored.operation("relaunch.status")
        self.assertEqual(calls[-1][0], destination)

    def test_removed_host_route_cannot_receive_apply_but_original_status_is_recoverable(self):
        calls = []
        local = SimpleNamespace(machines=SimpleNamespace(snapshot=lambda: []))
        host = {"id": "saved", "label": "Mac", "endpoint": {"host": "100.64.0.2", "port": 59001},
                "plan": {"operation_id": "op", "token": "token", "targets": [{"key": "pane"}], "excluded": []}}
        fleet = RelaunchFleet.restore(local, [host], call=lambda address, method, params:
            calls.append(method) or {"operation_state": "terminada", "results": []})
        value = fleet.operation("relaunch.apply")
        self.assertEqual(calls, [])
        self.assertEqual(value["results"][0]["cause"], "generacion_cambiada")
        fleet.operation("relaunch.status")
        self.assertEqual(calls, ["relaunch.status"])


class WorkerStatusTests(unittest.TestCase):
    def test_missing_journal_requires_user_and_seals_the_same_operation_against_late_start(self):
        import fcntl
        with tempfile.TemporaryDirectory(prefix="uc-relaunch-journal-") as directory:
            root = Path(directory)
            paths = root / "pane.lock", root / "claim.json", root / "operation.json"
            worker = TargetWorker({"action": "status", "session": "fixture", "socket": "fixture",
                                   "expected": {"generation": 1}})
            worker.paths = lambda: paths
            worker.inspect = lambda **kw: self.fail("status/late start must not inspect or close an agent")
            with paths[0].open("w") as lock:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                value = worker.dispatch()
                self.assertEqual(value["state"], "planificado")
                self.assertFalse(paths[2].exists())  # Never race the live owner.
            value = worker.dispatch()
            self.assertEqual(value, {"state": "necesita_usuario", "cause": "sin_autoridad"})
            self.assertEqual(worker.dispatch(), value)
            self.assertFalse(paths[1].exists())  # No generation consumed/released by an absent receipt.
            worker.request["action"] = "start"
            self.assertEqual(worker.dispatch(), value)  # A late request cannot close after a final response.


class RecoveryAndRevocationTests(unittest.TestCase):
    def setUp(self):
        self.candidate = {"provider": "codex", "connection": None,
                          "record": {"id": "window", "tmux": "fixture", "tmuxSocket": "fixture"}}
        self.proof = {"key": "pane", "generation": 1}

    def test_recover_verb_is_forwarded_to_the_idempotent_target_worker(self):
        adapter = RelaunchAgents()
        adapter.probe = lambda candidate, verb: self.proof
        calls = []
        def request(candidate, action, **values):
            calls.append((action, values))
            return {"state": "verificado"}
        adapter.request = request
        result = adapter.execute(self.candidate, "agent.recover", self.proof, str(uuid.uuid4()),
                                 lambda value: None, lambda: True)
        self.assertEqual(result["state"], "verificado")
        self.assertEqual(calls[0][0], "start")
        self.assertEqual(calls[0][1]["verb"], "agent.recover")

    def test_live_target_waiting_for_account_lock_is_not_reported_offline(self):
        clock = [0]
        adapter = RelaunchAgents(clock=lambda: clock[0], wait=lambda delay: clock.__setitem__(0, clock[0] + 50))
        adapter.request = lambda candidate, action, **kw: self.proof if action == "inspect" else {"state": "planificado"}
        result = adapter.execute(self.candidate, "agent.relaunch", self.proof, str(uuid.uuid4()), lambda result: None, lambda: True)
        self.assertEqual(result, {"state": "planificado"})

    def test_revocation_or_replacement_while_probe_is_pending_never_sends_start(self):
        for revoke in (True, False):
            allowed, current, calls = [True], [True], []
            adapter = RelaunchAgents(validate=lambda candidate: current[0])
            def request(candidate, action, **params):
                calls.append(action)
                if revoke:
                    allowed[0] = False
                else:
                    current[0] = False
                return self.proof
            adapter.request = request
            if revoke:
                with self.assertRaises(RelaunchUnavailable) as error:
                    adapter.execute(self.candidate, "agent.relaunch", self.proof, "operation", lambda r: None, lambda: allowed[0])
                self.assertEqual(error.exception.cause, "permisos")
            else:
                value = adapter.execute(self.candidate, "agent.relaunch", self.proof, "operation", lambda r: None, lambda: allowed[0])
                self.assertEqual(value["cause"], "generacion_cambiada")
            self.assertEqual(calls, ["inspect"])

    def test_lost_start_response_and_long_outage_recover_same_journal_without_another_start(self):
        for lose_start in (True, False):
            clock, starts, reachable, status_ids = [0], [], [False], []
            operation = str(uuid.uuid4())
            def run(command, **kwargs):
                request = json.loads(base64.b64decode(shlex.split(command)[-1]))
                action = request["action"]
                if action == "inspect":
                    value = self.proof
                elif action == "start":
                    starts.append(request["operation_id"])
                    if lose_start:
                        raise TransportError("connection_timeout")
                    value = {"state": "cerrando"}
                else:
                    status_ids.append(request["operation_id"])
                    if not reachable[0]:
                        raise TransportError("remote_command_failed")
                    value = {"state": "verificado", "effective_id": "same-conversation"}
                return SimpleNamespace(stdout="UC_RELAUNCH_V1 " + json.dumps(value))
            adapter = RelaunchAgents(transport_factory=lambda *a, **k: SimpleNamespace(run=run),
                resolve=lambda target: self.candidate, clock=lambda: clock[0],
                wait=lambda delay: clock.__setitem__(0, clock[0] + delay))
            value = adapter.execute(self.candidate, "agent.relaunch", self.proof, operation, lambda r: None, lambda: True)
            self.assertNotIn(value["state"], ("fallido", "necesita_usuario", "verificado"))
            with self.assertRaises(RelaunchUnavailable):
                adapter.recover({"proof": self.proof}, operation)
            reachable[0] = True
            self.assertEqual(adapter.recover({"proof": self.proof}, operation)["state"], "verificado")
            self.assertEqual(starts, [operation])
            self.assertEqual(set(status_ids), {operation})


PROVIDER = r'''
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <string.h>
static volatile sig_atomic_t stopped = 0;
static void stop(int ignored) { stopped = 1; }
static void draft(int ignored) { const char text[]="\033[2J\033[H› borrador"; write(1,text,sizeof(text)-1); }
static void clear(int ignored) { const char text[]="\033[2J\033[H› "; write(1,text,sizeof(text)-1); }
int main(int argc, char **argv) {
  const char *id = getenv("UC_FIXTURE_ID");
  int yolo = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "resume") && i + 1 < argc) id = argv[i + 1];
    if (!strcmp(argv[i], "--yolo")) yolo = 1;
  }
  char file[4096];
  if (yolo) {
    /* Like Codex: a --yolo resume records the settings it now runs with. */
    char path[4096], cwd[2048];
    snprintf(path, sizeof path, "%s/.codex/sessions/2026/09/14/rollout-fixture-%s.jsonl", getenv("UC_FIXTURE_ROOT"), id);
    FILE *rollout = getcwd(cwd, sizeof cwd) ? fopen(path, "a") : NULL;
    if (rollout) {
      fprintf(rollout, "{\"type\":\"event_msg\",\"payload\":{\"type\":\"thread_settings_applied\",\"thread_settings\":"
              "{\"permission_profile\":{\"type\":\"disabled\"},\"model\":\"fixture-model\",\"reasoning_effort\":null,"
              "\"cwd\":\"%s\",\"approval_policy\":\"never\"}}}\n", cwd);
      fclose(rollout);
    }
  }
  snprintf(file, sizeof file, "%s/.codex/thread-writer-locks/%s.lock", getenv("UC_FIXTURE_ROOT"), id);
  int fd = open(file, O_CREAT|O_RDWR, 0600);
  struct flock lock = {.l_type=F_WRLCK, .l_whence=SEEK_SET, .l_start=0, .l_len=0};
  if (fd < 0 || fcntl(fd, F_SETLK, &lock)) return 2;
  signal(SIGTERM, stop);
  signal(SIGUSR1, draft); signal(SIGUSR2, clear);
  printf("\033[2J\033[H› "); fflush(stdout);
  char input[128];
  while (!stopped) {
    if (fgets(input, sizeof input, stdin) && !strcmp(input, "/exit\n")) break;
  }
  close(fd);
  return 0;
}
'''


AGY_IDLE_FIXTURE = r'''
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    const char *statusline = getenv("UNICONNECT_AGY_TEST_STATUSLINE");
    if (statusline) {
        FILE *pipe = popen(statusline, "w");
        if (pipe) {
            fputs("{\"conversation_id\":\"4a1ec7f2-126f-4e63-a347-92ab4576fdda\",\"agent_state\":\"idle\",\"model\":{\"id\":\"gemini-fixture\",\"display_name\":\"Gemini fixture\",\"effort\":\"high\"},\"version\":\"1.2.17\",\"sandbox\":{\"enabled\":false},\"quota\":{}}", pipe);
            pclose(pipe);
        }
    }
    puts("Antigravity fixture");
    printf("\n❯ ");
    fflush(stdout);
    while (getchar() != EOF) {}
    return 0;
}
'''


@unittest.skipUnless(os.name == "posix" and Path("/proc").exists() and shutil.which("cc") and shutil.which("tmux"),
                     "Needs isolated Linux runner, C compiler and tmux")
class TargetIntegrationTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("tmux") and shutil.which("cc"),
                         "Linux tmux and C compiler required")
    def test_antigravity_closes_only_empty_idle_pane_and_reopens_same_conversation(self):
        from uniconnect.antigravity_integration import AntigravityIntegration
        from uniconnect.agent_identity_hook import BOOTSTRAP

        with tempfile.TemporaryDirectory(prefix="uc-relaunch-agy-") as directory:
            root = Path(directory)
            home = root / "home"
            home.mkdir()
            integration = AntigravityIntegration(home=home)
            integration.enable()
            executable = root / "agy"
            subprocess.run(["cc", "-x", "c", "-", "-o", str(executable)], input=AGY_IDLE_FIXTURE,
                           text=True, capture_output=True, check=True, timeout=30)
            socket_name = "uc-agy-" + uuid.uuid4().hex[:12]
            native = "4a1ec7f2-126f-4e63-a347-92ab4576fdda"
            statusline = shlex.split(json.loads(integration.settings_path.read_text())["statusLine"]["command"])
            statusline_command = shlex.join(statusline)
            env = dict(os.environ, HOME=str(home), UNICONNECT_AGY_TEST_STATUSLINE=statusline_command)
            subprocess.run(["tmux", "-L", socket_name, "new-session", "-d", "-s", "fixture", "-c", directory,
                            "/bin/bash", "--noprofile", "--norc", "-i"], check=True, capture_output=True,
                           timeout=5, env=env)
            helper = base64.b64encode(__import__("zlib").compress(
                Path(__file__).parents[1].joinpath("uniconnect/agent_identity_hook.py").read_bytes(), 9)).decode()
            request = json.dumps({"argv": [str(executable), "--conversation", native], "agent": "agy",
                                  "window_id": "fixture-window"})
            launcher = ("UNICONNECT_NATIVE_HELPER=" + shlex.quote(helper) + " "
                        + shlex.join(["python3", "-c", BOOTSTRAP, "launch", request]))
            subprocess.run(["tmux", "-L", socket_name, "send-keys", "-t", "=fixture:", "-l", launcher + "\n"],
                           check=True, capture_output=True, timeout=5)
            candidate = {"label": "Fixture · Antigravity", "provider": "agy", "connection": None,
                         "record": {"id": "fixture-window", "tmux": "fixture", "tmuxSocket": socket_name}}
            adapter = RelaunchAgents()
            with patch("uniconnect.relaunch_agents.RELAUNCHABLE", ("codex", "agy")):
                events = TmuxOutputEvents(["tmux", "-L", socket_name], "fixture")
                try:
                    deadline = time.monotonic() + 12
                    last_error = None
                    while True:
                        try:
                            proof = adapter.probe(candidate, "agent.relaunch")
                            break
                        except RelaunchUnavailable as error:
                            last_error = error.cause
                            if time.monotonic() >= deadline:
                                self.fail("Antigravity probe remained unavailable: " + str(last_error))
                            try:
                                events.wait(deadline, time.monotonic)
                            except Unavailable:
                                raw = subprocess.run(["tmux", "-L", socket_name, "show-options", "-p", "-v",
                                                      "-t", "=fixture:", "@uniconnect_native_identity"],
                                                     capture_output=True, text=True, timeout=5).stdout.strip()
                                try:
                                    snapshot = json.loads(raw)
                                    runtime = snapshot.get("runtime_status") or {}
                                    metadata = {key: runtime.get(key) for key in (
                                        "state", "version", "pending_input_count", "tool_confirmation_pending",
                                        "task_count", "model_id", "effort", "cycle_mode", "sandbox_enabled")}
                                    bound = snapshot.get("agent") == "agy" and snapshot.get("window_id") == "fixture-window"
                                except (ValueError, TypeError, AttributeError):
                                    metadata, bound = {}, False
                                stage = ["inspect"]
                                details = {}
                                worker = TargetWorker({"action": "inspect", "session": "fixture", "socket": socket_name,
                                    "provider": "agy", "window_id": "fixture-window",
                                    "catalog": AgentResumeCatalog().providers, "verb": "agent.relaunch"})
                                for name in ("pane", "process", "descendants", "native_id", "quiescent_configuration",
                                             "resume_arguments", "preserve_antigravity_configuration", "require_empty_composer"):
                                    original_method = getattr(worker, name)
                                    def trace_method(*args, _name=name, _original=original_method, **kwargs):
                                        stage[0] = _name
                                        if _name == "preserve_antigravity_configuration" and len(args) == 2:
                                            argv, configuration = args
                                            details["resume_flags"] = [token for token in argv[1:]
                                                if token.startswith("--") or token in ("high", "gemini-fixture")]
                                            details["configuration"] = {key: configuration.get(key) for key in
                                                ("model", "effort", "cycle_mode", "sandbox_enabled", "version")}
                                        return _original(*args, **kwargs)
                                    setattr(worker, name, trace_method)
                                try:
                                    worker.inspect()
                                    diagnostic = "direct inspect passed"
                                except Unavailable as error:
                                    diagnostic = "%s:%s" % (stage[0], error.cause)
                                self.fail("Antigravity probe unavailable (%s); %s; status=%r, identity_bound=%r, details=%r"
                                          % (last_error, diagnostic, metadata, bound, details))
                    result = adapter.execute(candidate, "agent.relaunch", proof, str(uuid.uuid4()),
                                             lambda _: None, lambda: True)
                    self.assertEqual(result, {"state": "verificado", "effective_id": native})
                    current = adapter.probe(candidate, "agent.relaunch")
                    self.assertEqual(current["pane"], proof["pane"])
                    self.assertNotEqual((current["pid"], current["start"]), (proof["pid"], proof["start"]))
                    self.assertEqual(current["effective_id"], native)
                    self.assertEqual(current["native_configuration"], proof["native_configuration"])
                finally:
                    events.close()
                    subprocess.run(["tmux", "-L", socket_name, "kill-server"], capture_output=True, timeout=5)

    def test_fresh_process_same_conversation_same_pane_and_duplicate_apply(self):
        with tempfile.TemporaryDirectory(prefix="uc-relaunch-runtime-") as directory:
            root = Path(directory)
            (root / ".codex/thread-writer-locks").mkdir(parents=True)
            executable = root / "codex"
            subprocess.run(["cc", "-x", "c", "-", "-o", str(executable)], input=PROVIDER,
                           text=True, capture_output=True, check=True, timeout=30)
            socket_name = "uc-relaunch-" + uuid.uuid4().hex[:12]
            native = str(uuid.uuid4())
            transcripts = root / ".codex/sessions/2026/09/14"
            transcripts.mkdir(parents=True)
            (transcripts / ("rollout-fixture-" + native + ".jsonl")).write_text("\n".join(json.dumps(row) for row in (
                {"type": "session_meta", "payload": {"id": native}},
                {"type": "turn_context", "payload": {"turn_id": "fixture-turn", "model": "fixture-model", "cwd": directory,
                    "sandbox_policy": {"type": "danger-full-access"}, "approval_policy": "never"}},
                {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "fixture-turn"}})) + "\n")
            transport = Transport(socket_name=socket_name)
            candidate = {"label": "Fixture · Codex", "provider": "codex", "connection": None,
                         "record": {"id": "fixture", "tmux": "fixture", "tmuxSocket": socket_name}}
            adapter = RelaunchAgents()
            subprocess.run(["tmux", "-L", socket_name, "new-session", "-d", "-s", "fixture", "-c", directory,
                            "/bin/bash", "--noprofile", "--norc", "-i"], check=True, capture_output=True, timeout=5)
            events = TmuxOutputEvents(["tmux", "-L", socket_name], "fixture")
            try:
                command = shlex.join(["env", "UC_FIXTURE_ID=" + native, "UC_FIXTURE_ROOT=" + directory,
                                      str(executable), "--yolo", "-m", "fixture-model"])
                subprocess.run(["tmux", "-L", socket_name, "send-keys", "-t", "=fixture:", "-l", command + "\n"],
                               check=True, capture_output=True, timeout=5)
                deadline = time.monotonic() + 8
                while True:
                    try:
                        proof = adapter.probe(candidate, "agent.relaunch")
                        break
                    except Exception:
                        self.assertLess(time.monotonic(), deadline)
                        events.wait(deadline, time.monotonic)
                operation = str(uuid.uuid4())
                phases = []
                import signal
                os.kill(proof["pid"], signal.SIGUSR1)
                def screen_until(predicate):
                    deadline = time.monotonic() + 5
                    while not predicate(subprocess.check_output(["tmux", "-L", socket_name, "capture-pane", "-p", "-t", "=fixture:"], text=True)):
                        events.wait(deadline, time.monotonic)
                screen_until(lambda screen: "› borrador" in screen)
                rejected = str(uuid.uuid4())
                draft_result = adapter.execute(candidate, "agent.relaunch", proof, rejected, phases.append, lambda: True)
                self.assertEqual(draft_result, {"state": "necesita_usuario", "cause": "dialogo_desconocido"})
                # Inspection itself must refuse to mint/refresh a proof while
                # the composer contains a draft; only the execute API converts
                # this safe preflight refusal into the user-facing state.
                with self.assertRaises(RelaunchUnavailable) as blocked:
                    adapter.probe(candidate, "agent.relaunch")
                self.assertEqual(blocked.exception.cause, "dialogo_desconocido")
                state = adapter.request(candidate, "start", expected=proof, operation_id=rejected)
                deadline = time.monotonic() + 5
                while state.get("state") == "planificado" and time.monotonic() < deadline:
                    events.wait(deadline, time.monotonic)
                    state = adapter.request(candidate, "status", expected=proof, operation_id=rejected)
                self.assertEqual(state, draft_result)
                os.kill(proof["pid"], signal.SIGUSR2)
                screen_until(lambda screen: screen.splitlines()[0].strip() == "›" and "borrador" not in screen)
                phases.clear()
                result = adapter.execute(candidate, "agent.relaunch", proof, operation, phases.append, lambda: True)
                self.assertEqual(result, {"state": "verificado", "effective_id": native})
                new = adapter.probe(candidate, "agent.relaunch")
                self.assertEqual(new["pane"], proof["pane"])
                self.assertNotEqual((new["pid"], new["start"]), (proof["pid"], proof["start"]))
                self.assertEqual(new["effective_id"], proof["effective_id"])
                self.assertEqual(adapter.request(candidate, "start", expected=proof, operation_id=operation), result)
                self.assertEqual(adapter.probe(candidate, "agent.relaunch"), new)
                another = adapter.request(candidate, "start", expected=proof, operation_id=str(uuid.uuid4()))
                self.assertEqual(another, {"state": "omitido", "cause": "duplicado"})
                self.assertTrue(all(p["state"] in ("planificado", "cerrando", "reabriendo", "verificado") for p in phases))
            finally:
                events.close()
                subprocess.run(["tmux", "-L", socket_name, "kill-server"], capture_output=True, timeout=5)
